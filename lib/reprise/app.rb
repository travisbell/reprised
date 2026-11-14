# frozen_string_literal: true

require "rack/head"

module Reprise
  # A Rack application. Subclass it, define routes or mount controllers, and `run` the class:
  #
  #   class App < Reprise::App
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

    FINALIZE_LOCK = Mutex.new
    FILTER_OVERLAP = [:warn, :raise, :ignore].freeze
    private_constant :FINALIZE_LOCK

    class << self
      # Controllers' restrictions don't apply to apps.
      define_method(:set, DSL.instance_method(:set))
      define_method(:use, DSL.instance_method(:use))
      def settings = self
      def app = self

      # Rack entry point.
      def call(env) = (@stack || finalize!.stack).call(env)

      # Mounts controllers at this point in the app's definitions: their routes and filters take this place in
      # definition order, as a Sinatra extension's do where it's registered.
      def mount(*controllers)
        ensure_definable!
        controllers.each do |controller|
          raise ArgumentError, "#{controller.inspect} isn't a Reprise::Controller" unless controller.is_a?(Class) && controller < Controller
          raise ArgumentError, "#{controller} is an app; apps can't be mounted" if controller <= App

          controller.mounted_in(self)
          mount = Mount.new(controller:)
          [:routes, :before, :after].each { definitions(it) << mount }
          (@controllers ||= []) << controller
        end
      end

      def controllers = @controllers || []

      # Installs a plugin: a module with `install(app, **options)`, such as Reprise::Plugins::ActionView.
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
          @router = build_router(@routes) { |route| route.verb }
          @filter_routers = @filters.transform_values { build_router(it) }.freeze
          @error_handlers = errors.transform_values { it.reverse.freeze }.freeze
          check_filter_overlap(@routes)
          precompile_views! if settings.precompile_templates?
          @stack = build_stack
          @finalized = true
        end
        self
      end

      def finalized? = @finalized == true

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

      # Every route, in the order they're tried: the app's own and its mounted controllers', with conditions compiled.
      # Finalizes the app. Used by `reprise routes` and for warming up.
      def routes = @routes || (finalize! && @routes)

      # Every before and after filter, in order, mounted controllers' included. Finalizes the app.
      def filters = @filters || (finalize! && @filters)

      attr_reader :stack

      def router = @router || (finalize! && @router)
      def filter_router(type) = (@filter_routers || (finalize! && @filter_routers)).fetch(type)

      # Error handlers for +key+, newest first, from the nearest app class in the hierarchy that has any.
      def error_handlers(key)
        own = (@error_handlers || errors).fetch(key, nil)
        return @error_handlers ? own : own.reverse if own
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
          definition.with(conditions: (options + definition.conditions).freeze)
        end
      end

      # With helper_isolation off, every controller's `helpers` are global, as Sinatra's extensions' helpers are.
      def share_helpers
        controllers.each { helpers_module.include(it.helpers_module) }
      end

      def build_router(definitions)
        router = Router.new(matcher: settings.matcher, **settings.mustermann_opts)
        definitions.each { |definition| router.add(block_given? ? yield(definition) : :any, definition.path || %r{.*}, definition) }
        router.finalize!
      end

      # Warns (or raises, per the filter_overlap setting) when a controller's filter matches another controller's
      # route: scoped to its own controller, it won't run for that route, as it would have in Sinatra.
      def check_filter_overlap(routes)
        mode = settings.filter_overlap
        raise ArgumentError, "filter_overlap must be one of #{FILTER_OVERLAP}" unless FILTER_OVERLAP.include?(mode)
        return if mode == :ignore

        overlaps = routes.flat_map do |route|
          next [] unless (path = sample_path(route.path))

          @filter_routers.values.flat_map do |filters|
            filters.each(:any, path).filter_map do |filter, _|
              [filter, route] unless filter.owner <= App || filter.owner == route.owner
            end
          end
        end
        return if overlaps.empty?

        message = overlaps.map do |filter, route|
          "#{filter} in #{filter.owner} (#{filter.source_location&.join(":")}) matches #{route} in #{route.owner} " \
            "(#{route.source_location&.join(":")}), but runs only for its own controller's routes"
        end.join("\n  ")
        raise ArgumentError, "Reprise: filters overlap other controllers' routes:\n  #{message}" if mode == :raise

        Kernel.warn("Reprise: filters overlap other controllers' routes:\n  #{message}")
      end

      # A path +pattern+ matches, for checking which filters would apply to it, or nil for a regexp or Array.
      def sample_path(pattern)
        return unless pattern.is_a?(String)

        mustermann = Mustermann.new(pattern, **settings.mustermann_opts)
        mustermann.expand(:ignore, mustermann.names.to_h { [it, it == "splat" ? ["x"] * pattern.count("*") : "x"] })
      rescue Mustermann::Error, ArgumentError
        nil
      end

      def build_stack
        app = ->(env) { Dispatch.new(self, env).call }
        app = Rack::Head.new(app)
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
    set :prefixed_redirects, false
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
    # Also set env["sinatra.route"] ("GET /movie/:id") and env["sinatra.error"], for middleware written for Sinatra.
    set :sinatra_env, false
  end
end
