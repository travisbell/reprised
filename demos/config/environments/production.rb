# frozen_string_literal: true

DemosApplication.configure do
  # Compiles the routes once the stack is built, rather than on the first request.
  config.warmup { Demos.finalize! }
end
