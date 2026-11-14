# frozen_string_literal: true

# Compares Reprise with Sinatra, Roda, and Hanami (hanami-router with Hanami::Action) on the same workloads, each written
# the way that framework is meant to be used. Every app is checked to give the expected response before it's measured.
#
#   cd bench/frameworks && bundle install
#   bundle exec ruby --yjit bench.rb               # every workload
#   bundle exec ruby --yjit bench.rb params erb    # some
#
# Each framework and workload runs in a process of its own: time is the median of ten rounds, after a warm-up, and
# allocations are per request.

require "bundler/setup"
require "json"
require "rack/mock"
require "reprise"
require "sinatra/base"
require "roda"
require "hanami/router"
require "hanami/action"

VIEWS = File.expand_path("../../spec/fixtures/views", __dir__)
RESOURCES = 500
CAST = Array.new(20) { "Actor #{it}" }.freeze

# -- Reprise ------------------------------------------------------------------------------------------------------------

module RepriseApps
  def self.app(&) = Class.new(Reprise::App) { set :environment, :production }.tap { it.class_eval(&) }.tap(&:finalize!)

  HELLO = app { get("/") { "Hello World" } }
  PARAMS = app { get("/users/:id") { |id| json(id:, fields: params[:fields]) } }
  FILTERS = app do
    before { @user = "ana" }
    after { response["x-served-by"] = "bench" }
    get("/users/:id") { "#{@user} #{params[:id]}" }
  end
  LARGE = app do
    RESOURCES.times do |n|
      get("/r#{n}") { "index" }
      get("/r#{n}/:id") { |id| "show #{id}" }
    end
  end
  ERB = app do
    set(:views, VIEWS)
    helpers { def movie_title = "Fight Club" }
    get("/") { erb(:"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: CAST }) }
  end
end

# -- Sinatra ------------------------------------------------------------------------------------------------------------

module SinatraApps
  def self.app(&)
    Class.new(Sinatra::Base) do
      set :environment, :production
      set :host_authorization, { permitted_hosts: [] } # accept Rack::MockRequest's example.org
      disable :protection, :logging, :static, :show_exceptions, :dump_errors
    end.tap { it.class_eval(&) }
  end

  HELLO = app { get("/") { "Hello World" } }
  PARAMS = app do
    get("/users/:id") do |id|
      content_type(:json)
      JSON.generate(id:, fields: params[:fields])
    end
  end
  FILTERS = app do
    before { @user = "ana" }
    after { response["x-served-by"] = "bench" }
    get("/users/:id") { "#{@user} #{params[:id]}" }
  end
  LARGE = app do
    RESOURCES.times do |n|
      get("/r#{n}") { "index" }
      get("/r#{n}/:id") { |id| "show #{id}" }
    end
  end
  ERB = app do
    set(:views, VIEWS)
    helpers { def movie_title = "Fight Club" }
    get("/") { erb(:"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: CAST }) }
  end
end

# -- Roda ---------------------------------------------------------------------------------------------------------------

module RodaApps
  def self.app(&) = Class.new(Roda, &).tap { it.freeze }.app

  HELLO = app { route { |r| r.root { "Hello World" } } }
  PARAMS = app do
    route do |r|
      r.get("users", String) do |id|
        response["content-type"] = "application/json"
        JSON.generate(id:, fields: r.params["fields"])
      end
    end
  end
  FILTERS = app do
    plugin(:hooks)
    before { @user = "ana" }
    after { |result| result[1]["x-served-by"] = "bench" if result }
    route { |r| r.get("users", String) { |id| "#{@user} #{id}" } }
  end
  LARGE = app do
    plugin(:hash_branches)
    RESOURCES.times do |n|
      hash_branch("r#{n}") do |r|
        r.get(true) { "index" }
        r.get(String) { |id| "show #{id}" }
      end
    end
    route(&:hash_branches)
  end
  ERB = app do
    plugin(:render, views: VIEWS, engine: "erb", layout: "layouts/main")
    # The fixture templates call Sinatra's erb for their partial.
    define_method(:erb) { |name, locals: {}| render(name.to_s, locals:) }
    define_method(:movie_title) { "Fight Club" }
    route { |r| r.root { view("movie/show", locals: { cast: CAST }, layout_opts: { locals: { title: "Movie" } }) } }
  end
end

# -- Hanami -------------------------------------------------------------------------------------------------------------

module HanamiApps
  # Formats are configured, as a Hanami app's actions are. Without them, an action negotiates the Accept header against
  # every MIME type Rack knows, which costs ~700 allocations a request.
  class HtmlAction < Hanami::Action
    config.formats.accept(:html)
  end

  class Hello < HtmlAction
    def handle(_request, response) = response.body = "Hello World"
  end

  class Params < Hanami::Action
    config.formats.accept(:json)

    def handle(request, response)
      response.format = :json
      response.body = JSON.generate(id: request.params[:id], fields: request.params[:fields])
    end
  end

  # Actions are frozen and shared across requests, so the before callback passes the user on as an exposure.
  class Filters < HtmlAction
    before :load_user
    after :tag

    def handle(request, response) = response.body = "#{response[:user]} #{request.params[:id]}"

    private

    def load_user(_request, response) = response[:user] = "ana"
    def tag(_request, response) = response.headers["x-served-by"] = "bench"
  end

  class Index < HtmlAction
    def handle(_request, response) = response.body = "index"
  end

  class Show < HtmlAction
    def handle(request, response) = response.body = "show #{request.params[:id]}"
  end

  HELLO = Hanami::Router.new { root(to: Hello.new) }
  PARAMS = Hanami::Router.new { get("/users/:id", to: Params.new) }
  FILTERS = Hanami::Router.new { get("/users/:id", to: Filters.new) }
  LARGE = Hanami::Router.new do
    index = Index.new
    show = Show.new
    RESOURCES.times do |n|
      get("/r#{n}", to: index)
      get("/r#{n}/:id", to: show)
    end
  end
end

# -- Workloads ----------------------------------------------------------------------------------------------------------

def env(path, query: "", accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
  env = Rack::MockRequest.env_for("http://example.org")
  env["PATH_INFO"] = path
  env["QUERY_STRING"] = query
  env["HTTP_ACCEPT"] = accept
  env.freeze
end

# Requests across the whole table, so a framework that tries routes in order is measured fairly.
LARGE_REQUESTS = (0...RESOURCES).step(25).flat_map { [env("/r#{it}"), env("/r#{it}/#{it * 7}")] }.freeze

# name => [requests, expected [status, body] for each, apps]
WORKLOADS = {
  "hello" => [[env("/")], ->(_) { [200, "Hello World"] }, :HELLO],
  "params" => [[env("/users/42", query: "fields=name,email", accept: "application/json")], ->(_) { [200, '{"id":"42","fields":"name,email"}'] }, :PARAMS],
  "filters" => [[env("/users/42")], ->(_) { [200, "ana 42"] }, :FILTERS],
  "large table" => [LARGE_REQUESTS, ->(e) { [200, e["PATH_INFO"].count("/") == 1 ? "index" : "show #{e["PATH_INFO"].split("/").last}"] }, :LARGE],
  "404" => [[env("/nope"), env("/r10/1/2"), env("/r9999")], ->(_) { [404, nil] }, :LARGE],
  "erb" => [[env("/")], ->(_) { [200, nil] }, :ERB]
}.freeze

FRAMEWORKS = { "reprise" => RepriseApps, "sinatra" => SinatraApps, "roda" => RodaApps, "hanami" => HanamiApps }.freeze

def body_of(response)
  body = +""
  response[2].each { body << it }
  response[2].close if response[2].respond_to?(:close)
  body
end

# Checks the app answers every request as expected; returns a description of the first difference, or nil.
def check(app, requests, expected)
  requests.each do |request|
    status, = response = app.call(request.dup)
    body = body_of(response)
    want_status, want_body = expected.(request)
    return "#{request["PATH_INFO"]}: #{status} #{body[0, 60].inspect}" if status != want_status || (want_body && body != want_body)
  end
  nil
end

def measure(app, requests, seconds: 3.0)
  run = -> { requests.each { |request| app.call(request.dup)[2].then { it.close if it.respond_to?(:close) } } }
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
  run.() while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

  rounds = Array.new(10) do
    count = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    while (elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < seconds / 10
      run.()
      count += requests.size
    end
    elapsed / count * 1_000_000
  end.sort

  GC.start
  before = GC.stat(:total_allocated_objects)
  run.()
  [rounds[5], (GC.stat(:total_allocated_objects) - before).fdiv(requests.size)]
end

def isolated
  reader, writer = IO.pipe
  pid = fork do
    reader.close
    GC.start
    GC.compact
    writer.write(JSON.generate(yield))
    writer.close
    exit!(0)
  end
  writer.close
  result = JSON.parse(reader.read)
  Process.wait(pid)
  result
end

names = ARGV.empty? ? WORKLOADS.keys : WORKLOADS.keys.select { |name| ARGV.any? { name.start_with?(it) } }
jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "YJIT" : "interpreter"
versions = { "reprise" => Reprise::VERSION, "sinatra" => Sinatra::VERSION, "roda" => Roda::RodaVersion,
             "hanami" => "router #{Gem.loaded_specs["hanami-router"].version}, controller #{Gem.loaded_specs["hanami-controller"].version}" }
puts "Ruby #{RUBY_VERSION}, #{jit}. #{versions.map { "#{_1} #{_2}" }.join("; ")}"
puts

names.each do |name|
  requests, expected, constant = WORKLOADS.fetch(name)
  results = FRAMEWORKS.filter_map do |framework, apps|
    next [framework, nil, "n/a"] unless apps.const_defined?(constant, false)

    app = apps.const_get(constant, false)
    problem = check(app, requests, expected)
    next [framework, nil, "wrong response: #{problem}"] if problem

    us, allocations = isolated { measure(app, requests) }
    [framework, [us, allocations], nil]
  end

  fastest = results.filter_map { it[1]&.first }.min
  puts format("%-12s %10s %10s %12s", name, "µs/req", "vs fastest", "allocs/req")
  results.each do |framework, numbers, note|
    if numbers
      puts format("  %-10s %10.2f %9.1f× %12.1f", framework, numbers[0], numbers[0] / fastest, numbers[1])
    else
      puts format("  %-10s %s", framework, note)
    end
  end
  puts
end
