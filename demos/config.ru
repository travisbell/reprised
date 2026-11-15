# frozen_string_literal: true

# The demos, under Falcon: bundle exec rake demos (see README.md).

require_relative "app"
require "reprised/telemetry"

# The stall detector logs any request that blocks the event loop for half a second, such as /streaming/block.
use Reprised::Telemetry::StallDetector, threshold: 0.5
# A log line per request, labelled with its route's pattern rather than its path.
use Reprised::Telemetry::Requests

if Demos.development?
  # Reloads the app before the next request, after a file in demos/ changes.
  require "reprised/reloader"
  run Reprised::Reloader.new("Demos", files: [File.join(__dir__, "**", "*.rb")])
else
  Demos.finalize!
  run Demos
end
