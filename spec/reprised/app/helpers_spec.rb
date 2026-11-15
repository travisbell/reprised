# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Helpers" do
  describe "halt" do
    it "accepts a status, a body, or both, with headers" do
      mock_app do
        get("/status") { halt 204 }
        get("/body") { halt "body" }
        get("/both") { halt 201, "created" }
        get("/headers") { halt 202, { "x-a" => "1" }, "accepted" }
      end

      get "/status"
      expect([status, body]).to eq([204, ""])
      get "/body"
      expect([status, body]).to eq([200, "body"])
      get "/both"
      expect([status, body]).to eq([201, "created"])
      get "/headers"
      expect([status, body, response_headers["x-a"]]).to eq([202, "accepted", "1"])
    end
  end

  it "drops the body and content headers of a 204 or 304" do
    mock_app { get("/") { [304, "ignored"] } }

    get "/"

    expect(body).to be_empty
    expect(response_headers).not_to include("content-type", "content-length")
  end

  it "sets a content-length for an Array body" do
    mock_app { get("/") { "héllo" } }

    get "/"

    expect(response_headers["content-length"]).to eq("6")
  end

  describe "redirect" do
    before do
      mock_app do
        get("/go") { redirect "/there" }
        post("/go") { redirect "/there" }
        get("/permanent") { redirect "/there", 301 }
        get("/away") { redirect "https://example.com/x" }
      end
    end

    it "redirects to an absolute URL with 302" do
      get "/go"

      expect([status, response_headers["location"]]).to eq([302, "http://example.org/there"])
    end

    it "uses 303 for a non-GET HTTP/1.1 request" do
      post "/go", {}, { "SERVER_PROTOCOL" => "HTTP/1.1" }

      expect(status).to eq(303)
    end

    it "takes a status, and absolute URLs as they are" do
      get "/permanent"
      expect(status).to eq(301)
      get "/away"
      expect(response_headers["location"]).to eq("https://example.com/x")
    end

    it "keeps HTTPS and non-default ports" do
      get "/go", {}, { "HTTPS" => "on", "HTTP_HOST" => "example.org:8443" }

      expect(response_headers["location"]).to eq("https://example.org:8443/there")
    end
  end

  describe "content_type" do
    it "adds the charset to text and some application types, but not JSON" do
      mock_app do
        get("/csv") { content_type :csv }
        get("/json") { content_type :json }
        get("/js") { content_type :js }
        get("/params") { content_type :html, charset: "latin1", profile: "a;b" }
      end

      get "/csv"
      expect(response_headers["content-type"]).to eq("text/csv;charset=utf-8")
      get "/json"
      expect(response_headers["content-type"]).to eq("application/json")
      get "/js"
      expect(response_headers["content-type"]).to eq("text/javascript;charset=utf-8")
      get "/params"
      expect(response_headers["content-type"]).to eq(%(text/html;charset=latin1;profile="a;b"))
    end

    it "rejects unknown types" do
      mock_app { get("/") { content_type :nope } }

      expect { get "/" }.to raise_error(ArgumentError, /Unknown media type/)
    end
  end

  it "sets cache headers" do
    mock_app do
      get("/cache") { cache_control :public, :must_revalidate, max_age: 60, no_store: false }
      get("/expires") { expires 500, :public }
    end

    get "/cache"
    expect(response_headers["cache-control"]).to eq("public, must-revalidate, max-age=60")
    get "/expires"
    expect(response_headers["cache-control"]).to eq("public, max-age=500")
    expect(Time.httpdate(response_headers["expires"])).to be_within(5).of(Time.now + 500)
  end

  it "sends files as attachments" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.csv")
      File.write(path, "a,b\n")
      mock_app do
        get("/file") { send_file path }
        get("/download") { send_file path, filename: "edits.csv" }
        get("/missing") { send_file File.join(dir, "missing.csv") }
      end

      get "/file"
      expect([status, body, response_headers["content-type"]]).to eq([200, "a,b\n", "text/csv;charset=utf-8"])
      get "/download"
      expect(response_headers["content-disposition"]).to eq('attachment; filename="edits.csv"')
      get "/missing"
      expect(status).to eq(404)
    end
  end

  describe "json" do
    it "encodes with JSON and sets the content type" do
      mock_app { get("/") { json(id: 550) } }

      get "/"

      expect([body, response_headers["content-type"]]).to eq(['{"id":550}', "application/json"])
    end

    it "uses the json_encoder setting, or the encoder and type given" do
      encoder = Module.new { def self.encode(object) = "encoded #{object[:id]}" }
      mock_app do
        set :json_encoder, encoder
        get("/") { json({ id: 1 }) }
        get("/patch") { json({ id: 2 }, content_type: "application/merge-patch+json", json_encoder: :to_json) }
      end

      get "/"
      expect(body).to eq("encoded 1")
      get "/patch"
      expect([body, response_headers["content-type"]]).to eq(['{"id":2}', "application/merge-patch+json"])
    end
  end

  describe "cookies" do
    before do
      mock_app do
        get("/read") { cookies[:theme].to_s }
        get("/write") do
          cookies[:theme] = "dark"
          cookies[:theme]
        end
        get("/delete") do
          cookies.delete(:theme)
          cookies[:theme].inspect
        end
      end
    end

    it "reads the request's cookies" do
      set_cookie "theme=light"
      get "/read"

      expect(body).to eq("light")
    end

    it "sets cookies with sinatra-contrib's defaults" do
      get "/write", {}, { "HTTPS" => "on" }

      expect(body).to eq("dark")
      expect(response_headers["set-cookie"]).to eq("theme=dark; domain=example.org; path=/; secure; httponly")
    end

    it "deletes cookies" do
      set_cookie "theme=light"
      get "/delete"

      expect(body).to eq("nil")
      expect(response_headers["set-cookie"]).to include("theme=;", "max-age=0")
    end
  end

  it "halts with a status from error and not_found" do
    mock_app do
      get("/forbidden") { error 403, "nope" }
      get("/missing") { not_found "gone" }
    end

    get "/forbidden"
    expect([status, body]).to eq([403, "nope"])
    get "/missing"
    expect([status, body]).to eq([404, "gone"])
  end

  it "has Rack::Utils' functions, as Sinatra::Base does, in routes, controllers, and templates" do
    movies = Class.new(Reprised::Controller) { get("/movies") { erb "<%= escape_html(params[:q]) %>|<%= build_query(q: params[:q]) %>" } }
    mock_app do
      mount movies
      get("/") { "#{escape("a b")} #{unescape("a%20b")} #{respond_to?(:escape_html)}" }
    end

    get "/"
    expect(body).to eq("a+b a b false")
    get "/movies", q: "<Fight & Club>"
    expect(body).to eq("&lt;Fight &amp; Club&gt;|q=%3CFight+%26+Club%3E")
  end

  it "reads the Rack session" do
    mock_app { get("/") { session[:user].to_s } }

    get "/", {}, { "rack.session" => { user: "ana" } }

    expect(body).to eq("ana")
  end
end
