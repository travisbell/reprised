# frozen_string_literal: true

RSpec.describe "Error handling" do
  let(:not_allowed) { Class.new(StandardError) }
  let(:not_allowed_here) { Class.new(not_allowed) }

  it "handles exceptions by class, and by superclass" do
    error_class = not_allowed_here
    parent = not_allowed
    mock_app do
      error(parent) { |boom| "handled #{boom.class == error_class}" }
      get("/") { raise error_class }
    end

    get "/"

    expect([status, body]).to eq([500, "handled true"])
  end

  it "lets a handler set the status" do
    error_class = not_allowed
    mock_app do
      error(error_class) do
        status 403
        "forbidden"
      end
      get("/") { raise error_class }
    end

    get "/"

    expect([status, body]).to eq([403, "forbidden"])
  end

  it "handles a status when a route halts with it" do
    mock_app do
      error(403) { "custom #{response.status}" }
      get("/") { halt 403 }
    end

    get "/"

    expect([status, body]).to eq([403, "custom 403"])
  end

  it "handles ranges of statuses" do
    mock_app do
      error(400..499) { "client error #{status}" }
      get("/") { halt 418 }
    end

    get "/"

    expect(body).to eq("client error 418")
  end

  it "routes NotFound to the 404 handler, with the route's params" do
    mock_app do
      not_found { "nothing at #{request.path_info}" }
      get("/movie/:id") { raise Reprise::NotFound if params[:id] == "0" }
    end

    get "/movie/0"
    expect([status, body]).to eq([404, "nothing at /movie/0"])
    get "/nope"
    expect([status, body]).to eq([404, "nothing at /nope"])
  end

  it "gives error handlers the route's params and the exception" do
    error_class = not_allowed
    mock_app do
      error(error_class) { "#{params[:id]} #{error.class == error_class}" }
      get("/movie/:id") { raise error_class }
    end

    get "/movie/550"

    expect(body).to eq("550 true")
  end

  it "runs the newest handler for a class first, falling back while they return nil" do
    error_class = not_allowed
    mock_app do
      error(error_class) { "older" }
      error(error_class) { nil }
      get("/") { raise error_class }
    end

    get "/"

    expect(body).to eq("older")
  end

  it "re-raises unhandled exceptions when raise_errors is on (the default in test)" do
    mock_app { get("/") { raise ArgumentError, "unhandled" } }

    expect { get "/" }.to raise_error(ArgumentError, "unhandled")
  end

  it "uses the catch-all handler when raise_errors is off, and logs the error" do
    errors = StringIO.new
    mock_app do
      set :raise_errors, false
      set :dump_errors, true
      error { "sorry: #{error.message}" }
      get("/") { raise ArgumentError, "unhandled" }
    end

    get "/", {}, { "rack.errors" => errors }

    expect([status, body]).to eq([500, "sorry: unhandled"])
    expect(errors.string).to include("ArgumentError - unhandled:")
  end

  it "answers Reprise errors with their status" do
    mock_app { get("/") { raise Reprise::BadRequest, "bad <input>" } }

    get "/"

    expect([status, body]).to eq([400, "bad &lt;input&gt;"])
  end

  it "uses handlers inherited from a parent app" do
    error_class = not_allowed
    parent = mock_app { error(error_class) { "parent" } }
    mock_app(parent) { get("/") { raise error_class } }

    get "/"

    expect(body).to eq("parent")
  end
end
