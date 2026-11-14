# frozen_string_literal: true

# Sinatra's cost per request on an extracted route table, with bodies that do nothing, so routing and filters are
# most of what's measured. "baseline" is the same Sinatra with one route and no filters: the difference between them
# is roughly what routing costs.
#
#   cd spike/oracle && ORACLE_FIXTURE=../fixtures/tmdb-web.routes.json bundle exec ruby bench_sinatra.rb tmdb-web

app = ARGV.fetch(0)
ENV["ORACLE_FIXTURE"] ||= File.expand_path("../fixtures/#{app}.routes.json", __dir__)
require_relative "sinatra_oracle"
require_relative "../sample"

class Baseline < Sinatra::Base
  set :environment, :production
  set :host_authorization, { permitted_hosts: [] } # harness only: accept Rack::MockRequest's example.org
  set :logging, nil
  set :show_exceptions, false
  set :static, false
  disable :protection
  %w[GET POST PUT PATCH DELETE OPTIONS].each { |verb| route(verb, %r{.*}) { "" } }
end

apps = { "sinatra" => Oracle, "baseline (1 route, no filters)" => Baseline }

# Optionally compare an app's own routing patch: ROUTE_INDEX=path/to/route_index.rb, defining TMDb::RouteIndex
# (tmdb-api's, which tries only the routes sharing the path's first two literal segments).
if (route_index = ENV["ROUTE_INDEX"]) && File.exist?(route_index)
  module TMDb; end
  require File.expand_path(route_index)
  indexed = Class.new(Oracle) { include TMDb::RouteIndex }
  # RouteIndex#route! reads routes from the class it's given, so copy the table down.
  indexed.instance_variable_set(:@routes, Oracle.routes)
  indexed.instance_variable_set(:@filters, Oracle.filters)
  apps["sinatra + RouteIndex"] = indexed
end

sample = Spike::Sample.load(app)
sample.each do |kind, requests|
  envs = requests.map do |request|
    env = Rack::MockRequest.env_for("http://example.org", "REQUEST_METHOD" => request["verb"])
    env["PATH_INFO"] = request["path"]
    env["HTTP_ACCEPT"] = request["accept"] if request["accept"]
    env.freeze
  end

  apps.each do |name, rack_app|
    us = Spike::Sample.measure(envs) { rack_app.call(it.dup) }
    puts format("%-10s %-11s %-34s %8.1f µs/request  (%d requests)", app, kind, name, us, envs.size)
  end
end
