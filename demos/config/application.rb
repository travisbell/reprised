# frozen_string_literal: true

require "reprised/application"
require "reprised/telemetry"

# The demos' configuration and boot (see "Application: configuration and boot" in the README): the middleware around
# the app, and, in config/environments/, what each environment changes. config.ru builds the stack from it.
class DemosApplication < Reprised::Application
  config.app = "Demos"

  # The stall detector logs any request that blocks the event loop for half a second, such as /streaming/block.
  config.middleware.use(Reprised::Telemetry::StallDetector, threshold: 0.5)
  # A log line per request, labelled with its route's pattern rather than its path.
  config.middleware.use(Reprised::Telemetry::Requests)
end
