# frozen_string_literal: true

# Dumps a Sinatra app's routes and filters, in the order Sinatra stores them, to JSON.
#
# Runs inside the target app's own bundle (it needs that app's Sinatra and code), e.g.
#
#   cd ~/workspace/tmdb-web && bundle exec ruby ~/workspace/reprise-router/spike/extract_routes.rb tmdb-web out.json
#   cd ~/workspace/tmdb-api && bundle exec ruby ~/workspace/reprise-router/spike/extract_routes.rb tmdb-api out.json
#
# Each record has a global definition index, so routes and filters can be replayed in exactly the original order.

kind, out = ARGV.shift(2)
abort("usage: extract_routes.rb tmdb-web|tmdb-api OUT.json") unless kind && out
out = File.expand_path(out)

require "bundler"
Bundler.setup(:default, :sinatra)
Bundler.require(:default, :sinatra)
require "sinatra/base"
require "json"

module RepriseExtract
  ROOT = Dir.pwd + "/"

  class << self
    def records = @records ||= []

    def record(app, type, verb, path, options, block)
      # Sinatra's `get` defines a HEAD route right after each GET one (Sinatra::MultiRoute's `route :get` doesn't).
      # Reprise's `get` does the same, so that's recorded as the GET route's head: true, not as a route of its own.
      last = records.last
      if verb == "HEAD" && last && last[:verb] == "GET" && last[:app] == app.name && last[:path] == serialize_path(path)
        last[:head] = true
        return
      end

      file, line = block&.source_location
      records << {
        index: records.size,
        app: app.name,
        type: type,
        verb: verb,
        head: (false if verb == "GET"),
        path: serialize_path(path),
        options: serialize_options(app, options),
        source: file && "#{file.delete_prefix(ROOT)}:#{line}"
      }.compact
    end

    def serialize_path(path)
      case path
      when String then { type: "string", value: path }
      when Regexp then { type: "regexp", value: path.source, flags: path.options }
      when Array then { type: "array", items: path.map { serialize_path(it) } }
      else { type: "other", value: path.inspect }
      end
    end

    def serialize_options(app, options)
      options.to_h do |key, value|
        values = Array(value).map { it.is_a?(Symbol) ? it.to_s : it }
        if key == :provides
          [key, { given: values, mime_types: values.flat_map { app.mime_types(it) } }]
        else
          [key, values]
        end
      end
    end
  end

  module Hook
    def route(verb, path, options = {}, &block)
      RepriseExtract.record(self, "route", verb, path, options.dup, block)
      super
    end

    def add_filter(type, path = /.*/, **options, &block)
      RepriseExtract.record(self, type.to_s, nil, path, options.dup, block)
      super
    end
  end
end

Sinatra::Base.singleton_class.prepend(RepriseExtract::Hook)

app = case kind
when "tmdb-web"
  require "./environment"
  require "./app"
  App
when "tmdb-api"
  require "./environment" # Requires app.rb itself.
  TMDb::API3
else
  abort("unknown app #{kind}")
end

records = RepriseExtract.records.select { it[:app] == app.name }
# An app that's moved to Reprise defines no Sinatra routes: don't overwrite a table with an empty one.
abort("#{kind}: #{app} defines no Sinatra routes; extract from a checkout that's still on Sinatra") if records.none? { it[:type] == "route" }

File.write(out, JSON.pretty_generate({
  app: kind,
  sinatra: Sinatra::VERSION,
  mustermann: Gem.loaded_specs["mustermann"]&.version&.to_s,
  extracted_at: Time.now.utc.iso8601,
  records: records
}))

counts = records.group_by { it[:type] }.transform_values(&:size)
$stderr.puts "#{kind}: #{counts.map { "#{_2} #{_1}" }.join(", ")} -> #{out}"
exit!(0) # Skip at_exit hooks (OTel shutdown, workers): nothing was started.
