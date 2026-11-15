# frozen_string_literal: true

class Demos
  # A plugin of the app's own: any module with `install(app, **options)`. It adds a Server-Timing header with how long
  # the app took, which browsers' developer tools show with each request.
  #
  #   plugin ServerTiming, name: "app"
  module ServerTiming
    def self.install(app, name: "app")
      app.before { @server_timing_started = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      app.after do
        next unless @server_timing_started

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @server_timing_started
        headers("server-timing" => "#{name};dur=#{(elapsed * 1000).round(2)}")
      end
    end
  end
end
