# frozen_string_literal: true

require "tmpdir"
require "reprised/plugins/sprockets"

RSpec.describe Reprised::Plugins::Sprockets, type: :app do
  include AppHelpers

  root = File.expand_path("../../fixtures/assets", __dir__)

  let(:assets) do
    Sprockets::Environment.new(root).tap do |environment|
      environment.append_path(File.join(root, "stylesheets"))
      environment.append_path(File.join(root, "javascripts"))
      environment.append_path(File.join(root, "images"))
      environment.cache = nil
    end
  end
  let(:options) { {} }

  before do
    plugin_options = { environment: assets, **options }
    mock_app do
      before { response["x-filtered"] = "yes" }
      get("/assets/vendor/*") { "vendor #{params[:splat].first}" }
      plugin Reprised::Plugins::Sprockets, **plugin_options
      get("/assets/late/*") { "late" }
      get("/path/*") { asset_path(params[:splat].first) }
      get("/exists/*") { asset_exists?(params[:splat].first).to_s }
    end
  end

  describe "serving" do
    it "compiles and serves assets under the prefix, from a route" do
      get "/assets/app.js"

      expect(status).to eq(200)
      expect(response_headers["content-type"]).to start_with("application/javascript")
      expect(body).to eq(%(console.log("2");\n))
      expect(response_headers["x-filtered"]).to eq("yes")
      expect(app.routes.map { "#{it.verb} #{it.path}" }).to include("GET /assets/*")
    end

    it "answers conditional requests and HEAD as Sprockets does" do
      get "/assets/site.css"
      etag = response_headers["etag"]

      get "/assets/site.css", {}, "HTTP_IF_NONE_MATCH" => etag
      expect(status).to eq(304)

      # Sprockets gives HEAD a content-length of 0.
      head "/assets/site.css"
      expect(status).to eq(200)
      expect(response_headers["content-type"]).to eq("text/css; charset=utf-8")
      expect(body).to be_empty
    end

    it "serves an asset by its digest path" do
      get "/assets/#{assets["site.css"].digest_path}"

      expect(status).to eq(200)
      expect(response_headers["cache-control"]).to include("immutable")
    end

    it "takes its place among the app's routes" do
      get "/assets/vendor/widgets.js"
      expect(body).to eq("vendor widgets.js")

      get "/assets/late/x.js"
      expect([status, body, response_headers["x-cascade"]]).to eq([404, "Not found", "pass"])

      post "/assets/site.css"
      expect(status).to eq(404)
    end

    context "with serve: false" do
      let(:options) { { serve: false } }

      it "leaves requests to the app" do
        get "/assets/site.css"

        expect(status).to eq(404)
        expect(app.routes.map(&:path)).not_to include("/assets/*")
      end
    end
  end

  describe Reprised::Plugins::Sprockets::Server do
    let(:app) do
      environment = assets
      Rack::Builder.app do
        use Reprised::Plugins::Sprockets::Server, environment: environment
        run ->(env) { [404, { "content-type" => "text/plain" }, ["app #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"]] }
      end
    end

    it "serves assets ahead of the app" do
      get "/assets/vendor/widgets.js"

      expect(status).to eq(200)
      expect(body).to eq("window.vendor = true;\n")
    end

    it "passes paths it has no asset for, other methods, other paths, and null bytes to the app" do
      ["/assets/missing.css", "/assetsy/site.css", "/assets/site.css%00"].each do |path|
        get path
        expect(body).to eq("app GET #{path}")
      end

      post "/assets/site.css"
      expect(body).to eq("app POST /assets/site.css")
    end
  end

  describe "helpers" do
    it "link to an asset's logical path, and check it exists without compiling it" do
      get "/path/site.css"
      expect(body).to eq("/assets/site.css")

      expect(assets).not_to receive(:find_asset)
      get "/exists/site.css"
      expect(body).to eq("true")
      get "/exists/nope.css"
      expect(body).to eq("false")
    end

    context "with digest and a manifest" do
      let(:public_path) { Dir.mktmpdir }
      let(:manifest) { Sprockets::Manifest.new(assets, public_path).tap { it.compile("site.css") } }
      let(:options) { { manifest:, digest: true, prefix: "/static/" } }

      after { FileUtils.rm_rf(public_path) }

      it "link to the digest path from the manifest, and don't serve" do
        get "/path/site.css"
        expect(body).to eq("/static/#{manifest.assets.fetch("site.css")}")

        get "/path/other.css"
        expect(body).to eq("/static/other.css")

        get "/exists/site.css"
        expect(body).to eq("true")
        expect(app.routes.map(&:path)).not_to include("/static/*")
      end

      it "link to the logical path once digest is turned off" do
        app.set(:assets_digest, false)

        get "/path/site.css"
        expect(body).to eq("/static/site.css")
      end
    end

    it "are available in controllers" do
      controller = Class.new(Reprised::Controller) do
        get("/controller") { asset_path("app.js") }
      end
      app.mount(controller)

      get "/controller"
      expect(body).to eq("/assets/app.js")
    end
  end

  describe "in assets" do
    it "link to assets as the helpers do, leaving URLs and paths with no asset alone" do
      expect(assets["branded.css"].to_s).to eq(<<~CSS)
        .logo { background: url(/assets/logo.svg); }
        .icon { background: url(/assets/logo.svg); }
        .missing { background: url(/missing.png); }
        .cdn { background: url(https://cdn.example.org/x.png); }
      CSS
    end

    it "link the asset, so a manifest compiles it too" do
      Dir.mktmpdir do |public_path|
        manifest = Sprockets::Manifest.new(assets, public_path)
        manifest.compile("branded.css")

        expect(manifest.assets.keys).to contain_exactly("branded.css", "logo.svg")
      end
    end

    context "with digest" do
      let(:options) { { digest: true, prefix: "/static" } }

      it "link to digest paths" do
        expect(assets["branded.css"].to_s).to include(".logo { background: url(/static/#{assets["logo.svg"].digest_path}); }")
      end
    end

    it "recompile when the digest setting changes" do
      Dir.mktmpdir do |cache|
        assets.cache = Sprockets::Cache::FileStore.new(cache)
        expect(assets["branded.css"].to_s).to include("url(/assets/logo.svg)")

        app.set(:assets_digest, true)
        expect(assets["branded.css"].to_s).to include("url(/assets/#{assets["logo.svg"].digest_path})")
      end
    end
  end
end
