# frozen_string_literal: true

require "i18n"

module Reprised
  module Plugins
    # The request's locale, from where the client says it is, set as I18n.locale for the request:
    #
    #   plugin Reprised::Plugins::Locale,
    #     available: ["en-US", "fr-FR", "fr-CA"],
    #     defaults: { "fr" => "fr-FR" },
    #     from: [:param, :cookie, :accept_language]
    #
    # The sources in +from+ are tried in order, and the first that names an available locale decides it:
    #
    # - :param, the +param+ query param (?locale=fr-CA)
    # - :cookie, the +cookie+ cookie
    # - :accept_language, the Accept-Language header: its language ranges in order of their q values (the first listed
    #   first, among equal ones), skipping q=0 and *
    # - a callable, which takes the Rack::Request and returns a locale, several, or nil
    #
    # A candidate matches an +available+ locale (by default I18n.available_locales, read on the first request) ignoring
    # case, with _ read as -. One that doesn't is shortened a subtag at a time, as RFC 4647's lookup does (zh-Hant-TW,
    # zh-TW without the script, zh-Hant, zh), and its language alone matches the locale +defaults+ gives it (fr-CH to
    # fr-FR). For Accept-Language, +region+ (a callable that takes the request and returns its country, as "CA") comes
    # first: a range that matches only by its language takes that language in the client's region, if it's available
    # (fr to fr-CA). With no match, the locale is +default+ (I18n.default_locale).
    #
    # It sets I18n.locale, which i18n keeps in fiber storage, so it's the request's own under Falcon and Async tasks the
    # request starts inherit it, and puts the previous one back once the response's body is closed (a body that streams
    # renders with the request's locale). The locale is also env["reprised.locale"] and the `locale` helper.
    #
    # An HTML response gets it as its content-language (unless the app sets one, or +content_language+ is false). Where
    # Accept-Language could have decided the locale (no source before it did), the response gets Vary: Accept-Language
    # (unless +vary+ is false), so a shared cache doesn't give one visitor's language to another.
    #
    # It runs as middleware in the app, ahead of routing, so error pages have it too. It reads the query and cookies
    # through the request, which keeps them in the env, so the app doesn't parse them again. A query string that doesn't
    # parse gives no locale (the app answers it with a 400).
    module Locale
      ENV_KEY = "reprised.locale"

      module Helpers
        # The request's locale, as a String.
        def locale = env[ENV_KEY] || I18n.locale.to_s
      end

      # Matches candidates (a client's language tags) to the available locales, remembering what each came to.
      class Matcher
        MAX_REMEMBERED = 2048
        # Longer tags than any locale has (RFC 5646 asks for 35 characters to be supported), and more ranges than any
        # browser sends, aren't looked at: a client could send any number, and each costs a lookup.
        MAX_TAG_LENGTH = 64
        MAX_RANGES = 32
        # Longer headers are matched, but not remembered, so a client sending big ones can't fill the memory.
        MAX_REMEMBERED_LENGTH = 512

        def initialize(available:, defaults:)
          @available = available
          @defaults = defaults.to_h { |language, locale| [language.to_s.downcase, locale.to_s] }
          @remembered = {}.freeze
        end

        # The available locale +candidate+ names, or nil.
        def match(candidate)
          candidate = candidate.to_s
          return if candidate.empty? || candidate.length > MAX_TAG_LENGTH

          remembered = @remembered
          return remembered[candidate] if remembered.key?(candidate)

          remember(candidate, lookup(candidate))
        end

        # The first available locale an Accept-Language header names, or nil. A range that matches only by its language
        # takes that language in +region+ (the client's country, as "CA"), if it's available, ahead of its default.
        def match_accept_language(header, region = nil)
          header = header.to_s
          return first_available(header, region) if header.bytesize > MAX_REMEMBERED_LENGTH

          remembered = @remembered
          key = "accept-language:#{region}:#{header}"
          return remembered[key] if remembered.key?(key)

          remember(key, first_available(header, region))
        end

        # An Accept-Language header's language ranges, most preferred first: in order of their q values, and of where
        # they're listed among equal ones, without those at q=0 and *. Only the first MAX_RANGES are read, and a range
        # longer than MAX_TAG_LENGTH is left out.
        def self.language_ranges(header)
          ranges = header.to_s.split(",", MAX_RANGES + 1).first(MAX_RANGES).each_with_index.filter_map do |entry, index|
            range, *params = entry.split(";")
            range = range.to_s.strip
            next if range.empty? || range == "*" || range.length > MAX_TAG_LENGTH

            q = params.find { it.strip.downcase.start_with?("q=") }&.then { it.strip[2..].to_f } || 1.0
            [range, q, index] if q > 0
          end
          ranges.sort_by { |_, q, index| [-q, index] }.map(&:first)
        end

        private

        def first_available(header, region) = Matcher.language_ranges(header).lazy.filter_map { lookup(it, region) }.first

        def lookup(candidate, region = nil)
          subtags = candidate.tr("_", "-").downcase.split("-")
          tags = subtags.length.downto(1).map { subtags.first(it).join("-") }
          # With a script (zh-Hant-TW), the language and region without it (zh-TW), before the shorter tags.
          tags.insert(1, "#{subtags[0]}-#{subtags[2]}") if subtags.length >= 3 && subtags[1].length == 4
          tags.each do |tag|
            locale = locales[tag]
            return locale if locale
          end

          language = subtags.first
          (region && locales["#{language}-#{region.to_s.downcase}"]) || ((locale = @defaults[language]) && locales[locale.downcase])
        end

        # The available locales, by their lowercase form.
        def locales
          @locales ||= Array(@available || I18n.available_locales).to_h { [it.to_s.downcase, it.to_s.freeze] }.freeze
        end

        # Copy-on-write, so requests can read it while another adds to it, and a fresh start once it's full: client
        # language tags repeat (a handful of browser defaults cover most traffic), but a client could send any.
        def remember(key, locale)
          remembered = @remembered.size >= MAX_REMEMBERED ? {} : @remembered
          @remembered = remembered.merge(key.dup.freeze => locale).freeze
          locale
        end
      end

      class Middleware
        def initialize(app, matcher:, from:, param:, cookie:, region:, default:, content_language:, vary:)
          @app = app
          @matcher = matcher
          @region = region
          @sources = from.map { source(it, param:, cookie:) }.freeze
          # Where Accept-Language comes among the sources, if it does: a request whose locale no earlier source decided
          # depends on it.
          @accept_language_at = (from.index(:accept_language) if vary)
          @default = default
          @content_language = content_language
        end

        def call(env)
          locale, decided_at = detect(Request.new(env))
          env[ENV_KEY] = locale
          previous = I18n.locale
          I18n.locale = locale

          begin
            status, headers, body = @app.call(env)
          rescue Exception # put the locale back, and re-raise
            I18n.locale = previous
            raise
          end
          headers["content-language"] ||= locale if @content_language && html?(headers)
          vary_on_accept_language(headers) if @accept_language_at && (decided_at.nil? || decided_at >= @accept_language_at)
          # The body may render as the server sends it (a stream): the locale is put back once it's closed.
          [status, headers, Rack::BodyProxy.new(body) { I18n.locale = previous }]
        end

        private

        # The locale, and the index of the source that decided it (nil for the default).
        def detect(request)
          @sources.each_with_index do |source, index|
            locale = source.call(request)
            return locale, index if locale
          end
          [(@default || I18n.default_locale).to_s, nil]
        end

        def html?(headers)
          type = headers["content-type"]
          type.nil? ? false : type.start_with?("text/html", "application/xhtml+xml")
        end

        def vary_on_accept_language(headers)
          vary = headers["vary"]
          if vary.nil? || vary.empty?
            headers["vary"] = "accept-language"
          elsif vary != "*" && !vary.split(",").any? { it.strip.casecmp?("accept-language") }
            headers["vary"] = "#{vary}, accept-language"
          end
        end

        # A source as a callable that takes the request and returns the available locale it names, or nil.
        def source(name, param:, cookie:)
          matcher = @matcher
          case name
          when :param
            lambda do |request|
              value = request.GET[param]
              matcher.match(value) if value.is_a?(String)
            rescue BadRequest # the app answers it with a 400
              nil
            end
          when :cookie then ->(request) { (value = request.cookies[cookie]) && matcher.match(value) }
          when :accept_language
            region = @region
            lambda do |request|
              header = request.get_header("HTTP_ACCEPT_LANGUAGE") or return
              matcher.match_accept_language(header, region&.call(request))
            end
          else
            raise ArgumentError, "#{name.inspect} isn't a locale source: use :param, :cookie, :accept_language, or a callable" unless name.respond_to?(:call)

            lambda do |request|
              Array(name.call(request)).each do |candidate|
                locale = matcher.match(candidate)
                return locale if locale
              end
              nil
            end
          end
        end
      end

      def self.install(app, available: nil, defaults: {}, from: [:param, :cookie, :accept_language], param: "locale",
        cookie: "locale", region: nil, default: nil, content_language: true, vary: true)
        matcher = Matcher.new(available: available&.map(&:to_s)&.freeze, defaults:)
        app.use(Middleware, matcher:, from:, param:, cookie:, region:, default:, content_language:, vary:)
        app.helpers(Helpers)
      end
    end
  end
end
