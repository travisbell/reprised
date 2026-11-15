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
end
