# frozen_string_literal: true

# Replays an extracted route table into a Reprised::App, as spike/oracle/sinatra_oracle.rb does into Sinatra, so the
# differential test can compare whole requests (status, route, params, content type, filters run) through Rack.
#
# With controllers: true, each controller file's routes and filters go into its own Reprised::Controller, mounted where
# the file's first definition was, and everything else stays on the app, which is how the app would be structured
# after migrating. Filters are then scoped to their controller.

require_relative "table"
require "rack/mock"

module Spike
  class AppTable
    # Custom conditions the fixtures use, written Sinatra-style (a class method calling `condition`), the way the apps
    # define them, so that path through Reprised is exercised too.
    module Conditions
      def only_provides(*types)
        condition { types.flat_map { Reprised::Negotiation.mime_types(it) }.any? { request.preferred_type.to_s.start_with?(it) } }
      end
    end

    CONTROLLER_FILE = %r{\Alib/controllers/[^:]+}

    attr_reader :app, :records

    # +record+: whether route and filter bodies record what ran (for the differential test), or do nothing (for
    # benchmarks, so they measure Reprised rather than the recording).
    def self.load(app_name, matcher: :index, controllers: false, record: true)
      new(JSON.parse(File.read("#{ROOT}/fixtures/#{app_name}.routes.json")), matcher:, controllers:, record:)
    end

    # The controller file that defined record +index+, or :app.
    def owner_of(index) = @owners.fetch(index)

    def initialize(fixture, matcher:, controllers: false, record: true)
      @record = record
      @records = {}
      fixture.fetch("records").each do |raw|
        @records[raw["index"]] = Record.new(index: raw["index"], type: raw["type"], verb: raw["verb"],
          head: Table.head?(raw), path: raw["path"], conditions: raw["options"], source: raw["source"])
      end
      records = fixture.fetch("records")
      @owners = records.to_h { [it["index"], (controllers && it["source"][CONTROLLER_FILE]) || :app] }

      @app = Class.new(Reprised::App) do
        set :environment, :production
        set :raise_errors, false
        set :dump_errors, false
        set :matcher, matcher
        set :filter_overlap, :ignore
        register Conditions
        mime_type :merge_patch, "application/merge-patch+json"
      end

      mounted = {}
      records.each do |record|
        owner = @owners.fetch(record["index"])
        target = if owner == :app
          @app
        else
          mounted[owner] ||= Class.new(Reprised::Controller).tap { @app.mount(it) }
        end
        define(target, record)
      end
      @app.finalize!
    end

    private def define(target, record)
      index = record["index"]
      path = Table.to_pattern(record["path"])
      # Sinatra records a filter without a path as /.*/; the app, migrated, would define it without one.
      path = nil if record["type"] != "route" && path == /.*/
      options = record["options"].to_h { |key, value| [key.to_sym, key == "provides" ? value["given"] : value] }

      case record["type"]
      when "before", "after"
        type = record["type"].to_sym
        # Sinatra's default filter path is /.*/; the fixtures record it explicitly.
        if @record
          target.public_send(type, path, **options) { (env["oracle.#{type}"] ||= []) << index }
        else
          target.public_send(type, path, **options) { nil }
        end
      when "route"
        action = if @record
          proc do
            env["oracle.route"] = index
            env["oracle.params"] = params.to_h
            env["oracle.content_type"] = response["content-type"]
            ""
          end
        else
          proc { "" }
        end
        # `get` answers HEAD too; a GET route that didn't in Sinatra (Sinatra::MultiRoute's) is defined with `route`.
        if record["verb"] == "GET" && !Table.head?(record)
          target.route(:get, path, **options, &action)
        else
          target.public_send(record["verb"].downcase, path, options, &action)
        end
      end
    end

    def dispatch(verb, path, accept_header)
      env = Rack::MockRequest.env_for("http://example.org", "REQUEST_METHOD" => verb)
      env["PATH_INFO"] = path
      env["HTTP_ACCEPT"] = accept_header if accept_header
      status, = @app.call(env)

      {
        "status" => status,
        "route" => env["oracle.route"],
        "params" => env["oracle.params"],
        "content_type" => env["oracle.content_type"],
        "before" => env["oracle.before"] || [],
        "after" => env["oracle.after"] || []
      }
    end
  end
end
