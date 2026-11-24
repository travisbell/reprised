# frozen_string_literal: true

require "opentelemetry"

module Reprised
  module Plugins
    # Names the request's span after its route and records server errors on it, with opentelemetry-instrumentation-
    # rack's span for the request:
    #
    #   plugin Reprised::Plugins::OpenTelemetry, skip_errors: [MyApp::Maintenance],
    #     trace_header: "x-trace-id", log_context: MyApp::LogContext
    #
    # The span gets http.route ("/movie/:id") and is named "GET /movie/:id", as OpenTelemetry's HTTP conventions have
    # it, unless +span_name+ (a callable taking the Route) says otherwise. A 5xx response's exception is recorded on the
    # span, and its status set to error, unless the exception is one of +skip_errors+ (or a subclass).
    #
    # +trace_header+ names a response header to send the request's trace id in, such as for a proxy in front of the
    # app to log, so its access log leads to what the app logged for the request.
    #
    # +log_context+ is the app's store of attributes for the log lines written during a block: anything with
    # `with(attributes) { }`. The request runs in it with http.route, a callable that gives the pattern of the route
    # answering when each line is written (nil until one matches, and the new one after a pass).
    module OpenTelemetry
      class Middleware
        def initialize(app, skip_errors: [], span_name: nil, trace_header: nil, log_context: nil)
          @app = app
          @skip_errors = skip_errors.freeze
          @span_name = span_name
          @trace_header = trace_header
          @log_context = log_context
        end

        def call(env)
          response = in_log_context(env) { @app.call(env) }
          send_trace_id(response) if @trace_header
          response
        ensure
          trace(env, response)
        end

        private

        def in_log_context(env, &)
          return yield unless @log_context

          @log_context.with("http.route" => -> { env["reprised.route"]&.pattern }, &)
        end

        def send_trace_id(response)
          context = ::OpenTelemetry::Instrumentation::Rack.current_span.context
          response[1][@trace_header] = context.hex_trace_id if context.valid?
        end

        def trace(env, response)
          span = ::OpenTelemetry::Instrumentation::Rack.current_span
          return unless span.recording?

          if (route = env["reprised.route"])
            span.set_attribute("http.route", route.pattern)
            span.name = @span_name ? @span_name.call(route) : "#{route.verb} #{route.pattern}"
          end

          return unless response && response.first >= 500 && (error = env["reprised.error"])
          return if @skip_errors.any? { error.is_a?(it) }

          span.record_exception(error)
          span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        end
      end

      def self.install(app, skip_errors: [], span_name: nil, trace_header: nil, log_context: nil)
        require "opentelemetry/instrumentation/rack"
        app.use(Middleware, skip_errors:, span_name:, trace_header:, log_context:)
      end
    end
  end
end
