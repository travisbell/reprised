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

  it "wraps the app in middleware, outermost first" do
    tagger = Class.new do
      def initialize(app, tag) = (@app, @tag = app, tag)

      def call(env)
        status, headers, body = @app.call(env)
        [status, headers.merge("x-trail" => [@tag, headers["x-trail"]].compact.join(" ")), body]
      end
    end
    mock_app do
      use tagger, "outer"
      use tagger, "inner"
      get("/") { "" }
    end

    get "/"

    expect(response_headers["x-trail"]).to eq("outer inner")
  end

  it "finalizes once, so the first request doesn't race to" do
    mock_app { get("/") { "" } }

    expect(app.finalize!).to equal(app.finalize!)
    expect(app).to be_finalized
  end
end
