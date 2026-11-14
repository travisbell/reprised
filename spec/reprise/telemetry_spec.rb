# frozen_string_literal: true

require "async"
require "rack/builder"
require "reprise/plugins/telemetry"
require "reprise/reloader"
require_relative "../support/open_telemetry"

# The one element of a list that should have exactly one.
module SoleElement
  refine Array do
    def sole = size == 1 ? first : raise(ArgumentError, "expected one element, got #{size}: #{inspect}")
  end
end
using SoleElement

RSpec.describe Reprise::Telemetry do
  include OpenTelemetrySupport

  before { start_metrics }
  after { stop_metrics }

  let(:movies) do
    Class.new(Reprise::App) do
      set :raise_errors, false
      set :dump_errors, false
      get("/movie/:id") { "movie #{params[:id]}" }
      get("/boom") { raise ArgumentError, "boom" }
    end
  end

  def env_for(path, **options) = Rack::MockRequest.env_for(path, **options)

  describe Reprise::Telemetry::Metrics do
    it "is enabled with an SDK provider, and not with the API's no-op" do
      expect(described_class).to be_enabled

      stop_metrics

      expect(described_class).not_to be_enabled
    end

    it "makes instruments again for a new provider" do
      described_class.counter("test.count", unit: "{thing}", description: "Things").add(1)
      start_metrics
      described_class.counter("test.count", unit: "{thing}", description: "Things").add(2)

      expect(data_points("test.count").sum(&:value)).to eq(2)
    end

    it "gives *.duration histograms its bucket boundaries" do
      described_class.histogram("test.duration", description: "Time").record(0.2)

      expect(data_points("test.duration").first.explicit_bounds).to eq(described_class::DURATION_BOUNDS)
    end
  end

  describe Reprise::Telemetry::QueryFilter do
    subject(:filter) { described_class.new }

    it "filters parameters whose names look secret, and cuts the query to length" do
      query = "api_key=abc&page=2&auth_session_id=xyz;user_password=hunter2&query=fight"

      expect(filter.call(query, max_length: 500))
        .to eq("api_key=[FILTERED]&page=2&auth_session_id=[FILTERED];user_password=[FILTERED]&query=fight")
      expect(filter.call(query, max_length: 10)).to eq("api_key=[F")
    end

    it "takes the names to filter" do
      expect(described_class.new(["pin"]).call("pin=1234&api_key=abc", max_length: 100)).to eq("pin=[FILTERED]&api_key=abc")
    end

    it "is nil for no query" do
      expect(filter.call("", max_length: 10)).to be_nil
      expect(filter.call(nil, max_length: 10)).to be_nil
    end
  end

  describe Reprise::Telemetry::Requests do
    let(:lines) { [] }
    let(:options) { {} }
    let(:app) do
      written = lines
      described_class.new(movies.tap(&:finalize!), log: ->(env, message, fields) { written << [message, fields] }, **options)
    end

    def counted = data_points("app.requests")

    it "counts requests by method, status, and route pattern, and times them by status class" do
      2.times { app.call(env_for("/movie/550")) }
      app.call(env_for("/movie/13"))

      expect(counted.map { [it.attributes, it.value] }).to eq([[
        { "method" => "GET", "status" => "200", "status_class" => "2xx", "route" => "/movie/:id" }, 3
      ]])
      histogram = data_points("app.request.duration").sole
      expect(histogram.attributes).to eq("status_class" => "2xx")
      expect(histogram.count).to eq(3)
    end

    it "labels requests no route answered unmatched" do
      app.call(env_for("/nope"))

      expect(counted.sole.attributes).to include("status" => "404", "route" => "unmatched")
    end

    it "logs a line for each request, with the query filtered and the error the app answered for" do
      app.call(env_for("/movie/550?api_key=abc&page=2", "HTTP_X_REQUEST_ID" => "req-1", "HTTP_USER_AGENT" => "spec"))
      app.call(env_for("/boom"))

      message, fields = lines.first
      expect(message).to eq("GET /movie/550 200")
      expect(fields).to include(
        path: "/movie/550", query: "api_key=[FILTERED]&page=2", request_id: "req-1", user_agent: "spec",
        method: "GET", status: "200", route: "/movie/:id", bytes: "9"
      )
      expect(fields[:duration]).to be_a(Float)
      expect(fields).not_to have_key(:error)
      expect(lines.last.last).to include(status: "500", error: "ArgumentError")
    end

    context "with labels, fields, a filter, histogram labels, and skipped paths" do
      let(:options) do
        {
          labels: ->(env) { { client: env["spec.client"], tier: nil } },
          fields: ->(env) { { account: env["spec.account"] } },
          filter: ->(env) { env["spec.client"] },
          histogram_labels: [:client],
          skip_paths: ["/movie/0"]
        }
      end

      it "records only what the filter picks, with the app's labels and fields" do
        app.call(env_for("/movie/1", "spec.client" => "ios", "spec.account" => 7))
        app.call(env_for("/movie/2"))
        app.call(env_for("/movie/0", "spec.client" => "ios"))

        expect(counted.sole.attributes).to include("client" => "ios", "tier" => "none")
        expect(data_points("app.request.duration").sole.attributes).to eq("client" => "ios")
        expect(lines.map(&:first)).to eq(["GET /movie/1 200"])
        expect(lines.sole.last).to include(client: "ios", tier: "none", account: 7)
      end
    end

    context "with a log sample" do
      let(:options) { { log_sample: 0 } }

      it "still counts every request, and logs every 5xx" do
        app.call(env_for("/movie/550"))
        app.call(env_for("/boom"))

        expect(counted.sum(&:value)).to eq(2)
        expect(lines.map(&:first)).to eq(["GET /boom 500"])
      end
    end

    context "with log: false" do
      let(:app) { described_class.new(movies.tap(&:finalize!), log: false) }

      it "records metrics only" do
        expect(Console).not_to receive(:info)

        app.call(env_for("/movie/550"))

        expect(counted.sum(&:value)).to eq(1)
      end
    end

    it "logs through Console by default, at a level by status" do
      app = described_class.new(movies.tap(&:finalize!))
      expect(Console).to receive(:info).with(app, "GET /movie/550 200", hash_including(route: "/movie/:id"))
      expect(Console).to receive(:warn).with(app, "GET /nope 404", hash_including(status: "404"))
      expect(Console).to receive(:error).with(app, "GET /boom 500", hash_including(error: "ArgumentError"))

      ["/movie/550", "/nope", "/boom"].each { app.call(env_for(it)) }
    end

    it "gives the log level for a status" do
      expect([200, 304, 404, 499, 500, "503"].map { described_class.log_level(it) }).to eq([:info, :info, :warn, :warn, :error, :error])
    end

    it "counts an exception that escapes as a 500, and re-raises it" do
      raising = described_class.new(->(_env) { raise IOError, "gone" }, log: ->(_env, _message, fields) { lines << fields })

      expect { raising.call(env_for("/x")) }.to raise_error(IOError)
      expect(counted.sole.attributes).to include("status" => "500")
      expect(lines.sole).to include(error: "IOError")
    end

    it "writes the line once the response is finished, outside the request's span, with its trace id" do
      inner = app
      traced = Rack::Builder.app do
        use OpenTelemetrySupport::TRACER_MIDDLEWARE
        run inner
      end
      OpenTelemetrySupport::SPANS.reset
      env = env_for("/movie/550", "rack.response_finished" => [])
      traced.call(env)

      expect(lines).to be_empty
      span_during_log = nil
      env["rack.response_finished"].each do |callback|
        callback.call(env, 200, {}, nil)
        span_during_log = OpenTelemetry::Trace.current_span
      end

      expect(lines.sole.last[:trace_id]).to eq(OpenTelemetrySupport::SPANS.finished_spans.last.hex_trace_id)
      expect(span_during_log).not_to be_recording
    end
  end

  describe Reprise::Telemetry::StallDetector do
    before do
      stub_const("#{described_class}::HEARTBEAT_INTERVAL", 0.02)
      stub_const("#{described_class}::WATCHDOG_INTERVAL", 0.02)
    end

    let(:blocking) do
      Class.new(Reprise::App) do
        get("/") { "ok" }
        get("/block") do
          started = Reprise::Telemetry.monotonic_now
          nil while Reprise::Telemetry.monotonic_now - started < 0.5
          "done"
        end
        # As the first request after a reload does, autoloading the app's code.
        get("/load") do
          started = Reprise::Telemetry.monotonic_now
          until Reprise::Telemetry.monotonic_now - started > 0.5
            Reprise::Reloader.loaded!
            nil while Reprise::Telemetry.monotonic_now - started < 0.05
          end
          "loaded"
        end
      end
    end

    it "logs while the event loop is blocked, and once it's running again, naming the request" do
      warnings = Thread::Queue.new
      allow(Console).to receive(:warn) { |_subject, message, **fields| warnings << [message, fields] }
      app = described_class.new(blocking.tap(&:finalize!), threshold: 0.1)

      Sync do
        # The first request starts the detector; its watchdog thread is running by the time the second blocks the loop.
        app.call(env_for("/"))
        sleep(0.05)
        app.call(env_for("/block?token=secret", "HTTP_X_REQUEST_ID" => "req-1"))
        sleep(0.1)
      end

      logged = Array.new(warnings.size) { warnings.pop }.to_h
      expect(logged.keys).to contain_exactly("Event loop is blocked", "Event loop was blocked")
      expect(logged["Event loop is blocked"][:backtrace]).to be_an(Array)
      expect(logged["Event loop is blocked"][:in_flight].sole).to include(path: "/block", query: "token=[FILTERED]", request_id: "req-1")
      expect(logged["Event loop was blocked"][:completed_during_stall].sole).to include(path: "/block")
    end

    it "doesn't report a stall while Reprise::Reloader loads the app's code" do
      allow(Console).to receive(:warn)
      app = described_class.new(blocking.tap(&:finalize!), threshold: 0.1)

      Sync do
        app.call(env_for("/"))
        sleep(0.05)
        expect(app.call(env_for("/load")).last).to eq(["loaded"])
        sleep(0.1)
      end

      expect(Console).not_to have_received(:warn)
    end

    it "doesn't take an idle loop's heartbeat interval for a stall" do
      stub_const("#{described_class}::HEARTBEAT_INTERVAL", 0.2)
      allow(Console).to receive(:warn)
      app = described_class.new(blocking.tap(&:finalize!), threshold: 0.1)

      Sync do
        app.call(env_for("/"))
        sleep(0.5)
      end

      expect(Console).not_to have_received(:warn)
    end

    it "passes requests through outside an event loop" do
      app = described_class.new(movies.tap(&:finalize!))

      expect(app.call(env_for("/movie/550")).first).to eq(200)
    end
  end

  describe Reprise::Telemetry::ReactorLag do
    it "samples the event loop's lag, once per loop, with metrics enabled" do
      Sync do
        task = described_class.start(interval: 0.005)
        expect(described_class.start(interval: 0.005)).to equal(task)
        sleep(0.05)
      end

      expect(data_points("reactor.lag").sole.count).to be >= 3
    end

    it "does nothing with metrics disabled, or outside an event loop" do
      expect(described_class.start).to be_nil
      stop_metrics

      expect(Sync { described_class.start }).to be_nil
    end
  end

  describe Reprise::Plugins::Telemetry do
    include Rack::Test::Methods

    let(:app) do
      Class.new(Reprise::App) do
        plugin Reprise::Plugins::Telemetry, requests: { log: false }, stalls: true, reactor_lag: { interval: 0.01 }
        get("/movie/:id") { "movie" }
      end
    end

    it "installs the middleware in the app" do
      get "/movie/550"

      expect(last_response.body).to eq("movie")
      expect(data_points("app.requests").sole.attributes).to include("route" => "/movie/:id")
      expect(app.middleware.map(&:first)).to eq(
        [Reprise::Telemetry::StallDetector, Reprise::Telemetry::ReactorLag::Middleware, Reprise::Telemetry::Requests]
      )
    end
  end
end
