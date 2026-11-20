# frozen_string_literal: true

RSpec.describe "The exception page" do
  include AppHelpers

  def movie_app(**settings, &block)
    mock_app do
      set :show_exceptions, true
      set :raise_errors, false
      settings.each { |name, value| set name, value }
      get "/movie/:id" do
        title = "Fight <Club>"
        @movie = { id: params[:id], title: }
        raise KeyError, "no poster for #{title}" unless @movie[:poster]
      end
      get("/missing") { raise Reprised::NotFound }
      error { "the app's 500 page" }
      error(404) { "the app's 404 page" }
      instance_eval(&block) if block
    end
  end

  def html_get(path, headers = {}) = get(path, {}, { "HTTP_ACCEPT" => "text/html" }.merge(headers))

  it "shows a 5xx's exception, the source around the app's frames, and the local variables where it was raised" do
    movie_app

    html_get "/movie/550"

    expect(status).to eq(500)
    expect(response_headers["content-type"]).to start_with("text/html")
    expect(body).to include("<h1>KeyError</h1>", "no poster for Fight &lt;Club&gt;")
    expect(body).to include("<code>GET /movie/:id</code>") # the route
    expect(body).to include('<span class="hit">') # the raising line, in its source
    expect(body).to include("<td><code>title</code></td><td><pre>&quot;Fight &lt;Club&gt;&quot;</pre>")
    expect(body).to include("<td><code>@movie</code></td>")
    expect(body).not_to include("<td><code>@env</code></td>") # the request scope's own state
  end

  it "shows it instead of the app's error handlers" do
    movie_app

    html_get "/movie/550"

    expect(body).to include("<h1>KeyError</h1>")
  end

  it "with :after_handler, shows it only when no handler answers" do
    mock_app do
      set :show_exceptions, :after_handler
      get("/handled") { raise KeyError, "handled" }
      error(KeyError) { "the app's KeyError page" }
      get("/unhandled") { raise ArgumentError, "unhandled" }
    end

    html_get "/handled"
    expect(body).to eq("the app's KeyError page")
    html_get "/unhandled"
    expect(body).to include("<h1>ArgumentError</h1>")
  end

  it "leaves 4xx responses to the error handlers" do
    movie_app

    html_get "/missing"

    expect([status, body]).to eq([404, "the app's 404 page"])
  end

  it "shows the causes" do
    movie_app do
      get("/wrapped") do
        raise KeyError, "inner"
      rescue KeyError
        raise ArgumentError, "outer"
      end
    end

    html_get "/wrapped"

    expect(body).to include("<h1>ArgumentError</h1>", "Caused by KeyError", "Backtrace of KeyError")
  end

  it "is plain text for XHR and JSON requests" do
    movie_app

    get "/movie/550", {}, "HTTP_ACCEPT" => "application/json"
    expect(response_headers["content-type"]).to start_with("text/plain")
    expect(body).to start_with("KeyError: no poster for Fight <Club>")
    expect(body).to include("Route: GET /movie/:id", "Local variables:\n  title = \"Fight <Club>\"")

    get "/movie/550", {}, "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest"
    expect(response_headers["content-type"]).to start_with("text/plain")
  end

  it "shows only to the addresses in show_exceptions_from, by REMOTE_ADDR (loopback by default)" do
    movie_app

    html_get "/movie/550", "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "127.0.0.1"
    expect(body).to eq("the app's 500 page")
    html_get "/movie/550", "REMOTE_ADDR" => "::ffff:127.0.0.1"
    expect(body).to include("<h1>KeyError</h1>")
  end

  it "shows behind a proxy only when every address it forwarded the request for is allowed too" do
    movie_app

    shown = ->(headers) { html_get("/movie/550", { "REMOTE_ADDR" => "127.0.0.1" }.merge(headers)) && body.include?("<h1>KeyError</h1>") }

    expect(shown.({ "HTTP_X_FORWARDED_FOR" => "127.0.0.1" })).to be(true)
    expect(shown.({ "HTTP_FORWARDED" => 'for="[::1]:4711";proto=http, for=127.0.0.1' })).to be(true)
    expect(shown.({ "HTTP_X_FORWARDED_FOR" => "203.0.113.9" })).to be(false)
    expect(shown.({ "HTTP_X_FORWARDED_FOR" => "127.0.0.1, 203.0.113.9" })).to be(false) # the proxy added the real one
    expect(shown.({ "HTTP_X_REAL_IP" => "203.0.113.9" })).to be(false)
    expect(shown.({ "HTTP_FORWARDED" => "for=203.0.113.9:80" })).to be(false)
    expect(shown.({ "HTTP_FORWARDED" => "for=unknown" })).to be(false)
  end

  it "masks headers whose names are spelled with hyphens" do
    movie_app
    key = %w[sk live 123].join("_")

    html_get "/movie/550", "HTTP_X_API_KEY" => key

    expect(body).not_to include(key)
  end

  it "shows to the other addresses it's given" do
    movie_app(show_exceptions_from: ["10.0.0.0/8"])

    html_get "/movie/550", "REMOTE_ADDR" => "10.0.0.5"

    expect(body).to include("<h1>KeyError</h1>")
  end

  it "masks secrets in the params and headers" do
    movie_app

    # Built here, so the page's source excerpts (this spec is in the backtrace) don't have them.
    password, token, session = %w[hunter 2].join, ["Bear", "er xyz"].join, %w[session abc].join("=")

    html_get "/movie/550?password=#{password}&q=fight", "HTTP_COOKIE" => session, "HTTP_AUTHORIZATION" => token

    expect(body).not_to include(password, token, session)
    expect(body).to include("&quot;q&quot;: &quot;fight&quot;")
  end

  it "links frames to the editor" do
    movie_app(editor: :vscode)

    html_get "/movie/550"

    expect(body).to include("vscode://file#{__FILE__}:")
  end

  it "rejects an editor it doesn't know" do
    movie_app(editor: :notepad)

    html_get "/movie/550"

    expect(body).to eq("the app's 500 page") # the page couldn't render, so the handlers answer
    expect(last_request.env["rack.errors"].string).to include("unknown editor :notepad")
  end

  it "is off outside development, and the exception goes to the handlers (or is raised, in test)" do
    mock_app do
      get("/boom") { raise KeyError, "boom" }
    end

    expect { html_get "/boom" }.to raise_error(KeyError)
  end
end
