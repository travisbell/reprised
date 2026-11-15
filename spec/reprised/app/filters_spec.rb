# frozen_string_literal: true

RSpec.describe "Filters" do
  it "run without the content type the route's provides: chose, as Sinatra's run before matching" do
    mock_app do
      before("/private") { halt 401, "no" }
      before { response["x-seen"] = content_type.inspect }
      get("/private", provides: :json) { "{}" }
      get("/public", provides: :json) { "{}" }
    end

    get "/private", {}, { "HTTP_ACCEPT" => "application/json" }
    expect([status, response_headers["content-type"]]).to eq([401, "text/html;charset=utf-8"])

    get "/public", {}, { "HTTP_ACCEPT" => "application/json" }
    expect(response_headers).to include("content-type" => "application/json", "x-seen" => "nil")
  end

  it "run before filters, in order, before the route" do
    mock_app do
      before { @trail = ["first"] }
      before { @trail << "second" }
      get("/") { (@trail << "route").join(" ") }
    end

    get "/"

    expect(body).to eq("first second route")
  end

  it "run filters whose pattern matches, with its params" do
    mock_app do
      before("/movie/:id/*") { @filtered = params[:id] }
      get("/movie/:movie_id/cast") { "#{@filtered.inspect} #{params[:id].inspect}" }
      get("/movie/:movie_id") { @filtered.inspect }
    end

    get "/movie/550/cast"
    expect(body).to eq(%("550" nil))
    get "/movie/550"
    expect(body).to eq("nil")
  end

  it "don't clobber a route param of the same name" do
    mock_app do
      before("/movie/:id/edit") { @id = params[:id] }
      get("/movie/:id/edit") { "#{@id} #{params[:id]}" }
    end

    get "/movie/550/edit"

    expect(body).to eq("550 550")
  end

  it "can add params for the route, as in Sinatra" do
    mock_app do
      before("/discover/*") { params[:genre] ||= "28" }
      get("/discover/movie") { "#{params[:genre]} #{params[:splat].inspect}" }
      after("/discover/*") { response["x-genre"] = params[:genre].to_s }
    end

    get "/discover/movie"

    expect([body, response_headers["x-genre"]]).to eq(["28 nil", "28"])
  end

  it "see the matched route" do
    mock_app do
      before { @route = route.to_s }
      get("/movie/:id") { @route }
    end

    get "/movie/1"

    expect(body).to eq("GET /movie/:id")
  end

  it "run when nothing matches" do
    mock_app do
      before { response["x-before"] = "ran" }
      get("/") { "" }
    end

    get "/nope"

    expect(status).to eq(404)
    expect(response_headers["x-before"]).to eq("ran")
  end

  it "stop the request when a before filter halts, and still run after filters" do
    mock_app do
      before { halt 401, "no" }
      after { response["x-after"] = "ran" }
      get("/") { "route" }
    end

    get "/"

    expect([status, body, response_headers["x-after"]]).to eq([401, "no", "ran"])
  end

  it "run after filters after the route, with its response" do
    mock_app do
      after { response.body = ["#{response.body.join} after"] }
      get("/") { "route" }
    end

    get "/"

    expect(body).to eq("route after")
  end

  it "run once, even when routes pass" do
    mock_app do
      before { @count = (@count || 0) + 1 }
      get("/") { pass }
      get("/") { @count.to_s }
    end

    get "/"

    expect(body).to eq("1")
  end

  it "skip the rest of a filter on pass" do
    mock_app do
      before do
        pass
        @reached = true
      end
      get("/") { @reached.inspect }
    end

    get "/"

    expect(body).to eq("nil")
  end

  it "keep a regexp filter's captures to the filter" do
    mock_app do
      before(%r{/teams/(\w+)}) { @team = params[:captures].first }
      get("/teams/:name") { "#{@team} #{params[:captures].inspect}" }
    end

    get "/teams/ana"

    expect(body).to eq("ana nil")
  end

  it "handle an exception from an after filter" do
    mock_app do
      set :raise_errors, false
      after { raise "after" }
      error { "handled #{error.message}" }
      get("/") { "route" }
    end

    get "/"

    expect([status, body]).to eq([500, "handled after"])
  end
end
