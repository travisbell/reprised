# frozen_string_literal: true

require "rack/head"

module Reprise
  # A Rack application. Subclass it, define routes, and `run` the class:
  #
  #   class App < Reprise::App
  #     get "/movie/:id", provides: :json do
  #       json(Movie.find(params[:id]))
  #     end
  #   end
  #
  #   run App  # config.ru
  #
  # The first request finalizes the app: its definitions compile into frozen routers, and no more can be added.
  # Call App.finalize! at boot (before forking, or in Falcon's warmup) to do that up front.
  class App < Controller
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

    FINALIZE_LOCK = Mutex.new
    private_constant :FINALIZE_LOCK

    class << self
      # Rack entry point.
      def call(env) = (@stack || finalize!.stack).call(env)

      # Compiles routes, filters, and error handlers into frozen tables and builds the middleware stack. Safe to call
      # more than once; definitions are closed after the first call.
      def finalize!
        return self if @finalized

        FINALIZE_LOCK.synchronize do
          return self if @finalized

          @router = build_router(routes) { |route| route.verb }
          @filter_routers = { before: build_router(filters[:before]), after: build_router(filters[:after]) }.freeze
          @error_handlers = errors.transform_values { it.reverse.freeze }.freeze
          @stack = build_stack
          @finalized = true
        end
        self
      end

      def finalized? = @finalized == true

      attr_reader :stack

      def router = @router || (finalize! && @router)
      def filter_router(type) = (@filter_routers || (finalize! && @filter_routers)).fetch(type)

      # Error handlers for +key+, newest first, from the nearest class in the hierarchy that has any.
      def error_handlers(key)
        own = (@error_handlers || errors).fetch(key, nil)
        return @error_handlers ? own : own.reverse if own
        return superclass.error_handlers(key) if superclass.respond_to?(:error_handlers)

        [].freeze
      end

      private

      def build_router(definitions)
        router = Router.new(matcher: settings.matcher, **settings.mustermann_opts)
        definitions.each { |definition| router.add(block_given? ? yield(definition) : :any, definition.path || %r{.*}, definition) }
        router.finalize!
      end

      def build_stack
        app = ->(env) { new(env).call! }
        app = Rack::Head.new(app)
        middleware.reverse_each { |klass, args, block| app = klass.new(app, *args, &block) }
        app
      end
    end
  end
end
