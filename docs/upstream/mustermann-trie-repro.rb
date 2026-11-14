# frozen_string_literal: true

# Standalone reproduction for docs/upstream/mustermann-trie.md. Prints each case with the trie and linear results.
#
#   ruby docs/upstream/mustermann-trie-repro.rb

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "mustermann", ENV.fetch("MUSTERMANN_VERSION", "4.0.1")
end

require "mustermann/set"
require "mustermann/version"

CASES = [
  ["/movie/:id/?", "/movie/550/"],
  ["/movie/:id.json", "/movie/550"],
  ["/movie/:id.json", "/movie/550.json"],
  ["/account/?", "/account"],
  ["/account/*", "/account/"],
  ["/tv/:id/edit/?*", "/tv/1/edit/images"],
  ["/tv/:id/edit/?*", "/tv/1/edit"],
  ["/a/:b?", "/a/"],
  ["/a/:b?/c", "/a//c"]
].freeze

def matches(pattern, path, use_trie:)
  set = Mustermann::Set.new(use_trie:, use_cache: false)
  set.add(pattern, :value)
  set.match_all(path).map(&:params)
end

puts "mustermann #{Mustermann::VERSION}"
CASES.each do |pattern, path|
  trie = matches(pattern, path, use_trie: true)
  linear = matches(pattern, path, use_trie: false)
  puts format("%-6s %-18s %-20s trie=%-40s linear=%s",
    trie == linear ? "ok" : "DIFF", pattern, path.inspect, trie.inspect, linear.inspect)
end
