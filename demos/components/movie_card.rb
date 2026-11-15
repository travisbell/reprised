# frozen_string_literal: true

class Demos
  module Components
    # A movie, as a card that links to its page in the routing demo.
    class MovieCard < Phlex::HTML
      def initialize(movie)
        @movie = movie
      end

      def view_template
        article(class: "card") do
          h3 { a(href: "/routing/movies/#{@movie.id}") { @movie.title } }
          p { "#{@movie.year}, directed by #{@movie.director}" }
          render(Badge.new(@movie.genre, tone: @movie.genre.downcase.tr(" ", "-")))
        end
      end
    end
  end
end
