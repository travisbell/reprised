# frozen_string_literal: true

require "securerandom"
require "rack/utils"

module Reprised
  # Protection from cross-site request forgery, in two parts.
  #
  # The cross-origin check (`set :csrf, true`) turns away a browser's unsafe request (anything but GET, HEAD, or
  # OPTIONS) that another origin made: by its Sec-Fetch-Site header, or where a browser doesn't send that, by comparing
  # its Origin header with the request's host. A request with neither header isn't from a browser (a webhook, a
  # script, an API client), so it isn't one that could be forged, and passes. It needs no tokens, so it covers every
  # route at once. `set :csrf, :report` reports what it would turn away (App.report_forged_request!) and lets it
  # through, to find the cross-origin requests an app needs before enforcing it.
  #
  # Tokens are the older defence, for the routes that want one as well: `csrf_token` (or `csrf_field`,
  # `csrf_meta_tags`) puts the session's token in a page, and `verify_csrf_token!` (or the route option
  # `csrf: :token`) checks that a request sent it back, as the csrf_param param or an X-CSRF-Token header.
  #
  #   set :csrf, true
  #   set :csrf_trusted_origins, ["https://accounts.example.com"]
  #
  #   post("/login/provider/callback", csrf: false) { ... } # posted by another site's page
  #   post("/settings/delete", csrf: :token) { ... }        # and needs the form's token
  module CSRF
    SAFE_METHODS = ["GET", "HEAD", "OPTIONS"].freeze
    ROUTE_OPTIONS = [nil, false, :token].freeze
    SETTINGS = [false, true, :report].freeze
    # Sec-Fetch-Site values for a request the page's own origin made, or the user did (typing the URL, a bookmark).
    OWN_SITES = ["same-origin", "none"].freeze
    DEFAULT_PORT = /:(?:80|443)\z/

    # Why +env+'s request is a cross-origin one that +trusted+ (normalized origins) doesn't allow, or nil if it isn't.
    def self.cross_origin(env, trusted)
      fetch_site = env["HTTP_SEC_FETCH_SITE"]
      origin = env["HTTP_ORIGIN"]
      return if fetch_site && OWN_SITES.include?(fetch_site)
      return if origin && trusted.include?(origin.downcase)

      if fetch_site.nil? || fetch_site.empty?
        return if origin.nil? || origin.empty? # Not from a browser, or one too old to send either header.
        return if same_authority?(origin, env)

        "Origin #{origin} isn't the request's own"
      else
        "Sec-Fetch-Site is #{fetch_site}#{" (Origin #{origin})" if origin}"
      end
    end

    # Whether +origin+ names the request's host (and port). The scheme isn't compared, since behind a proxy the request's
    # may not be the browser's.
    def self.same_authority?(origin, env)
      authority = origin.split("://", 2)[1]
      return false unless authority

      authority.downcase.sub(DEFAULT_PORT, "") == Rack::Request.new(env).authority.to_s.downcase.sub(DEFAULT_PORT, "")
    end

    # Whether the request is one the cross-origin check applies to. A POST whose _method made it a GET still is.
    def self.unsafe?(env)
      !SAFE_METHODS.include?(env[Rack::RACK_METHODOVERRIDE_ORIGINAL_METHOD] || env["REQUEST_METHOD"])
    end

    # +origins+ as the Origin header gives them: lowercase, without a path or a trailing slash.
    def self.normalize_origins(origins)
      Array(origins).map do |origin|
        normalized = origin.to_s.downcase.delete_suffix("/")
        unless normalized.match?(%r{\A[a-z][a-z0-9+.-]*://[^/?#]+\z})
          raise ArgumentError, "csrf_trusted_origins takes origins (\"https://example.com\"), not #{origin.inspect}"
        end

        normalized
      end.freeze
    end

    # A new token for a session: 32 random bytes, in URL-safe Base64 without padding.
    def self.generate_token = SecureRandom.urlsafe_base64(32)

    # +token+ masked with a one-time pad, so a page's token differs on every render and compressing it alongside text
    # an attacker chose (BREACH) doesn't reveal it: the pad, then the token XORed with it, in URL-safe Base64.
    def self.mask(token)
      pad = SecureRandom.random_bytes(token.bytesize)
      encode(pad + xor(pad, token))
    end

    # Whether +submitted+ is +token+, masked (as csrf_token gives it) or as it is.
    def self.matches?(submitted, token)
      return false unless submitted.is_a?(String) && !submitted.empty? && token.is_a?(String) && !token.empty?

      decoded = decode(submitted)
      if decoded&.bytesize == token.bytesize * 2
        pad = decoded.byteslice(0, token.bytesize)
        return true if Rack::Utils.secure_compare(xor(pad, decoded.byteslice(token.bytesize, token.bytesize)), token)
      end
      Rack::Utils.secure_compare(submitted, token)
    end

    def self.xor(a, b) = a.bytes.zip(b.bytes).map! { |x, y| x ^ y }.pack("C*")
    def self.encode(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    def self.decode(string)
      string = string.tr("-_", "+/")
      string += "=" * (-string.length % 4)
      string.unpack1("m0")
    rescue ArgumentError
      nil
    end

    private_class_method :xor, :encode, :decode

    # The token helpers, in routes, filters, error handlers, and templates.
    module Helpers
      # The session's token, masked afresh (so it differs on each call, and every one is valid). The session gets one
      # the first time it's asked for.
      def csrf_token = CSRF.mask(session_csrf_token)

      # A hidden form field with the token.
      def csrf_field
        %(<input type="hidden" name="#{escape_html(settings.csrf_param)}" value="#{csrf_token}">)
      end

      # Meta tags with the token and the param it's sent as, for scripts: <meta name="csrf-token" content="...">.
      def csrf_meta_tags
        %(<meta name="csrf-param" content="#{escape_html(settings.csrf_param)}">\n<meta name="csrf-token" content="#{csrf_token}">)
      end

      # The token the request sent: the csrf_param param, or else the X-CSRF-Token header.
      def submitted_csrf_token = params[settings.csrf_param] || env["HTTP_X_CSRF_TOKEN"]

      # Whether +token+ (by default, the one the request sent) is the session's.
      def valid_csrf_token?(token = submitted_csrf_token)
        CSRF.matches?(token, session[settings.csrf_session_key])
      end

      # Raises Reprised::InvalidCSRFToken (a 403) unless +token+ is the session's.
      def verify_csrf_token!(token = submitted_csrf_token)
        raise InvalidCSRFToken, "the request's CSRF token isn't the session's" unless valid_csrf_token?(token)
      end

      # Gives the session a new token, the next time one is asked for (as on signing in, so a token from before doesn't
      # carry over).
      def reset_csrf_token!
        session.delete(settings.csrf_session_key)
        nil
      end

      private

      def session_csrf_token
        session = env["rack.session"] or raise(ArgumentError, "CSRF tokens are kept in the session, and there's none (rack.session)")
        key = settings.csrf_session_key
        session[key] ||= CSRF.generate_token
      end
    end
  end
end
