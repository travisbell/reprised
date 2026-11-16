# frozen_string_literal: true

require "reprised/plugins/locale"

RSpec.describe Reprised::Plugins::Locale, type: :app do
  include AppHelpers

  AVAILABLE = ["en-US", "fr-FR", "fr-CA", "de-DE", "zh-Hant", "zh-TW", "zh-CN", "pt-BR", "es-ES", "es-MX"].freeze

  def locale_app(**options, &block)
    mock_app do
      plugin Reprised::Plugins::Locale, available: AVAILABLE, **options
      get("/") { "#{locale} #{I18n.locale} #{env["reprised.locale"]}" }
      instance_eval(&block) if block
    end
  end

  def locale_for(path = "/", headers = {})
    get path, {}, headers
    body.split.first
  end

  around do |example|
    I18n.available_locales = AVAILABLE + ["en"]
    example.run
  ensure
    I18n.locale = I18n.default_locale # while it's available
    I18n.available_locales = nil # back to what the backends have
  end

  it "sets the locale for the request: I18n.locale, the helper, and env[\"reprised.locale\"]" do
    locale_app

    get "/?locale=fr-CA"

    expect(body).to eq("fr-CA fr-CA fr-CA")
    expect(response_headers["content-language"]).to eq("fr-CA")
  end

  it "tries its sources in order, and passes over a candidate that's not available to the next source" do
    locale_app(from: [:param, :cookie, :accept_language])

    expect(locale_for("/?locale=de-DE", "HTTP_COOKIE" => "locale=fr-FR", "HTTP_ACCEPT_LANGUAGE" => "pt-BR")).to eq("de-DE")
    expect(locale_for("/", "HTTP_COOKIE" => "locale=fr-FR", "HTTP_ACCEPT_LANGUAGE" => "pt-BR")).to eq("fr-FR")
    expect(locale_for("/?locale=xx-XX", "HTTP_COOKIE" => "locale=yy", "HTTP_ACCEPT_LANGUAGE" => "pt-BR")).to eq("pt-BR")
  end

  it "falls back to I18n.default_locale" do
    locale_app

    expect(locale_for("/?locale=xx")).to eq("en")
  end

  it "falls back to its default" do
    locale_app(default: "en-US")

    expect(locale_for("/")).to eq("en-US")
  end

  it "matches ignoring case and with _ for -, shortens a tag a subtag at a time, and maps a language to its default" do
    locale_app(defaults: { "fr" => "fr-FR", "de" => "de-DE" })

    expect(locale_for("/?locale=FR-ca")).to eq("fr-CA")
    expect(locale_for("/?locale=pt_br")).to eq("pt-BR")
    expect(locale_for("/?locale=zh-Hant-TW")).to eq("zh-TW") # the language and region without the script, first
    expect(locale_for("/?locale=zh-Hant-HK")).to eq("zh-Hant")
    expect(locale_for("/?locale=fr-CH")).to eq("fr-FR")
    expect(locale_for("/?locale=de")).to eq("de-DE")
  end

  describe "Accept-Language" do
    before { locale_app(from: [:accept_language], defaults: { "fr" => "fr-FR" }) }

    it "takes the most preferred range that's available, not only the first" do
      expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "xx-YY, fr-CA;q=0.9, en-US;q=0.8")).to eq("fr-CA")
      expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "en-US;q=0.5, de-DE;q=0.8")).to eq("de-DE")
    end

    it "keeps the order ranges are listed in among equal q values, and skips q=0 and *" do
      expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "pt-BR, de-DE")).to eq("pt-BR")
      expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "*, de-DE;q=0, pt-BR;q=0.1")).to eq("pt-BR")
    end

    it "reads spaces and upper-case Q, and maps a regional range to its language's default" do
      expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "fr-CH ; Q=0.9 , de ; q = 0.4")).to eq("fr-FR")
    end

    it "parses each header once: the same header comes to the same locale" do
      header = "xx-YY, fr-CA;q=0.9"
      expect(Reprised::Plugins::Locale::Matcher).to receive(:language_ranges).once.and_call_original

      2.times { expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => header)).to eq("fr-CA") }
    end
  end

  it "takes an Accept-Language range that matches only by its language in the client's region, then its default" do
    locale_app(from: [:param, :accept_language], defaults: { "es" => "es-ES", "fr" => "fr-FR" }, region: ->(request) { request.get_header("HTTP_X_COUNTRY") })

    expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "es-419,es;q=0.9", "HTTP_X_COUNTRY" => "MX")).to eq("es-MX")
    expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "es-419,es;q=0.9", "HTTP_X_COUNTRY" => "US")).to eq("es-ES")
    expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "fr", "HTTP_X_COUNTRY" => "ca")).to eq("fr-CA")
    expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "fr-FR", "HTTP_X_COUNTRY" => "CA")).to eq("fr-FR") # an exact match first
    expect(locale_for("/?locale=fr", "HTTP_X_COUNTRY" => "CA")).to eq("fr-FR") # not for the other sources
  end

  it "takes callables, which get the request and return a locale, several, or nil" do
    preferred = ->(request) { request.cookies["prefs"]&.split("|") }
    locale_app(from: [->(_request) {}, preferred, :accept_language])

    expect(locale_for("/", "HTTP_COOKIE" => "prefs=xx|de-DE", "HTTP_ACCEPT_LANGUAGE" => "fr-FR")).to eq("de-DE")
    expect(locale_for("/", "HTTP_ACCEPT_LANGUAGE" => "fr-FR")).to eq("fr-FR")
  end

  it "rejects a source it doesn't know" do
    expect { locale_app(from: [:session]).finalize! }.to raise_error(ArgumentError, /isn't a locale source/)
  end

  it "uses I18n.available_locales when it isn't given the available locales" do
    mock_app do
      plugin Reprised::Plugins::Locale
      get("/") { locale }
    end

    expect(locale_for("/?locale=pt-br")).to eq("pt-BR")
  end

  it "leaves a content-language the app set" do
    locale_app { get("/set") { headers("content-language" => "de") and "x" } }

    get "/set?locale=fr-FR"

    expect(response_headers["content-language"]).to eq("de")
  end

  it "sets content-language on HTML responses only" do
    locale_app { get("/json") { json(ok: true) } }

    get "/json?locale=fr-FR"

    expect(response_headers).not_to include("content-language")
  end

  describe "Vary" do
    it "adds Accept-Language where it could have decided the locale" do
      locale_app(from: [:param, :accept_language])

      get "/", {}, "HTTP_ACCEPT_LANGUAGE" => "fr-CA" # decided by it
      expect(response_headers["vary"]).to eq("accept-language")
      get "/" # no header, but one would have counted
      expect(response_headers["vary"]).to eq("accept-language")
      get "/", {}, "HTTP_ACCEPT_LANGUAGE" => "xx" # no match, so the default
      expect(response_headers["vary"]).to eq("accept-language")
      get "/?locale=de-DE", {}, "HTTP_ACCEPT_LANGUAGE" => "fr-CA" # decided before it
      expect(response_headers).not_to include("vary")
    end

    it "adds to the app's Vary, once" do
      locale_app(from: [:accept_language]) do
        get("/encoding") { headers("vary" => "Accept-Encoding") and "x" }
        get("/already") { headers("vary" => "Accept-Encoding, Accept-Language") and "x" }
        get("/any") { headers("vary" => "*") and "x" }
      end

      get "/encoding"
      expect(response_headers["vary"]).to eq("Accept-Encoding, accept-language")
      get "/already"
      expect(response_headers["vary"]).to eq("Accept-Encoding, Accept-Language")
      get "/any"
      expect(response_headers["vary"]).to eq("*")
    end

    it "isn't added with vary: false" do
      locale_app(vary: false)
      get "/", {}, "HTTP_ACCEPT_LANGUAGE" => "fr-CA"
      expect(response_headers).not_to include("vary")
    end

    it "isn't added without Accept-Language among the sources" do
      locale_app(from: [:param, :cookie])
      get "/"
      expect(response_headers).not_to include("vary")
    end
  end

  it "sets no content-language with content_language: false" do
    locale_app(content_language: false)

    get "/?locale=fr-FR"

    expect(response_headers).not_to include("content-language")
  end

  it "puts the previous locale back once the body is closed, after a stream has rendered with the request's" do
    streamed = nil
    locale_app { get("/stream") { stream { |out| out << (streamed = I18n.locale.to_s) } } }
    I18n.locale = "de-DE"

    get "/stream?locale=fr-CA"

    expect([body, streamed, I18n.locale]).to eq(["fr-CA", "fr-CA", :"de-DE"])
  end

  it "puts the previous locale back when the app raises" do
    locale_app { get("/boom") { raise "boom" } }
    I18n.locale = "de-DE"

    expect { get "/boom?locale=fr-CA" }.to raise_error("boom")
    expect(I18n.locale).to eq(:"de-DE")
  end

  it "sets the locale for error pages too" do
    locale_app { not_found { "missing #{locale}" } }

    get "/nowhere?locale=fr-CA"

    expect([status, body]).to eq([404, "missing fr-CA"])
  end

  it "leaves the query and cookies it parsed in the env, for the app" do
    parsed = []
    locale_app(from: [:param, :cookie]) do
      before { parsed << [env["rack.request.query_hash"], env["rack.request.cookie_hash"]] }
    end

    get "/?page=2", {}, "HTTP_COOKIE" => "locale=de-DE"

    expect(parsed).to eq([[{ "page" => "2" }, { "locale" => "de-DE" }]])
    expect(body).to start_with("de-DE")
  end

  it "gives a query that doesn't parse no locale, and leaves the app to answer it" do
    locale_app(from: [:param, :cookie])

    get "/?a[]=1&a[b]=2", {}, "HTTP_COOKIE" => "locale=de-DE"

    expect(status).to eq(400)
  end
end
