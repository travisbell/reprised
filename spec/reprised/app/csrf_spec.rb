# frozen_string_literal: true

RSpec.describe "CSRF protection" do
  # A session that lasts the example: env["rack.session"] is this Hash on every request.
  class SpecSession
    def initialize(app, store)
      @app = app
      @store = store
    end

    def call(env)
      env["rack.session"] = @store
      @app.call(env)
    end
  end

  let(:session) { {} }

  # With +handled+, an error handler names the ForgedRequest raised.
  def csrf_app(handled: true, **settings, &block)
    store = session
    mock_app do
      use SpecSession, store
      settings.each { |name, value| set name, value }
      error(Reprised::ForgedRequest) { |e| "forged: #{e.class.name.split("::").last}" } if handled
      instance_eval(&block) if block
    end
  end

  def cross_site = { "HTTP_SEC_FETCH_SITE" => "cross-site", "HTTP_ORIGIN" => "https://elsewhere.example" }

  describe "the cross-origin check" do
    it "is off by default" do
      csrf_app { post("/rate") { "rated" } }

      post "/rate", {}, cross_site

      expect([status, body]).to eq([200, "rated"])
    end

    context "when on" do
      before do
        csrf_app(csrf: true) do
          post("/rate") { "rated" }
          get("/rate") { "the form" }
          post("/callback", csrf: false) { "called back" }
        end
      end

      it "turns away another site's request, as a 403 for the error handlers" do
        post "/rate", {}, cross_site

        expect([status, body]).to eq([403, "forged: CrossOriginRequest"])
      end

      it "turns away another origin on the same site" do
        post "/rate", {}, { "HTTP_SEC_FETCH_SITE" => "same-site", "HTTP_ORIGIN" => "https://accounts.example.org" }

        expect(status).to eq(403)
      end

      it "lets the page's own origin through, and a request the user made" do
        post "/rate", {}, { "HTTP_SEC_FETCH_SITE" => "same-origin" }
        expect(body).to eq("rated")

        post "/rate", {}, { "HTTP_SEC_FETCH_SITE" => "none" }
        expect(body).to eq("rated")
      end

      it "compares the Origin with the host, for a browser that doesn't send Sec-Fetch-Site" do
        post "/rate", {}, { "HTTP_ORIGIN" => "https://example.org" }
        expect(body).to eq("rated")

        post "/rate", {}, { "HTTP_ORIGIN" => "https://example.org:8443" }
        expect(status).to eq(403)

        post "/rate", {}, { "HTTP_ORIGIN" => "https://elsewhere.example" }
        expect(status).to eq(403)

        post "/rate", {}, { "HTTP_ORIGIN" => "null" }
        expect(status).to eq(403)
      end

      it "lets a request with neither header through: it isn't from a browser" do
        post "/rate"

        expect(body).to eq("rated")
      end

      it "leaves safe requests alone" do
        get "/rate", {}, cross_site

        expect(body).to eq("the form")
      end

      it "lets a route opt out" do
        post "/callback", {}, cross_site

        expect(body).to eq("called back")
      end

      it "doesn't turn away a request no route answers" do
        post "/nowhere", {}, cross_site

        expect(status).to eq(404)
      end
    end

    it "runs before the before filters, so a forged request runs none of them" do
      ran = []
      csrf_app(handled: false, csrf: true) do
        before { ran << :app_filter }
        post("/rate") { "rated" }
        error(403) { "forbidden (filters: #{ran.inspect})" }
      end

      post "/rate", {}, cross_site
      expect([status, body]).to eq([403, "forbidden (filters: [])"])

      post "/rate", {}, { "HTTP_SEC_FETCH_SITE" => "same-origin" }
      expect([body, ran]).to eq(["rated", [:app_filter]])
    end

    it "checks a route's token before its before filters too" do
      ran = []
      csrf_app do
        before { ran << :filter }
        post("/delete", csrf: :token) { "deleted" }
      end

      post "/delete"

      expect([body, ran]).to eq(["forged: InvalidCSRFToken", []])
    end

    it "checks the route a request passes to" do
      csrf_app(csrf: true) do
        post("/rate", csrf: false) { pass }
        post("/rate") { "rated" }
      end

      post "/rate", {}, cross_site

      expect(status).to eq(403)
    end

    it "checks a POST whose _method makes it a GET" do
      csrf_app(csrf: true, method_override: true) { get("/rate") { "rated" } }

      post "/rate", { "_method" => "GET" }, cross_site

      expect(status).to eq(403)
    end

    it "lets trusted origins through" do
      csrf_app(csrf: true, csrf_trusted_origins: ["https://Accounts.example.org/"]) { post("/rate") { "rated" } }

      post "/rate", {}, { "HTTP_SEC_FETCH_SITE" => "same-site", "HTTP_ORIGIN" => "https://accounts.example.org" }
      expect(body).to eq("rated")

      post "/rate", {}, { "HTTP_ORIGIN" => "https://accounts.example.org" }
      expect(body).to eq("rated")
    end

    it "only reports what it would turn away, with :report" do
      reported = []
      csrf_app(csrf: :report) { post("/rate") { "rated" } }
      @app.define_singleton_method(:report_forged_request!) { |error, env| reported << [error, env["PATH_INFO"]] }

      post "/rate", {}, cross_site

      expect(body).to eq("rated")
      expect(reported.map { |error, path| [error.class, error.message, path] })
        .to eq([[Reprised::CrossOriginRequest, "Sec-Fetch-Site is cross-site (Origin https://elsewhere.example)", "/rate"]])
    end

    it "reports to rack.errors by default" do
      errors = StringIO.new
      csrf_app(csrf: :report) { post("/rate") { "rated" } }

      post "/rate", {}, cross_site.merge("rack.errors" => errors)

      expect(errors.string).to eq("Reprised: would turn away POST /rate: Sec-Fetch-Site is cross-site (Origin https://elsewhere.example)\n")
    end

    it "rejects settings and options it doesn't know" do
      expect { csrf_app(csrf: :yes) { get("/") { "" } }.finalize! }.to raise_error(ArgumentError, /csrf must be one of/)
      expect { csrf_app(csrf: true, csrf_trusted_origins: ["accounts.example.org"]).finalize! }
        .to raise_error(ArgumentError, /takes origins/)
      expect { csrf_app { post("/rate", csrf: true) { "" } } }.to raise_error(ArgumentError, /csrf: takes false or :token/)
    end
  end

  describe "tokens" do
    it "masks the session's token afresh each time, every one of them valid" do
      csrf_app do
        get("/form") { [csrf_token, csrf_token].join(" ") }
        post("/check") { valid_csrf_token?.to_s }
      end

      get "/form"
      first, second = body.split

      expect(first).not_to eq(second)
      expect(session["_csrf_token"]).to match(/\A[\w-]{43}\z/)
      [first, second, session["_csrf_token"]].each do |token|
        post "/check", { "authenticity_token" => token }
        expect(body).to eq("true")
      end
      ["", "nope", "#{first}x", first.reverse].each do |token|
        post "/check", { "authenticity_token" => token }
        expect(body).to eq("false")
      end
    end

    it "takes the token from the X-CSRF-Token header" do
      csrf_app do
        get("/form") { csrf_token }
        post("/check") { valid_csrf_token?.to_s }
      end
      get "/form"

      post "/check", {}, { "HTTP_X_CSRF_TOKEN" => body }

      expect(body).to eq("true")
    end

    it "is needed for a route with csrf: :token, whatever the csrf setting" do
      [false, true, :report].each do |mode|
        session.clear
        csrf_app(csrf: mode) do
          get("/form") { csrf_token }
          post("/delete", csrf: :token) { "deleted" }
        end
        get "/form"
        token = body

        post "/delete"
        expect([mode, status, body]).to eq([mode, 403, "forged: InvalidCSRFToken"])

        post "/delete", { "authenticity_token" => token }
        expect([mode, status, body]).to eq([mode, 200, "deleted"])
      end
    end

    it "checks a token given to verify_csrf_token!" do
      csrf_app do
        get("/form") { csrf_token }
        post("/report") do
          verify_csrf_token!(JSON.parse(params["data"])["token"])
          "reported"
        end
      end
      get "/form"

      post "/report", { "data" => { token: body }.to_json }
      expect(body).to eq("reported")

      post "/report", { "data" => { token: "nope" }.to_json }
      expect(status).to eq(403)
    end

    it "never matches a session without one" do
      csrf_app { post("/check", csrf: :token) { "checked" } }

      post "/check", { "authenticity_token" => "" }

      expect(status).to eq(403)
    end

    it "is replaced after reset_csrf_token!" do
      csrf_app do
        get("/form") { csrf_token }
        post("/login") do
          reset_csrf_token!
          "signed in"
        end
        post("/check") { valid_csrf_token?.to_s }
      end
      get "/form"
      old = body

      post "/login"
      get "/form"
      post "/check", { "authenticity_token" => old }

      expect(body).to eq("false")
    end

    it "renders a form field and meta tags, with the param and session key the settings name" do
      csrf_app(csrf_param: "token", csrf_session_key: "csrf") do
        get("/form") { [csrf_field, csrf_meta_tags].join("\n") }
        post("/check") { valid_csrf_token?.to_s }
      end

      get "/form"

      field, param, meta = body.lines(chomp: true)
      token = field[/\A<input type="hidden" name="token" value="([\w-]+)">\z/, 1]
      expect(token).not_to be_nil
      expect(param).to eq(%(<meta name="csrf-param" content="token">))
      expect(meta).to match(/\A<meta name="csrf-token" content="[\w-]+">\z/)
      expect(session.keys).to eq(["csrf"])

      post "/check", { "token" => token }
      expect(body).to eq("true")
    end

    it "needs a session" do
      mock_app { get("/form") { csrf_token } }

      expect { get "/form" }.to raise_error(ArgumentError, /kept in the session/)
    end
  end
end
