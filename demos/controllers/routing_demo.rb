# frozen_string_literal: true

class Demos
  # Routes: patterns, params, conditions, content negotiation, pass, halt, error handlers, filters, and cookies. A
  # controller's filters, error handlers, and methods are its own: they apply to these routes only.
  class RoutingDemo < Reprised::Controller
    # A named condition: the route takes it as an option, and matches only if it's true.
    condition(:min_length) { |length| params[:q].to_s.strip.length >= length }

    # This controller's filter: it runs for its own routes only, even with a pattern another demo's routes match.
    after(["/routing", "/routing/*"]) { headers("x-demo" => "routing") }

    get "/routing" do
      @title = "Routing"
      erb :routing
    end

    # The same movie as JSON or HTML. The .json route comes first, since :id would match "1.json" too.
    get "/routing/movies/:id.json" do |id|
      json(Demos.find_movie(id).to_h)
    end

    # provides: matches when the Accept header takes the type, and sets the content type. A browser (or curl) gets
    # HTML, and `curl -H "Accept: application/json"` gets the next route. (A browser's Accept ends with */*, which
    # takes JSON too, so the HTML route comes first.)
    get "/routing/movies/:id", provides: :html do |id|
      @movie = Demos.find_movie(id)
      @title = @movie.title
      erb :movie
    end

    get "/routing/movies/:id", provides: :json do |id|
      json(Demos.find_movie(id).to_h)
    end

    # Two params in one segment. The block takes the pattern's params in order.
    get "/routing/years/:from-:to" do |from, to|
      list("Released from #{from} to #{to}", MOVIES.select { it.year.between?(from.to_i, to.to_i) })
    end

    # min_length: this route needs at least three characters, and the next one answers otherwise.
    get "/routing/search", min_length: 3 do
      query = params[:q].strip
      list("Titles with “#{query}”", MOVIES.select { it.title.downcase.include?(query.downcase) })
    end

    get "/routing/search" do
      list("Search for at least three characters", [])
    end

    # pass: this route takes ids, and passes anything else to the next route that matches.
    get "/routing/lookup/:key" do |key|
      pass unless key.match?(/\A\d+\z/)
      redirect("/routing/movies/#{key}")
    end

    get "/routing/lookup/:key" do |key|
      genre = GENRES.find { it.casecmp?(key.tr("-", " ")) } or halt(404, "No genre or movie called #{key}")
      list(genre, MOVIES.select { it.genre == genre })
    end

    # halt answers at once, with a status, headers, and a body.
    get "/routing/teapot" do
      halt(418, { "x-brew" => "earl grey" }, "I'm a teapot")
    end

    # One block for several verbs.
    route :get, :post, "/routing/echo" do
      json(method: request.request_method, params: params.to_h)
    end

    # Cookies: a visit counter.
    get "/routing/visits" do
      visits = cookies[:visits].to_i + 1
      cookies[:visits] = visits.to_s
      content_type(:text)
      "You've been here #{pluralize(visits, "time")}."
    end

    # This controller's error handler: a movie that isn't there gets a 404 in the format its route answers.
    error(MovieNotFound) do
      if route.pattern.end_with?(".json") || route.options[:provides] == :json
        json(error: error.message)
      else
        @title = "Not found"
        erb(:not_found, locals: { message: error.message })
      end
    end

    private

    def list(heading, movies)
      @title = heading
      erb(:movies, locals: { heading:, movies: })
    end
  end
end
