# frozen_string_literal: true

require "socket"
require "protocol/http"
require "reprised/falcon"
require "tmpdir"
require "async/service"
require "falcon/environment/rack"

module FalconAdapterSpec
  PEER = Addrinfo.tcp("203.0.113.7", 54_321)

  # As Async::HTTP's server requests: they know their peer, and whether they can be hijacked.
  class Request < Protocol::HTTP::Request
    attr_writer :peer, :hijackable

    def peer = @peer
    def hijack? = @hijackable
    def hijack! = Struct.new(:io).new(:io)
  end
end

RSpec.describe Reprised::Falcon::Adapter do
  # Builds the request afresh each time: the adapters take content-type out of its headers.
  def build(path: "/", authority: "example.org", method: "GET", version: "HTTP/1.1", headers: [], body: nil,
    protocol: nil, hijackable: false, with_peer: true)
    request = FalconAdapterSpec::Request.new("https", authority, method, path, version,
      Protocol::HTTP::Headers.new(headers.map(&:dup)), body&.call, protocol)
    request.peer = FalconAdapterSpec::PEER if with_peer
    request.hijackable = hijackable
    request
  end

  # An env, with the parts that are new objects each time replaced by what they hold.
  def comparable(env)
    env.to_h do |key, value|
      case key
      when "protocol.http.request" then [key, value.headers.fields]
      when "rack.input" then [key, value.read]
      when "rack.hijack" then [key, value.call]
      else [key, value]
      end
    end
  end

  def expect_same_env(**request)
    app = ->(_env) { [200, {}, []] }
    expected = Protocol::Rack::Adapter.new(app).make_environment(build(**request))
    actual = described_class.new(app).make_environment(build(**request))

    expect(comparable(actual)).to eq(comparable(expected))
    actual
  end

  browser = [
    ["Host", "example.org"], ["User-Agent", "Mozilla/5.0"], ["Accept", "text/html"], ["Accept-Encoding", "gzip, br"],
    ["Accept-Language", "en-US"], ["Cookie", "a=1"], ["Sec-Fetch-Mode", "navigate"], ["DNT", "1"]
  ]
  proxied = [
    ["host", "api.example.org"], ["user-agent", "curl/8"], ["accept", "*/*"], ["authorization", "Bearer abc"],
    ["x-forwarded-for", "203.0.113.7"], ["x-forwarded-for", "198.51.100.2"], ["x-request-id", "abc"],
    ["traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"], ["x-unknown-header", "1"],
    ["X-Mixed-CASE", "2"]
  ]

  it "builds protocol-rack's env for a browser's request" do
    env = expect_same_env(path: "/movie/550?language=en-US&page=2", headers: browser)
    expect(env).to include("HTTP_USER_AGENT" => "Mozilla/5.0", "QUERY_STRING" => "language=en-US&page=2",
      "PATH_INFO" => "/movie/550", "HTTP_DNT" => "1", "REMOTE_ADDR" => "203.0.113.7")
  end

  it "builds protocol-rack's env for a proxied request, joining repeated headers" do
    env = expect_same_env(headers: proxied)
    expect(env).to include("HTTP_X_FORWARDED_FOR" => "203.0.113.7,198.51.100.2", "HTTP_X_MIXED_CASE" => "2")
  end

  it "joins repeated cookie headers with semicolons" do
    env = expect_same_env(headers: [["cookie", "a=1"], ["Cookie", "b=2"]])
    expect(env["HTTP_COOKIE"]).to eq("a=1;b=2")
  end

  it "takes content-type out of the headers, as protocol-rack does, with the last one winning" do
    body = -> { Protocol::HTTP::Body::Buffered.new(["a=1&b=2"]) }
    headers = [["Content-Type", "text/plain"], ["content-type", "application/x-www-form-urlencoded"], ["x-a", "1"]]
    env = expect_same_env(method: "POST", headers:, body:)

    expect(env).to include("CONTENT_TYPE" => "application/x-www-form-urlencoded", "CONTENT_LENGTH" => "7")
    expect(env).not_to have_key("HTTP_CONTENT_TYPE")
    expect(env["protocol.http.request"].headers.fields).to eq([["x-a", "1"]])
  end

  it "keeps a content_type header as an ordinary one" do
    env = expect_same_env(headers: [["content_type", "text/plain"]])
    expect(env["HTTP_CONTENT_TYPE"]).to eq("text/plain")
  end

  it "drops a header named with _ when its - spelling came too, so a client can't add to a header a proxy set" do
    app = ->(_env) { [200, {}, []] }
    headers = [
      ["x-forwarded-for", "10.0.0.1"], ["X_Forwarded_For", "6.6.6.6"], ["x_forwarded_proto", "https"],
      ["x-forwarded-proto", "http"], ["x_custom", "a"], ["X_Custom", "b"]
    ]
    env = described_class.new(app).make_environment(build(headers:))

    expect(env).to include("HTTP_X_FORWARDED_FOR" => "10.0.0.1", "HTTP_X_FORWARDED_PROTO" => "http", "HTTP_X_CUSTOM" => "a,b")
  end

  it "joins thousands of repeated headers in time proportional to their size" do
    app = ->(_env) { [200, {}, []] }
    request = build(headers: Array.new(2000) { ["x-pad", "a" * 8000] })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    env = described_class.new(app).make_environment(request)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(env["HTTP_X_PAD"].bytesize).to eq(2000 * 8001 - 1)
  end

  it "closes an empty body, giving no rack.input" do
    env = expect_same_env(method: "POST", body: -> { Protocol::HTTP::Body::Buffered.new([]) })
    expect(env).not_to have_key("rack.input")
  end

  it "builds protocol-rack's env for paths and authorities at the edges" do
    expect_same_env(path: "/search?")
    expect_same_env(path: "/a?b?c")
    expect_same_env(path: "/café?q=été")
    expect_same_env(path: "*", method: "OPTIONS")
    expect_same_env(authority: "example.org:8080")
    expect_same_env(authority: "[::1]:8080")
    expect_same_env(authority: "example.org:")
    expect_same_env(authority: "")
    expect_same_env(authority: nil, with_peer: false)
    expect_same_env(authority: nil, headers: [["host", "example.org"]])
  end

  it "builds protocol-rack's env for upgrades, HTTP/2, and hijackable requests" do
    env = expect_same_env(protocol: "websocket", headers: [["upgrade", "h2c"], ["sec-websocket-version", "13"]])
    expect(env["HTTP_UPGRADE"]).to eq("websocket")

    expect_same_env(version: "HTTP/2", protocol: "websocket")
    env = expect_same_env(hijackable: true)
    expect(env["rack.hijack?"]).to be(true)
  end

  it "wraps response headers as protocol-rack does" do
    app = ->(_env) { [200, {}, []] }
    fields = { "content-type" => "text/html", "Set-Cookie" => ["a=1", "b=2"], "rack.hijack" => :hijack, "X-A" => "1" }
    expected = Protocol::Rack::Adapter.new(app).wrap_headers(fields)
    actual = described_class.new(app).wrap_headers(fields)

    expect(actual.first.fields).to eq(expected.first.fields)
    expect(actual.last).to eq(expected.last)
  end

  it "serves a Reprised app" do
    app = Class.new(Reprised::App) { get("/movie/:id") { "movie #{params[:id]} #{request.user_agent}" } }
    response = described_class.new(app).call(build(path: "/movie/550", headers: browser))

    expect(response.status).to eq(200)
    expect(response.read).to eq("movie 550 Mozilla/5.0")
  end

  it "knows the CGI names of common headers in both spellings, and builds the rest" do
    expect(described_class.cgi_name("user-agent")).to eq("HTTP_USER_AGENT")
    expect(described_class.cgi_name("User-Agent")).to equal(described_class.cgi_name("user-agent"))
    expect(described_class.cgi_name("x-something")).to eq("HTTP_X_SOMETHING")
    expect(described_class::CGI_NAMES).to be_frozen
  end
end

RSpec.describe Reprised::Falcon::Environment do
  def adapter_in(middleware)
    middleware = middleware.delegate until middleware.is_a?(Protocol::Rack::Adapter::Generic)
    middleware
  end

  it "serves a falcon.rb service's rackup file through Reprised::Falcon::Adapter, under its middleware block" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "config.ru"), "run ->(env) { [200, {}, [\"ok\"]] }\n")
      wrapped = false
      environment = Async::Service::Environment.build(Falcon::Environment::Rack, described_class, root:) do
        middleware do
          wrapped = true
          super()
        end
      end

      expect(adapter_in(environment.evaluator.middleware)).to be_a(Reprised::Falcon::Adapter)
      expect(wrapped).to be(true)
    end
  end
end
