# frozen_string_literal: true

require "rack/builder"
require_relative "../reprised"

module Reprised
  # An app's configuration and boot, in one place, defined per environment, as a Rails application's is. It holds the
  # app's settings, the Rack middleware around it, its code loader, and what to do before forking workers, in each
  # worker, and at exit; config.ru and the server's preload become a line each:
  #
  #   # config/application.rb
  #   require "reprised/application"
  #
  #   class Application < Reprised::Application
  #     config.app = "App"                    # the Reprised::App to serve, by name (so the reloader can swap it)
  #     config.loader = LOADER                # a Zeitwerk loader, for eager loading and reloading
  #     config.static_cache_control = 3600    # the app's settings, as `set` would have them
  #     config.middleware.use Rack::Session::Cookie, secret: ENV.fetch("SESSION_SECRET")
  #     config.on_worker_start { Metrics.start }
  #   end
  #
  #   # config/environments/development.rb
  #   Application.configure do
  #     config.reload = true                  # Reprised::Reloader around the app
  #   end
  #
  #   # config/environments/production.rb
  #   Application.configure do
  #     config.eager_load = true
  #     config.middleware.use Rack::Deflater
  #   end
  #
  #   # config/environment.rb             # config.ru: require_relative "config/environment"
  #   require_relative "application"      #            Application.rackup(self)
  #   Application.boot!
  #
  # boot! loads config/environments/<environment>.rb (after config/application.rb, so it can change what that set up),
  # then eager loads the loader's code if eager_load is set. The app class is configured as it's defined, before its
  # class body runs, so `set` in the class still wins, and a reloaded app is configured afresh.
  #
  # It's optional: an app run from config.ru with `use` and `run` works as it always has.
  class Application
    # Raised when the app is defined before the application has booted, which would leave out its environment's
    # settings.
    class BootError < StandardError; end

    HOOKS = [:before_fork, :on_worker_start, :on_shutdown, :warmup].freeze

    class << self
      def inherited(subclass)
        super
        path = caller_locations(1, 1).first.path
        dir = File.dirname(File.expand_path(path))
        subclass.instance_variable_set(:@config, Config.new(root: File.basename(dir) == "config" ? File.dirname(dir) : dir))
        Reprised.application = subclass
      end

      def config = @config || raise(BootError, "configure a subclass of Reprised::Application")

      # Runs the block in the application, where `config` is the configuration: config/environments/*.rb use it.
      def configure(&) = class_exec(&)

      def env = config.environment
      def development? = env == :development
      def production? = env == :production
      def test? = env == :test

      # Loads config/environments/<environment>.rb, then eager loads the loader's code if eager_load is set. Once.
      def boot!
        return self if @booted

        path = File.join(config.root, "config", "environments", "#{env}.rb")
        require path if File.exist?(path)
        @booted = true
        config.loader.eager_load if config.eager_load && config.loader
        self
      end

      def booted? = @booted == true

      # The app class, config.app.
      def app_class
        raise BootError, "set config.app to the app's class name" unless config.app

        Object.const_get(config.app)
      end

      # What runs the app: the app class, or a Reprised::Reloader for it when config.reload is set.
      def rack_app
        return app_class unless config.reload

        require_relative "reloader"
        files = config.reload_files.map { File.expand_path(it, config.root) }
        Reloader.new(config.app, loader: config.loader, files:)
      end

      # Prepares the app in the server's parent process, before it forks workers: boots, runs the before_fork hooks,
      # finalizes the app (unless it's reloaded), then compacts the heap (Process.warmup) so workers share as much
      # memory as they can. For Falcon's preload file.
      def preload!
        boot!
        config.hooks(:before_fork).each(&:call)
        app_class.finalize! unless config.reload
        Process.warmup if config.process_warmup && Process.respond_to?(:warmup)
        self
      end

      # Builds the Rack stack in +builder+ (config.ru's self): runs the on_worker_start hooks (once a process), has the
      # on_shutdown hooks run at exit, registers the warmup hooks, and adds the middleware, the mounted apps, and the
      # app. With start_worker: false the hooks don't run, for a stack served outside a worker (a test server), where
      # the services they start have no event loop to run in.
      #
      #   # config.ru
      #   require_relative "config/environment"
      #   Application.rackup(self)
      def rackup(builder, start_worker: true)
        boot!
        start_worker! if start_worker
        warmups = config.hooks(:warmup)
        builder.warmup { |app| warmups.each { it.call(app) } } if warmups.any?
        config.middleware.each { |entry| builder.use(entry.resolve, *entry.args, **entry.options, &entry.block) }
        config.mounts.each { |path, app| builder.map(path) { run(app) } }
        builder.run(rack_app)
        builder
      end

      # The whole Rack stack, as config.ru would build it.
      def to_app(start_worker: true) = rackup(Rack::Builder.new, start_worker: start_worker).to_app

      # Gives the app being defined the configuration's settings, if it's config.app. Reprised::App calls it.
      def configure_app(app)
        return unless config.app && app.name == config.app
        unless booted?
          raise BootError, "#{app} was defined before #{self}.boot!, so it would miss config/environments/#{env}.rb"
        end

        config.apply(app)
      end

      private

      def start_worker!
        return if @worker_pid == Process.pid

        @worker_pid = Process.pid
        config.hooks(:on_worker_start).each(&:call)
        shutdown = config.hooks(:on_shutdown)
        return if shutdown.empty?

        at_exit do
          shutdown.each do |hook|
            hook.call
          rescue StandardError => error
            warn("[Reprised::Application] on_shutdown hook failed: #{error.class}: #{error.message}")
          end
        end
      end
    end

    # The configuration. Beside its own options, it takes the app's settings by name (`config.method_override = true`
    # is the app's `set :method_override, true`); a name that isn't a Reprised::App setting raises, to catch typos. A
    # setting the app defines itself is `config.set(:name, value)`, and configuration of your own goes in `config.x`.
    class Config
      # +app+:: the app's class name.
      # +root+:: the project's directory: config/application.rb's parent, by default. The app's root setting too.
      # +environment+:: APP_ENV or RACK_ENV (or :development), as a Symbol. The app's environment setting too.
      # +loader+:: a Zeitwerk loader (or anything with eager_load, and reload for the reloader).
      # +eager_load+:: whether boot! eager loads the loader's code.
      # +reload+:: whether the app runs inside a Reprised::Reloader.
      # +reload_files+:: for the reloader, the files (or globs, from root) that define an app the loader doesn't load.
      # +process_warmup+:: whether preload! calls Process.warmup (true).
      attr_accessor :root, :environment, :loader, :eager_load, :reload, :reload_files, :process_warmup
      attr_reader :app, :middleware, :mounts, :x

      def initialize(root:)
        @root = root
        @environment = (ENV["APP_ENV"] || ENV["RACK_ENV"] || "development").to_sym
        @eager_load = false
        @reload = false
        @reload_files = []
        @process_warmup = true
        @middleware = MiddlewareStack.new
        @mounts = []
        @x = Custom.new
        @settings = {}
        @hooks = HOOKS.to_h { [it, []] }
      end

      def app=(app)
        @app = app.is_a?(Module) ? app.name : app.to_s
      end

      # Serves +app+ under +path+, beside the app, inside the middleware: Rack::Builder's `map`.
      def mount(path, app) = @mounts << [path, app]

      # before_fork:: runs in preload!, in the parent process: work the workers should share.
      # on_worker_start:: runs in each worker as it builds the Rack stack: what starts threads, which don't survive a
      #                   fork.
      # on_shutdown:: runs at exit, in each worker, in the order defined.
      # warmup:: runs with the built Rack app once it's built (Rack::Builder's warmup).
      HOOKS.each do |hook|
        define_method(hook) do |&block|
          raise ArgumentError, "#{hook} takes a block" unless block

          @hooks[hook] << block
        end
      end

      def hooks(name) = @hooks.fetch(name).dup

      # Sets one of the app's settings, which needn't be one of Reprised::App's: `config.set(:cache_ttl, 60)`. A block
      # is a setting evaluated each time it's read, in the app.
      def set(name, value = nil, &block)
        @settings[name.to_sym] = block || value
      end

      # The app's settings, as they've been set here.
      def settings = @settings.dup

      def apply(app)
        app.set(:environment, environment)
        app.set(:root, root)
        @settings.each { |name, value| app.set(name, value) }
      end

      # A Reprised::App setting by name; any other name says what to use instead.
      def method_missing(name, *args, &)
        setting = name.to_s.delete_suffix("=").to_sym
        unless App.setting?(setting)
          raise NoMethodError.new(
            "#{setting} isn't a Reprised::App setting: config.set(:#{setting}, value) sets one the app defines, and " \
              "config.x.#{setting} is for configuration of your own", name, receiver: self
          )
        end

        if name.end_with?("=") && args.size == 1
          @settings[setting] = args.first
        elsif args.empty?
          @settings.fetch(setting) { App.public_send(setting) }
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        App.setting?(name.to_s.delete_suffix("=")) || super
      end
    end

    # The Rack middleware around the app, outermost first. A middleware is named by its class, or by its class's name,
    # as a String, for one that isn't loaded yet; the string is resolved when the stack is built.
    class MiddlewareStack
      include Enumerable

      Entry = Data.define(:middleware, :args, :options, :block) do
        def name = middleware.is_a?(Module) ? middleware.name : middleware.to_s
        def resolve = middleware.is_a?(Module) ? middleware : Object.const_get(middleware)
      end

      def initialize = @entries = []

      def initialize_copy(source)
        super
        @entries = @entries.dup
      end

      def use(middleware, *args, **options, &block) = tap { @entries << Entry.new(middleware, args, options, block) }
      def unshift(middleware, *args, **options, &block) = tap { @entries.unshift(Entry.new(middleware, args, options, block)) }

      def insert_before(target, middleware, *args, **options, &block)
        tap { @entries.insert(index!(target), Entry.new(middleware, args, options, block)) }
      end

      def insert_after(target, middleware, *args, **options, &block)
        tap { @entries.insert(index!(target) + 1, Entry.new(middleware, args, options, block)) }
      end

      # Replaces +target+ with another middleware, or the same with other arguments.
      def swap(target, middleware, *args, **options, &block)
        tap { @entries[index!(target)] = Entry.new(middleware, args, options, block) }
      end

      # Removes +target+, which must be in the stack.
      def delete(target) = tap { @entries.delete_at(index!(target)) }

      def include?(target) = !index(target).nil?
      def each(&) = @entries.each(&)
      def size = @entries.size
      def names = map(&:name)
      def inspect = "#<#{self.class} #{names.join(", ")}>"

      private

      def index(target)
        name = target.is_a?(Module) ? target.name : target.to_s
        @entries.index { it.name == name }
      end

      def index!(target)
        index(target) || raise(ArgumentError, "#{target} isn't in the middleware stack (#{names.join(", ")})")
      end
    end

    # config.x: configuration of the app's own, read as it's set (`config.x.page_max_age = 86_400`, then
    # `Application.config.x.page_max_age`, or `page_max_age?` for its truth). Reading one that isn't set raises, so a
    # typo, or an environment that leaves one out, shows.
    class Custom
      def initialize = @values = {}

      def to_h = @values.dup
      def key?(name) = @values.key?(name.to_sym)
      def inspect = "#<#{self.class} #{@values.inspect}>"

      def method_missing(name, *args)
        key = name.to_s
        if key.end_with?("=") && args.size == 1
          @values[key.delete_suffix("=").to_sym] = args.first
        elsif args.empty? && key.end_with?("?")
          !!fetch(key.delete_suffix("?"))
        elsif args.empty?
          fetch(key)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        name.end_with?("=") || key?(name.to_s.delete_suffix("?")) || super
      end

      private

      def fetch(key)
        @values.fetch(key.to_sym) do
          raise NoMethodError.new("config.x.#{key} isn't set: set it in config/application.rb or the environment's file",
            key.to_sym)
        end
      end
    end
  end
end
