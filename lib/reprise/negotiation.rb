# frozen_string_literal: true

require "rack/mime"

module Reprise
  # Accept header parsing and media type selection, with Sinatra 4.2's semantics (Sinatra::Request#accept,
  # #preferred_type, AcceptEntry, MimeTypeEntry and Base.mime_types), so `provides:` picks the same route and content
  # type it does today.
  #
  # One deliberate difference: entries of equal priority keep their order in the header. Sinatra sorts with
  # Array#sort, which isn't stable, so its choice between them is unspecified.
  module Negotiation
    HEADER_PARAM = /\s*[\w.]+=(?:[\w.]+|"(?:[^"\\]|\\.)*")?\s*/
    HEADER_VALUE_WITH_PARAMS = %r{(?:(?:\w+|\*)/(?:\w+(?:\.|-|\+)?|\*)*)\s*(?:;#{HEADER_PARAM})*}

    # A media range from an Accept header.
    Entry = Data.define(:type, :params, :q) do
      def priority = [q, -type.count("*"), params.size]
      def to_s = type
      def to_str = type
    end

    ANY = [Entry.new(type: "*/*", params: {}.freeze, q: 1.0)].freeze

    class << self
      # The Accept header's media ranges, best first. A missing or empty header accepts anything.
      def parse_accept(header)
        return ANY if header.nil? || header.empty?

        entries = header.scan(HEADER_VALUE_WITH_PARAMS).map { parse_entry(it) }
        entries.each_with_index.sort_by { |entry, index| [*entry.priority.map(&:-@), index] }.map!(&:first).freeze
      end

      # The first of +types+ (media type strings) the client accepts, trying its media ranges best first, or nil.
      def preferred_type(accept, types)
        return types.first if accept.empty?

        accept.each do |range|
          type = types.find { accepts?(range, it) }
          return type if type
        end
        nil
      end

      # Every media type +type+ names, as Sinatra's mime_types: a file extension or symbol ("json", :html) or a media
      # type ("application/json"). XML and JavaScript come in pairs, for their deprecated text/ and application/
      # forms.
      def mime_types(type)
        type = mime_type(type)
        case type
        when %r{\Aapplication/(xml|javascript)\z} then [type, "text/#{Regexp.last_match(1)}"]
        when %r{\Atext/(xml|javascript)\z} then [type, "application/#{Regexp.last_match(1)}"]
        else [type]
        end
      end

      def mime_type(type)
        return if type.nil?
        return type.to_s if type.to_s.include?("/")

        type = ".#{type}" unless type.to_s.start_with?(".")
        Rack::Mime.mime_type(type, nil)
      end

      private

      def parse_entry(entry)
        params = parse_params(entry)
        q = params.delete("q") { 1.0 }.to_f
        Entry.new(type: entry[/[^;]+/].delete(" "), params: params.freeze, q:)
      end

      def parse_params(entry)
        entry.scan(HEADER_PARAM).to_h do |param|
          key, value = param.strip.split("=", 2)
          value = value[1..-2].gsub(/\\(.)/, '\1') if value.start_with?('"')
          [key, value]
        end
      end

      # Whether the media range accepts +type+: its wildcards match, and any parameters both specify agree.
      def accepts?(range, type)
        return false unless File.fnmatch(range.type, type[/[^;]+/].delete(" "))

        type_params = parse_params(type)
        type_params.empty? || range.params.all? { |key, value| !type_params.key?(key) || type_params[key] == value }
      end
    end
  end
end
