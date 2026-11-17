# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "rack/conditional_get"
require "rack/content_length"
require "rack/etag"
require "rack/head"
require "reprised/application"

module ApplicationSpec
  # Adds its name to a response header, so a spec can read the order the middleware ran in.
  class Tag
    def initialize(app, name = "tag", suffix: "") = (@app, @name = app, "#{name}#{suffix}")

    def call(env)
      status, headers, body = @app.call(env)
      [status, headers.merge("x-stack" => [@name, headers["x-stack"]].compact.join(",")), body]
    end
  end
end

RSpec.describe Reprised::Application do
  let(:root) { Dir.mktmpdir }
  let(:namespace) { Module.new.tap { ApplicationSpec.const_set("Case#{SecureRandom.hex(4)}", it) } }
  let(:ns) { namespace.name }

  after do
    Reprised.application = nil
    FileUtils.rm_rf(root)
  end

  def write(name, content)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # Defines the application in config/application.rb, as a project would, and returns it.
  def application(body = "", environments: {})
    environments.each { |env, source| write("config/environments/#{env}.rb", source) }
    load write("config/application.rb", <<~RUBY)
      class #{ns}::Application < Reprised::Application
        config.app = "#{ns}::App"
        config.process_warmup = false
        #{body}
      end
    RUBY
    namespace::Application
  end

  def define_app(source = "")
    namespace.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      class App < Reprised::App
        get("/") { "home" }
        #{source}
      end
    RUBY
    namespace::App
  end

  def request(rack_app, path = "/")
    status, headers, body = rack_app.call(Rack::MockRequest.env_for(path))
    content = +""
    body.each { content << it }
    [status, headers, content]
  end

  describe "booting" do
    it "finds the project's root from config/application.rb, and loads the environment's file on boot!" do
      app = application(environments: { test: "#{ns}::Application.configure { config.x.booted = true }" })

      expect(app.config.root).to eq(root)
      expect(app.env).to eq(:test)
      expect(Reprised.application).to be(app)
      expect(app.config.x.key?(:booted)).to be(false)

      app.boot!

      expect(app.config.x.booted).to be(true)
      expect(app).to be_booted
    end

    it "eager loads the loader's code when eager_load is set" do
      loader = double("loader")
      app = application(environments: { test: "#{ns}::Application.configure { config.eager_load = true }" })
      app.config.loader = loader

      expect(loader).to receive(:eager_load).once
      app.boot!
      app.boot!
    end

    it "loads staging's file, which can start from production's" do
      app = application("config.environment = :staging", environments: {
        production: "#{ns}::Application.configure { config.method_override = true; config.x.tier = :production }",
        staging: "require_relative 'production'\n#{ns}::Application.configure { config.x.tier = :staging }"
      })

      app.boot!

      expect([app.config.method_override, app.config.x.tier]).to eq([true, :staging])
    end
  end

  describe "the app's settings" do
    it "gives the app the application's settings, then the environment's, before its class body runs" do
      application(<<~RUBY, environments: { test: "#{ns}::Application.configure { config.static_cache_control = 60 }" }).boot!
        config.static_cache_control = 30
        config.show_exceptions_from = ["10.0.0.0/8"]
        config.set(:cache_ttl, 300)
        config.set(:cache_key) { "v1-\#{environment}" }
      RUBY

      app = define_app("set :show_exceptions_from, ['192.168.0.0/16']")

      expect(app.static_cache_control).to eq(60)
      expect(app.show_exceptions_from).to eq(["192.168.0.0/16"]) # the class body wins
      expect([app.cache_ttl, app.cache_key, app.environment, app.root]).to eq([300, "v1-test", :test, root])
    end

    it "configures a reloaded app afresh" do
      application("config.method_override = true").boot!
      define_app
      namespace.send(:remove_const, :App)

      expect(define_app.method_override).to be(true)
    end

    it "leaves other apps alone" do
      application("config.method_override = true").boot!

      expect(Class.new(Reprised::App).method_override).to be(false)
    end

    it "refuses an app defined before boot!, which would miss its environment's settings" do
      application

      expect { define_app }.to raise_error(described_class::BootError, /defined before .*boot!/)
    end

    it "reads a setting as it's set, or the app's default" do
      app = application("config.method_override = true")

      expect([app.config.method_override, app.config.filter_overlap]).to eq([true, :warn])
    end

    it "raises for a name that isn't a setting, saying what to use instead" do
      expect { application("config.cache_ttl = 300") }
        .to raise_error(NoMethodError, /cache_ttl isn't a Reprised::App setting: config.set\(:cache_ttl, value\)/)
    end
  end

  describe "config.x" do
    it "holds configuration of the app's own, and raises for one that isn't set" do
      x = application("config.x.page_max_age = 86_400; config.x.indexable = false").config.x

      expect([x.page_max_age, x.indexable?, x.to_h]).to eq([86_400, false, { page_max_age: 86_400, indexable: false }])
      expect { x.page_max_ag }.to raise_error(NoMethodError, /config.x.page_max_ag isn't set/)
    end
  end

  describe "the middleware" do
    let(:stack) { described_class::MiddlewareStack.new }

    it "can be added to, inserted into, swapped, and deleted from, by class or by name" do
      stack.use(ApplicationSpec::Tag, "b").use("Rack::ETag").unshift(Rack::Head)
      stack.insert_before(Rack::ETag, Rack::ConditionalGet)
      stack.insert_after("ApplicationSpec::Tag", Rack::ContentLength)
      stack.swap(ApplicationSpec::Tag, ApplicationSpec::Tag, "c", suffix: "!")
      stack.delete(Rack::Head)

      expect(stack.names).to eq(["ApplicationSpec::Tag", "Rack::ContentLength", "Rack::ConditionalGet", "Rack::ETag"])
      expect(stack.first.args).to eq(["c"])
      expect(stack.first.options).to eq(suffix: "!")
      expect(stack.to_a.last.resolve).to be(Rack::ETag)
    end

    it "raises for a middleware that isn't in it" do
      stack.use(Rack::ETag)

      expect { stack.delete(Rack::Head) }.to raise_error(ArgumentError, /Rack::Head isn't in the middleware stack \(Rack::ETag\)/)
      expect { stack.insert_before("Rack::Lint", Rack::Head) }.to raise_error(ArgumentError)
    end
  end

  describe "rackup" do
    it "builds the middleware, outermost first, around the app and the mounted apps" do
      app = application(<<~RUBY, environments: { test: "#{ns}::Application.configure { config.middleware.insert_before ApplicationSpec::Tag, ApplicationSpec::Tag, 'outer' }" })
        config.middleware.use ApplicationSpec::Tag, "inner"
        config.middleware.use "ApplicationSpec::Tag", "innermost", suffix: "!"
        config.mount "/status", ->(_env) { [200, {}, ["ok"]] }
      RUBY
      app.boot!
      define_app

      rack_app = app.to_app

      expect(request(rack_app)).to match([200, include("x-stack" => "outer,inner,innermost!"), "home"])
      expect(request(rack_app, "/status")).to match([200, include("x-stack" => "outer,inner,innermost!"), "ok"])
    end

    it "runs the worker's hooks once a process, the shutdown hooks at exit, and the warmup with the built app" do
      app = application(<<~RUBY)
        config.on_worker_start { (ApplicationSpec::EVENTS << :worker_start) }
        config.on_shutdown { raise "the first fails" }
        config.on_shutdown { (ApplicationSpec::EVENTS << :shutdown) }
        config.warmup { |rack_app| ApplicationSpec::EVENTS << [:warmup, rack_app.class] }
      RUBY
      stub_const("ApplicationSpec::EVENTS", [])
      exits = []
      allow(app).to receive(:at_exit) { |&block| exits << block }
      app.boot!
      define_app

      app.to_app
      app.to_app
      expect { exits.each(&:call) }.to output(/on_shutdown hook failed: RuntimeError: the first fails/).to_stderr

      expect(ApplicationSpec::EVENTS).to eq([:worker_start, [:warmup, Class], [:warmup, Class], :shutdown])
      expect(exits.size).to eq(1)
    end

    it "runs the app in a Reprised::Reloader when reload is set" do
      path = write("app.rb", "class #{ns}::App < Reprised::App\n  get('/') { 'reloadable' }\nend\n")
      app = application("config.reload = true; config.reload_files = ['app.rb']")
      app.boot!
      require path

      rack_app = app.rack_app

      expect(rack_app).to be_a(Reprised::Reloader)
      expect(request(rack_app).last).to eq("reloadable")
    end
  end

  describe "preload!" do
    it "boots, runs the before_fork hooks, finalizes the app, and warms the process" do
      app = application("config.before_fork { ApplicationSpec::EVENTS << :before_fork }; config.process_warmup = true")
      stub_const("ApplicationSpec::EVENTS", [])
      app.boot!
      define_app
      expect(Process).to receive(:warmup) if Process.respond_to?(:warmup)

      app.preload!

      expect(ApplicationSpec::EVENTS).to eq([:before_fork])
      expect(namespace::App).to be_finalized
    end

    it "leaves a reloaded app for the reloader to finalize" do
      app = application("config.reload = true; config.reload_files = ['app.rb']")
      app.boot!
      define_app

      app.preload!

      expect(namespace::App).not_to be_finalized
    end
  end
end
