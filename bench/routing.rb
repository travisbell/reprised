# frozen_string_literal: true

# Reprise's routing cost per request on an extracted route table: finding the route (checking its conditions) and
# the before and after filters that apply, which is what Sinatra's routing does per request.
#
#   bundle exec ruby bench/routing.rb tmdb-web

require_relative "../spike/table"
require_relative "../spike/sample"

app = ARGV.fetch(0)
sample = Spike::Sample.load(app)

tables = Reprise::Router::MATCHERS.to_h { [it, Spike::Table.load(app, matcher: it)] }

sample.each do |kind, requests|
  requests = requests.map { it.merge("accept" => Reprise::Negotiation.parse_accept(it["accept"])) }
  tables.each do |matcher, table|
    us = Spike::Sample.measure(requests) { table.dispatch(it["verb"], it["path"], it["accept"]) }
    puts format("%-10s %-11s %-34s %8.1f µs/request  (%d requests)", app, kind, "reprise #{matcher}", us, requests.size)
  end
end
