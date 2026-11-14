# frozen_string_literal: true

require "console"
require "rack/request"

module Reprise
  module Telemetry
    # Rack middleware that counts each request (app.requests), times it (app.request.duration), and writes an access log
    # line for it through Console:
    #
    #   use Reprise::Telemetry::Requests,
    #     labels: ->(env) { { client: env["myapp.client"] } },
    #     fields: ->(env) { { account_id: env["myapp.account_id"] } },
    #     skip_paths: ["/healthcheck"]
    #
    # Requests are labelled by method, status, status class, and route: the Reprise route's pattern ("/movie/:id"), so a
    # route is one series whatever its ids, or "unmatched" for requests no route answered. The histogram has only the
    # status class (and any of +histogram_labels+), since its series multiply by its buckets.
    #
    # +filter+, +labels+, and +fields+ are called once the app has answered, so they see what it put in the env. filter
    # picks the requests to record (all of them without one); labels go on the counter and the log line, so keep them to
    # a handful of values each; fields go on the log line only.
    #
    # The log line is written for +log_sample+ percent of requests, and for every 5xx. Where the server supports
    # rack.response_finished (Falcon does), it's written once the response has been sent, after the request's span has
    # ended, so a log-triggered tail sampler doesn't keep every trace. Put the middleware below OpenTelemetry's Rack
    # middleware for the line to carry the request's trace_id. +log+ may be false (metrics only) or a callable taking
    # (env, message, fields) to write the line itself.
    #
    # In config.ru it records what every middleware below it answers; installed with the Telemetry plugin, what the app
    # answers.
    class Requests
      NONE = "none"
      UNMATCHED = "unmatched"
      MAX_QUERY_LENGTH = 500
      MAX_USER_AGENT_LENGTH = 200
      HISTOGRAM_LABELS = ["status_class"].freeze

      def initialize(
        app,
        filter: nil,
        labels: nil,
        fields: nil,
        skip_paths: [],
        histogram_labels: HISTOGRAM_LABELS,
        log: true,
        log_sample: 100,
        request_id: "HTTP_X_REQUEST_ID",
        query_filter: QueryFilter.new
      )
        @app = app
        @filter = filter
        @labels = labels
        @fields = fields
        @skip_paths = skip_paths.to_set.freeze
        @histogram_labels = histogram_labels.map(&:to_s).freeze
        @log = log
        @log_sample = log_sample
        @request_id = request_id
        @query_filter = query_filter
      end

      def call(env)
        return @app.call(env) if @skip_paths.include?(env["PATH_INFO"])

        started = Telemetry.monotonic_now
        span = current_span_context
        status, headers, = response = @app.call(env)
        finished(env, status, headers, Telemetry.monotonic_now - started, span)
        response
      rescue => error
        finished(env, 500, nil, Telemetry.monotonic_now - started, span, error) if started
        raise
      end

      private

      def finished(env, status, headers, duration, span, error = nil)
        return if @filter && !@filter.call(env)

        status = status.to_i
        metrics = Metrics.enabled?
        log = @log && log?(status)
        return unless metrics || log

        labels = request_labels(env, status)
        if metrics
          request_counter.add(1, attributes: labels)
          duration_histogram.record(duration, attributes: labels.slice(*@histogram_labels))
        end
        return unless log

        fields = log_fields(env, status, headers, duration, labels, span, error)
        message = "#{labels["method"]} #{env["PATH_INFO"]} #{status}"
        if (callbacks = env["rack.response_finished"])
          callbacks << ->(*) { write(env, message, fields) }
        else
          write(env, message, fields)
        end
      rescue => record_error
        Console.error(self, "Couldn't record request", exception: record_error)
      end

      def request_labels(env, status)
        labels = {
          "method" => env["REQUEST_METHOD"].to_s,
          "status" => status.to_s,
          "status_class" => "#{status / 100}xx",
          "route" => env["reprise.route"]&.pattern || UNMATCHED,
        }
        @labels&.call(env)&.each { |key, value| labels[key.to_s] = value.nil? ? NONE : value.to_s }
        labels
      end

      def log?(status)
        status >= 500 || @log_sample >= 100 || rand * 100 < @log_sample
      end

      def log_fields(env, status, headers, duration, labels, span, error)
        fields = {
          path: env["PATH_INFO"],
          query: @query_filter.call(env["QUERY_STRING"], max_length: MAX_QUERY_LENGTH),
          duration: duration.round(4),
          bytes: headers&.[]("content-length"),
          request_id: env[@request_id],
          trace_id: (span.hex_trace_id if span&.valid?),
          ip: ::Rack::Request.new(env).ip,
          user_agent: env["HTTP_USER_AGENT"]&.slice(0, MAX_USER_AGENT_LENGTH),
        }
        labels.each { |key, value| fields[key.to_sym] = value }
        @fields&.call(env)&.each { |key, value| fields[key.to_sym] = value }
        # An exception the app raised, or one it rescued and answered for (such as with a 500).
        error ||= env["reprise.error"]
        fields[:error] = error.class.name if error
        fields.compact!
        fields
      end

      def write(env, message, fields)
        if @log.respond_to?(:call)
          @log.call(env, message, fields)
        elsif @log
          Console.info(self, message, **fields)
        end
      end

      # The request's span, when the middleware is below OpenTelemetry's Rack middleware: its trace id goes in the log
      # line, which is written once the span has ended.
      def current_span_context
        ::OpenTelemetry::Trace.current_span.context if defined?(::OpenTelemetry::Trace)
      end

      def request_counter
        Metrics.counter("app.requests", unit: "{request}", description: "Requests answered by the app")
      end

      def duration_histogram
        Metrics.histogram("app.request.duration", description: "How long the app took to answer a request")
      end
    end
  end
end
