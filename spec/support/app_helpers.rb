# frozen_string_literal: true

# For specs that drive a Reprised::App through Rack::Test: `mock_app { get("/") { "hi" } }`, then `get "/"`.
module AppHelpers
  include Rack::Test::Methods

  def mock_app(base = Reprised::App, &block)
    @app = Class.new(base, &block)
  end

  def app = @app

  def body = last_response.body
  def status = last_response.status
  def response_headers = last_response.headers
end
