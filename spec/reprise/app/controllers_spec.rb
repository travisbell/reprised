# frozen_string_literal: true

RSpec.describe "Controllers" do
  def controller(&) = Class.new(Reprise::Controller, &)

  it "answers a mounted controller's routes" do
    movies = controller { get("/movie/:id") { "movie #{params[:id]}" } }
    mock_app { mount movies }

    get "/movie/550"

    expect(body).to eq("movie 550")
  end

  it "places a controller's routes where it was mounted, in definition order" do
    movies = controller { get("/movie/:id") { "controller" } }
    mock_app do
      get("/movie/new") { "before the mount" }
      mount movies
      get("/movie/:slug") { "after the mount" }
    end

    get "/movie/new"
    expect(body).to eq("before the mount")
    get "/movie/550"
    expect(body).to eq("controller")
  end

  it "mounts with register, as Sinatra extensions are" do
    movies = controller { get("/movies") { "movies" } }
    mock_app { register movies }

    get "/movies"

    expect(body).to eq("movies")
  end

  describe "helpers" do
    let(:movies) do
      controller do
        helpers { def movie_title = "Fight Club" }
        get("/movie") { "#{movie_title} #{site_name}" }
        get("/movie/override") { greeting }

        private def greeting = "controller's greeting"
      end
    end

    let(:people) do
      controller do
        get("/person") { movie_title }
        get("/person/greeting") { greeting }
      end
    end

    before do
      movies = self.movies
      people = self.people
      mock_app do
        helpers do
          def site_name = "TMDB"
          def greeting = "app's greeting"
        end
        mount movies, people
      end
    end

    it "gives a controller its own helpers and the app's" do
      get "/movie"

      expect(body).to eq("Fight Club TMDB")
    end

    it "lets a controller's methods override the app's helpers" do
      get "/movie/override"
      expect(body).to eq("controller's greeting")
      get "/person/greeting"
      expect(body).to eq("app's greeting")
    end

    it "keeps a controller's helpers from other controllers" do
      expect { get "/person" }.to raise_error(NameError, /movie_title/)
    end
  end

  it "shares controllers' helpers everywhere with helper_isolation off, as in Sinatra" do
    movies = controller { helpers { def movie_title = "Fight Club" } }
    people = controller { get("/person") { movie_title } }
    mock_app do
      set :helper_isolation, false
      mount movies, people
    end

    get "/person"

    expect(body).to eq("Fight Club")
  end

  describe "filters" do
    let(:trail) { [] }

    before do
      trail = self.trail
      movies = controller do
        before("/movie/*") { trail << "movie filter" }
        after { trail << "movie after" }
        get("/movie/:id") { trail << "movie route" and "" }
      end
      credits = controller do
        get("/movie/:id/credits") { trail << "credits route" and "" }
      end
      mock_app do
        set :filter_overlap, :ignore
        before { trail << "app filter 1" }
        mount credits, movies
        before { trail << "app filter 2" }
        get("/") { "" }
      end
    end

    it "run the app's filters and the matched controller's, in definition order" do
      get "/movie/550"

      expect(trail).to eq(["app filter 1", "movie filter", "app filter 2", "movie route", "movie after"])
    end

    it "don't run a controller's filters for another controller's routes" do
      get "/movie/550/credits"

      expect(trail).to eq(["app filter 1", "app filter 2", "credits route"])
    end

    it "don't run a controller's filters when nothing matches" do
      get "/movie/550/nope"

      expect([status, trail]).to eq([404, ["app filter 1", "app filter 2"]])
    end
  end

  it "warns at finalize about a filter that matches another controller's route" do
    teams = controller { before("/teams/*") { halt 404 } }
    search = controller { get("/teams/search") { "search" } }
    mock_app { mount teams, search }

    expect { app.finalize! }.to output(%r{before /teams/\* in .* matches GET /teams/search in .*runs only for its own}m).to_stderr
  end

  it "raises about overlapping filters when filter_overlap is :raise" do
    teams = controller { before("/teams/*") { halt 404 } }
    search = controller { get("/teams/search") { "search" } }
    mock_app do
      set :filter_overlap, :raise
      mount teams, search
    end

    expect { app.finalize! }.to raise_error(ArgumentError, /filters overlap/)
  end

  describe "error handlers" do
    let(:missing) { Class.new(StandardError) }

    it "use the matched controller's before the app's, in the controller's scope" do
      error_class = missing
      movies = controller do
        error(error_class) { "movies: #{@movie_id} #{movie_helper}" }
        get("/movie/:id") do
          @movie_id = params[:id]
          raise error_class
        end

        private def movie_helper = "helper"
      end
      people = controller { get("/person") { raise error_class } }
      mock_app do
        error(error_class) { "app" }
        mount movies, people
      end

      get "/movie/550"
      expect(body).to eq("movies: 550 helper")
      get "/person"
      expect(body).to eq("app")
    end

    it "use the app's for a status, with the app's helpers, when nothing matches" do
      movies = controller { get("/movie") { "" } }
      mock_app do
        helpers { def site_name = "TMDB" }
        not_found { "#{site_name}: not found" }
        mount movies
      end

      get "/nope"

      expect(body).to eq("TMDB: not found")
    end
  end

  describe "conditions" do
    it "can use the app's named and Sinatra-style conditions" do
      extension = Module.new do
        def only_provides(*types)
          condition { types.flat_map { Reprise::Negotiation.mime_types(it) }.any? { request.preferred_type.to_s.start_with?(it) } }
        end
      end
      movies = controller do
        get("/list", only_provides: :html) { "html" }
        get("/list", level: 2) { "admin" }
        get("/list") { "other" }
      end
      mock_app do
        register extension
        condition(:level) { |minimum| params[:level].to_i >= minimum }
        mount movies
      end

      get "/list", {}, { "HTTP_ACCEPT" => "text/html" }
      expect(body).to eq("html")
      get "/list?level=3", {}, { "HTTP_ACCEPT" => "application/json" }
      expect(body).to eq("admin")
    end
  end

  it "carries instance variables across a pass into another controller" do
    first = controller do
      before { @seen = "set by a filter" }
      get("/shared") { pass }
    end
    second = controller { get("/shared") { "#{@seen}, read by #{self.class == second}" } }
    mock_app { mount first, second }

    get "/shared"

    expect(body).to eq("set by a filter, read by true")
  end

  describe "settings" do
    it "are the app's" do
      movies = controller { get("/") { "#{settings.greeting} #{settings == self.class.app}" } }
      mock_app do
        set :greeting, "hi"
        mount movies
      end

      get "/"

      expect(body).to eq("hi true")
    end

    it "can't be set on a controller, and need it mounted" do
      expect { controller { set :greeting, "hi" } }.to raise_error(ArgumentError, /belong to the app/)
      expect { controller.settings }.to raise_error(ArgumentError, /isn't mounted/)
    end
  end

  it "mounts a controller in one app only" do
    movies = controller { get("/") { "" } }
    mock_app { mount movies }

    expect { Class.new(Reprise::App) { mount movies } }.to raise_error(ArgumentError, /already mounted/)
  end

  it "doesn't mount apps or other things" do
    other_app = Class.new(Reprise::App)

    expect { mock_app { mount other_app } }.to raise_error(ArgumentError, /apps can't be mounted/)
    expect { mock_app { mount Module.new } }.to raise_error(ArgumentError, /isn't a Reprise::Controller/)
  end
end
