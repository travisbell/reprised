# frozen_string_literal: true

RSpec.describe "Static files" do
  fixtures = File.expand_path("../../fixtures", __dir__)

  define_method(:public_app) do |&block|
    mock_app do
      set :root, fixtures
      before { response["x-before"] = "ran" }
      after { response["x-after"] = "ran" }
      get("/hello.txt") { "route" }
      post("/hello.txt") { "posted" }
      get("/css/*") { "route" }
      class_eval(&block) if block
    end
  end

  it "serves the public folder ahead of the routes and filters, as Sinatra does" do
    public_app

    get "/hello.txt"

    expect(status).to eq(200)
    expect(body).to eq("hello\n")
    expect(response_headers).to include("content-type" => "text/plain;charset=utf-8", "content-length" => "6")
    expect(response_headers).to include("last-modified")
    expect(response_headers).not_to include("x-before", "x-after", "content-disposition")
  end

  it "answers HEAD with the file's headers, and leaves other methods to the routes" do
    public_app

    head "/css/site.css"
    expect([status, body, response_headers["content-type"]]).to eq([200, "", "text/css;charset=utf-8"])

    post "/hello.txt"
    expect(body).to eq("posted")
  end

  it "goes on to the routes when there's no such file, or the path leaves the folder" do
    public_app

    get "/css/missing.css"
    expect(body).to eq("route")

    ["/css/../../outside.txt", "/css/%2e%2e/%2e%2e/outside.txt", "/hello.txt%00"].each do |path|
      get path
      expect(body).not_to include("secret")
      expect(env_file = last_request.env["reprised.static_file"]).to be_nil, "#{path} served #{env_file}"
    end
  end

  it "leaves dotfiles, and what's in dot folders, to the routes, but serves .well-known" do
    public_app

    ["/.hidden.txt", "/%2Ehidden.txt", "/.config/settings.txt", "/css/../.hidden.txt"].each do |path|
      get path
      expect(body).not_to eq("hidden\n"), "#{path} was served"
      expect(last_request.env["reprised.static_file"]).to be_nil
    end

    get "/.well-known/security.txt"
    expect(body).to eq("Contact: mailto:security@example.org\n")
  end

  it "unescapes the path, and serves a directory's path to the routes" do
    public_app

    get "/hello%2Etxt"
    expect(body).to eq("hello\n")

    get "/css"
    expect(response_headers).to include("x-before" => "ran")
  end

  it "adds static_cache_control and static_headers, and notes the file in the env" do
    public_app do
      set :static_cache_control, [:public, { max_age: 2_592_000 }]
      set :static_headers, { "x-static" => "yes" }
      set :sinatra_env, true
    end

    get "/hello.txt"

    expect(response_headers).to include("cache-control" => "public, max-age=2592000", "x-static" => "yes")
    expect(last_request.env["reprised.static_file"]).to eq(File.join(fixtures, "public/hello.txt"))
    expect(last_request.env["sinatra.static_file"]).to eq(File.join(fixtures, "public/hello.txt"))
  end

  it "is off without a public folder, or with static disabled" do
    public_app { disable :static }
    get "/hello.txt"
    expect(body).to eq("route")

    mock_app do
      set :root, File.join(fixtures, "views")
      get("/hello.txt") { "route" }
    end
    get "/hello.txt"
    expect(body).to eq("route")
  end

  it "serves another folder with public_folder" do
    mock_app { set :public_folder, File.join(fixtures, "public/css") }

    get "/site.css"

    expect(body).to eq("body{}\n")
  end
end
