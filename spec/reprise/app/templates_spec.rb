# frozen_string_literal: true

RSpec.describe "Templates" do
  views = File.expand_path("../../fixtures/views", __dir__)

  def app_with_views(views, &block)
    mock_app do
      set :views, views
      class_eval(&block)
    end
  end

  it "renders a template from the views directory with locals" do
    app_with_views(views) { get("/") { erb :hello, locals: { name: "Ana" } } }

    get "/"

    expect(body).to eq("Hello Ana!\n")
  end

  it "renders a layout around it, with the template's locals" do
    app_with_views(views) { get("/") { erb :hello, layout: :"layouts/main", locals: { name: "Ana", title: "Greeting" } } }

    get "/"

    expect(body).to eq("<title>Greeting</title>\n<main>Hello Ana!\n</main>\n")
  end

  it "renders templates inside templates, without the layout" do
    app_with_views(views) do
      helpers { def movie_title = "Fight Club" }
      get("/") { erb :"movie/show", layout: :"layouts/main", locals: { title: "Movie", cast: ["Edward", "Brad"] } }
    end

    get "/"

    expect(body).to eq("<title>Movie</title>\n<main><h1>Fight Club</h1>\n<li>Edward</li><li>Brad</li>\n\n</main>\n")
  end

  it "uses views/layout.erb for a route's template when it exists" do
    app_with_views(File.expand_path("../../fixtures/implicit_layout/views", __dir__)) do
      get("/page") { erb :page }
      get("/bare") { erb :page, layout: false }
    end

    get "/page"
    expect(body).to eq("[page\n]\n")
    get "/bare"
    expect(body).to eq("page\n")
  end

  it "goes without a layout when views/layout.erb doesn't exist" do
    app_with_views(views) { get("/") { erb :hello, locals: { name: "Ana" } } }

    get "/"

    expect(body).to eq("Hello Ana!\n")
  end

  it "raises for a missing template or explicit layout" do
    app_with_views(views) do
      get("/template") { erb :missing }
      get("/layout") { erb :hello, layout: :missing, locals: { name: "Ana" } }
    end

    expect { get "/template" }.to raise_error(Errno::ENOENT)
    expect { get "/layout" }.to raise_error(Errno::ENOENT)
  end

  it "renders a String as the template" do
    mock_app { get("/") { erb "<%= 1 + 1 %> from <%= request.path_info %>" } }

    get "/"

    expect(body).to eq("2 from /")
  end

  it "renders partials, passing locals as keywords and a block to yield" do
    app_with_views(views) { get("/") { partial(:card) { "content" } + partial(:hello, name: "Bo") } }

    get "/"

    expect(body).to eq(%(<div class="card">content</div>\nHello Bo!\n))
  end

  it "doesn't escape <%= by default, as in Sinatra, and escapes <%==" do
    app_with_views(views) do
      get("/") { erb :escaped, locals: { value: "<b>" } }
      get("/escape") { erb :escaped, locals: { value: "<b>" }, escape: true }
    end

    get "/"
    expect(body).to eq("<b>|&lt;b&gt;\n")
  end

  it "escapes <%= with escape: true, from the erb setting too" do
    app_with_views(views) do
      set :erb, escape: true
      get("/") { erb :escaped, locals: { value: "<b>" } }
    end

    get "/"

    expect(body).to eq("&lt;b&gt;|<b>\n")
  end

  it "captures the block a helper takes from the template" do
    app_with_views(views) do
      helpers { def box(&block) = "[#{capture(&block).strip}]" }
      get("/") { erb :boxed, locals: { word: "box" } }
    end

    get "/"

    expect(body).to eq("[inside box]\n")
  end

  it "sees a controller's private helpers and instance variables" do
    views_dir = views
    movies = Class.new(Reprise::Controller) do
      get("/movie") do
        @cast = ["Edward"]
        erb :"movie/show", locals: { cast: @cast }
      end

      private def movie_title = "Fight Club"
    end
    mock_app do
      set :views, views_dir
      mount movies
    end

    get "/movie"

    expect(body).to eq("<h1>Fight Club</h1>\n<li>Edward</li>\n\n")
  end

  it "reports errors at the template's own line" do
    app_with_views(views) { get("/") { erb :boom } }

    expect { get "/" }.to raise_error(RuntimeError, "template error") do |error|
      expect(error.backtrace.first).to start_with("#{views}/boom.erb:2:")
    end
  end

  it "sets a content type from the content_type: option, if nothing else does" do
    mock_app do
      get("/") { erb "{}", content_type: :json }
      get("/set") do
        content_type :csv
        erb "a,b", content_type: :json
      end
    end

    get "/"
    expect(response_headers["content-type"]).to eq("application/json")
    get "/set"
    expect(response_headers["content-type"]).to eq("text/csv;charset=utf-8")
  end

  describe "caching" do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    it "compiles a template once" do
      File.write("#{@dir}/page.erb", "v1")
      app_with_views(@dir) { get("/") { erb :page } }

      get "/"
      File.write("#{@dir}/page.erb", "v2")
      FileUtils.touch("#{@dir}/page.erb", mtime: Time.now + 5)
      get "/"

      expect(body).to eq("v1")
    end

    it "recompiles a template that changed, with reload_templates on" do
      File.write("#{@dir}/page.erb", "v1")
      app_with_views(@dir) do
        set :reload_templates, true
        get("/") { erb :page }
      end

      get "/"
      File.write("#{@dir}/page.erb", "v2")
      FileUtils.touch("#{@dir}/page.erb", mtime: Time.now + 5)
      get "/"

      expect(body).to eq("v2")
    end

    it "precompiles every template at finalize when precompile_templates is on" do
      FileUtils.mkdir_p("#{@dir}/movie")
      File.write("#{@dir}/movie/show.erb", "show")
      app_with_views(@dir) { set :precompile_templates, true }

      app.finalize!
      File.delete("#{@dir}/movie/show.erb")

      expect(app.template(:"movie/show", {}, @dir).render(app.new(Rack::MockRequest.env_for("/")))).to eq("show")
    end
  end
end
