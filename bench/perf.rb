# frozen_string_literal: true

# Reprise's cost per request, end to end through Rack, on workloads that each stress one part of it. Reports time and
# object allocations per request.
#
#   bundle exec ruby bench/perf.rb                 # interpreter
#   bundle exec ruby --yjit bench/perf.rb          # YJIT, as production runs
#   bundle exec ruby --yjit bench/perf.rb api erb  # only some workloads
#
# With the private route tables present (spike/fixtures), the TMDB apps' tables are measured too.

require "bundler/setup"
require "rack/mock"
require_relative "../lib/reprise"

module Bench
  VIEWS = File.expand_path("../spec/fixtures/views", __dir__)

  def self.env(path, method: "GET", accept: nil, query: "")
    env = Rack::MockRequest.env_for("http://example.org", "REQUEST_METHOD" => method)
    env["PATH_INFO"] = path
    env["QUERY_STRING"] = query
    env["HTTP_ACCEPT"] = accept if accept
    env.freeze
  end

  JSON_ACCEPT = "application/json, text/javascript, */*; q=0.01"
  BROWSER_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"

  class Hello < Reprise::App
    set :environment, :production
    get("/") { "hi" }
  end

  class Api < Reprise::App
    set :environment, :production
    before { @user = request.env["HTTP_AUTHORIZATION"] }
    after { response["x-served-by"] = "bench" }
    get("/3/movie/:id", provides: :json) { |id| json(id:, page: params[:page], language: params[:language]) }
    get("/3/movie/:id") { "html" }
  end

  class MovieController < Reprise::Controller
    before("/movie/:id/*") { @movie_id = params[:id] }
    get("/movie/:id/cast") { "cast of #{@movie_id} #{title}" }

    private def title = "Fight Club"
  end

  class PersonController < Reprise::Controller
    before("/person/*") { @person = true }
    get("/person/:id") { "person" }
  end

  class Controllers < Reprise::App
    set :environment, :production
    set :filter_overlap, :ignore
    before { @global = true }
    mount MovieController, PersonController
  end

  class Rendered < Reprise::App
    set :environment, :production
    set :views, VIEWS
    helpers { def movie_title = "Fight Club" }
    get("/") { erb :"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: Array.new(20) { "Actor #{it}" } } }
  end

  WORKLOADS = { # rubocop:disable Style/MutableConstant -- the TMDB tables are added below, when present
    "hello" => [Hello, [env("/")]],
    "api" => [Api, [env("/3/movie/550", accept: JSON_ACCEPT, query: "language=en-US&page=2")]],
    "api 404" => [Api, [env("/3/nope", accept: JSON_ACCEPT)]],
    "controller" => [Controllers, [env("/movie/550/cast", accept: BROWSER_ACCEPT)]],
    "erb" => [Rendered, [env("/")]]
  }

  fixtures = File.expand_path("../spike/fixtures", __dir__)
  if File.exist?("#{fixtures}/tmdb-web.routes.json") && File.exist?(File.expand_path("../spike/results/tmdb-web.oracle.jsonl", __dir__))
    require_relative "../spike/app_table"
    require_relative "../spike/sample"
    ["tmdb-web", "tmdb-api"].each do |name|
      sample = Spike::Sample.load(name)
      app = Spike::AppTable.load(name, controllers: name == "tmdb-web").app
      to_env = ->(request) { env(request["path"], method: request["verb"], accept: request["accept"]) }
      WORKLOADS["#{name} routed"] = [app, sample["routed"].map(&to_env)]
      WORKLOADS["#{name} 404"] = [app, sample["not_found"].map(&to_env)]
    end
  end

  def self.measure(app, envs, seconds: 2.0)
    run = -> { envs.each { |env| app.call(env.dup).last.then { it.close if it.respond_to?(:close) } } }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    run.() while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline # warm up (and let YJIT compile)

    rounds = Array.new(10) do
      count = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while (elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < seconds / 10
        run.()
        count += envs.size
      end
      elapsed / count * 1_000_000
    end.sort

    GC.start
    before = GC.stat(:total_allocated_objects)
    run.()
    allocations = (GC.stat(:total_allocated_objects) - before).fdiv(envs.size)

    # The median, and the spread between the fastest and slowest rounds.
    [rounds[5], (rounds[-1] - rounds[0]) / rounds[5] * 100, allocations]
  end

  def self.run(names)
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "interpreter"
    puts format("%-18s %10s %8s %12s   (%s, Ruby %s)", "workload", "µs/req", "±%", "allocs/req", jit, RUBY_VERSION)
    WORKLOADS.each do |name, (app, envs)|
      next unless names.empty? || names.any? { name.start_with?(it) }

      us, spread, allocations = measure(app, envs)
      puts format("%-18s %10.2f %7.1f%% %12.1f", name, us, spread, allocations)
    end
  end
end

Bench.run(ARGV) if $PROGRAM_NAME == __FILE__
