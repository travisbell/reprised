# frozen_string_literal: true

require "reprised/plugins/open_telemetry"
require "rack/builder"
require_relative "../../support/open_telemetry"

RSpec.describe Reprised::Plugins::OpenTelemetry do
  include Rack::Test::Methods

  let(:skipped) { Class.new(StandardError) }
  let(:options) { {} }

  attr_reader :app

  before do
    OpenTelemetrySupport::SPANS.reset
    skipped_error = skipped
    plugin_options = options.merge(skip_errors: [skipped_error])
    reprised_app = Class.new(Reprised::App) do
      set :raise_errors, false
      set :dump_errors, false
      plugin Reprised::Plugins::OpenTelemetry, **plugin_options
      get("/movie/:id") { "movie" }
      get("/boom") { raise ArgumentError, "boom" }
      get("/skipped") { raise skipped_error }
    end
    @app = Rack::Builder.app do
      use OpenTelemetrySupport::TRACER_MIDDLEWARE
      run reprised_app
    end
  end

  def span = OpenTelemetrySupport::SPANS.finished_spans.last

  it "names the span after the route, and sets http.route" do
    get "/movie/550"

    expect(span.name).to eq("GET /movie/:id")
    expect(span.attributes["http.route"]).to eq("/movie/:id")
  end

  context "with span_name" do
    let(:options) { { span_name: ->(route) { route.pattern } } }

    it "names the span with it" do
      get "/movie/550"

      expect(span.name).to eq("/movie/:id")
    end
  end

  it "records a server error's exception, and sets the span's status" do
    get "/boom"

    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(span.events.map(&:name)).to include("exception")
    expect(span.events.find { it.name == "exception" }.attributes["exception.message"]).to eq("boom")
  end

  it "doesn't record errors it's told to skip" do
    get "/skipped"

    expect(last_response.status).to eq(500)
    expect(span.events.to_a.map(&:name)).not_to include("exception")
  end

  it "leaves a 404 that matched no route alone" do
    get "/nope"

    expect(span.attributes).not_to have_key("http.route")
  end

  context "with trace_header" do
    let(:options) { { trace_header: "x-trace-id" } }

    it "sends the request's trace id" do
      get "/movie/550"

      expect(last_response.headers["x-trace-id"]).to eq(span.hex_trace_id)
    end
  end

  context "with log_context" do
    let(:log_context) do
      Module.new do
        def self.with(attributes)
          previous = Fiber[:test_log_context]
          Fiber[:test_log_context] = attributes
          yield
        ensure
          Fiber[:test_log_context] = previous
        end

        def self.route = Fiber[:test_log_context]&.fetch("http.route")&.call
      end
    end
    let(:options) { { log_context: log_context } }

    it "runs the request with the route that's answering, and sends no trace id outside a trace" do
      context = log_context
      seen = []
      reprised_app = Class.new(Reprised::App) do
        set :raise_errors, false
        set :dump_errors, false
        plugin Reprised::Plugins::OpenTelemetry, log_context: context, trace_header: "x-trace-id"
        before { seen << context.route }
        get("/movie/:id") do
          seen << context.route
          pass if params[:id] == "top-rated"
          "movie"
        end
        get("/movie/top-rated") do
          seen << context.route
          "top rated"
        end
      end
      @app = reprised_app

      get "/movie/top-rated"

      expect(last_response.body).to eq("top rated")
      expect(seen).to eq(["/movie/:id", "/movie/:id", "/movie/top-rated"])
      expect(context.route).to be_nil
      expect(last_response.headers).not_to have_key("x-trace-id") # no tracer, so no trace
    end
  end
end
