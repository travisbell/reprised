# frozen_string_literal: true

RSpec.describe "Conditions" do
  describe "provides" do
    before do
      mock_app do
        get("/movie/:id", provides: :json) { "json" }
        get("/movie/:id") { "html" }
      end
    end

    it "matches the route whose type the client accepts, and sets the content type" do
      get "/movie/1", {}, { "HTTP_ACCEPT" => "application/json, text/javascript, */*; q=0.01" }

      expect(body).to eq("json")
      expect(response_headers["content-type"]).to eq("application/json")
    end

    it "moves on when the client doesn't accept the type" do
      get "/movie/1", {}, { "HTTP_ACCEPT" => "text/html" }

      expect(body).to eq("html")
      expect(response_headers["content-type"]).to eq("text/html;charset=utf-8")
    end

    it "matches any type when there's no Accept header" do
      get "/movie/1"

      expect(body).to eq("json")
    end
  end

  it "keeps a content type a before filter set across pass, and later routes must agree with it" do
    # Conditions choose the first route before filters run, so a filter's content type doesn't affect that choice.
    mock_app do
      before { content_type :json }
      get("/", provides: :html) { pass }
      get("/", provides: :html) { "second html" }
      get("/") { "plain" }
    end

    get "/", {}, { "HTTP_ACCEPT" => "text/html" }

    expect([body, response_headers["content-type"]]).to eq(["plain", "application/json"])
  end

  it "accepts named conditions" do
    mock_app do
      condition(:level) { |minimum| params[:level].to_i >= minimum }
      get("/", level: 2) { "admin" }
      get("/") { "everyone" }
    end

    get "/?level=3"
    expect(body).to eq("admin")
    get "/?level=1"
    expect(body).to eq("everyone")
  end

  it "only fails a condition that returns false" do
    mock_app do
      condition(:nothing) { nil }
      get("/", nothing: true) { "matched" }
    end

    get "/"

    expect(body).to eq("matched")
  end

  it "supports Sinatra-style condition methods" do
    extension = Module.new do
      def only_provides(*types)
        condition { types.flat_map { Reprised::Negotiation.mime_types(it) }.any? { request.preferred_type.to_s.start_with?(it) } }
      end
    end

    mock_app do
      register extension
      get("/list", only_provides: "html") { "html" }
      get("/list") { "other" }
    end

    get "/list", {}, { "HTTP_ACCEPT" => "text/html,*/*;q=0.8" }
    expect(body).to eq("html")
    get "/list", {}, { "HTTP_ACCEPT" => "application/json" }
    expect(body).to eq("other")
  end

  it "applies an anonymous condition to the next route" do
    mock_app do
      condition { params[:ok] }
      get("/") { "conditional" }
      get("/") { "fallback" }
    end

    get "/?ok=1"
    expect(body).to eq("conditional")
  end

  it "sees the request but not what filters set, because conditions are part of matching" do
    mock_app do
      before { @user = "ana" }
      condition(:user) { |_| !@user.nil? }
      get("/", user: true) { "user" }
      get("/") { "anonymous" }
    end

    get "/"

    expect(body).to eq("anonymous")
  end
end
