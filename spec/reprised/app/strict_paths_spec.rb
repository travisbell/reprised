# frozen_string_literal: true

RSpec.describe "Trailing slashes (strict_paths)" do
  def movie_app(**settings)
    mock_app do
      settings.each { |name, value| set name, value }
      before("/movie/:id") { @seen = params[:id] }
      get("/movie/:id") { "movie #{params[:id]} (#{@seen}) at #{request.path}" }
      get("/movie/:id/cast/") { "cast" }
      get("/") { "home" }
    end
  end

  it "matches the path as it is by default" do
    movie_app

    get "/movie/550/"

    expect(status).to eq(404)
  end

  context "when off" do
    before { movie_app(strict_paths: false) }

    it "matches routes and filters against the path without its trailing slash, as Sinatra does" do
      get "/movie/550/"

      expect([status, body]).to eq([200, "movie 550 (550) at /movie/550/"])
    end

    it "still answers the path without one" do
      get "/movie/550"

      expect(body).to eq("movie 550 (550) at /movie/550")
    end

    it "leaves the root alone" do
      get "/"

      expect(body).to eq("home")
    end

    it "takes off only one slash" do
      get "/movie/550//"

      expect(status).to eq(404)
    end

    it "no longer matches a pattern that ends in a slash" do
      get "/movie/550/cast/"
      expect(status).to eq(404)

      get "/movie/550/cast"
      expect(status).to eq(404)
    end
  end
end
