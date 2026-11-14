# frozen_string_literal: true

# Reprise's rendering cost: a layout, a template, and a nested partial, through a full Rack call. Compare with
# spike/oracle/bench_templates.rb (Sinatra + Tilt).
#
#   bundle exec ruby bench/templates.rb

require "bundler/setup"
require "rack/mock"
require_relative "../lib/reprise"
require_relative "../spike/sample"

class Rendered < Reprise::App
  set :environment, :production
  set :views, File.expand_path("../spec/fixtures/views", __dir__)
  helpers { def movie_title = "Fight Club" }
  get("/") { erb :"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: Array.new(20) { "Actor #{it}" } } }
end

env = Rack::MockRequest.env_for("http://example.org/").freeze
us = Spike::Sample.measure([env]) { Rendered.call(it.dup) }
puts format("%-40s %8.1f µs/request", "reprise (layout, template, partial)", us)
