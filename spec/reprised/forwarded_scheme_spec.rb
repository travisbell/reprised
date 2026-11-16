# frozen_string_literal: true

require "reprised/forwarded_scheme"

RSpec.describe Reprised::ForwardedScheme do
  # Requests as a proxy sends them, with a Host header (so the port comes from the scheme).
  def call(headers = {}, path = "/")
    app = Class.new(Reprised::App) do
      get("/") { [request.scheme, request.ssl?, env["rack.url_scheme"], uri("/x")].join(" ") }
      get("/back") { redirect("/there") }
    end
    middleware = described_class.new(app, header: "CloudFront-Forwarded-Proto")
    Rack::MockRequest.new(middleware).get(path, { "HTTP_HOST" => "example.org" }.merge(headers))
  end

  it "makes the request HTTPS when the proxy's header says so" do
    response = call({ "HTTP_CLOUDFRONT_FORWARDED_PROTO" => "https" })

    expect(response.body).to eq("https true https https://example.org/x")
  end

  it "reads the header's value ignoring case" do
    expect(call({ "HTTP_CLOUDFRONT_FORWARDED_PROTO" => "HTTPS" }).body).to start_with("https true")
  end

  it "wins over the forwarded headers a client sends" do
    response = call({ "HTTP_CLOUDFRONT_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_PROTO" => "http", "HTTP_FORWARDED" => "proto=http" })

    expect(response.body).to start_with("https true https")
  end

  it "leaves the request as it is without the header, or for another value" do
    expect(call.body).to eq("http false http http://example.org/x")
    expect(call({ "HTTP_CLOUDFRONT_FORWARDED_PROTO" => "http" }).body).to start_with("http false http")
  end

  it "gives redirects the scheme" do
    response = call({ "HTTP_CLOUDFRONT_FORWARDED_PROTO" => "https" }, "/back")

    expect(response.headers["location"]).to eq("https://example.org/there")
  end
end
