# frozen_string_literal: true

require_relative "lib/reprise/version"

Gem::Specification.new do |spec|
  spec.name = "reprise-router"
  spec.version = Reprise::VERSION
  spec.authors = ["Travis Bell"]
  spec.email = ["me@travisbell.com"]

  spec.summary = "A Sinatra-compatible Rack router for Ruby 4, built on Mustermann and designed for Falcon and Async."
  spec.description = <<~DESCRIPTION
    Reprise keeps Sinatra's controller DSL (routes, filters, conditions, halt,
    pass, erb) and drops the rest. Routes dispatch through an index over
    Mustermann patterns in Sinatra's first-defined-wins order, controllers get
    private helpers, and the request scope is fiber-safe and frozen after boot.
  DESCRIPTION
  spec.homepage = "https://github.com/travisbell/reprise-router"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["reprise"]
  spec.require_paths = ["lib"]

  spec.add_dependency("erubi", "~> 1.13")
  spec.add_dependency("mustermann", ">= 3.1", "< 5")
  spec.add_dependency("rack", "~> 3.2")
end
