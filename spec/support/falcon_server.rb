# frozen_string_literal: true

require "async"
require "async/http/client"
require "async/http/endpoint"
require "falcon/server"
require "reprised/falcon"

# Runs a Rack app under a real Falcon server on a random port, for the duration of a block, inside a reactor:
#
#   with_falcon(app) { |client, url| client.get("/") }
#
# The app is served through +adapter+: protocol-rack's, as Falcon does by default, or Reprised::Falcon::Adapter.
#
# Apps run as in production (raise_errors off), so errors become responses as they would for real clients.
module FalconServer
  def with_falcon(app, adapter: Protocol::Rack::Adapter)
    app.set(:raise_errors, false)
    app.set(:dump_errors, false)
    Sync do |task|
      endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:0")
      bound = endpoint.bound
      port = bound.sockets.first.local_address.ip_port
      # Without the response cache, as `falcon serve` and `falcon host` run by default.
      middleware = Falcon::Server.protocol_middleware(adapter.new(app), cache: false)
      server = Falcon::Server.new(middleware, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
      server_task = task.async { server.run }

      url = "http://127.0.0.1:#{port}"
      client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse(url))
      yield client, url
    ensure
      # A failed expectation can leave a response unread, and closing the client waits for it: don't let that hang.
      begin
        task.with_timeout(1) { client&.close }
      rescue Async::TimeoutError
        nil
      end
      server_task&.stop
      bound&.close
    end
  end
end
