# frozen_string_literal: true

module Reprised
  # sinatra-contrib's Sinatra::Extension: a module whose body uses the app DSL (routes, filters, error handlers,
  # helpers, settings, configure), recorded and replayed on each app that registers it.
  #
  #   module Errors
  #     extend Reprised::Extension
  #
  #     error(404) { erb :not_found }
  #     configure(:development) { set :dump_errors, true }
  #   end
  #
  #   class App < Reprised::App
  #     register Errors
  #   end
  #
  # The module's own methods extend the app, as any extension's do.
  module Extension
    def configure(*envs, &block)
      record(:configure, envs, {}) { |app| app.instance_exec(app, &block) }
    end

    # Replays the recorded calls on +base+. With a block instead, records the block to run in the app's class body.
    def registered(base = nil, &block)
      base ? replay(base) : record(:class_eval, [], {}, &block)
    end

    private

    def record(method, args, options, &block)
      recorded_methods << [method, args, options, block]
      nil
    end

    def replay(app)
      recorded_methods.each { |method, args, options, block| app.send(method, *args, **options, &block) }
    end

    def recorded_methods = @recorded_methods ||= []

    # Like sinatra-contrib, it doesn't define respond_to_missing?: the module would claim App's methods, call among them.
    def method_missing(method, *args, **options, &block)
      return super unless App.respond_to?(method)

      record(method, args, options, &block)
      DontCall.new(method)
    end

    # What a recorded call returns: it has no result until it's replayed.
    class DontCall < BasicObject
      def initialize(method)
        @method = method
      end

      def method_missing(*) = ::Kernel.raise(::NoMethodError, "the result of #{@method} isn't available in an extension")
      def respond_to_missing?(*) = false
      def inspect = "#<Reprised::Extension::DontCall #{@method}>"
    end
  end
end
