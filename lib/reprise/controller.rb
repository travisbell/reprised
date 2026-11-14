# frozen_string_literal: true

module Reprise
  # A group of routes with their own filters, error handlers, and helpers, mounted into an app:
  #
  #   class MovieController < Reprise::Controller
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
  #   class App < Reprise::App
  #     mount MovieController
  #   end
  #
  # An instance is the request scope: routes, filters, error handlers, helpers, and templates all run as its methods
  # (Reprise::Dispatch runs the request). So a controller's methods, and its `helpers`, are visible to its own routes
  # and templates only, alongside the app's helpers, which every controller gets when it's mounted. A controller's
  # filters run only for its own routes. Settings are the app's.
  #
  # Reprise::App is a Controller too: the app's own routes, filters, and methods work the same way, and its helpers
  # are the global ones.
  class Controller
    extend DSL
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
      def mounted_in(app)
        raise ArgumentError, "#{self} is already mounted in #{@app}" if @app && !@app.equal?(app)
        raise ArgumentError, "#{self} has no routes, filters, or error handlers to mount" if self == Controller

        @app = app
        include(app.helpers_module)
      end

      # Error handlers for +key+, newest first.
      def error_handlers(key) = errors.fetch(key, []).reverse
    end

    attr_reader :env, :request, :response, :params

    # The Route answering this request, set once one matches (also during before filters). nil for a 404.
    attr_reader :route

    def initialize(env)
      @env = env
      @request = Request.new(env)
      @response = Response.new
      @params = Params.new
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
      elsif (preferred = request.preferred_type(types))
        content_type(preferred)
        true
      else
        false
      end
    end
  end
end
