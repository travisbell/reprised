# frozen_string_literal: true

require "async"
require "securerandom"
require "tmpdir"
require "zeitwerk"
require "reprised/reloader"

module ReloaderSpec; end

RSpec.describe Reprised::Reloader do
  let(:dir) { Dir.mktmpdir }
  let(:namespace) { Module.new.tap { ReloaderSpec.const_set("Case#{SecureRandom.hex(4)}", it) } }
  let(:ns) { namespace.name }

  after { FileUtils.rm_rf(dir) }

  # Writes a file, a little later each time, so a change shows in its mtime however quickly the spec runs.
  def write(name, content)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    @clock = (@clock || Time.now) + 2
    File.utime(@clock, @clock, path)
  end

  # From the machine the server runs on, as a developer's browser is.
  def env_for(path, **options) = Rack::MockRequest.env_for(path, "REMOTE_ADDR" => "127.0.0.1", **options)

  def request(reloader, path, env = env_for(path))
    status, _headers, body = reloader.call(env)
    content = +""
    body.each { content << it }
    [status, content]
  end

  context "with a Zeitwerk loader" do
    let(:loader) do
      Zeitwerk::Loader.new.tap do |loader|
        loader.push_dir(dir, namespace:)
        loader.enable_reloading
      end
    end
    let(:reloader) do
      loader.setup
      described_class.new("#{ns}::Web", loader:)
    end

    before do
      write("web.rb", <<~RUBY)
        class #{ns}::Web < Reprised::App
          get("/") { #{ns}::Greeting.text }
          get("/farewell") { defined?(#{ns}::Farewell) ? #{ns}::Farewell.text : "none" }
          get("/slow") { sleep(0.1); #{ns}::Greeting.text }
        end
      RUBY
      write("greeting.rb", "module #{ns}::Greeting; def self.text = \"hello\"; end\n")
    end

    after do
      loader.unload
      loader.unregister
    end

    it "reloads the app and the code it uses when a file it loaded changes, and not otherwise" do
      expect(request(reloader, "/")).to eq([200, "hello"])
      app = namespace::Web
      expect(request(reloader, "/")).to eq([200, "hello"])
      expect(namespace::Web).to equal(app)

      write("greeting.rb", "module #{ns}::Greeting; def self.text = \"hi\"; end\n")

      expect(request(reloader, "/")).to eq([200, "hi"])
      expect(namespace::Web).not_to equal(app)
      expect(namespace::Web).to be_finalized
    end

    it "says the app's code is loading while it reloads, for the stall detector" do
      request(reloader, "/")
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(described_class.loading_since?(before)).to be(false)

      write("greeting.rb", "module #{ns}::Greeting; def self.text = \"hi\"; end\n")
      request(reloader, "/")

      expect(described_class.loading_since?(before)).to be(true)
      expect(described_class.loading_since?(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(false)
    end

    it "reloads when a file is added" do
      expect(request(reloader, "/farewell")).to eq([200, "none"])

      write("farewell.rb", "module #{ns}::Farewell; def self.text = \"bye\"; end\n")

      expect(request(reloader, "/farewell")).to eq([200, "bye"])
    end

    it "answers with the error while the code doesn't load, and reloads once it does" do
      request(reloader, "/")
      write("web.rb", "class #{ns}::Web < Reprised::App\n  get(\"/\") {\n")

      env = env_for("/")
      status, body = request(reloader, "/", env)
      expect(status).to eq(500)
      expect(body).to start_with("Couldn't reload #{ns}::Web: SyntaxError")
      expect(env["rack.errors"].string).to include("Couldn't reload #{ns}::Web: SyntaxError")
      expect(request(reloader, "/").first).to eq(500)

      write("web.rb", "class #{ns}::Web < Reprised::App\n  get(\"/\") { \"fixed\" }\nend\n")

      expect(request(reloader, "/")).to eq([200, "fixed"])
    end

    it "keeps the error to the log for a client its addresses don't take in" do
      write("web.rb", "class #{ns}::Web < Reprised::App\n  get(\"/\") {\n")

      env = env_for("/", "REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.9")
      expect(request(reloader, "/", env)).to eq([500, "Couldn't reload the app: the error is in the server's log.\n"])
      expect(env["rack.errors"].string).to include("SyntaxError")

      docker = described_class.new("#{ns}::Web", loader:, show_errors_from: ["172.16.0.0/12"])
      expect(request(docker, "/", env_for("/", "REMOTE_ADDR" => "172.17.0.1")).last).to include("SyntaxError")
    end

    it "answers with the error when the app doesn't load the first time" do
      write("web.rb", "class #{ns}::Web < Reprised::App\n  get(\"/\") {\n")

      status, body = request(reloader, "/")
      expect([status, body]).to match([500, /\ACouldn't reload #{ns}::Web: SyntaxError/])

      write("web.rb", "class #{ns}::Web < Reprised::App\n  get(\"/\") { \"fixed\" }\nend\n")

      expect(request(reloader, "/")).to eq([200, "fixed"])
    end

    it "waits for the requests in flight before reloading, and holds new ones" do
      request(reloader, "/")
      results = []

      Sync do
        slow = Async { results << [:slow, *request(reloader, "/slow")] }
        write("greeting.rb", "module #{ns}::Greeting; def self.text = \"hi\"; end\n")
        Async { results << [:new, *request(reloader, "/")] }.wait
        slow.wait
      end

      expect(results).to eq([[:slow, 200, "hello"], [:new, 200, "hi"]])
    end

    it "reloads anyway once it has waited long enough" do
      reloader = described_class.new("#{ns}::Web", loader: loader.tap(&:setup), wait: 0.02)
      request(reloader, "/")
      env = env_for("/")

      Sync do
        slow = Async { request(reloader, "/slow") }
        write("greeting.rb", "module #{ns}::Greeting; def self.text = \"hi\"; end\n")
        expect(request(reloader, "/", env)).to eq([200, "hi"])
        slow.wait
      end

      expect(env["rack.errors"].string).to include("Reloading with requests still in flight after 0.02s")
    end
  end

  context "with an app defined in required files" do
    let(:files) { [File.join(dir, "app.rb"), File.join(dir, "routes/*.rb")] }

    before do
      write("app.rb", "class #{ns}::Api < Reprised::App\n  get(\"/\") { \"root\" }\nend\n")
      write("routes/movies.rb", "class #{ns}::Api\n  get(\"/movies\") { \"movies\" }\nend\n")
      files.flat_map { Dir.glob(it) }.each { require it }
    end

    it "defines the app afresh from its files when one changes" do
      reloader = described_class.new("#{ns}::Api", files:)
      expect(request(reloader, "/movies")).to eq([200, "movies"])

      write("routes/movies.rb", "class #{ns}::Api\n  get(\"/films\") { \"films\" }\nend\n")

      expect(request(reloader, "/films")).to eq([200, "films"])
      expect(request(reloader, "/movies").first).to eq(404)
      expect(request(reloader, "/")).to eq([200, "root"])
    end

    it "reloads when a file matching its globs is added" do
      reloader = described_class.new("#{ns}::Api", files:)
      expect(request(reloader, "/people").first).to eq(404)

      write("routes/people.rb", "class #{ns}::Api\n  get(\"/people\") { \"people\" }\nend\n")

      expect(request(reloader, "/people")).to eq([200, "people"])
    end
  end

  it "needs reloading enabled on the loader" do
    loader = Zeitwerk::Loader.new
    loader.push_dir(dir)
    loader.setup

    expect { described_class.new("App", loader:) }.to raise_error(ArgumentError, /enable_reloading/)
  ensure
    loader.unregister
  end

  it "needs a loader or files" do
    expect { described_class.new("App") }.to raise_error(ArgumentError, /loader, files, or both/)
  end
end
