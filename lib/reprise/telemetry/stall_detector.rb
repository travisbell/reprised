# frozen_string_literal: true

require "console"

module Reprise
  module Telemetry
    # Rack middleware that logs when the event loop stops running, with the requests in flight, the blocked thread's
    # backtrace (while it's still blocked), and the process's memory. A request that hogs the CPU stalls every other
    # request on its event loop, and this names it.
    #
    #   use Reprise::Telemetry::StallDetector, threshold: 1.0
    #
    # Put it near the top of the stack, so every request is in flight from the start. Each event loop's detector starts
    # with its first request (so in each of Falcon's forked workers), and does nothing outside one. A loop blocked for
    # +threshold+ seconds is logged twice: by a watchdog thread while it's blocked, with the backtrace, and by the loop's
    # heartbeat once it's running again, with the slow requests that finished meanwhile.
    class StallDetector
      HEARTBEAT_INTERVAL = 0.25
      WATCHDOG_INTERVAL = 0.5
      MAX_LISTED = 20
      MAX_QUERY_LENGTH = 200

      def initialize(app, threshold: 1.0, request_id: "HTTP_X_REQUEST_ID", query_filter: QueryFilter.new)
        @app = app
        @threshold = threshold
        @request_id = request_id
        @query_filter = query_filter
      end

      def call(env)
        watch = Telemetry.for_reactor(StallDetector) { Watch.new(@threshold, @query_filter).tap(&:start) }
        return @app.call(env) unless watch

        watch.started(env, @request_id)
        begin
          @app.call(env)
        ensure
          watch.finished(env)
        end
      end

      # One event loop's requests in flight, heartbeat, and watchdog.
      class Watch
        def initialize(threshold, query_filter)
          @threshold = threshold
          @query_filter = query_filter
          @in_flight = {}.compare_by_identity
          @slow = []
          @stopped = false
        end

        def start
          @last_beat = Telemetry.monotonic_now
          reactor = Thread.current
          Async(transient: true, annotation: "Reprise stall detector") { heartbeat }
          Thread.new { watchdog(reactor) }.name = "reprise-stall-detector"
        end

        def started(env, request_id)
          @in_flight[env] = [Telemetry.monotonic_now, env["REQUEST_METHOD"], env["PATH_INFO"], env["QUERY_STRING"], env[request_id]]
        end

        # The request that caused a stall usually finishes before the heartbeat reports it, so recent slow ones are kept.
        def finished(env)
          entry = @in_flight.delete(env) or return
          now = Telemetry.monotonic_now
          return if now - entry[0] < @threshold

          @slow << [now, *entry]
          @slow.shift if @slow.size > MAX_LISTED
        end

        private

        def heartbeat
          loop do
            before = Telemetry.monotonic_now
            sleep(HEARTBEAT_INTERVAL)
            @last_beat = Telemetry.monotonic_now
            blocked_for = @last_beat - before - HEARTBEAT_INTERVAL
            next if blocked_for < @threshold

            Console.warn(
              StallDetector, "Event loop was blocked",
              pid: Process.pid, blocked_for: blocked_for.round(3), rss_mb: Telemetry.rss_mb,
              in_flight: in_flight, completed_during_stall: completed_since(before)
            )
          end
        ensure
          @stopped = true
        end

        # On a thread of its own, so it can capture the loop's backtrace mid-stall, unless whatever's blocking it holds
        # the GVL (a long native call): then it reports once the GVL is free.
        def watchdog(reactor)
          reported = nil
          until @stopped
            sleep(WATCHDOG_INTERVAL)
            last_beat = @last_beat
            blocked_for = Telemetry.monotonic_now - last_beat
            next if @stopped || blocked_for < @threshold || reported == last_beat

            reported = last_beat
            Console.warn(
              StallDetector, "Event loop is blocked",
              pid: Process.pid, blocked_for: blocked_for.round(3), rss_mb: Telemetry.rss_mb,
              backtrace: reactor.backtrace&.first(30), in_flight: in_flight
            )
          end
        rescue => error
          Console.error(StallDetector, "Stall watchdog stopped", exception: error)
        end

        # Oldest first, so a request running since before the stall leads the list.
        def in_flight
          now = Telemetry.monotonic_now
          @in_flight.values.first(MAX_LISTED).map do |started, method, path, query, request_id|
            { age: (now - started).round(3), method:, path:, query: loggable(query), request_id: }.compact
          end
        end

        def completed_since(time)
          @slow.select { |finished, *| finished >= time }.map do |finished, started, method, path, query, request_id|
            { duration: (finished - started).round(3), method:, path:, query: loggable(query), request_id: }.compact
          end
        end

        def loggable(query) = @query_filter.call(query, max_length: MAX_QUERY_LENGTH)
      end
    end
  end
end
