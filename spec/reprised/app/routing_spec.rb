# frozen_string_literal: true

RSpec.describe "Routing" do
  it "answers each verb" do
    mock_app do
      get("/") { "get" }
      post("/") { "post" }
      put("/") { "put" }
      patch("/") { "patch" }
      delete("/") { "delete" }
      options("/") { "options" }
    end

    ["get", "post", "put", "patch", "delete", "options"].each do |verb|
      public_send(verb, "/")
      expect(body).to eq(verb)
    end
  end

  it "answers HEAD with the GET route, without a body" do
    mock_app { get("/") { "hello" } }

    # Called directly: Rack::Test's response recomputes content-length from the (empty) body.
    status, headers, body = app.call(Rack::MockRequest.env_for("/", method: "HEAD"))

    expect([status, body.to_a, headers["content-length"]]).to eq([200, [], "5"])
  end

  it "answers HEAD with a route defined with route :get only if :head is listed, as Sinatra::MultiRoute does" do
    mock_app do
      route(:get, :post, "/session") { "session" }
      route(:get, :head, "/token") { "token" }
    end

    expect(app.call(Rack::MockRequest.env_for("/session", method: "HEAD")).first).to eq(404)
    expect(app.call(Rack::MockRequest.env_for("/token", method: "HEAD")).first).to eq(200)
    get "/session"
    expect(body).to eq("session")
  end

  it "keeps HEAD routes in definition order, among the GET routes that answer HEAD too" do
    mock_app do
      get("/movie/:id") { "get" }
      head("/movie/:id") { headers("x-route" => "head") and "" }
      head("/person/:id") { headers("x-route" => "head") and "" }
      get("/person/:id") { "get" }
    end

    movie = app.call(Rack::MockRequest.env_for("/movie/1", method: "HEAD"))
    person = app.call(Rack::MockRequest.env_for("/person/1", method: "HEAD"))
    tv = app.call(Rack::MockRequest.env_for("/tv/1", method: "HEAD"))

    expect([movie[1]["x-route"], movie[1]["content-length"]]).to eq([nil, "3"])
    expect(person[1]["x-route"]).to eq("head")
    expect(tv.first).to eq(404)
  end

  it "tries routes in definition order" do
    mock_app do
      get("/movie/:id") { "show #{params[:id]}" }
      get("/movie/new") { "new" }
    end

    get "/movie/new"

    expect(body).to eq("show new")
  end

  it "is a 404 with x-cascade when nothing matches" do
    mock_app { get("/") { "" } }

    get "/nope"

    expect(status).to eq(404)
    expect(response_headers["x-cascade"]).to eq("pass")
    expect(body).to eq("<h1>Not Found</h1>")
  end

  describe "params" do
    it "are indifferent, and merge route params over the query's" do
      mock_app { get("/movie/:id") { "#{params[:id]} #{params["id"]} #{params[:page]}" } }

      get "/movie/550?id=1&page=2"

      expect(body).to eq("550 550 2")
    end

    it "keep a query param where an optional route param is missing" do
      mock_app { get("/movie/:id?") { params[:id].to_s } }

      get "/movie/?id=7"

      expect(body).to eq("7")
    end

    it "are passed to the block, in pattern order" do
      mock_app { get("/tv/:id/season/:number") { |id, number| "#{id}-#{number}" } }

      get "/tv/1399/season/2"

      expect(body).to eq("1399-2")
    end

    it "decode the path" do
      mock_app { get("/person/:name") { params[:name] } }

      get "/person/caf%C3%A9"

      expect(body).to eq("café")
      expect(body.encoding).to eq(Encoding::UTF_8)
    end

    it "include splats" do
      mock_app { get("/files/*.*") { params[:splat].join("|") } }

      get "/files/a/b.txt"

      expect(body).to eq("a/b|txt")
    end

    it "include a regexp route's captures" do
      mock_app { get(%r{/tv/season/([0-9]+)(.*)}) { |number, rest| "#{number} #{rest.inspect} #{params[:captures].inspect}" } }

      get "/tv/season/3/x"

      expect(body).to eq(%(3 "/x" ["3", "/x"]))
    end

    it "nest indifferently" do
      mock_app { post("/") { params[:movie][:title] } }

      post "/", movie: { title: "Fight Club" }

      expect(body).to eq("Fight Club")
    end

    it "are a 400 when the query can't be parsed" do
      mock_app { get("/") { "" } }

      get "/?a[]=1&a[b]=2"

      expect(status).to eq(400)
    end
  end

  it "matches an optional trailing slash" do
    mock_app { get("/movie/:id/?") { params[:id] } }

    get "/movie/1/"
    expect(body).to eq("1")
    get "/movie/1"
    expect(body).to eq("1")
  end

  it "matches any of an Array of paths" do
    mock_app { get(["/team", "/teams/*"]) { "teams" } }

    get "/teams/2024"

    expect(body).to eq("teams")
  end

  it "defines one route for several verbs and paths with `route`" do
    mock_app { route(:get, :post, ["/session", "/session/new"]) { request.request_method } }

    post "/session/new"
    expect(body).to eq("POST")
    get "/session"
    expect(body).to eq("GET")
  end

  it "makes the matched route available" do
    mock_app { get("/movie/:id") { "#{route} #{env["reprised.route"].equal?(route)}" } }

    get "/movie/1"

    expect(body).to eq("GET /movie/:id true")
  end

  it "rejects unknown route options when finalized, once the app's conditions are known" do
    mock_app { get("/", nope: 1) { "" } }

    expect { app.finalize! }.to raise_error(ArgumentError, /unknown route option :nope/)
  end

  it "closes definitions once finalized" do
    mock_app { get("/") { "" } }
    get "/"

    expect { app.get("/late") { "" } }.to raise_error(FrozenError, /finalized/)
  end
end
