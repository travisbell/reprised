# frozen_string_literal: true

# Replays an extracted route table into a Reprise::App, as spike/oracle/sinatra_oracle.rb does into Sinatra, so the
# differential test can compare whole requests (status, route, params, content type, filters run) through Rack.
#
# With controllers: true, each controller file's routes and filters go into its own Reprise::Controller, mounted where
# the file's first definition was, and everything else stays on the app, which is how the app would be structured
# after migrating. Filters are then scoped to their controller.

require_relative "table"
require "rack/mock"

module Spike
  class AppTable
    # Custom conditions the fixtures use, written Sinatra-style (a class method calling `condition`), the way the apps
    # define them, so that path through Reprise is exercised too.
    module Conditions
      def only_provides(*types)
        condition { types.flat_map { Reprise::Negotiation.mime_types(it) }.any? { request.preferred_type.to_s.start_with?(it) } }
      end
    end

    CONTROLLER_FILE = %r{\Alib/controllers/[^:]+}

    attr_reader :app, :records

    def self.load(app_name, matcher: :index, controllers: false)
      new(JSON.parse(File.read("#{ROOT}/fixtures/#{app_name}.routes.json")), matcher:, controllers:)
    end

    # The controller file that defined record +index+, or :app.
    def owner_of(index) = @owners.fetch(index)

    def initialize(fixture, matcher:, controllers: false)
      @records = {}
      fixture.fetch("records").each do |raw|
        @records[raw["index"]] = Record.new(index: raw["index"], type: raw["type"], verb: raw["verb"], path: raw["path"],
          conditions: raw["options"], source: raw["source"])
      end
      records = fixture.fetch("records")
      @owners = records.to_h { [it["index"], (controllers && it["source"][CONTROLLER_FILE]) || :app] }

      @app = Class.new(Reprise::App) do
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
          mounted[owner] ||= Class.new(Reprise::Controller).tap { @app.mount(it) }
        end
        define(target, record)
      end
      @app.finalize!
    end

    private def define(target, record)
      index = record["index"]
      path = Table.to_pattern(record["path"])
      options = record["options"].to_h { |key, value| [key.to_sym, key == "provides" ? value["given"] : value] }

      case record["type"]
      when "before", "after"
        type = record["type"].to_sym
        # Sinatra's default filter path is /.*/; the fixtures record it explicitly.
        target.public_send(type, path, **options) { (env["oracle.#{type}"] ||= []) << index }
      when "route"
        target.public_send(record["verb"].downcase, path, options) do
          env["oracle.route"] = index
          env["oracle.params"] = params.to_h
          env["oracle.content_type"] = response["content-type"]
          ""
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
