# frozen_string_literal: true

require "logger"
require "opentelemetry/sdk"
require "opentelemetry-metrics-sdk"
require "opentelemetry-instrumentation-rack"

# One OpenTelemetry SDK for the process, as an app has. Spans go to SPANS; each spec resets it. Metrics need a provider
# of their own per example (see MetricsHelpers).
module OpenTelemetrySupport
  SPANS = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new

  OpenTelemetry::SDK.configure do |config|
    config.logger = Logger.new(File::NULL)
    config.use("OpenTelemetry::Instrumentation::Rack")
    config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(SPANS))
  end

  TRACER_MIDDLEWARE = OpenTelemetry::Instrumentation::Rack::Middlewares::Stable::TracerMiddleware

  # A fresh SDK meter provider, with Reprise's views, reading into an in-memory exporter.
  def start_metrics
    @metrics = OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new
    provider = Reprise::Telemetry::Metrics.add_views(OpenTelemetry::SDK::Metrics::MeterProvider.new)
    provider.add_metric_reader(@metrics)
    OpenTelemetry.meter_provider = provider
  end

  def stop_metrics = OpenTelemetry.meter_provider = OpenTelemetry::Metrics::MeterProvider.new

  # The data points recorded for the metric +name+.
  def data_points(name)
    @metrics.reset
    @metrics.pull
    @metrics.metric_snapshots.select { it.name == name }.flat_map(&:data_points)
  end
end
