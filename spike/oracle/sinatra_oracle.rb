# frozen_string_literal: true

# Replays an extracted route table (spike/extract_routes.rb) into a bare Sinatra 4.2 app, sends it a generated corpus
# of requests, and records what Sinatra decided for each: which route answered, its params, the content type a
# `provides` condition set, and which filters ran. spike/differential.rb then asks Reprise the same questions.
#
#   cd spike/oracle && bundle exec ruby sinatra_oracle.rb ../fixtures/tmdb-web.routes.json ../results/tmdb-web.oracle.jsonl
#
# Route and filter bodies only record; they never halt, so every matching filter runs and routing is all that's
# measured.

# Loading this file defines Oracle from ORACLE_FIXTURE (or the first argument); running it also sends the corpus.
fixture_path = ENV.fetch("ORACLE_FIXTURE") { ARGV[0] }
abort("usage: sinatra_oracle.rb FIXTURE.json OUT.jsonl") unless fixture_path

require "bundler/setup"
require "sinatra/base"
require "json"
require "fileutils"

FIXTURE = JSON.parse(File.read(fixture_path))
RECORDS = FIXTURE.fetch("records")

ACCEPTS = {
  "browser" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
  "jquery_json" => "application/json, text/javascript, */*; q=0.01",
  "json" => "application/json",
  "any" => "*/*",
  "none" => nil
}.freeze

# Parameter values chosen to collide with things: numeric ids, slugs, BSON ids, static sibling segments ("new"),
# non-ASCII, and a nested splat.
SAMPLE_VALUES = ["550", "550-fight-club", "5f1e7a3c9d1b2a0012345678", "new", "café"].freeze
SPLAT_VALUE = "a/b"

# Hand-picked paths for the regexp routes, which the corpus can't generate by expanding patterns. They name an app's
# own routes, so they live beside its private route table: fixtures/<app>.extra_paths.json, a JSON array of paths.
EXTRA_PATHS_FILE = File.join(File.dirname(fixture_path), "#{FIXTURE["app"]}.extra_paths.json")
EXTRA_PATHS = File.exist?(EXTRA_PATHS_FILE) ? JSON.parse(File.read(EXTRA_PATHS_FILE)).freeze : [].freeze

NOT_FOUND_PATHS = ["", "/", "//", "/nope", "/nope/", "/movie", "/movie/", "/movie//cast", "/3", "/3/", "/3/nope"].freeze

module Corpus
  module_function

  def to_path(spec)
    case spec["type"]
    when "string" then spec["value"]
    when "regexp" then Regexp.new(spec["value"], spec["flags"])
    when "array" then spec["items"].map { to_path(it) }
    else raise "unsupported path #{spec.inspect}"
    end
  end

  def string_patterns(spec)
    case spec["type"]
    when "string" then [spec["value"]]
    when "array" then spec["items"].flat_map { string_patterns(it) }
    else []
    end
  end

  def sample_paths(pattern_string)
    pattern = Mustermann.new(pattern_string)
    SAMPLE_VALUES.filter_map do |value|
      values = pattern.names.to_h { [it, it == "splat" ? [SPLAT_VALUE] * pattern.to_s.count("*") : value] }
      pattern.expand(:ignore, values)
    rescue Mustermann::ExpandError, ArgumentError
      nil
    end.uniq
  end

  def corpus
    paths = RECORDS.flat_map { string_patterns(it["path"]) }.flat_map { sample_paths(it) }
    paths += EXTRA_PATHS + NOT_FOUND_PATHS
    paths += paths.reject { it.end_with?("/") || it.empty? }.map { "#{it}/" }
    paths.uniq.sort
  end
end

class Oracle < Sinatra::Base
  set :environment, :production
  set :host_authorization, { permitted_hosts: [] } # harness only: accept Rack::MockRequest's example.org
  set :logging, nil
  set :raise_errors, false
  set :show_exceptions, false
  set :dump_errors, false
  set :static, false
  disable :protection

  # Custom conditions the fixtures use, with the same definitions as the apps.
  def self.only_provides(*types)
    condition do
      types.flat_map { Sinatra::Base.mime_types(it) }.any? { request.preferred_type.to_s.start_with?(it) }
    end
  end

  def self.takes_bson_id(*keys)
    condition { keys.all? { params[it].to_s.match?(/\A\h{24}\z/) } }
  end

  mime_type(:merge_patch, "application/merge-patch+json") # tmdb-api

  RECORDS.each do |record|
    index = record["index"]
    path = Corpus.to_path(record["path"])
    options = record["options"].to_h do |key, value|
      [key.to_sym, key == "provides" ? value["given"] : value]
    end

    case record["type"]
    when "before", "after"
      type = record["type"]
      send(type, path, **options) { (env["oracle.#{type}"] ||= []) << index }
    when "route"
      # Sinatra's `get` also defines a HEAD route for the same path, right after the GET one. The extractor leaves
      # those out, so put them back.
      verbs = record["verb"] == "GET" ? ["GET", "HEAD"] : [record["verb"]]
      verbs.each do |verb|
        route(verb, path, options.dup) do
          env["oracle.route"] = index
          env["oracle.params"] = params.to_h
          env["oracle.content_type"] = response["content-type"]
          ""
        end
      end
    end
  end
end

return unless $PROGRAM_NAME == __FILE__

out_path = ARGV[1] or abort("usage: sinatra_oracle.rb FIXTURE.json OUT.jsonl")
FileUtils.mkdir_p(File.dirname(out_path))
verbs = RECORDS.filter_map { it["verb"] }.uniq.sort + ["HEAD"]
paths = Corpus.corpus
count = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

File.open(out_path, "w") do |out|
  out.puts(JSON.generate({ meta: { app: FIXTURE["app"], paths: paths.size, verbs:, accepts: ACCEPTS } }))

  paths.each do |path|
    verbs.each do |verb|
      ACCEPTS.each do |accept_name, accept|
        env = Rack::MockRequest.env_for("http://example.org", "REQUEST_METHOD" => verb)
        env["PATH_INFO"] = path # Set directly so "", "//" and %-escapes reach the router untouched.
        env["HTTP_ACCEPT"] = accept if accept
        status, = Oracle.call(env)

        out.puts(JSON.generate({
          verb:, path:, accept: accept_name, status:,
          route: env["oracle.route"], params: env["oracle.params"], content_type: env["oracle.content_type"],
          before: env["oracle.before"] || [], after: env["oracle.after"] || [],
          error: env["sinatra.error"]&.then { "#{it.class}: #{it.message}" unless it.is_a?(Sinatra::NotFound) }
        }))
        count += 1
      end
    end
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
$stderr.puts format("%s: %d paths, %d requests in %.1fs (%.1f µs/request) -> %s",
  FIXTURE["app"], paths.size, count, elapsed, elapsed / count * 1_000_000, out_path)
