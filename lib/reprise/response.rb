# frozen_string_literal: true

require "rack/response"

module Reprise
  # The response, as Sinatra::Response: a String body becomes [body], 204 and 304 drop their body and content headers,
  # and an Array body gets a content-length.
  class Response < Rack::Response
    DROP_BODY_STATUSES = [204, 304].freeze

    def body=(value)
      value = value.body while value.is_a?(Rack::Response)
      @body = value.is_a?(String) ? [value.to_str] : value
    end

    def each(&block) = block ? super : enum_for(:each)

    def finish
      result = body

      if informational? || drop_body?
        headers.delete("content-length")
        headers.delete("content-type")
      end

      if drop_body?
        close
        result = []
      end

      if headers["content-type"] && !headers["content-length"] && body.is_a?(Array)
        headers["content-length"] = body.sum(&:bytesize).to_s
      end

      [status, headers, result]
    end

    private

    def drop_body? = DROP_BODY_STATUSES.include?(status)
  end
end
