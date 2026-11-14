# frozen_string_literal: true

require "reprise/plugins/action_view"

RSpec.describe Reprise::Plugins::ActionView, type: :app do
  include AppHelpers

  views = File.expand_path("../../fixtures/views", __dir__)

  before do
    views_dir = views
    mock_app do
      set :views, views_dir
      plugin Reprise::Plugins::ActionView, helpers: [
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

  it "escapes helper arguments, doesn't escape helper output twice, and leaves <%= raw as in Sinatra" do
    get "/tags"

    expect(body).to eq(%(<div class="card"><span>&lt;Fight Club&gt;</span> 1.23 Million</div>|<b>|&lt;b&gt;\n))
  end

  it "gives controllers the helpers too" do
    views_dir = views
    search = Class.new(Reprise::Controller) { get("/search") { erb :"action_view/form", locals: { query: "x" } } }
    mock_app do
      set :views, views_dir
      plugin Reprise::Plugins::ActionView, helpers: [ActionView::Helpers::FormTagHelper]
      mount search
    end

    get "/search"

    expect(body).to start_with("<form")
  end
end
