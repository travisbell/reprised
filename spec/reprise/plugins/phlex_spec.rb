# frozen_string_literal: true

require "reprise/plugins/action_view"
require "reprise/plugins/phlex"
require "action_dispatch"
require "phlex/rails"

class Greeting < Phlex::HTML
  def initialize(name:) = @name = name

  def view_template
    h1 { "Hello #{@name}" }
    p { "from #{context[:reprise]&.request&.path_info}" } if context[:reprise]
  end
end

RSpec.describe Reprise::Plugins::Phlex, type: :app do
  include AppHelpers

  views = File.expand_path("../../fixtures/views", __dir__)

  it "renders components from routes, with the request scope in the context" do
    mock_app do
      plugin Reprise::Plugins::Phlex
      get("/") { phlex Greeting.new(name: "Ana") }
    end

    get "/"

    expect(body).to eq("<h1>Hello Ana</h1><p>from /</p>")
  end

  it "renders a component inside an ERB layout, which gets the locals" do
    views_dir = views
    mock_app do
      set :views, views_dir
      plugin Reprise::Plugins::Phlex
      get("/") { phlex Greeting.new(name: "Ana"), layout: :"layouts/main", locals: { title: "Hi" } }
    end

    get "/"

    expect(body).to eq("<title>Hi</title>\n<main><h1>Hello Ana</h1><p>from /</p></main>\n")
  end

  it "renders components with render, in routes and in ERB" do
    views_dir = views
    mock_app do
      set :views, views_dir
      plugin Reprise::Plugins::Phlex
      get("/route") { render Greeting.new(name: "Bo") }
      get("/erb") { erb :"action_view/phlex", locals: { name: "Cy" } }
      get("/still-erb") { render :erb, "<%= 1 + 1 %>" }
    end

    get "/route"
    expect(body).to eq("<h1>Hello Bo</h1><p>from /route</p>")
    get "/erb"
    expect(body).to eq("<section><h1>Hello Cy</h1><p>from /erb</p></section>\n")
    get "/still-erb"
    expect(body).to eq("2")
  end

  it "renders through an ActionView view context with rails: true, for phlex-rails' helpers" do
    helper_component = Class.new(Phlex::HTML) do
      include Phlex::Rails::Helpers::NumberToHuman

      def view_template = div { number_to_human(1_234_567) }
    end
    mock_app do
      plugin Reprise::Plugins::ActionView
      plugin Reprise::Plugins::Phlex, rails: true
      get("/") { phlex helper_component.new }
    end

    get "/"

    expect(body).to eq("<div>1.23 Million</div>")
  end
end
