# frozen_string_literal: true

module Reprise
  # A Rack app for development that reloads the app's code when it changes, before the next request:
  #
  #   # config.ru
  #   if ENV["RACK_ENV"] == "development"
  #     require "reprise/reloader"
  #     run Reprise::Reloader.new("App", loader:)
  #   else
  #     run App
  #   end
  #
  # +app+ is the app's constant name. +loader+ is a Zeitwerk loader with reloading enabled; everything it manages is
  # reloaded. An app Zeitwerk doesn't load, defined in files that are required (such as one class reopened across
  # several files), names them in +files+ (paths or globs, in the order to require them). Its constant is removed and
  # the files are required again:
  #
  #   run Reprise::Reloader.new("API", loader:, files: ["app.rb", "routes/*.rb"])
  #
  # Each request first checks whether a loaded file the loader manages, or one of +files+, has changed, or whether a
  # `.rb` file was added to or removed from their directories. If so, it waits for the requests in flight to finish (for
  # up to +wait+ seconds), holds new ones, reloads, and finalizes the new app. A reload that raises (a syntax error, say)
  # answers with the error, and is tried again with the next request.
  #
  # config.ru, its middleware, and code outside the loader and +files+ aren't reloaded. A response body that streams
  # after the app returns keeps running the code it started with.
  class Reloader
    def initialize(app, loader: nil, files: [], wait: 10)
      raise ArgumentError, "give a Zeitwerk loader, files, or both" if loader.nil? && files.empty?
      if loader.respond_to?(:reloading_enabled?) && !loader.reloading_enabled?
        raise ArgumentError, "enable reloading on the Zeitwerk loader (loader.enable_reloading) before its setup"
      end

      @app_name = app.to_s
      @loader = loader
      @patterns = files.map { File.expand_path(it) }
      @wait = wait
      @lock = Lock.new
      @failed = false
      @watch = Watch.new(loader)
      @watch.update(app_files)
      loader.on_load { |_cpath, _value, abspath| @watch.loaded(abspath) } if loader.respond_to?(:on_load)
    end

    def call(env)
      reload!(env) if @app.nil? || @failed || @watch.changed?
      @lock.shared { @app.call(env) }
    rescue ReloadError => error
      reload_failed(env, error.cause)
    end

    # Reloads the app if its code has changed (or the last reload failed), once the requests in flight have finished,
    # or loads it the first time. Raises ReloadError, with the error as its cause, if that raises.
    def reload!(env = {})
      on_timeout = -> { log(env, "Reloading with requests still in flight after #{@wait}s") }
      @lock.exclusive(timeout: @wait, on_timeout:) do
        if @failed || @watch.changed?
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          reload_app { unload }
          log(env, "Reloaded #{@app_name} in #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round}ms")
        elsif @app.nil?
          reload_app
        end
      end
    end

    # Raised by #reload!, with the error the app's code raised as its cause.
    class ReloadError < StandardError; end

    private

    # Loads the app, after the block unloads the old one, and finalizes it.
    def reload_app
      @app = nil
      files = app_files
      if block_given?
        yield
        files = app_files # Files may have been added or removed.
        files.each { require it }
      end
      app = Object.const_get(@app_name)
      app.finalize! if app.respond_to?(:finalize!)
      @watch.update(files)
      @failed = false
      @app = app
    rescue StandardError, ScriptError # ScriptError: a SyntaxError or LoadError in the app's code
      @app = nil
      @failed = true
      raise ReloadError, "Couldn't reload #{@app_name}"
    end

    def unload
      @watch.reset
      unload_files if @patterns.any?
      @loader&.reload
    end

    def app_files = @patterns.flat_map { Dir.glob(it).sort }.uniq

    # Removes the app's constant, and its files from $LOADED_FEATURES, so requiring them defines the app afresh.
    def unload_files
      *namespace, name = @app_name.split("::")
      owner = namespace.empty? ? Object : Object.const_get(namespace.join("::"))
      owner.send(:remove_const, name) if owner.const_defined?(name, false)

      files = app_files.to_set { File.realpath(it) }
      names = files.to_set { File.basename(it) }
      $LOADED_FEATURES.delete_if { names.include?(File.basename(it)) && files.include?(Watch.realpath(it)) }
    end

    def reload_failed(env, error)
      log(env, "Couldn't reload #{@app_name}: #{error.class}: #{error.message}")
      body = +"Couldn't reload #{@app_name}: #{error.class}\n\n#{error.message}\n\n"
      error.backtrace&.first(20)&.each { body << it << "\n" }
      [500, { "content-type" => "text/plain; charset=utf-8", "content-length" => body.bytesize.to_s }, [body]]
    end

    def log(env, message)
      (env["rack.errors"] || $stderr).puts("[Reprise::Reloader] #{message}")
    end

    # What the app's code was loaded from, and when each part last changed: the loaded files the loader manages (as each
    # loads) and the app's files, the loader's directories, and the app's files' directories (with their .rb files, so a
    # file that's added or removed counts, and an editor's swap file doesn't).
    class Watch
      def self.realpath(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def initialize(loader)
        @loader = loader
        @mutex = Thread::Mutex.new
        @files = {}
        @dirs = {}
      end

      def reset = @mutex.synchronize { @files.clear && @dirs.clear }

      # Adds the app's +files+, the loader's directories, and the files it manages that are already loaded (when it's
      # first created, say), to what's watched.
      def update(files)
        @mutex.synchronize do
          managed = managed_paths
          managed.each { track_dir(it) unless it.end_with?(".rb") }
          files.each { track(Watch.realpath(it)) }
          $LOADED_FEATURES.each do |feature|
            next unless feature.end_with?(".rb")

            path = Watch.realpath(feature)
            track(path) if managed.include?(path)
          end
        end
      end

      # A file or directory the loader has just loaded.
      def loaded(path)
        @mutex.synchronize { path.end_with?(".rb") ? track(Watch.realpath(path)) : track_dir(Watch.realpath(path)) }
      end

      def changed?
        @mutex.synchronize do
          @files.any? { |path, mtime| mtime(path) != mtime } ||
            @dirs.any? { |dir, (mtime, children)| mtime(dir) != mtime && rb_children(dir) != children }
        end
      end

      private

      def managed_paths
        return Set.new unless @loader.respond_to?(:all_expected_cpaths)

        @loader.all_expected_cpaths.keys.to_set { Watch.realpath(it) }
      end

      def track(path)
        @files[path] ||= mtime(path)
        track_dir(File.dirname(path))
      end

      def track_dir(dir)
        @dirs[dir] ||= [mtime(dir), rb_children(dir)]
      end

      def mtime(path)
        File.mtime(path)
      rescue SystemCallError
        nil
      end

      def rb_children(dir)
        Dir.children(dir).select { it.end_with?(".rb") }.sort
      rescue SystemCallError
        nil
      end
    end

    # Requests share it. A reload takes it exclusively once the requests in flight have finished (or +timeout+ has
    # passed), and holds new requests until it's done. Thread::Mutex and ConditionVariable work across fibers too.
    class Lock
      def initialize
        @mutex = Thread::Mutex.new
        @changed = Thread::ConditionVariable.new
        @shared = 0
        @exclusive = false
      end

      def shared
        @mutex.synchronize do
          @changed.wait(@mutex) while @exclusive
          @shared += 1
        end
        begin
          yield
        ensure
          @mutex.synchronize do
            @shared -= 1
            @changed.broadcast if @shared.zero?
          end
        end
      end

      def exclusive(timeout:, on_timeout:)
        @mutex.synchronize do
          @changed.wait(@mutex) while @exclusive
          @exclusive = true
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while @shared.positive?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break on_timeout.call if remaining <= 0

            @changed.wait(@mutex, remaining)
          end
        end
        begin
          yield
        ensure
          @mutex.synchronize do
            @exclusive = false
            @changed.broadcast
          end
        end
      end
    end
  end
end
