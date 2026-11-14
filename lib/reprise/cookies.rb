# frozen_string_literal: true

module Reprise
  # The `cookies` helper: the request's cookies plus any set during this request, as sinatra-contrib's Cookies.
  # Cookies are set with the same defaults: httponly, secure on HTTPS, path "/", and the request's host as domain
  # (none for localhost), merged with the app's `cookie_options` setting.
  class Cookies
    include Enumerable

    attr_reader :options

    def initialize(request, response, settings)
      @request = request
      @response = response
      @set = {}
      @deleted = []
      @options = {
        path: request.script_name.to_s.empty? ? "/" : request.script_name,
        domain: request.host == "localhost" ? nil : request.host,
        secure: request.secure?,
        httponly: true
      }
      @options.merge!(settings.cookie_options) if settings.respond_to?(:cookie_options)
    end

    def [](key) = @set.fetch(key.to_s) { request_cookies[key.to_s] }

    def []=(key, value)
      set(key, value:)
    end
    alias_method :store, :[]=

    # Sets a cookie with options (expires:, max_age:, same_site:, ...) merged over the defaults.
    def set(key, options = {})
      key = key.to_s
      @deleted.delete(key)
      @set[key] = options[:value]
      @response.set_cookie(key, @options.merge(options))
    end

    def delete(key)
      key = key.to_s
      value = self[key]
      @set.delete(key)
      @deleted << key unless @deleted.include?(key)
      @response.delete_cookie(key, @options)
      value
    end

    def fetch(key, ...) = to_hash.fetch(key.to_s, ...)
    def key?(key) = to_hash.key?(key.to_s)
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    def each(&) = to_hash.each(&)
    def keys = to_hash.keys
    def values = to_hash.values
    def empty? = to_hash.empty?
    def size = to_hash.size
    def to_hash = request_cookies.merge(@set)
    alias_method :to_h, :to_hash
    def inspect = "#<#{self.class} #{to_hash.inspect}>"

    private

    def request_cookies = @request.cookies.except(*@deleted)
  end
end
