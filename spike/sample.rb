# frozen_string_literal: true

# The benchmark request sample, drawn the same way in both bundles from the oracle's results: one answered request
# per route (the first in corpus order), and the first 200 unanswered ones.
require "json"

module Spike
  module Sample
    ROUTE_LIMIT = Float::INFINITY
    NOT_FOUND_LIMIT = 200

    def self.load(app)
      lines = File.foreach(File.expand_path("results/#{app}.oracle.jsonl", __dir__))
      accepts = JSON.parse(lines.first).dig("meta", "accepts")
      routed = {}
      not_found = []

      lines.drop(1).each do |line|
        request = JSON.parse(line)
        next if request["verb"] == "HEAD"

        entry = { "verb" => request["verb"], "path" => request["path"], "accept" => accepts.fetch(request["accept"]) }
        if request["route"]
          routed[request["route"]] ||= entry
        elsif not_found.size < NOT_FOUND_LIMIT && request["accept"] == "browser"
          not_found << entry
        end
      end

      { "routed" => routed.values, "not_found" => not_found }
    end

    # Runs the block over +requests+ until at least +seconds+ have passed, after a warmup pass, and returns
    # microseconds per request.
    def self.measure(requests, seconds: 1.5)
      requests.each { yield(it) }
      count = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while (elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < seconds
        requests.each { yield(it) }
        count += requests.size
      end
      elapsed / count * 1_000_000
    end
  end
end
