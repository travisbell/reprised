# frozen_string_literal: true

require "opentelemetry-metrics-api"
require "opentelemetry/metrics/global"

module Reprised
  module Telemetry
    # Reprised's instruments, from the global meter provider. Until the app configures an SDK provider, they're the
    # API's no-ops (or proxies that start recording once it does), and enabled? is false.
    #
    # The SDK doesn't yet apply a histogram's advised bucket boundaries, so give the provider Reprised's views when
    # configuring it, or histograms get the SDK's defaults (which suit milliseconds, not seconds):
    #
    #   provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    #   Reprised::Telemetry::Metrics.add_views(provider)
    module Metrics
      METER_NAME = "reprised"
      # Upper bounds in seconds for *.duration histograms: requests.
      DURATION_BOUNDS = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30, 45, 60].freeze
      # Upper bounds in seconds for *.lag histograms, which are normally well under a millisecond.
      SHORT_DURATION_BOUNDS = [0.0001, 0.001, 0.005, 0.01, 0.025, 0.1, 0.5, 2.5].freeze
      VIEWS = { "*.duration" => DURATION_BOUNDS, "*.lag" => SHORT_DURATION_BOUNDS }.freeze

      LOCK = Mutex.new
      private_constant :LOCK

      class << self
        # Whether an SDK provider is configured, so recording does something. Anything that does work only to record a
        # metric can skip it otherwise.
        def enabled?
          provider = ::OpenTelemetry.meter_provider
          !(provider.instance_of?(::OpenTelemetry::Internal::ProxyMeterProvider) ||
            provider.instance_of?(::OpenTelemetry::Metrics::MeterProvider))
        end

        def counter(name, unit:, description:)
          instrument(name) { it.create_counter(name, unit:, description:) }
        end

        # Records seconds: name it *.duration or *.lag for Reprised's views to apply.
        def histogram(name, description:, boundaries: DURATION_BOUNDS)
          instrument(name) do
            it.create_histogram(name, unit: "s", description:, advisory: { explicit_bucket_boundaries: boundaries })
          end
        end

        # Adds a view for each of VIEWS to an SDK meter provider, so Reprised's histograms get its bucket boundaries.
        def add_views(provider)
          aggregation = ::OpenTelemetry::SDK::Metrics::Aggregation::ExplicitBucketHistogram
          VIEWS.each do |pattern, boundaries|
            provider.add_view(pattern, type: :histogram, aggregation: aggregation.new(boundaries:))
          end
          provider
        end

        private

        # Instruments by name, for the current provider: replaced when the app configures (or swaps) one.
        def instrument(name)
          provider = ::OpenTelemetry.meter_provider
          instruments = @instruments if provider.equal?(@provider)
          instruments&.[](name) || LOCK.synchronize do
            unless provider.equal?(@provider)
              @provider = provider
              @meter = provider.meter(METER_NAME, version: Reprised::VERSION)
              @instruments = {}
            end
            @instruments[name] ||= yield(@meter)
          end
        end
      end
    end
  end
end
