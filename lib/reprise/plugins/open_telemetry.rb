# frozen_string_literal: true

require "opentelemetry"

module Reprise
  module Plugins
    # Names the request's span after its route and records server errors on it, with opentelemetry-instrumentation-
    # rack's span for the request:
    #
    #   plugin Reprise::Plugins::OpenTelemetry, skip_errors: [MyApp::Maintenance]
    #
    # The span gets http.route ("/movie/:id") and is named "GET /movie/:id", as OpenTelemetry's HTTP conventions have
    # it, unless +span_name+ (a callable taking the Route) says otherwise. A 5xx response's exception is recorded on the
    # span, and its status set to error, unless the exception is one of +skip_errors+ (or a subclass).
    module OpenTelemetry
      class Middleware
        def initialize(app, skip_errors: [], span_name: nil)
          @app = app
          @skip_errors = skip_errors.freeze
          @span_name = span_name
        end

        def call(env)
          response = @app.call(env)
        ensure
          trace(env, response)
        end

        private

        def trace(env, response)
          span = ::OpenTelemetry::Instrumentation::Rack.current_span
          return unless span.recording?

          if (route = env["reprise.route"])
            span.set_attribute("http.route", route.pattern)
            span.name = @span_name ? @span_name.call(route) : "#{route.verb} #{route.pattern}"
          end

          return unless response && response.first >= 500 && (error = env["reprise.error"])
          return if @skip_errors.any? { error.is_a?(it) }

          span.record_exception(error)
          span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        end
      end

      def self.install(app, skip_errors: [], span_name: nil)
        require "opentelemetry/instrumentation/rack"
        app.use(Middleware, skip_errors:, span_name:)
      end
    end
  end
end
