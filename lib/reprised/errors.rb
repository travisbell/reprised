# frozen_string_literal: true

module Reprised
  # Errors Reprised raises itself. Each carries the HTTP status it answers with.
  class Error < StandardError; end

  # No route matched the request, or every match passed. Handled by `error(404)` and `error(Reprised::NotFound)`.
  class NotFound < Error
    def http_status = 404
  end

  # The request's params couldn't be parsed.
  class BadRequest < Error
    def http_status = 400
  end

  # A request that may have been forged (Reprised::CSRF). Handled by `error(403)` and `error(Reprised::ForgedRequest)`.
  class ForgedRequest < Error
    def http_status = 403
  end

  # A browser's unsafe request that another origin made (`set :csrf, true`).
  class CrossOriginRequest < ForgedRequest; end

  # A request without the session's CSRF token, where one was needed (`verify_csrf_token!`, `csrf: :token`).
  class InvalidCSRFToken < ForgedRequest; end
end
