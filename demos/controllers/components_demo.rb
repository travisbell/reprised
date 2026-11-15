# frozen_string_literal: true

class Demos
  # Phlex components: a page component inside the app's ERB layout, and components rendered from an ERB template.
  class ComponentsDemo < Reprised::Controller
    get "/components" do
      @title = "Phlex"
      phlex(Components::MovieGrid.new(MOVIES), layout: :layout)
    end

    get "/components/erb" do
      @title = "Phlex in ERB"
      erb(:components, locals: { movies: MOVIES.first(3) })
    end
  end
end
