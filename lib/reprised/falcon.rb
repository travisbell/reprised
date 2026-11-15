# frozen_string_literal: true

require "protocol/rack"

module Reprised
  # Serving a Reprised app (or any Rack app) with Falcon.
  module Falcon
    # Falcon's Rack adapter (protocol-rack's, for Rack 3.1+), with the request's env built in about half the time and a
    # sixth of the allocations. The env is the same, key for key. protocol-rack builds each header's CGI name
    # ("HTTP_USER_AGENT") as three new strings, and finds content-type by downcasing every header name. This looks the
    # common names up in a frozen table and reads the headers once.
    #
    # Use it with Falcon::Server.protocol_middleware(Reprised::Falcon::Adapter.new(app)), or include
    # Reprised::Falcon::Environment in a falcon.rb service.
    class Adapter < ::Protocol::Rack::Adapter::Rack31
      CGI = ::Protocol::Rack::CGI
      PROTOCOL_HTTP_REQUEST = ::Protocol::Rack::PROTOCOL_HTTP_REQUEST
      RACK_ERRORS = ::Protocol::Rack::RACK_ERRORS
      RACK_HIJACK = ::Protocol::Rack::RACK_HIJACK
      RACK_INPUT = ::Protocol::Rack::RACK_INPUT
      RACK_IS_HIJACK = ::Protocol::Rack::RACK_IS_HIJACK
      RACK_LOGGER = ::Protocol::Rack::RACK_LOGGER
      RACK_PROTOCOL = ::Protocol::Rack::RACK_PROTOCOL
      RACK_RESPONSE_FINISHED = ::Protocol::Rack::RACK_RESPONSE_FINISHED
      RACK_URL_SCHEME = ::Protocol::Rack::RACK_URL_SCHEME
      HTTP_CONTENT_TYPE = "HTTP_CONTENT_TYPE"
      CONTENT_TYPE = "content-type"
      UPPERCASE = /[A-Z]/

      # Request headers common enough to be worth a table entry. Others get their CGI name built, as protocol-rack does.
      COMMON_HEADERS = %w[
        accept accept-charset accept-encoding accept-language access-control-request-headers
        access-control-request-method authorization baggage cache-control cdn-loop cf-connecting-ip cf-ipcountry cf-ray
        cf-visitor connection content-length content-type cookie dnt early-data forwarded host if-match
        if-modified-since if-none-match if-range if-unmodified-since keep-alive origin pragma priority range referer
        sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform sec-fetch-dest sec-fetch-mode sec-fetch-site sec-fetch-user
        sec-purpose sec-websocket-extensions sec-websocket-key sec-websocket-protocol sec-websocket-version te
        traceparent tracestate true-client-ip upgrade upgrade-insecure-requests user-agent via x-amzn-trace-id
        x-csrf-token x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-prefix x-forwarded-proto
        x-forwarded-scheme x-forwarded-ssl x-http-method-override x-real-ip x-request-id x-request-start
        x-requested-with
      ].freeze

      # Each common header's CGI name, by the spellings clients send: lowercase (HTTP/2, and most proxies) and
      # Title-Case (most HTTP/1 clients).
      CGI_NAMES = COMMON_HEADERS.each_with_object({}) do |name, names|
        cgi_name = "HTTP_#{name.upcase.tr("-", "_")}".freeze
        names[name.freeze] = cgi_name
        names[name.split("-").map(&:capitalize).join("-").freeze] = cgi_name
      end.freeze

      def self.cgi_name(key) = CGI_NAMES[key] || "HTTP_#{key.upcase.tr("-", "_")}"

      # protocol-rack's Rack31#make_environment and Generic#unwrap_request, in one pass. The order things are set in
      # matters where they overlap (HTTP_UPGRADE, HTTP_HOST), and is kept.
      def make_environment(request)
        path = request.path
        if (question = path.byteindex("?"))
          request_path = path.byteslice(0, question)
          query_string = path.byteslice(question + 1, path.bytesize)
        else
          request_path = path
          query_string = ""
        end

        env = {
          PROTOCOL_HTTP_REQUEST => request,
          RACK_ERRORS => $stderr,
          RACK_LOGGER => logger,
          RACK_RESPONSE_FINISHED => [],
          CGI::REQUEST_METHOD => request.method,
          CGI::SCRIPT_NAME => "",
          CGI::PATH_INFO => request_path,
          CGI::REQUEST_PATH => request_path,
          CGI::REQUEST_URI => path,
          CGI::QUERY_STRING => query_string,
          CGI::SERVER_PROTOCOL => request.version,
          RACK_URL_SCHEME => request.scheme,
          CGI::SERVER_NAME => nil
        }

        # As (authority || "").split(":", 2).
        authority = request.authority
        if authority && !authority.empty?
          if (colon = authority.byteindex(":"))
            env[CGI::SERVER_NAME] = authority.byteslice(0, colon)
            env[CGI::SERVER_PORT] = authority.byteslice(colon + 1, authority.bytesize)
          else
            env[CGI::SERVER_NAME] = authority
          end
        end

        protocol = request.protocol
        env[RACK_PROTOCOL] = protocol if protocol

        if (body = request.body)
          if body.empty?
            body.close
          else
            env[RACK_INPUT] = ::Protocol::Rack::Input.new(body)
          end
        end

        content_type = nil
        request.headers.header do |key, value|
          name = Adapter.cgi_name(key)
          # (Not "content_type", which shares its CGI name but is an ordinary header to protocol-rack.)
          if name == HTTP_CONTENT_TYPE && key.casecmp?(CONTENT_TYPE)
            content_type = value
          elsif (current = env[name])
            env[name] = name == CGI::HTTP_COOKIE ? "#{current};#{value}" : "#{current},#{value}"
          else
            env[name] = value.to_s
          end
        end

        if content_type
          env[CGI::CONTENT_TYPE] = content_type
          # protocol-rack takes it out of the request's headers, so the request looks the same afterwards too.
          request.headers.delete(CONTENT_TYPE)
        end

        if body && (length = body.length)
          env[CGI::CONTENT_LENGTH] = length.to_s
        end

        if protocol && request.version.start_with?("HTTP/1")
          env[CGI::HTTP_UPGRADE] = Array(protocol).join(",")
        end

        if request.respond_to?(:hijack?) && request.hijack?
          env[RACK_IS_HIJACK] = true
          env[RACK_HIJACK] = proc { request.hijack!.io }
        end

        env[CGI::HTTP_HOST] ||= authority

        if (peer = request.peer)
          env[CGI::REMOTE_ADDR] = peer.ip_address
        end

        env
      end

      # As protocol-rack's, but downcasing only the names that need it: Rack 3 response headers are already lowercase.
      def wrap_headers(fields)
        headers = ::Protocol::HTTP::Headers.new
        meta = {}

        fields.each do |key, value|
          key = key.downcase if UPPERCASE.match?(key)

          if key.start_with?("rack.")
            meta[key] = value
          elsif value.is_a?(Array)
            value.each { headers.add(key, it) }
          else
            headers.add(key, value)
          end
        end

        [headers, meta]
      end
    end

    # A Falcon environment that serves the rackup file through Reprised::Falcon::Adapter. Include it after
    # Falcon::Environment::Rack:
    #
    #   service "app.localhost" do
    #     include Falcon::Environment::Rack
    #     include Reprised::Falcon::Environment
    #   end
    module Environment
      def middleware = ::Falcon::Server.protocol_middleware(Adapter.new(rack_app), verbose:, cache:)
    end
  end
end
