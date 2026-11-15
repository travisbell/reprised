# frozen_string_literal: true

# What Falcon's Rack adapter (protocol-rack) costs per request, measured in-process: a Protocol::HTTP request goes in,
# a Protocol::HTTP response comes out, and its body is drained, as Falcon's server does. No sockets or HTTP parsing,
# which a native adapter wouldn't save either.
#
#   bundle exec ruby --yjit bench/adapter.rb
#
# Each Rack workload runs behind protocol-rack's adapter (Falcon's default) and behind Reprised::Falcon::Adapter.
# "native" is a Protocol::HTTP app that answers directly: the floor any adapter sits on. "rack floor" is a bare Rack
# app, so its difference from native is an adapter's whole cost. The phase rows split protocol-rack's cost into
# building the env and wrapping the response.

require_relative "perf"
require "protocol/http"
require "protocol/rack"
require_relative "../lib/reprised/falcon"
require "socket"

module Bench
  module Adapter
    # A request as it arrives behind a load balancer and a CDN: about 15 headers.
    FIELDS = [
      ["host", "api.example.org"],
      ["user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"],
      ["accept", JSON_ACCEPT],
      ["accept-encoding", "gzip, br"],
      ["accept-language", "en-US,en;q=0.9"],
      ["authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl"],
      ["x-forwarded-for", "203.0.113.7, 198.51.100.2"],
      ["x-forwarded-proto", "https"],
      ["x-real-ip", "203.0.113.7"],
      ["x-request-id", "9f0c1d6e-3b2a-4c5d-8e7f-0a1b2c3d4e5f"],
      ["traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"],
      ["cf-connecting-ip", "203.0.113.7"],
      ["cf-ipcountry", "US"],
      ["cf-ray", "8a1b2c3d4e5f6a7b-SJC"],
      ["sec-fetch-mode", "cors"]
    ].map { |pair| pair.map(&:freeze).freeze }.freeze

    PEER = Addrinfo.tcp("10.0.0.1", 54_321)

    # As Async::HTTP's server request: it knows its peer.
    class Request < Protocol::HTTP::Request
      def peer = PEER
      def hijack? = false
    end

    def self.request(path)
      Request.new("http", "api.example.org", "GET", path, "HTTP/1.1", Protocol::HTTP::Headers.new(FIELDS.dup), nil)
    end

    NATIVE = lambda do |_request|
      Protocol::HTTP::Response[200, Protocol::HTTP::Headers[[["content-type", "text/html;charset=utf-8"]]], ["hi"]]
    end

    RACK_FLOOR = ->(_env) { [200, { "content-type" => "text/html;charset=utf-8", "content-length" => "2" }, ["hi"]] }

    # The Rack apps, and the path each is asked for.
    WORKLOADS = {
      "rack floor" => -> { [RACK_FLOOR, "/"] },
      "hello" => -> { [Hello, "/"] },
      "api" => -> { [Api, "/3/movie/550?language=en-US&page=2"] },
      "api 404" => -> { [Api, "/3/nope"] },
      "controller" => -> { [Controllers, "/movie/550/cast"] },
      "erb" => -> { [Rendered, "/"] }
    }.freeze

    ADAPTERS = [Protocol::Rack::Adapter, Reprised::Falcon::Adapter].freeze

    # The adapter's two halves, alone.
    PHASES = {
      "  build request" => lambda do
        -> { Adapter.request("/3/movie/550?language=en-US&page=2") }
      end,
      "  + make env" => lambda do
        adapter = Protocol::Rack::Adapter.new(RACK_FLOOR)
        -> { adapter.make_environment(Adapter.request("/3/movie/550?language=en-US&page=2")) }
      end,
      "  + make env, reprised" => lambda do
        adapter = Reprised::Falcon::Adapter.new(RACK_FLOOR)
        -> { adapter.make_environment(Adapter.request("/3/movie/550?language=en-US&page=2")) }
      end,
      "  wrap response" => lambda do
        adapter = Protocol::Rack::Adapter.new(RACK_FLOOR)
        env = { Protocol::Rack::RACK_RESPONSE_FINISHED => [] }.freeze
        lambda do
          status, headers, body = RACK_FLOOR.call(env)
          headers, meta = adapter.wrap_headers(headers)
          Protocol::Rack::Response.wrap(env, status, headers, meta, body).body.join
        end
      end
    }.freeze

    def self.measure(app, path, seconds: 3.0)
      run = -> { app.call(request(path)).body&.join }
      time(run, seconds:)
    end

    def self.time(run, seconds: 3.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      run.() while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      rounds = Array.new(10) do
        count = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        while (elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < seconds / 10
          run.()
          count += 1
        end
        elapsed / count * 1_000_000
      end.sort

      GC.start
      before = GC.stat(:total_allocated_objects)
      100.times { run.() }
      allocations = (GC.stat(:total_allocated_objects) - before) / 100.0

      [rounds[5], (rounds[-1] - rounds[0]) / rounds[5] * 100, allocations]
    end

    def self.isolated
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        result = yield
        writer.write(Marshal.dump(result))
        writer.close
        exit!(0)
      end
      writer.close
      result = Marshal.load(reader.read)
      Process.wait(pid)
      result
    end

    def self.run(names)
      jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "interpreter"
      puts format("%-22s %22s %22s   (%s, Ruby %s, protocol-rack %s)", "", "protocol-rack", "Reprised::Falcon",
        jit, RUBY_VERSION, Protocol::Rack::VERSION)
      puts format("%-22s %11s %10s %11s %10s", "workload", "µs/req", "allocs", "µs/req", "allocs")
      selected = ->(name) { names.empty? || names.any? { name.strip.start_with?(it) } }

      if selected.("native")
        us, _, allocations = isolated { measure(NATIVE, "/") }
        puts format("%-22s %11.2f %10.1f", "native", us, allocations)
      end

      WORKLOADS.each do |name, build|
        next unless selected.(name)

        columns = ADAPTERS.flat_map do |adapter|
          us, _, allocations = isolated do
            app, path = build.()
            measure(adapter.new(app), path)
          end
          [us, allocations]
        end
        puts format("%-22s %11.2f %10.1f %11.2f %10.1f", name, *columns)
      end

      PHASES.each do |name, build|
        next unless names.empty?

        us, _, allocations = isolated { time(build.()) }
        puts format("%-22s %11.2f %10.1f", name, us, allocations)
      end
    end
  end
end

Bench::Adapter.run(ARGV) if $PROGRAM_NAME == __FILE__
