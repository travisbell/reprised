# frozen_string_literal: true

# Replays the Sinatra oracle's requests (spike/oracle/sinatra_oracle.rb) through Reprise::Router and reports every
# request where Reprise would choose a different route, different params, a different content type, or run
# different filters.
#
#   bundle exec ruby spike/differential.rb tmdb-web [index|trie]
#
# Filters are compared unscoped (every matching filter, as Sinatra runs them). Owner scoping is layered on later.

require_relative "table"

app = ARGV.fetch(0) { abort("usage: differential.rb tmdb-web|tmdb-api [index|trie]") }
matcher = ARGV.fetch(1, "index").to_sym
table = Spike::Table.load(app, matcher:)
oracle_lines = File.foreach("#{Spike::ROOT}/results/#{app}.oracle.jsonl")
accepts = JSON.parse(oracle_lines.first).dig("meta", "accepts").transform_values { Reprise::Negotiation.parse_accept(it) }

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

puts format("%s (%s matcher): %d requests compared in %.1fs", app, matcher, total, elapsed)
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
