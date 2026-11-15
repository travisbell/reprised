# frozen_string_literal: true

RSpec.describe "Settings and app definition" do
  it "reads settings from the class, in routes too" do
    mock_app do
      set :greeting, "hello"
      set(:computed) { "#{greeting}!" }
      set :limits, { page: 20 }
      set :limits, { max: 100 }
      enable :feature
      get("/") { "#{settings.computed} #{settings.limits} #{settings.feature?}" }
    end

    get "/"

    expect(body).to eq(%(hello! {page: 20, max: 100} true))
  end

  it "evaluates a Proc setting each time it's read" do
    calls = 0
    mock_app { set(:counter) { calls += 1 } }

    2.times { app.counter }

    expect(calls).to eq(2)
  end

  it "sets many settings from a Hash" do
    mock_app { set(a: 1, b: 2) }

    expect([app.a, app.b]).to eq([1, 2])
  end

  it "runs configure blocks for the current environment" do
    mock_app do
      configure { set :everywhere, true }
      configure(:test) { set :in_test, true }
      configure(:production) { set :in_production, true }
    end

    expect([app.everywhere, app.in_test, app.respond_to?(:in_production)]).to eq([true, true, false])
  end

  it "won't let a setting replace one of the app's methods" do
    expect { mock_app { set :mount, true } }.to raise_error(ArgumentError, /mount is a method/)
    expect { mock_app { set :views, "elsewhere" } }.not_to raise_error
  end

  it "warns about Sinatra settings that belong in middleware" do
    expect { mock_app { set :protection, true } }.to output(/`set :protection` has no effect/).to_stderr
  end

  it "registers media types" do
    mock_app do
      mime_type :merge_patch, "application/merge-patch+json"
      get("/", provides: :merge_patch) { "patched" }
    end

    get "/", {}, { "HTTP_ACCEPT" => "application/merge-patch+json" }

    expect(response_headers["content-type"]).to eq("application/merge-patch+json")
  end

  it "adds helpers from blocks and modules" do
    greeting = Module.new { def greet(name) = "hi #{name}" }
    mock_app do
      helpers(greeting) { def shout(text) = text.upcase }
      get("/") { shout(greet("ana")) }
    end

    get "/"

    expect(body).to eq("HI ANA")
  end

  it "registers extensions, calling their registered hook" do
    extension = Module.new do
      def self.registered(app) = app.get("/extension") { app_name }
      def app_name = "extended"
    end
    mock_app do
      register extension
      helpers { def app_name = "app" }
    end

    get "/extension"

    expect(body).to eq("app")
    expect(app.extensions).to eq([extension])
  end

  it "replays an extension's DSL calls on each app that registers it, as Sinatra::Extension does" do
    extension = Module.new do
      extend Reprised::Extension

      def only_json(*) = condition { request.preferred_type.to_s == "application/json" }

      helpers { def label = "extended" }
      before("/filtered") { @filtered = "yes" }
      get("/json", only_json: true) { "json #{label}" }
      get("/filtered") { "filtered #{@filtered}" }
      get("/missing", provides: :json) { halt 404 }
      error(404) { "not here" }
      configure(:test) { set :from_extension, environment }
      configure(:production) { set :from_extension, :production }
    end
    first = mock_app { register extension }
    second = mock_app { register extension }

    expect(first.from_extension).to eq(:test)
    expect(second.routes.size).to eq(first.routes.size)

    get "/json", {}, { "HTTP_ACCEPT" => "application/json" }
    expect(body).to eq("json extended")
    get "/filtered"
    expect(body).to eq("filtered yes")
    get "/missing", {}, { "HTTP_ACCEPT" => "application/json" }
    expect([status, body]).to eq([404, "not here"])
  end

  it "says when a recorded call's result is used in an extension" do
    recording = Module.new { extend Reprised::Extension }
    expect { recording.module_eval { settings.views } }
      .to raise_error(NoMethodError, "the result of settings isn't available in an extension")
  end

  it "lists the media types a name stands for, as Sinatra::Base.mime_types does" do
    expect(Reprised::App.mime_types(:json)).to eq(["application/json"])
    expect(Reprised::App.mime_types("js")).to eq(["text/javascript", "application/javascript"])
  end

  it "wraps the app in middleware, outermost first" do
    tagger = Class.new do
      def initialize(app, tag, suffix: "") = (@app, @tag = app, "#{tag}#{suffix}")

      def call(env)
        status, headers, body = @app.call(env)
        [status, headers.merge("x-trail" => [@tag, headers["x-trail"]].compact.join(" ")), body]
      end
    end
    mock_app do
      use tagger, "outer"
      use tagger, "inner", suffix: "!"
      get("/") { "" }
    end

    get "/"

    expect(response_headers["x-trail"]).to eq("outer inner!")
  end

  it "sets Sinatra's env keys too with sinatra_env, for middleware written for Sinatra" do
    seen = {}
    recorder = Class.new do
      define_method(:initialize) { |app| @app = app }
      define_method(:call) do |env|
        @app.call(env).tap { seen.merge!(env.slice("sinatra.route", "sinatra.error")) }
      end
    end
    mock_app do
      set :sinatra_env, true
      set :raise_errors, false
      set :dump_errors, false
      use recorder
      get("/movie/:id") { raise ArgumentError, "boom" }
    end

    get "/movie/1"

    expect(seen["sinatra.route"]).to eq("GET /movie/:id")
    expect(seen["sinatra.error"]).to be_a(ArgumentError)
  end

  it "sets sinatra.route only once a route's body starts, as Sinatra does" do
    seen = {}
    recorder = Class.new do
      define_method(:initialize) { |app| @app = app }
      define_method(:call) { |env| @app.call(env).tap { seen[:route] = env["sinatra.route"] } }
    end
    mock_app do
      set :sinatra_env, true
      use recorder
      before { halt 401 }
      get("/movie/:id") { "" }
    end

    get "/movie/1"

    expect(seen).to eq(route: nil)
  end

  it "doesn't set Sinatra's env keys by default" do
    mock_app { get("/") { env.key?("sinatra.route").to_s } }

    get "/"

    expect(body).to eq("false")
  end

  it "finalizes once, so the first request doesn't race to" do
    mock_app { get("/") { "" } }

    expect(app.finalize!).to equal(app.finalize!)
    expect(app).to be_finalized
  end
end
