# frozen_string_literal: true

require_relative "../demos/app"
require_relative "support/falcon_server"
require "async/websocket/client"
require "json"

# The demos app (demos/), so the demos keep working as Reprised changes.
RSpec.describe "The demos" do
  include Rack::Test::Methods

  def app = Demos

  it "links to every demo from the home page, and each one answers" do
    get "/"

    expect(last_response).to be_ok
    paths = Demos::DEMOS.map(&:first)
    expect(last_response.body).to include(*paths.map { %(href="#{it}") })
    paths.each do |path|
      get path
      expect(last_response.status).to eq(200), "#{path}: #{last_response.status}"
      expect(last_response.body).to include(%(<a href="#{path}" aria-current="page">))
    end
  end

  it "serves the stylesheet through Sprockets, with the logo's asset_path" do
    get "/assets/demos.css"

    expect(last_response.content_type).to start_with("text/css")
    expect(last_response.body).to include("url(/assets/logo.svg)")
  end

  it "adds the ServerTiming plugin's header, and the routing demo's filter's to its own routes only" do
    get "/routing"
    expect(last_response.headers).to include("server-timing" => a_string_starting_with("app;dur="), "x-demo" => "routing")

    get "/forms"
    expect(last_response.headers).to include("server-timing")
    expect(last_response.headers).not_to include("x-demo")
  end

  describe "routing" do
    it "answers a movie as HTML or JSON, by path or by Accept header" do
      header "Accept", "text/html,application/xhtml+xml,*/*;q=0.8"
      get "/routing/movies/8"
      expect(last_response.content_type).to start_with("text/html")
      expect(last_response.body).to include("<h1>Metropolis</h1>")

      header "Accept", "application/json"
      get "/routing/movies/8"
      expect(JSON.parse(last_response.body)).to include("title" => "Metropolis", "year" => 1927)

      header "Accept", nil
      get "/routing/movies/8.json"
      expect(JSON.parse(last_response.body)).to include("director" => "Fritz Lang")
    end

    it "answers a missing movie with a 404, in its route's format" do
      get "/routing/movies/99"
      expect([last_response.status, last_response.body]).to match([404, a_string_including("There&#39;s no movie 99.")])

      get "/routing/movies/99.json"
      expect([last_response.status, JSON.parse(last_response.body)]).to eq([404, { "error" => "There's no movie 99." }])
    end

    it "matches params, conditions, and pass" do
      get "/routing/years/1920-1922"
      expect(last_response.body.scan("<article")).to have_attributes(size: 3)

      get "/routing/search", q: "gold"
      expect(last_response.body).to include("The Gold Rush")
      get "/routing/search", q: "go"
      expect(last_response.body).to include("Search for at least three characters")

      get "/routing/lookup/3"
      expect(last_response.headers["location"]).to end_with("/routing/movies/3")
      get "/routing/lookup/science-fiction"
      expect(last_response.body).to include("Metropolis")
      get "/routing/lookup/westerns"
      expect(last_response.status).to eq(404)
    end

    it "halts, answers several verbs, and sets cookies" do
      get "/routing/teapot"
      expect([last_response.status, last_response.headers["x-brew"], last_response.body]).to eq([418, "earl grey", "I'm a teapot"])

      post "/routing/echo", film: "Nosferatu"
      expect(JSON.parse(last_response.body)).to eq("method" => "POST", "params" => { "film" => "Nosferatu" })

      get "/routing/visits"
      get "/routing/visits"
      expect(last_response.body).to eq("You've been here 2 times.")
    end
  end

  describe "forms" do
    it "shows the form again with its errors, escaped, and a 422" do
      post "/forms/suggestions", title: "<b>Sunrise</b>", year: "1800", genre: "Western"

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include(
        %(value="&lt;b&gt;Sunrise&lt;/b&gt;"),
        %(<div class="field invalid"><label for="year">Year</label>),
        %(<p class="error">A year from 1888 to #{Time.now.year}</p>),
        %(<p class="error">Choose a genre</p>)
      )
      expect(last_response.body).not_to include("utf8")
    end

    it "redirects after a suggestion, which is listed" do
      post "/forms/suggestions", title: "Sunrise", year: "1927", genre: "Drama", notes: "Moonlight.", seen: "1"

      expect([last_response.status, last_response.headers["location"]]).to match([302, a_string_ending_with("/forms#suggestions")])
      get "/forms"
      expect(last_response.body).to include("<strong>Sunrise</strong> (1927)", "<p>Moonlight.</p>", "less than a minute ago")
    end

    it "takes a file upload" do
      post "/forms/poster", poster: Rack::Test::UploadedFile.new(File.expand_path("../demos/assets/images/logo.svg", __dir__), "image/svg+xml")

      expect(last_response.body).to include("<dd>logo.svg</dd>", "<dd>image/svg+xml</dd>", "Bytes</dd>")
    end
  end

  describe "components" do
    it "renders a Phlex page in the ERB layout, sorted by the request's params" do
      get "/components", sort: "title"

      expect(last_response.body).to include("<title>Phlex · Reprised demos</title>", "<strong>title</strong>")
      titles = last_response.body.scan(%r{<h3><a [^>]+>([^<]+)</a></h3>}).flatten
      expect(titles).to eq(titles.sort).and(have_attributes(size: Demos::MOVIES.size))
    end

    it "renders Phlex components in ERB, unescaped" do
      get "/components/erb"

      expect(last_response.body).to include(%(<span class="badge badge-science-fiction">Science fiction</span>))
    end
  end

  describe "under Falcon" do
    include FalconServer

    it "streams, runs lookups concurrently, and times out" do
      with_falcon(Demos) do |client|
        countdown = client.get("/streaming/countdown")
        expect(countdown.body.read).to eq("10...\n")
        countdown.close

        expect(JSON.parse(client.get("/streaming/parallel").read)["took"]).to be < 1.5

        slow = client.get("/streaming/slow?seconds=2")
        expect([slow.status, slow.read]).to match([503, a_string_including("took longer than 1s")])
      end
    end

    it "sends Server-Sent Events, carrying on from Last-Event-ID" do
      with_falcon(Demos) do |client|
        clock = client.get("/events/clock", { "last-event-id" => "41" })
        expect(clock.body.read).to eq("retry: 1000\n\n").or(start_with("retry: 1000\n\nid: 42\n"))
        clock.close

        progress = client.get("/events/progress").read
        expect(progress).to include(%(data: {"percent":100,"step":"Writing the subtitles"}), "event: done\ndata: Restored\n\n")
      end
    end

    it "broadcasts chat messages to everyone in the room, and refuses other sites' sockets" do
      with_falcon(Demos) do |client, url|
        endpoint = ->(name) { Async::HTTP::Endpoint.parse("#{url}/chat/socket?name=#{name}") }
        read = ->(connection) { JSON.parse(connection.read.to_str) }

        Async::WebSocket::Client.connect(endpoint.("Ana")) do |ana|
          expect(read.(ana)).to eq("type" => "joined", "name" => "Ana", "count" => 1)
          Async::WebSocket::Client.connect(endpoint.("Bo")) do |bo|
            expect(read.(ana)).to include("type" => "joined", "name" => "Bo")
            bo.write("Hello, Ana")
            bo.flush
            expect(read.(ana)).to eq("type" => "message", "name" => "Bo", "text" => "Hello, Ana")
          end
          expect(read.(ana)).to eq("type" => "left", "name" => "Bo", "count" => 1)
        end

        upgrade = { "upgrade" => "websocket", "sec-websocket-version" => "13", "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==" }
        refused = client.get("/chat/socket", upgrade.merge("origin" => "https://elsewhere.example"))
        expect([refused.status, refused.read]).to eq([403, "Not from this site"])
      end
    end
  end
end
