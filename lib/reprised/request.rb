# frozen_string_literal: true

require "rack/request"
require "rack/utils"

module Reprised
  # The request, as Sinatra::Request: Rack::Request plus content negotiation and stricter param parsing.
  class Request < Rack::Request
    # The Accept header's media ranges, best first.
    def accept = @env["reprised.accept"] ||= Negotiation.parse_accept(@env["HTTP_ACCEPT"])

    def accept?(type) = preferred_type(type).to_s.include?(type)

    # With no arguments, the client's most preferred media range. Otherwise the first of +types+ it accepts.
    def preferred_type(*types)
      return accept.first if types.empty?

      Negotiation.preferred_type(accept, types.flatten)
    end

    # A query string with nothing to decode or nest: pairs of letters, digits, and "-._~,:", split by "&" and "=".
    PLAIN_QUERY = /\A[A-Za-z0-9_\-.~,:=&]{1,1024}\z/

    # The query string's params. A plain one ("language=en-US&page=2") is split directly, giving what Rack's parser
    # would, without its unescaping; anything else goes to Rack's parser.
    def GET # rubocop:disable Naming/MethodName -- overrides Rack::Request#GET
      get_header(Rack::RACK_REQUEST_QUERY_HASH) || set_header(Rack::RACK_REQUEST_QUERY_HASH, plain_query || super)
    rescue Rack::BadRequest => error # Rack's parse errors: conflicting params, bad encoding, too deep, too many
      raise BadRequest, "Invalid query parameters: #{Rack::Utils.escape_html(error.message)}"
    end

    alias_method :secure?, :ssl?

    def forwarded? = !forwarded_authority.nil?
    def safe? = get? || head? || options? || trace?
    def idempotent? = safe? || put? || delete? || link? || unlink?

    # Whether the request has a body Rack would parse into params.
    def form_body? = form_data? || parseable_data?

    # Rack's params, with parse failures raised as BadRequest (400) rather than a 500: every error Rack marks as a bad
    # request (query and form errors, multipart errors, and their limits), and a multipart body that ends early.
    def params
      super
    rescue Rack::BadRequest, EOFError => error
      kind = error.is_a?(EOFError) || error.class.name.to_s.start_with?("Rack::Multipart") ? "multipart/form-data" : "query parameters"
      raise BadRequest, "Invalid #{kind}: #{Rack::Utils.escape_html(error.message)}"
    end

    private

    def plain_query
      query = query_string
      return unless PLAIN_QUERY.match?(query)

      # Scanned in place: each pair becomes just its key and value strings. Keys are frozen, so the Hash keeps them
      # rather than copying them.
      params = {}
      length = query.bytesize
      position = 0
      while position < length
        pair_end = query.byteindex("&", position) || length
        if pair_end > position
          equals = query.byteindex("=", position)
          equals = nil if equals && equals > pair_end
          return nil if equals == position # an empty key: Rack has its own rules for those

          key = query.byteslice(position, (equals || pair_end) - position).force_encoding(Encoding::UTF_8).freeze
          params[key] = (query.byteslice(equals + 1, pair_end - equals - 1).force_encoding(Encoding::UTF_8) if equals)
        end
        position = pair_end + 1
      end
      params
    end
  end
end
