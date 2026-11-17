# frozen_string_literal: true

# What loads the demos: the configuration, booted for the environment, then the app.
require_relative "application"
DemosApplication.boot!
require_relative "../app"
