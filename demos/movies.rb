# frozen_string_literal: true

class Demos
  # The demos' data: a few silent films.
  Movie = Data.define(:id, :title, :year, :genre, :director)

  MOVIES = [
    Movie.new(1, "The Cabinet of Dr. Caligari", 1920, "Horror", "Robert Wiene"),
    Movie.new(2, "The Kid", 1921, "Comedy", "Charlie Chaplin"),
    Movie.new(3, "Nosferatu", 1922, "Horror", "F. W. Murnau"),
    Movie.new(4, "Sherlock Jr.", 1924, "Comedy", "Buster Keaton"),
    Movie.new(5, "Battleship Potemkin", 1925, "Drama", "Sergei Eisenstein"),
    Movie.new(6, "The Gold Rush", 1925, "Comedy", "Charlie Chaplin"),
    Movie.new(7, "The General", 1926, "Comedy", "Buster Keaton"),
    Movie.new(8, "Metropolis", 1927, "Science fiction", "Fritz Lang"),
    Movie.new(9, "The Passion of Joan of Arc", 1928, "Drama", "Carl Theodor Dreyer")
  ].freeze

  GENRES = MOVIES.map(&:genre).uniq.sort.freeze

  # A Reprised::Error answers with its http_status.
  class MovieNotFound < Reprised::Error
    def http_status = 404
  end

  def self.find_movie(id)
    MOVIES.find { it.id == Integer(id.to_s, 10, exception: false) } or raise MovieNotFound, "There's no movie #{id}."
  end
end
