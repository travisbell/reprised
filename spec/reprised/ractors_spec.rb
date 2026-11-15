# frozen_string_literal: true

require "rack/mock"
require "stringio"

RSpec.describe "Reprised::App.ractorize!" do
  views = File.expand_path("../fixtures/ractors", __dir__).freeze

  # Runs the block in a child process and returns what it returns: App.ractorize! freezes Rack's globals for the whole
  # process, which would break the other specs. An exception comes back as [:raised, class name, message].
  def isolated
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Warning[:experimental] = false
      result = begin
        yield
      rescue Exception => error
        [:raised, error.class.name, error.message]
      end
      writer.write(Marshal.dump(result))
      writer.close
      exit!(0)
    end
    writer.close
    data = reader.read
    Process.wait(pid)
    raise "the child process exited without a result (#{$?.inspect})" if data.empty?

    Marshal.load(data)
  end

  # Rack envs for +requests+ (path, Rack::MockRequest options), shareable: the input as a String, since
  # Rack::MockRequest doesn't run in other Ractors.
  def shareable_envs(requests)
    envs = requests.map do |path, options|
      env = Rack::MockRequest.env_for(path, **options.to_h)
      env["rack.input"] = env["rack.input"]&.read.to_s
      env.delete("rack.errors")
      env
    end
    Ractor.make_shareable(envs)
  end

  # Calls the app from a new Ractor with each request, returning status, the content-type, and the body, or the
  # exception's class and message.
  def in_ractor(app, *requests)
    Ractor.new(app, shareable_envs(requests)) do |app, envs|
      envs.map do |shared|
        env = shared.merge("rack.input" => StringIO.new(shared["rack.input"]), "rack.errors" => StringIO.new)
        status, headers, body = app.call(env)
        text = +""
        body.each { text << it }
        body.close if body.respond_to?(:close)
        [status, headers["content-type"], text]
      rescue => error
        [error.class.name, error.message]
      end
    end.value
  end

  def in_main(app, *requests)
    requests.map do |path, options|
      status, headers, body = app.call(Rack::MockRequest.env_for(path, **options.to_h))
      text = +""
      body.each { text << it }
      [status, headers["content-type"], text]
    end
  end

  # The requests whose response wasn't the one expected, with what it was.
  def differences(responses) = requests.zip(responses, expected).reject { |_, response, want| response == want }

  let(:movies) do
    Class.new(Reprised::Controller) do
      get("/movies/:id") { "controller #{params[:id]} #{shout("x")}" }
    end
  end

  let(:app) do
    controller = movies
    Class.new(Reprised::App) do
      set :views, views
      set :raise_errors, false
      set :dump_errors, false
      set :reload_templates, false
      set :precompile_templates, true
      helpers { def shout(text) = text.upcase }
      condition(:admin) { |level| params["level"].to_i >= level }

      before("/admin/*") { halt 401, "no" }
      get("/") { "hello" }
      get("/movie/:id") { "movie #{params[:id]} #{params["x"]}" }
      get("/files/*") { "file #{params[:splat].first}" }
      get("/json") { json(ok: true, list: [1, 2]) }
      get("/redirect") { redirect "/" }
      get("/admin/x") { "never" }
      get("/page") { erb :page, locals: { title: "Fight Club" } }
      get("/movie_page") { erb :movie, locals: { name: "Fight Club", year: 1999 } }
      get("/inline") { erb "<b><%= 1 + 1 %></b>" }
      get("/boom") { raise ArgumentError, "boom" }
      get("/cookie") do
        response.set_cookie("a", "1")
        cookies["b"].to_s
      end
      get("/accept", provides: :json) { "json!" }
      get("/secret", admin: 2) { "secret" }
      post("/form") { "posted #{params["name"]}" }
      error(ArgumentError) { "handled #{env["reprised.error"].message}" }
      not_found { "nothing here" }
      mount controller
    end
  end

  let(:requests) do
    [
      ["/"], ["/movie/550?x=1"], ["/files/a%20b/c.txt"], ["/json"], ["/redirect"], ["/admin/x"], ["/page"],
      ["/movie_page"], ["/inline"], ["/boom"], ["/nope"], ["/cookie", { "HTTP_COOKIE" => "b=2" }],
      ["/accept", { "HTTP_ACCEPT" => "application/json" }], ["/secret?level=3"], ["/secret?level=1"],
      ["/form", { method: "POST", params: { name: "Tyler" } }], ["/movies/7"], ["/", { method: "HEAD" }]
    ]
  end

  let(:expected) do
    html = "text/html;charset=utf-8"
    [
      [200, html, "hello"], [200, html, "movie 550 1"], [200, html, "file a b/c.txt"],
      [200, "application/json", %({"ok":true,"list":[1,2]})], [302, html, ""], [401, html, "no"],
      [200, html, "<h1>Fight Club</h1>\n"], [200, html, "<p>Fight Club (1999)</p>\n"], [200, html, "<b>2</b>"],
      [500, html, "handled boom"], [404, html, "nothing here"], [200, html, "2"], [200, "application/json", "json!"],
      [200, html, "secret"], [404, html, "nothing here"], [200, html, "posted Tyler"], [200, html, "controller 7 X"],
      [200, html, ""]
    ]
  end

  it "serves the app from other Ractors as it does in the main one" do
    result = isolated do
      before = differences(in_main(app, *requests))
      app.ractorize!
      [app.ractorized?, Ractor.shareable?(app.stack), before, differences(in_ractor(app, *requests)), differences(in_main(app, *requests))]
    end

    expect(result).to eq([true, true, [], [], []])
  end

  it "serves requests from several Ractors at once, each compiling what it needs" do
    statuses = isolated do
      app.ractorize!
      envs = shareable_envs(requests)
      Array.new(4) do
        Ractor.new(app, envs) do |app, envs|
          Array.new(50) do
            envs.map { app.call(it.merge("rack.input" => StringIO.new(it["rack.input"]), "rack.errors" => StringIO.new)).first }
          end.uniq
        end
      end.map(&:value).uniq
    end

    expect(statuses).to eq([[expected.map(&:first)]])
  end

  it "lists the blocks that use variables it can't share" do
    raised = isolated do
      title = +"mutable"
      count = 0
      broken = Class.new(Reprised::App) do
        get("/title") { title }
        get("/count") { count += 1 }
      end
      broken.ractorize!
    end

    expect(raised[0, 2]).to eq([:raised, "Reprised::RactorError"])
    expect(raised.last).to include("GET /title (#{__FILE__}:", "'title'")
    expect(raised.last).to include("GET /count (#{__FILE__}:", "outer variables")
  end

  it "says what in the middleware can't be shared" do
    raised = isolated do
      locking = Class.new do
        def initialize(app) = (@app, @lock = app, Mutex.new)
        def call(env) = @lock.synchronize { @app.call(env) }
      end
      Class.new(Reprised::App) do
        use locking
        get("/") { "hi" }
      end.ractorize!
    end

    expect(raised[0, 2]).to eq([:raised, "Reprised::RactorError"])
    expect(raised.last).to match(/\.@stack → @lock holds Thread::Mutex, which can't be shared$/)
  end

  it "warns about settings it can't share, which only the main Ractor can read" do
    warning, greeting, mutex, frozen = isolated do
      unshareable = Class.new(Reprised::App) do
        set :mutex, Mutex.new
        set :greeting, +"hi"
        get("/") { settings.greeting }
        get("/mutex") { settings.mutex.class.name }
      end
      $stderr = StringIO.new
      unshareable.ractorize!
      # (raise_errors is on in the test environment, so the error the read raises reaches the caller.)
      [$stderr.string, in_ractor(unshareable, ["/"]).first.last, in_ractor(unshareable, ["/mutex"]).first, unshareable.greeting.frozen?]
    end

    expect(warning).to include("settings mutex can't be shared with other Ractors")
    expect(greeting).to eq("hi")
    expect(mutex).to eq(["RuntimeError", "defined with an un-shareable Proc in a different Ractor"])
    expect(frozen).to be(true)
  end

  it "freezes Rack's media types, and says so when one is registered afterwards" do
    raised = isolated do
      Class.new(Reprised::App) { get("/") { "hi" } }.ractorize!
      Class.new(Reprised::App) { mime_type :movie, "video/x-movie" }
    end

    expect(raised).to eq([:raised, "FrozenError", "Rack's media types are frozen (by App.ractorize! or rack/ractorize); register .movie before"])
  end
end
