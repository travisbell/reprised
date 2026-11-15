# frozen_string_literal: true

class Demos
  # Async under Falcon: a response streamed as it's written, work done concurrently with Async::Barrier, a route
  # timeout, and a route that blocks the event loop, for the stall detector in config.ru to catch.
  class StreamingDemo < Reprised::Controller
    get "/streaming" do
      @title = "Streaming"
      erb :streaming
    end

    # Each line is sent as it's written, so the page shows them one by one (and so does curl -N).
    get "/streaming/countdown" do
      content_type(:text)
      stream do |out|
        10.downto(1) do |count|
          out << "#{count}...\n"
          sleep(0.3)
        end
        out << "Liftoff!\n"
      end
    end

    # Three lookups at once, so they take as long as the slowest of them, not all three added up. Each reaches the
    # request through Reprised.current, from inside its task.
    get "/streaming/parallel" do
      started = now
      barrier = Async::Barrier.new
      tasks = { cast: 0.9, reviews: 0.7, trailers: 0.5 }.map do |name, seconds|
        barrier.async { Lookup.call(name, seconds) }
      end
      json(lookups: tasks.map(&:wait), sequentially: 2.1, took: (now - started).round(2))
    ensure
      barrier&.stop
    end

    # Runs longer than its timeout unless ?seconds= is under 1: Reprised::Timeout, answered by the handler below.
    get "/streaming/slow", timeout: 1 do
      seconds = params.fetch(:seconds, "3").to_f.clamp(0, 5)
      sleep(seconds)
      content_type(:text)
      "Finished in #{seconds}s, inside the 1s timeout."
    end

    error(Reprised::Timeout) do
      content_type(:text)
      "503: #{error.message}, so it was stopped. Try /streaming/slow?seconds=0.5."
    end

    # Busy work that never yields to the event loop, which holds up every other request in this process. The stall
    # detector logs it, naming this request.
    get "/streaming/block" do
      deadline = now + 1.5
      nil while now < deadline
      content_type(:text)
      "Blocked the event loop for 1.5s: see the server's log."
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # A service object, which reaches the request it's working for with Reprised.current.
    module Lookup
      def self.call(name, seconds)
        sleep(seconds) # Standing in for an HTTP call or a query, which would also let the other tasks run meanwhile.
        { name:, seconds:, for: Reprised.current.request.path_info }
      end
    end
  end
end
