# frozen_string_literal: true

# Replays the Sinatra oracle's requests (spike/oracle/sinatra_oracle.rb) through Reprise::Router and reports every
# request where Reprise would choose a different route, different params, a different content type, or run
# different filters.
#
#   bundle exec ruby spike/differential.rb tmdb-web [index|trie] [router|app]
#
# The router level asks Reprise::Router directly. The app level replays the table into a Reprise::App and sends each
# request through Rack, so dispatch (conditions, filters, params, statuses) is compared too.
#
# Filters are compared unscoped (every matching filter, as Sinatra runs them). Owner scoping is layered on later.

require_relative "table"
require_relative "app_table"

app = ARGV.fetch(0) { abort("usage: differential.rb tmdb-web|tmdb-api [index|trie] [router|app]") }
matcher = ARGV.fetch(1, "index").to_sym
level = ARGV.fetch(2, "router")
table = level == "app" ? Spike::AppTable.load(app, matcher:) : Spike::Table.load(app, matcher:)
oracle_lines = File.foreach("#{Spike::ROOT}/results/#{app}.oracle.jsonl")
accepts = JSON.parse(oracle_lines.first).dig("meta", "accepts")
accepts = accepts.transform_values { Reprise::Negotiation.parse_accept(it) } unless level == "app"

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

    mismatches[key] << { verb: expected["verb"], path: expected["path"], accept: expected["accept"],
                         expected: expected[key], actual: value }
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
describe = ->(index) { index ? table.records.fetch(index).describe : "404" }

puts format("%s (%s matcher, %s level): %d requests compared in %.1fs", app, matcher, level, total, elapsed)
known.each { |reason, count| puts "  known: #{reason} (#{count} requests)" }
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
