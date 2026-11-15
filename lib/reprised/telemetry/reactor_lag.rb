# frozen_string_literal: true

module Reprised
  module Telemetry
    # How late the event loop resumes a sleeping task (reactor.lag). Every request on a loop shares it, so lag is time
    # requests spend waiting for the CPU (busy fibers, GC, other threads holding the GVL) rather than for I/O.
    #
    #   use Reprised::Telemetry::ReactorLag   # starts it in each event loop, with its first request
    #   Reprised::Telemetry::ReactorLag.start # or start it in the current one
    #
    # Does nothing until metrics are enabled (see Metrics).
    module ReactorLag
      INTERVAL = 0.1

      class << self
        # Starts sampling in the current event loop, unless it already is. Returns the sampling task, or nil outside an
        # event loop or with metrics disabled.
        def start(interval: INTERVAL)
          return unless Metrics.enabled?

          Telemetry.for_reactor(ReactorLag) do
            Async(transient: true, annotation: "Reprised reactor lag") { sample(interval) }
          end
        end

        def lag = Metrics.histogram("reactor.lag", description: "How late the event loop resumed a timer", boundaries: Metrics::SHORT_DURATION_BOUNDS)

        private

        def sample(interval)
          loop do
            started = Telemetry.monotonic_now
            sleep(interval)
            lag.record([Telemetry.monotonic_now - started - interval, 0].max)
          end
        end
      end

      # Rack middleware that starts sampling in each event loop with its first request.
      class Middleware
        def initialize(app, interval: INTERVAL)
          @app = app
          @interval = interval
        end

        def call(env)
          ReactorLag.start(interval: @interval)
          @app.call(env)
        end
      end

      # So `use Reprised::Telemetry::ReactorLag` works.
      def self.new(app, **) = Middleware.new(app, **)
    end
  end
end
