# frozen_string_literal: true

# Replays the Sinatra oracle's requests (spike/oracle/sinatra_oracle.rb) through Reprise::Router and reports every
# request where Reprise would choose a different route, different params, a different content type, or run
# different filters.
#
#   bundle exec ruby spike/differential.rb tmdb-web [index|trie] [router|app|controllers]
#
# The router level asks Reprise::Router directly. The app level replays the table into a Reprise::App and sends each
# request through Rack, so dispatch (conditions, filters, params, statuses) is compared too. At those levels every
# definition belongs to the app, so filters run unscoped, as Sinatra runs them.
#
# The controllers level puts each controller file's definitions in a mounted Reprise::Controller, as the app would be
# after migrating. Filters are then scoped to their controller, and the report classifies each filter difference that
# scoping explains: a controller's filters not running on a 404, or for another controller's route.

require_relative "table"
require_relative "app_table"

app = ARGV.fetch(0) { abort("usage: differential.rb tmdb-web|tmdb-api [index|trie] [router|app|controllers]") }
matcher = ARGV.fetch(1, "index").to_sym
level = ARGV.fetch(2, "router")
table = case level
when "router" then Spike::Table.load(app, matcher:)
when "app" then Spike::AppTable.load(app, matcher:)
when "controllers" then Spike::AppTable.load(app, matcher:, controllers: true)
else abort("unknown level #{level}")
end
oracle_lines = File.foreach("#{Spike::ROOT}/results/#{app}.oracle.jsonl")
accepts = JSON.parse(oracle_lines.first).dig("meta", "accepts")
accepts = accepts.transform_values { Reprise::Negotiation.parse_accept(it) } if level == "router"
skipped_for = Hash.new(0)

mismatches = Hash.new { |h, k| h[k] = [] }
known = Hash.new(0)
total = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

oracle_lines.drop(1).each do |line|
  expected = JSON.parse(line)
  total += 1
  actual = table.dispatch(expected["verb"], expected["path"], accepts.fetch(expected["accept"]))

  actual.each do |key, value|
    next if value == expected[key]

    # Known, intended: Sinatra leaks a regexp filter's params["captures"] into the route that runs after it
    # (process_route restores the filter's other params, but not captures). Reprise scopes filter params to the
    # filter. Neither app reads captures outside the filter or route that set them.
    if key == "params" && expected[key]&.key?("captures") && expected[key].except("captures") == value
      known["filter captures don't leak into the route"] += 1
      next
    end

    # Known, intended at the controllers level: a controller's filters run only for its own routes.
    if level == "controllers" && ["before", "after"].include?(key)
      route_owner = expected["route"] && table.owner_of(expected["route"])
      scoped = expected[key].select { [:app, route_owner].include?(table.owner_of(it)) }
      if scoped == value
        if route_owner
          known["controller filters skipped for another controller's route"] += 1
          (expected[key] - scoped).each { skipped_for[[it, expected["route"]]] += 1 }
        else
          known["controller filters don't run on 404s"] += 1
        end
        next
      end
    end

    mismatches[key] << { verb: expected["verb"], path: expected["path"], accept: expected["accept"],
                         expected: expected[key], actual: value }
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
describe = ->(index) { index ? table.records.fetch(index).describe : "404" }

puts format("%s (%s matcher, %s level): %d requests compared in %.1fs", app, matcher, level, total, elapsed)
known.each { |reason, count| puts "  known: #{reason} (#{count} requests)" }
skipped_for.group_by { |(filter, route), _| [filter, table.records.fetch(route).describe] }.each do |(filter, route), group|
  puts "    #{table.records.fetch(filter).describe}\n      skipped for #{route} (#{group.sum { it[1] }} requests)"
end
puts "  no differences" if mismatches.empty?

mismatches.each do |key, list|
  puts "  #{key}: #{list.size} differences"
  list.group_by { [it[:expected], it[:actual]] }.first(15).each do |(expected, actual), group|
    sample = group.first
    if key == "route"
      puts "    sinatra #{describe.(expected)}\n      reprise #{describe.(actual)}"
    else
      puts "    sinatra #{expected.inspect}\n      reprise #{actual.inspect}"
    end
    puts "      e.g. #{sample[:verb]} #{sample[:path].inspect} accept=#{sample[:accept]} (#{group.size} requests)"
  end
end

exit(mismatches.empty? ? 0 : 1)
