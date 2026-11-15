# frozen_string_literal: true

require "reprised/telemetry"

module Reprised
  module Plugins
    # Installs Reprised::Telemetry's middleware in the app:
    #
    #   plugin Reprised::Plugins::Telemetry,
    #     requests: { labels: ->(env) { { client: env["myapp.client"] } }, skip_paths: ["/healthcheck"] },
    #     stalls: { threshold: 0.5 },
    #     reactor_lag: true
    #
    # Each part takes true (its defaults), false, or its middleware's options. Request metrics and logs are on unless
    # turned off; the stall detector and reactor lag are opt-in. Installed in the app, the middleware sees only what the
    # app answers: put Reprised::Telemetry::Requests in config.ru instead to record what other middleware answers too.
    module Telemetry
      def self.install(app, requests: true, stalls: false, reactor_lag: false)
        app.use(Reprised::Telemetry::StallDetector, **options(stalls)) if stalls
        app.use(Reprised::Telemetry::ReactorLag::Middleware, **options(reactor_lag)) if reactor_lag
        app.use(Reprised::Telemetry::Requests, **options(requests)) if requests
      end

      def self.options(value) = value == true ? {} : value
      private_class_method :options
    end
  end
end
