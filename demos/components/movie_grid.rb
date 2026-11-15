# frozen_string_literal: true

class Demos
  module Components
    # A page of movie cards, sorted by the request's sort param. A component reaches the request through
    # `context[:reprised]` (the request's scope, with its params and helpers), or from anywhere with Reprised.current.
    class MovieGrid < Phlex::HTML
      SORTS = { "year" => :year, "title" => :title, "director" => :director }.freeze

      def initialize(movies)
        @movies = movies
      end

      def view_template
        scope = context[:reprised]
        sort = SORTS.key?(scope.params[:sort]) ? scope.params[:sort] : "year"

        h1 { "Phlex components" }
        p do
          plain("This page is a Phlex component inside the app's ERB layout. Each card is a component too, and so is ")
          plain("each genre's badge. ")
          a(href: "/components/erb") { "The same components in an ERB template" }
          plain(".")
        end

        nav(class: "sorts") do
          plain("Sort by ")
          SORTS.each_key do |key|
            key == sort ? strong { key } : a(href: "?sort=#{key}") { key }
            whitespace
          end
          span(class: "muted") { "(read from #{scope.request.path_info}?sort=, through context[:reprised])" }
        end

        div(class: "grid") do
          @movies.sort_by { [it.public_send(SORTS.fetch(sort)), it.year] }.each { render(MovieCard.new(it)) }
        end
      end
    end
  end
end
