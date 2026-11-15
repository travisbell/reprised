# frozen_string_literal: true

require_relative "../support/falcon_server"
require "async/barrier"
require "async/websocket/client"

# Reprised under a real Falcon server. Run with ASYNC_SAFE=1 to also check for concurrent access to single-owner
# objects (see spec_helper).
RSpec.describe "Reprised under Falcon" do
  include FalconServer

  it "handles requests concurrently: a route waiting on IO doesn't hold up the others" do
    app = Class.new(Reprised::App) { get("/sleep") { sleep(0.2) and "slept" } }

    with_falcon(app) do |client|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bodies = Array.new(5) { Async { client.get("/sleep").read } }.map(&:wait)

      expect(bodies).to all(eq("slept"))
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.6
    end
  end

  it "keeps Reprised.current in the tasks of an Async::Barrier the route starts" do
    app = Class.new(Reprised::App) do
      get("/barrier") do
        barrier = Async::Barrier.new
        scopes = Array.new(3) { barrier.async { sleep(0.01) and Reprised.current } }
        barrier.wait
        scopes.map(&:wait).all? { it.equal?(self) }.to_s
      end
    end

    with_falcon(app) { |client| expect(client.get("/barrier").read).to eq("true") }
  end

  it "sends a stream's writes as they're made" do
    app = Class.new(Reprised::App) do
      get("/stream") do
        stream do |out|
          3.times do |index|
            out << "chunk #{index}\n"
            sleep(0.1)
          end
        end
      end
    end

    with_falcon(app) do |client|
      response = client.get("/stream")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      first = response.body.read
      first_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      rest = +""
      while (chunk = response.body.read)
        rest << chunk
      end

      expect(first).to eq("chunk 0\n")
      expect(first_at).to be < 0.05
      expect(rest).to eq("chunk 1\nchunk 2\n")
    end
  end

  it "streams Server-Sent Events" do
    app = Class.new(Reprised::App) do
      get("/events") { event_stream { |sse| 2.times { sse.event(:tick, it) } } }
    end

    with_falcon(app) do |client|
      response = client.get("/events")

      expect(response.headers["content-type"]).to eq("text/event-stream;charset=utf-8")
      expect(response.read).to eq("event: tick\ndata: 0\n\nevent: tick\ndata: 1\n\n")
    end
  end

  it "answers a route that overruns its timeout with 503, through error handlers" do
    app = Class.new(Reprised::App) do
      get("/slow", timeout: 0.05) { sleep(1) and "too late" }
      get("/handled", timeout: 0.05) { sleep(1) }
      error(Reprised::Timeout) { "timed out: #{error.message}" if request.path_info == "/handled" }
    end

    with_falcon(app) do |client|
      slow = client.get("/slow")
      expect(slow.status).to eq(503)
      slow.finish

      handled = client.get("/handled")
      expect([handled.status, handled.read]).to eq([503, "timed out: GET /handled took longer than 0.05s"])
    end
  end

  it "writes the Telemetry plugin's log line once the response has been sent" do
    require "reprised/plugins/telemetry"
    lines = []
    app = Class.new(Reprised::App) do
      plugin Reprised::Plugins::Telemetry, requests: { log: ->(_env, message, fields) { lines << [message, fields[:route]] } }
      get("/slow/:id") do
        stream do |out|
          out << "a"
          sleep(0.05)
          out << "b"
        end
      end
    end

    with_falcon(app) do |client|
      response = client.get("/slow/1")
      expect(lines).to be_empty

      expect(response.read).to eq("ab")
      sleep(0.01)
      expect(lines).to eq([["GET /slow/1 200", "/slow/:id"]])
    end
  end

  describe "websockets" do
    it "upgrades the request and runs the block with the connection, in the request's scope" do
      app = Class.new(Reprised::App) do
        helpers { def greeting = "hello" }
        websocket("/echo/:name") do |connection|
          connection.write("#{greeting} #{params[:name]} #{Reprised.current.equal?(self)}")
          while (message = connection.read)
            connection.write("echo #{message.to_str}")
            connection.flush
          end
        end
        get("/echo/:name") { "not a websocket" }
      end

      with_falcon(app) do |client, url|
        Async::WebSocket::Client.connect(Async::HTTP::Endpoint.parse("#{url}/echo/ana")) do |connection|
          expect(connection.read.to_str).to eq("hello ana true")
          connection.write("ping")
          connection.flush
          expect(connection.read.to_str).to eq("echo ping")
        end

        expect(client.get("/echo/ana").read).to eq("not a websocket")
      end
    end

    it "passes options to the adapter" do
      handler = Class.new(Async::WebSocket::Connection) do
        def read(...) = super&.then { Protocol::WebSocket::TextMessage.new("handled") }
      end
      app = Class.new(Reprised::App) do
        websocket("/ws", handler:, extensions: nil) do |connection|
          connection.write(connection.read)
          connection.flush
        end
      end

      with_falcon(app) do |_client, url|
        Async::WebSocket::Client.connect(Async::HTTP::Endpoint.parse("#{url}/ws")) do |connection|
          connection.write("anything")
          connection.flush
          expect(connection.read.to_str).to eq("handled")
        end
      end
    end
  end
end
