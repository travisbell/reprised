# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "reprise"
require "rack/test"
require_relative "support/app_helpers"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include(AppHelpers, type: :app)
  config.define_derived_metadata(file_path: %r{/spec/reprise/app/}) { |metadata| metadata[:type] = :app }
end
