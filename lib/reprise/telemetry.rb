# frozen_string_literal: true

module Reprise
  # Opt-in telemetry for apps on Falcon and Async: request metrics and an access log, a stall detector for the event
  # loop, and the loop's lag. Not loaded by `require "reprise"`:
  #
  #   require "reprise/telemetry"
  #
  # Each part is Rack middleware (or starts from one), so it can go in config.ru, where it also sees what other
  # middleware answers, or in the app, with `plugin Reprise::Plugins::Telemetry`. Metrics go through the OpenTelemetry
  # metrics API: they're no-ops until the app configures an SDK meter provider. Logs go through Console, as Falcon's
  # and Async's do.
  #
  # - Requests: counts each request (app.requests), times it (app.request.duration), and logs a line for it.
  # - StallDetector: logs when the event loop is blocked, with the requests in flight and the blocked backtrace.
  # - ReactorLag: how late the event loop resumes a timer (reactor.lag).
  module Telemetry
    # Services that run once per event loop (a heartbeat, a sampling task), by scheduler. Falcon runs a loop per worker
    # (and per thread, in a threaded container); each gets its own.
    REACTORS = ObjectSpace::WeakKeyMap.new
    private_constant :REACTORS

    class << self
      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The service +key+ for the current event loop, built by the block (given the scheduler) the first time it's
      # asked for in that loop, and again after a fork. Nil outside an Async event loop.
      def for_reactor(key)
        return unless defined?(::Async::Scheduler)

        scheduler = Fiber.scheduler
        return unless scheduler.is_a?(::Async::Scheduler)

        pid, services = REACTORS[scheduler]
        REACTORS[scheduler] = [pid = Process.pid, services = {}] unless pid == Process.pid
        services.fetch(key) { services[key] = yield(scheduler) }
      end

      # This process's resident memory in MB, from /proc. Nil where there's none (macOS).
      def rss_mb
        line = File.foreach("/proc/self/status").find { it.start_with?("VmRSS:") }
        (line.split[1].to_i / 1024.0).round(1) if line
      rescue Errno::ENOENT
        nil
      end
    end
  end
end

require_relative "telemetry/metrics"
require_relative "telemetry/query_filter"
require_relative "telemetry/requests"
require_relative "telemetry/stall_detector"
require_relative "telemetry/reactor_lag"
