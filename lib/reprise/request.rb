# frozen_string_literal: true

require "rack/request"
require "rack/utils"

module Reprise
  # The request, as Sinatra::Request: Rack::Request plus content negotiation and stricter param parsing.
  class Request < Rack::Request
    # The Accept header's media ranges, best first.
    def accept = @env["reprise.accept"] ||= Negotiation.parse_accept(@env["HTTP_ACCEPT"])

    def accept?(type) = preferred_type(type).to_s.include?(type)

    # With no arguments, the client's most preferred media range. Otherwise the first of +types+ it accepts.
    def preferred_type(*types)
      return accept.first if types.empty?

      Negotiation.preferred_type(accept, types.flatten)
    end

    alias_method :secure?, :ssl?

    def forwarded? = !forwarded_authority.nil?
    def safe? = get? || head? || options? || trace?
    def idempotent? = safe? || put? || delete? || link? || unlink?

    # Rack's params, with parse failures raised as BadRequest (400) rather than a 500.
    def params
      super
    rescue Rack::Utils::ParameterTypeError, Rack::Utils::InvalidParameterError => error
      raise BadRequest, "Invalid query parameters: #{Rack::Utils.escape_html(error.message)}"
    rescue EOFError => error
      raise BadRequest, "Invalid multipart/form-data: #{Rack::Utils.escape_html(error.message)}"
    end
  end
end
