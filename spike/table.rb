# frozen_string_literal: true

# Loads an extracted route table (spike/extract_routes.rb) into Reprise routers, for spike/differential.rb and the
# benchmarks. Conditions are the ones the TMDB fixtures use: provides, and tmdb-web's only_provides.

require "bundler/setup"
require "json"
require_relative "../lib/reprise"

module Spike
  ROOT = __dir__

  Record = Data.define(:index, :type, :verb, :head, :path, :conditions, :source) do
    def describe = "##{index} #{verb} #{path["value"] || path} (#{source})"
  end

  class Table
    attr_reader :app, :records, :routes, :filters

    def self.load(app, matcher: :index)
      new(app, JSON.parse(File.read("#{ROOT}/fixtures/#{app}.routes.json")), matcher:)
    end

    def initialize(app, fixture, matcher:)
      @app = app
      @records = {}
      @routes = Reprise::Router.new(matcher:)
      @filters = { "before" => Reprise::Router.new(matcher:), "after" => Reprise::Router.new(matcher:) }

      fixture.fetch("records").each do |raw|
        record = Record.new(index: raw["index"], type: raw["type"], verb: raw["verb"], head: Table.head?(raw),
          path: raw["path"], conditions: raw["options"], source: raw["source"])
        @records[record.index] = record
        router = record.type == "route" ? @routes : @filters.fetch(record.type)
        lanes = record.type != "route" ? [:any] : [record.verb, *("HEAD" if record.head)]
        lanes.each { router.add(it, self.class.to_pattern(raw["path"]), record) }
      end

      @routes.finalize!
      @filters.each_value(&:finalize!)
    end

    # Whether a GET record also answers HEAD. Tables extracted before this was recorded assume every GET route does.
    def self.head?(raw) = raw["verb"] == "GET" && raw.fetch("head", true)

    def self.to_pattern(spec)
      case spec["type"]
      when "string" then spec["value"]
      when "regexp" then Regexp.new(spec["value"], spec["flags"])
      when "array" then spec["items"].map { to_pattern(it) }
      else raise "unsupported path #{spec.inspect}"
      end
    end

    # What Reprise decides for a request: the route (or nil), its params and content type, and the filters that run.
    def dispatch(verb, path, accept)
      content_type = nil
      record, params = @routes.find(verb, path) do |candidate, _params|
        matched, content_type = check_conditions(candidate, accept)
        matched
      end

      {
        "route" => record&.index,
        "params" => record && params,
        "content_type" => record && content_type,
        "before" => @filters["before"].each(:any, path).map { |filter, _| filter.index },
        "after" => @filters["after"].each(:any, path).map { |filter, _| filter.index }
      }
    end

    # Returns [matched, content_type].
    def check_conditions(record, accept)
      content_type = nil
      record.conditions.each do |name, value|
        case name
        when "provides"
          content_type = Reprise::Negotiation.preferred_type(accept, value.fetch("mime_types")) or return [false, nil]
        when "only_provides"
          first = accept.first.to_s
          types = value.flat_map { Reprise::Negotiation.mime_types(it) }
          return [false, nil] unless types.any? { first.start_with?(it) }
        else
          raise "unknown condition #{name}"
        end
      end
      [true, content_type]
    end
  end
end
