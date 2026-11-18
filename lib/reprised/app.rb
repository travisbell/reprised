# frozen_string_literal: true

require "rack/head"

module Reprised
  # Raised by App.ractorize! with everything that keeps the app from being shared with other Ractors.
  class RactorError < StandardError; end

  # A Rack application. Subclass it, define routes or mount controllers, and `run` the class:
  #
  #   class App < Reprised::App
  #     helpers SessionHelpers          # global: the app's routes and every controller have these
  #     before { load_current_user }    # runs for every request
  #
  #     mount MovieController
  #     mount PersonController
  #
  #     get "/" do
  #       "home"
  #     end
  #   end
  #
  #   run App  # config.ru
  #
  # The first request finalizes the app: its definitions compile into frozen routers, and no more can be added.
  # Call App.finalize! at boot (before forking, or in Falcon's warmup) to do that up front.
  class App < Controller
    extend Templates::Lookup

    # What a request needs to know about the app, worked out once at finalize! so requests skip what the app doesn't
    # use:
    # +before+, +after+:: the filters' compiled blocks, when every filter of the type applies to every request (no path,
    #                     no conditions, the app's own); nil when some need matching, so the router runs them.
    # +status_handlers+:: whether any error handler is for a status, so a response's status needs looking up.
    # +scope_classes+:: the scope class for each owner of a route: the app for its own (and its ancestors'), else the
    #                   controller.
    # +use_code+, +dump_errors+, +x_cascade+, +raise_errors+:: those settings, read once (raise_errors and dump_errors
    #                                                      are Procs by default, evaluated on every read).
    Runtime = Data.define(
      :before, :after, :status_handlers, :sinatra_env, :scope_classes,
      :use_code, :dump_errors, :x_cascade, :raise_errors, :public_folder, :static_cache_control, :static_headers,
      :method_override, :show_exceptions, :show_exceptions_from, :editor, :root, :strict_paths, :csrf,
      :csrf_trusted_origins
    )

    FINALIZE_LOCK = Mutex.new
    FILTER_OVERLAP = [:warn, :raise, :ignore].freeze
    private_constant :FINALIZE_LOCK

    class << self
      # Controllers' restrictions don't apply to apps.
      define_method(:set, DSL.instance_method(:set))
      define_method(:use, DSL.instance_method(:use))
      def settings = self
      def app = self

      # An app being defined gets its settings from the Reprised::Application whose config.app it is, before its class
      # body runs (so `set` there wins).
      def inherited(subclass)
        super
        Reprised.application&.configure_app(subclass)
      end

      # Rack entry point.
      def call(env) = (@stack || finalize!.stack).call(env)

      # Mounts controllers at this point in the app's definitions: their routes and filters take this place in
      # definition order, as a Sinatra extension's do where it's registered.
      #
      # A module mounts every controller defined in it (its own constants, not those of modules inside it), in the
      # order of their names, apart from those named in +except+ (as Symbols, Strings, or the classes). Constants
      # Zeitwerk autoloads are loaded as they're found.
      #
      #   mount Controllers, except: [:DebugController]
      def mount(*controllers, except: [])
        ensure_definable!
        except = Array(except).to_set { it.is_a?(Module) ? it.name.split("::").last : it.to_s }
        names = Set.new
        controllers = controllers.flat_map { mountable(it, except, names) }
        unless (unknown = except - names).empty?
          raise ArgumentError, "except names no constant of the modules mounted: #{unknown.to_a.join(", ")}"
        end

        controllers.each do |controller|
          raise ArgumentError, "#{controller} is already mounted in #{self}" if self.controllers.include?(controller)

          controller.mounted_in(self)
          mount = Mount.new(controller:)
          [:routes, :before, :after].each { definitions(it) << mount }
          (@controllers ||= []) << controller
        end
      end

      def controllers = @controllers || []

      # The controllers +controller+ stands for: itself, or a module's (adding the module's constants to +names+).
      private def mountable(controller, except, names)
        if controller.is_a?(Class)
          raise ArgumentError, "#{controller} is an app; apps can't be mounted" if controller <= App
          raise ArgumentError, "#{controller.inspect} isn't a Reprised::Controller" unless controller < Controller

          return [controller]
        end
        raise ArgumentError, "#{controller.inspect} isn't a Reprised::Controller or a module of them" unless controller.is_a?(Module)

        found = controller.constants.sort.filter_map do |name|
          names << name.to_s
          next if except.include?(name.to_s)

          value = controller.const_get(name, false)
          value if value.is_a?(Class) && value < Controller && !(value <= App)
        end
        raise ArgumentError, "#{controller} has no controllers to mount" if found.empty?

        found
      end

      # Installs a plugin: a module with `install(app, **options)`, such as Reprised::Plugins::ActionView.
      def plugin(plugin, **options)
        ensure_definable!
        plugin.install(self, **options)
        (@plugins ||= []) << plugin
      end

      def plugins = @plugins || []

      # The global helpers module: the app compiles its routes, filters, and handlers into it, and every mounted
      # controller includes it. It includes its parent app's.
      def helpers_module
        @helpers_module ||= super.tap do |mod|
          mod.include(superclass.helpers_module) if superclass < App
        end
      end

      # Compiles definitions into frozen routers and builds the middleware stack. Safe to call more than once;
      # definitions are closed after the first call.
      def finalize!
        return self if @finalized

        FINALIZE_LOCK.synchronize do
          return self if @finalized

          share_helpers unless settings.helper_isolation
          @routes = compiled(:routes).freeze
          @filters = { before: compiled(:before).freeze, after: compiled(:after).freeze }.freeze
          @router = build_router(@routes) { |route| route.head ? [route.verb, "HEAD"] : route.verb }
          @filter_routers = @filters.transform_values { build_router(it) }.freeze
          @error_handlers = errors.transform_values { it.reverse.freeze }.freeze
          check_filter_overlap(@routes)
          @runtime = build_runtime
          precompile_views! if settings.precompile_templates?
          @stack = build_stack
          @finalized = true
        end
        self
      end

      def finalized? = @finalized == true

      # Makes the app shareable with other Ractors, so a server can run it in several (see Reprised::Ractors). Call it
      # once at boot, after every app is defined: it finalizes the app and freezes Rack's globals too. Raises
      # Reprised::RactorError with everything that can't be shared.
      def ractorize!
        require_relative "ractors"
        Ractors.ractorize!(self)
      end

      def ractorized? = @ractorized == true

      # The content-type header for +type+ (with no parameters), from the block the first time. Bounded, since the
      # type can come from a request.
      def content_type_for(type)
        cache = (@content_types ||= {})
        cache.fetch(type) do
          cache.clear if cache.size >= 256
          cache[type] = yield
        end
      end

      # Logs a server error, when dump_errors is on: by default to env["rack.errors"], as Sinatra does. Override it to
      # log elsewhere, or to skip errors that are expected.
      def dump_errors!(boom, env)
        message = boom.detailed_message(highlight: false)
        details = []
        if (match = message.match(/\A(.*?)(?: \(#{Regexp.quote(boom.class.to_s)}\))?\n/))
          details = match.post_match.lines(chomp: true)
          message = match[1]
        end
        env["rack.errors"]&.puts(["#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} - #{boom.class} - #{message}:", *details, *boom.backtrace].join("\n\t"))
      end

      # Reports a request the cross-origin check would have turned away, with `set :csrf, :report`: by default to
      # env["rack.errors"]. Override it to log elsewhere.
      def report_forged_request!(error, env)
        env["rack.errors"]&.puts("Reprised: would turn away #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}: #{error.message}")
      end

      # Every route, in the order they're tried: the app's own and its mounted controllers', with conditions compiled.
      # Finalizes the app. Used by `reprised routes` and for warming up.
      def routes = @routes || (finalize! && @routes)

      # Every before and after filter, in order, mounted controllers' included. Finalizes the app.
      def filters = @filters || (finalize! && @filters)

      attr_reader :stack

      def router = @router || (finalize! && @router)
      def runtime = @runtime || (finalize! && @runtime)
      def filter_router(type) = (@filter_routers || (finalize! && @filter_routers)).fetch(type)

      # Error handlers for +key+, newest first, from the nearest app class in the hierarchy that has any. Once
      # finalized, remembered per key: keys are exception classes and statuses, a finite set.
      def error_handlers(key)
        return find_error_handlers(key) unless @finalized

        lookup = (@error_lookup ||= {}.compare_by_identity)
        lookup.fetch(key) { lookup[key] = find_error_handlers(key) }
      end

      def find_error_handlers(key)
        own = (@error_handlers || errors).fetch(key, nil)
        return @error_handlers ? own : own.reverse.freeze if own
        return superclass.error_handlers(key) if superclass < App

        [].freeze
      end

      private

      def compile_target = helpers_module

      # The app's routes or filters of +kind+, mounted controllers' in their place, with options compiled into
      # conditions.
      def compiled(kind)
        definitions = definitions(kind).flat_map do |definition|
          next definition unless definition.is_a?(Mount)

          definition.controller.definitions(kind)
        end
        definitions.map do |definition|
          options = definition.owner.compile_conditions(definition.options, self)
          # With no options to compile, the definition is its own compiled form.
          next definition if options.empty?

          definition.with(conditions: (options + definition.conditions).freeze)
        end
      end

      # With helper_isolation off, every controller's `helpers` are global, as Sinatra's extensions' helpers are.
      def share_helpers
        controllers.each { helpers_module.include(it.helpers_module) }
      end

      def build_runtime
        show_exceptions = settings.show_exceptions
        show_exceptions = show_exceptions == :after_handler ? :after_handler : (show_exceptions ? true : false)
        if show_exceptions
          # Loaded, and the bindings captured, only where the page shows: in development.
          require_relative "exception_page"
          ExceptionPage.capture_bindings!
        end
        unconditional = ->(filters) do
          filters.map(&:action).freeze if filters.all? { it.path.nil? && it.conditions.empty? && it.owner <= App }
        end
        handlers = [self, *ancestors.select { it.is_a?(Class) && it < App }, *controllers]
        Runtime.new(
          before: unconditional.(@filters[:before]), after: unconditional.(@filters[:after]),
          status_handlers: handlers.any? { it.errors.each_key.any?(Integer) },
          sinatra_env: settings.sinatra_env ? true : false,
          scope_classes: @routes.to_h { [it.owner, it.owner <= App ? self : it.owner] }.compare_by_identity.freeze,
          use_code: settings.use_code? ? true : false, dump_errors: settings.dump_errors? ? true : false,
          x_cascade: settings.x_cascade? ? true : false, raise_errors: settings.raise_errors? ? true : false,
          # Worked out once, at boot, rather than checking the folder exists on each request as Sinatra does.
          public_folder: settings.static? && settings.public_folder ? File.expand_path(settings.public_folder).freeze : nil,
          static_cache_control: settings.static_cache_control || nil, static_headers: settings.static_headers || {},
          method_override: settings.method_override? ? true : false,
          show_exceptions:, show_exceptions_from: (ExceptionPage.ranges(settings.show_exceptions_from) if show_exceptions),
          editor: settings.editor, root: settings.root, strict_paths: settings.strict_paths? ? true : false,
          csrf: csrf_mode, csrf_trusted_origins: CSRF.normalize_origins(settings.csrf_trusted_origins)
        )
      end

      def csrf_mode
        mode = settings.csrf
        raise ArgumentError, "csrf must be one of #{CSRF::SETTINGS}, not #{mode.inspect}" unless CSRF::SETTINGS.include?(mode)

        mode || nil
      end

      def build_router(definitions)
        router = Router.new(matcher: settings.matcher, **settings.mustermann_opts)
        definitions.each do |definition|
          lanes = block_given? ? yield(definition) : :any
          Array(lanes).each { router.add(it, definition.path || Router::EVERY_PATH, definition) }
        end
        router.finalize!
      end

      # Warns (or raises, per the filter_overlap setting) when a controller's filter matches another controller's
      # route: scoped to its own controller, it won't run for that route, as it would have in Sinatra. Each of a route's
      # patterns is checked with sample values. A regexp route can't be, so it's checked only against filters with no
      # path (which match every request), and listed as unchecked if there are other controllers' filters with paths.
      # The report goes to $stderr whatever $VERBOSE is, since a filter that doesn't run may be an auth check.
      def check_filter_overlap(routes)
        mode = settings.filter_overlap
        raise ArgumentError, "filter_overlap must be one of #{FILTER_OVERLAP}" unless FILTER_OVERLAP.include?(mode)
        return if mode == :ignore

        # A filter marked overlap: :ok means to match other controllers' routes too.
        scoped = @filters.values.flatten.reject { it.owner <= App || it.overlap }
        # Only a controller's filters are scoped, so with none there's nothing to check (and nothing to expand).
        return if scoped.empty?

        overlaps = []
        unchecked = []
        routes.each do |route|
          patterns = Array(route.path)
          if patterns.any?(Regexp)
            overlaps.concat(scoped.select { it.path.nil? && it.owner != route.owner }.map { [it, route] })
            unchecked << route if scoped.any? { it.path && it.owner != route.owner }
          end
          patterns.grep(String).filter_map { sample_path(it) }.each do |path|
            @filter_routers.values.each do |filters|
              filters.each(:any, path) do |filter, _|
                overlaps << [filter, route] unless filter.owner <= App || filter.owner == route.owner || filter.overlap
              end
            end
          end
        end
        overlaps.uniq!
        return if overlaps.empty? && unchecked.empty?

        lines = overlaps.map do |filter, route|
          "#{filter} in #{filter.owner} (#{filter.source_location&.join(":")}) matches #{route} in #{route.owner} " \
            "(#{route.source_location&.join(":")}), but runs only for its own controller's routes"
        end
        lines.concat(unchecked.map do |route|
          "#{route} in #{route.owner} (#{route.source_location&.join(":")}) is a regexp route, so it wasn't checked " \
            "against other controllers' filters with paths"
        end)
        message = "Reprised: filters overlap other controllers' routes:\n  #{lines.join("\n  ")}"
        raise ArgumentError, message if mode == :raise && !overlaps.empty?

        $stderr.puts(message)
      end

      # A path +pattern+ matches, for checking which filters would apply to it, or nil if it can't be expanded.
      def sample_path(pattern)
        mustermann = Mustermann.new(pattern, **settings.mustermann_opts)
        mustermann.expand(:ignore, mustermann.names.to_h { [it, it == "splat" ? ["x"] * pattern.count("*") : "x"] })
      rescue Mustermann::Error, ArgumentError
        nil
      end

      def build_stack(shareable: false)
        # (HEAD bodies are dropped by Dispatch itself, rather than by Rack::Head.)
        owner = self
        app = shareable ? Ractor.shareable_lambda { |env| Dispatch.new(owner, env).call } : ->(env) { Dispatch.new(self, env).call }
        middleware.reverse_each { |klass, args, options, block| app = klass.new(app, *args, **options, &block) }
        app
      end
    end

    set :environment, (ENV["APP_ENV"] || ENV["RACK_ENV"] || :development).to_sym
    set :raise_errors, proc { test? }
    set :dump_errors, proc { !test? }
    set :use_code, false
    set :x_cascade, true
    set :default_encoding, "utf-8"
    set :default_content_type, "text/html"
    set :add_charset, ["application/javascript", "application/xml", "application/xhtml+xml", %r{^text/}]
    set :absolute_redirects, true
    # Files in the public folder are served ahead of the routes, for GET and HEAD, as in Sinatra.
    set :public_folder, proc { root && File.join(root, "public") }
    set :static, proc { public_folder && File.exist?(public_folder) }
    set :static_cache_control, false
    set :static_headers, {}
    # In development, a 5xx's exception gets the exception page (Reprised::ExceptionPage) rather than the error handlers,
    # for requests from these addresses. :after_handler shows it only when no handler answers.
    set :show_exceptions, proc { development? }
    set :show_exceptions_from, ["127.0.0.0/8", "::1/128"]
    # The exception page's links to files: :vscode, :cursor, :zed, :rubymine, :textmate, :sublime, :macvim, or a URL
    # template with %{file} and %{line}.
    set :editor, nil
    # A POST's _method form param (or X-HTTP-Method-Override header) names the method the routes see, as in Sinatra.
    set :method_override, false
    set :prefixed_redirects, false
    # Off: a trailing slash is left off the path routes and filters are matched against, so /movie/:id answers
    # /movie/550/ too, as in Sinatra.
    set :strict_paths, true
    set :mustermann_opts, {}
    set :matcher, :index
    set :json_encoder, ::JSON
    set :json_content_type, :json
    set :helper_isolation, true
    set :filter_overlap, :warn
    set :root, proc { Dir.pwd }
    set :views, proc { File.join(root, "views") }
    set :erb, {}
    set :reload_templates, proc { development? }
    set :precompile_templates, proc { !development? && !test? }
    # Cross-site request forgery protection (Reprised::CSRF): true turns away a browser's unsafe request from another
    # origin, :report only reports it (report_forged_request!). Routes opt out with `csrf: false`.
    set :csrf, false
    # Origins ("https://accounts.example.com") whose requests the cross-origin check lets through.
    set :csrf_trusted_origins, []
    # Where the session keeps the CSRF token, and the param a form sends it back as (or the X-CSRF-Token header).
    set :csrf_session_key, "_csrf_token"
    set :csrf_param, "authenticity_token"
    # Also set env["sinatra.route"] ("GET /movie/:id") and env["sinatra.error"], for middleware written for Sinatra.
    set :sinatra_env, false
  end
end
