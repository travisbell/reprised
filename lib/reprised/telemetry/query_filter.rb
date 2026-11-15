# frozen_string_literal: true

module Reprised
  module Telemetry
    # A query string as it's safe to log: the values of parameters whose names look secret replaced with [FILTERED],
    # and the whole cut to a length.
    #
    #   QueryFilter.new.call("api_key=abc&page=2", max_length: 200) # => "api_key=[FILTERED]&page=2"
    class QueryFilter
      # Parts of parameter names (case ignored) whose values are filtered: Rails' defaults, session ids, and the other
      # common names for keys and credentials (apikey, auth and authorization, jwt, signature, pwd).
      DEFAULT_PARAMS = %w[
        passw email secret token _key crypt salt certificate otp ssn cvv cvc session apikey auth jwt signature pwd credential
      ].freeze
      FILTERED = '\1[FILTERED]'

      # @parameter params [Array(String)] Parts of parameter names to filter: a name containing any of them is.
      def initialize(params = DEFAULT_PARAMS)
        names = params.map { Regexp.escape(it) }.join("|")
        @pattern = /((?:\A|[&;])[^&;=]*(?:#{names})[^&;=]*=)[^&;]*/i
      end

      def call(query, max_length:)
        return if query.nil? || query.empty?

        query.gsub(@pattern, FILTERED)[0, max_length]
      end
    end
  end
end
