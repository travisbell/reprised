# frozen_string_literal: true

require "rack/response"

module Reprise
  # The response, as Sinatra::Response: a String body becomes [body], 204 and 304 drop their body and content headers,
  # and an Array body gets a content-length.
  class Response < Rack::Response
    DROP_BODY_STATUSES = [204, 304].freeze

    # Rack::Response#initialize, for the empty response Reprise starts with, without making the Method object only
    # #write uses (it's made on first #write instead).
    def initialize
      @status = 200
      @headers = Rack::Headers.new
      @writer = nil
      @block = nil
      @body = []
      @buffered = true
      @length = nil
    end

    def write(chunk)
      @writer ||= method(:append)
      super
    end

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

      if body.is_a?(Array) && !headers.key?("content-length") && headers.key?("content-type")
        headers["content-length"] = body.sum(&:bytesize).to_s
      end

      [status, headers, result]
    end

    private

    def drop_body? = DROP_BODY_STATUSES.include?(status)
  end
end
