# frozen_string_literal: true

module Reprised
  # A group of routes with their own filters, error handlers, and helpers, mounted into an app:
  #
  #   class MovieController < Reprised::Controller
  #     before("/movie/:id/edit") { require_editor }
  #
  #     get "/movie/:id" do
  #       load_movie
  #       erb :"movie/show"
  #     end
  #
  #     private def load_movie = (@movie = Movie.find(params[:id]) or halt 404)
  #   end
  #
  #   class App < Reprised::App
  #     mount MovieController
  #   end
  #
  # An instance is the request scope: routes, filters, error handlers, helpers, and templates all run as its methods
  # (Reprised::Dispatch runs the request). So a controller's methods, and its `helpers`, are visible to its own routes
  # and templates only, alongside the app's helpers, which every controller gets when it's mounted. A controller's
  # filters run only for its own routes. Settings are the app's.
  #
  # Reprised::App is a Controller too: the app's own routes, filters, and methods work the same way, and its helpers
  # are the global ones.
  class Controller
    NO_HANDLERS = [].freeze

    extend DSL
    # Rack::Utils' functions (escape_html, escape, unescape, build_query, ...) in routes, filters, and templates, as
    # Sinatra::Base includes them. They're private, and the helpers below (and the app's) take precedence.
    include Rack::Utils
    include Helpers
    include Templates
    include Template::Methods

    class << self
      # The app this controller is mounted in.
      attr_reader :app

      def settings
        app&.settings or raise(ArgumentError, "#{self} isn't mounted in an app, so it has no settings")
      end

      def set(*)
        raise ArgumentError, "settings belong to the app; set them on #{app || "the app"}"
      end

      def use(*)
        raise ArgumentError, "middleware belongs to the app; `use` it in #{app || "the app"}"
      end

      # Called by App.mount: gives the controller the app's helpers, and its settings.
      # A controller that isn't reloaded can be mounted again in a reloaded app: one whose constant has replaced the
      # app it was mounted in.
      def mounted_in(app)
        raise ArgumentError, "#{self} is already mounted in #{@app}" if @app && !@app.equal?(app) && !replaced?(@app)
        raise ArgumentError, "#{self} has no routes, filters, or error handlers to mount" if self == Controller

        @app = app
        include(app.helpers_module)
        # Then its own, so they come before the app's: a controller's helpers override global ones, as its methods do.
        include(@helpers_module) if @helpers_module
      end

      # A controller's helpers module is included when it's mounted, after the app's (an app's, as it's made).
      def include_helpers_module? = self <= App || !@app.nil?

      # Whether +app+'s name now names another class, as it does once the app is reloaded.
      private def replaced?(app)
        !app.name.nil? && Object.const_defined?(app.name) && !Object.const_get(app.name).equal?(app)
      end

      # Error handlers for +key+, newest first: remembered per key once the app is finalized.
      def error_handlers(key)
        return errors.fetch(key, NO_HANDLERS).reverse unless app&.finalized?

        lookup = (@error_lookup ||= {}.compare_by_identity)
        lookup.fetch(key) { lookup[key] = errors.fetch(key, NO_HANDLERS).reverse.freeze }
      end
    end

    # The instance variables #initialize sets: the request's state, carried over when the scope changes controller.
    STATE = [:@env, :@request, :@response, :@params, :@route, :@__default_layout].freeze

    attr_reader :env, :response

    # Made on first use: a route that reads neither costs neither.
    def request = @request ||= Request.new(@env)
    def params = @params ||= Params.new

    # The Route answering this request, set once one matches (also during before filters). nil for a 404.
    attr_reader :route

    def initialize(env)
      @env = env
      @request = nil
      @response = Response.new
      @params = nil
      @route = nil
      @__default_layout = :layout
    end

    def settings = self.class.settings

    private

    # The provides: condition. Matches when the client accepts one of +types+, and sets the content type to it, unless
    # a before filter already set one, which must then be among +types+.
    def provides?(types)
      if (current = response["content-type"])
        types.include?(current) || types.include?(current[/^[^;]+/])
      elsif (preferred = Negotiation.preferred_type(request.accept, types))
        content_type(preferred)
        true
      else
        false
      end
    end
  end
end
