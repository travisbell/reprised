# frozen_string_literal: true

# Sinatra 4.2 + Tilt rendering cost, for comparison with bench/templates.rb: a layout, a template, and a nested
# partial, through a full Rack call.
#
#   cd spike/oracle && bundle exec ruby bench_templates.rb

require "bundler/setup"
require "sinatra/base"
require "rack/mock"
require "erubi/capture_block"
require_relative "../sample"

class Rendered < Sinatra::Base
  set :environment, :production
  set :host_authorization, { permitted_hosts: [] } # harness only: accept Rack::MockRequest's example.org
  set :views, File.expand_path("../../spec/fixtures/views", __dir__)
  set :erb, engine_class: Erubi::CaptureBlockEngine
  helpers { def movie_title = "Fight Club" }
  get("/") { erb :"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: Array.new(20) { "Actor #{it}" } } }
end

env = Rack::MockRequest.env_for("http://example.org/").freeze
us = Spike::Sample.measure([env]) { Rendered.call(it.dup) }
puts format("%-40s %8.1f µs/request", "sinatra + tilt (layout, template, partial)", us)
