# frozen_string_literal: true

# Reprised's cost per request on an extracted route table, with bodies that do nothing:
#
# - router: finding the route (checking its conditions) and the filters that apply, which is what Sinatra's routing
#   does per request
# - app: a full Rack call through a Reprised::App, comparable with spike/oracle/bench_sinatra.rb's "sinatra" row
#
#   bundle exec ruby bench/routing.rb tmdb-web

require_relative "../spike/table"
require_relative "../spike/app_table"
require_relative "../spike/sample"

app = ARGV.fetch(0)
sample = Spike::Sample.load(app)
tables = Reprised::Router::MATCHERS.to_h { [it, Spike::Table.load(app, matcher: it)] }
rack_apps = { "reprised app (full Rack call)" => Spike::AppTable.load(app).app }
rack_apps["reprised app, controllers mounted"] = Spike::AppTable.load(app, controllers: true).app if app == "tmdb-web"

sample.each do |kind, requests|
  parsed = requests.map { it.merge("accept" => Reprised::Negotiation.parse_accept(it["accept"])) }
  tables.each do |matcher, table|
    us = Spike::Sample.measure(parsed) { table.dispatch(it["verb"], it["path"], it["accept"]) }
    puts format("%-10s %-11s %-34s %8.1f µs/request  (%d requests)", app, kind, "reprised router (#{matcher})", us, requests.size)
  end

  envs = requests.map do |request|
    env = Rack::MockRequest.env_for("http://example.org", "REQUEST_METHOD" => request["verb"])
    env["PATH_INFO"] = request["path"]
    env["HTTP_ACCEPT"] = request["accept"] if request["accept"]
    env.freeze
  end
  rack_apps.each do |name, rack_app|
    us = Spike::Sample.measure(envs) { rack_app.call(it.dup) }
    puts format("%-10s %-11s %-34s %8.1f µs/request  (%d requests)", app, kind, name, us, requests.size)
  end
end
