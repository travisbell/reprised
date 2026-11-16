# frozen_string_literal: true

module Reprised
  # Rack middleware that takes the request's scheme from a proxy's own header, for proxies that don't send
  # X-Forwarded-Proto, such as CloudFront:
  #
  #   require "reprised/forwarded_scheme"
  #
  #   use Reprised::ForwardedScheme, header: "CloudFront-Forwarded-Proto"
  #
  # When +header+ says https, the request is HTTPS for everything after it: rack.url_scheme, HTTPS, and
  # X-Forwarded-Proto, so Rack::Request#scheme and #ssl?, the app's redirects and URLs, and middleware that read
  # rack.url_scheme directly (OpenTelemetry's url.scheme) all agree, whatever forwarded headers the client sent. Any
  # other value leaves the request as it is.
  #
  # Put it in config.ru, ahead of the middleware that cares (sessions, protection, tracing). Only use it behind a proxy
  # that sets the header itself, since a client can send any header.
  class ForwardedScheme
    HTTPS = "https"

    def initialize(app, header:)
      @app = app
      @key = "HTTP_#{header.to_s.upcase.tr("-", "_")}"
    end

    def call(env)
      if (value = env[@key]) && value.casecmp?(HTTPS)
        env[Rack::RACK_URL_SCHEME] = HTTPS
        env[Rack::HTTPS] = "on"
        env["HTTP_X_FORWARDED_PROTO"] = HTTPS
      end

      @app.call(env)
    end
  end
end
