# frozen_string_literal: true

module Reprise
  # Errors Reprise raises itself. Each carries the HTTP status it answers with.
  class Error < StandardError; end

  # No route matched the request, or every match passed. Handled by `error(404)` and `error(Reprise::NotFound)`.
  class NotFound < Error
    def http_status = 404
  end

  # The request's params couldn't be parsed.
  class BadRequest < Error
    def http_status = 400
  end
end
