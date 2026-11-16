# frozen_string_literal: true

require "reprised/plugins/action_view"

RSpec.describe Reprised::Plugins::ActionView, type: :app do
  include AppHelpers

  views = File.expand_path("../../fixtures/views", __dir__)

  before do
    views_dir = views
    mock_app do
      set :views, views_dir
      plugin Reprised::Plugins::ActionView, helpers: [
        ActionView::Helpers::TagHelper, ActionView::Helpers::FormTagHelper, ActionView::Helpers::NumberHelper
      ]
      get("/form") { erb :"action_view/form", locals: { query: "fight club" } }
      get("/tags") { erb :"action_view/tags", locals: { title: "<Fight Club>", views_count: 1_234_567, raw_html: "<b>" } }
    end
  end

  it "captures the blocks helpers take in templates" do
    get "/form"

    # The utf8 input is standalone ActionView's default (default_enforce_utf8), which Rails apps turn off.
    expect(body).to eq(
      %(<form class="search" action="/search" accept-charset="UTF-8" method="get">) +
      %(<input type="hidden" name="utf8" value="&#x2713;" autocomplete="off" />) +
      %(<input type="text" name="q" id="q" value="fight club" /></form>\n)
    )
  end

  it "with escape: true, escapes <%= but not helper output, as Rails does" do
    mock_app do
      plugin Reprised::Plugins::ActionView, helpers: [ActionView::Helpers::TagHelper]
      set :erb, { escape: true }
      get("/") { erb "<%= value %>|<%== value %>|<%= tag.b(value) %>", locals: { value: "<script>" } }
    end

    get "/"

    expect(body).to eq("&lt;script&gt;|<script>|<b>&lt;script&gt;</b>")
  end

  it "escapes helper arguments, doesn't escape helper output twice, and leaves <%= raw as in Sinatra" do
    get "/tags"

    expect(body).to eq(%(<div class="card"><span>&lt;Fight Club&gt;</span> 1.23 Million</div>|<b>|&lt;b&gt;\n))
  end

  # FormOptionsHelper is a plain module that includes TextHelper (and so SanitizeHelper, whose strip_tags reads
  # self.class.full_sanitizer): ActiveSupport::Concern gives SanitizeHelper's ClassMethods only to FormOptionsHelper.
  it "gives the app and its controllers the class methods of Concerns inside other helpers, in any order" do
    helper_lists = [
      [ActionView::Helpers::FormOptionsHelper],
      [ActionView::Helpers::FormHelper, ActionView::Helpers::FormOptionsHelper],
      [ActionView::Helpers::FormOptionsHelper, ActionView::Helpers::FormHelper]
    ]
    helper_lists.each do |list|
      tags = Class.new(Reprised::Controller) { get("/controller") { strip_tags("<b>controller</b>") } }
      app = Class.new(Reprised::App) do
        plugin Reprised::Plugins::ActionView, helpers: list
        get("/app") { strip_tags("<b>app</b>") }
        mount tags
      end
      # A request of its own for each app: Rack::Test keeps the app its session started with.
      request = Rack::MockRequest.new(app)

      expect(request.get("/app").body).to eq("app"), list.inspect
      expect(request.get("/controller").body).to eq("controller"), list.inspect
    end
  end

  it "gives controllers the helpers too" do
    views_dir = views
    search = Class.new(Reprised::Controller) { get("/search") { erb :"action_view/form", locals: { query: "x" } } }
    mock_app do
      set :views, views_dir
      plugin Reprised::Plugins::ActionView, helpers: [ActionView::Helpers::FormTagHelper]
      mount search
    end

    get "/search"

    expect(body).to start_with("<form")
  end
end
