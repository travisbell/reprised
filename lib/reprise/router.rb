# frozen_string_literal: true

require "uri"
require "mustermann"
require "mustermann/regular"
require "mustermann/sinatra"
require_relative "mustermann_fixes"

module Reprise
  # Matches request paths against patterns in definition order, the way Sinatra tries routes, without trying every
  # pattern.
  #
  #   router = Reprise::Router.new
  #   router.add("GET", "/movie/:id", :show)
  #   router.add("GET", "/movie/new", :new)
  #   router.finalize!
  #
  #   router.find("GET", "/movie/new") { |value, params| value == :new }  # => [:new, {}]
  #   router.each("GET", "/movie/new").map { |value, _| value }        # => [:show, :new]
  #
  # Patterns are grouped in lanes (a verb, or anything else, e.g. :before for filters). How a lane finds its
  # candidates is the matcher:
  #
  # [:index] (default) Indexes each pattern by its leading literal segments ("/movie/:id" under "movie") and, for a
  #          path, tries only the patterns under the segments it starts with, plus those with no literal prefix, in
  #          definition order. Each candidate is matched by its own Mustermann pattern, so matching is exactly what
  #          Sinatra does; only the candidate list is shorter. A path containing "%" tries every pattern, since
  #          Mustermann matches literals against their percent-encoded forms ("/m%6Fvie").
  # [:trie]  Mustermann::Set's trie (Mustermann 4 only). Experimental: Mustermann 4.0.1's trie misses several Sinatra
  #          pattern forms ("/a/?" on "/a", "/a/*" on "/a/", "/tv/:id/edit/?*"), see docs/upstream/mustermann-trie.md.
  class Router
    # What a lane stores for each route or filter: the caller's value, and the definition index that orders it.
    # +composite+ is set for an Array of patterns, which matches once however many of its patterns match.
    Entry = Data.define(:index, :value, :composite)

    URI_PARSER = URI::RFC2396_PARSER
    private_constant :URI_PARSER

    MATCHERS = [:index, :trie].freeze

    attr_reader :matcher, :size

    def initialize(matcher: :index, **pattern_options)
      raise ArgumentError, "unknown matcher #{matcher.inspect}, expected one of #{MATCHERS}" unless MATCHERS.include?(matcher)

      @matcher = matcher
      @pattern_options = pattern_options.freeze
      @lanes = {}
      @size = 0
    end

    # Matches every path, with no params: what a filter without a path is added as.
    EVERY_PATH = Object.new.tap { def it.inspect = "EVERY_PATH" }.freeze

    NO_PARAMS = {}.freeze
    private_constant :NO_PARAMS

    # Adds +pattern+ (a String, Regexp, Mustermann::Pattern, an Array of them, or EVERY_PATH) to +lane+, associated
    # with +value+. Patterns are tried in the order they were added.
    def add(lane, pattern, value)
      raise FrozenError, "can't add to a finalized router" if frozen?

      patterns = pattern.equal?(EVERY_PATH) ? [EVERY_PATH] : Array(pattern).map { compile(it) }
      entry = Entry.new(index: @size, value:, composite: patterns.size > 1)
      target = (@lanes[lane] ||= new_lane)
      patterns.each { target.add(it, entry) }
      @size += 1
      entry
    end

    def finalize!
      @lanes.each_value(&:finalize!)
      @lanes.freeze
      freeze
    end

    def lanes = @lanes.keys
    def lane?(lane) = @lanes.key?(lane)

    # Yields (value, params) for every pattern in +lane+ that matches +path+, in definition order.
    def each(lane, path, &block)
      return enum_for(__method__, lane, path) unless block

      @lanes[lane]&.each_match(path.empty? ? "/" : path, &block)
      nil
    end

    # The first (value, params) for which the block returns truthy, or nil. Routes dispatch through this: the block
    # checks the route's conditions and runs it, and returns false (a failed condition, or `pass`) to try the next.
    def find(lane, path)
      each(lane, path) { |value, params| return [value, params] if yield(value, params) }
      nil
    end

    # Sinatra's params for a regexp pattern: its named captures, plus every capture, unescaped, as "captures".
    def self.regexp_params(pattern, path)
      return unless (params = pattern.params(path))

      captures = pattern.match(path).captures.map { URI_PARSER.unescape(it) if it }
      params["captures"] = captures unless captures.empty?
      params
    end

    private

    def new_lane = @matcher == :trie ? TrieLane.new : IndexLane.new(simple: @pattern_options.empty?)

    def compile(pattern)
      pattern.is_a?(Mustermann::Pattern) ? pattern : Mustermann.new(pattern, **@pattern_options)
    end

    # Tracks Array patterns already yielded for a path, so each matches once, at its first matching pattern.
    module Composites
      private

      def first_sighting?(entry, seen)
        return true unless entry.composite
        return false if seen.include?(entry.index)

        seen << entry.index
        true
      end
    end

    # A Sinatra pattern made only of literal segments and whole-segment params, like "/tv/:id/season/:number/?",
    # matched by comparing path segments rather than with Mustermann's regexp. It's used only for paths with no "%", "?"
    # or "#", where Mustermann would decode nothing, so the params are the same strings Mustermann would give.
    class SimplePattern
      SHAPE = %r{\A((?:/(?:[\w\-.~]+|:[A-Za-z_]\w*))+)(/\?|/)?\z}
      PARAM = /\A:([A-Za-z_]\w*)\z/

      # A SimplePattern for +source+ (a Sinatra pattern's string), or nil if it's not that simple.
      def self.for(source)
        return new([], :required) if source == "/"
        return unless (match = SHAPE.match(source))

        segments = match[1].split("/").drop(1).map { (param = PARAM.match(it)) ? param[1].freeze : it.to_sym }
        names = segments.grep(String)
        return unless names.uniq.size == names.size

        trailing = case match[2] when "/?" then :optional when "/" then :required else :forbidden end
        new(segments.freeze, trailing)
      end

      # +segments+: Symbols for literal segments (as Symbols, so they can't be confused with param names) and Strings
      # for param names. +trailing+: whether the path may (:optional), must (:required), or mustn't (:forbidden) end
      # with "/".
      def initialize(segments, trailing)
        @segments = segments
        @literals = segments.map { it.is_a?(Symbol) ? it.name.freeze : nil }.freeze
        @size = segments.size
        @trailing = trailing
        # With no params, the paths it matches, compared whole.
        unless segments.any?(String)
          base = segments.empty? ? "" : "/#{@literals.join("/")}"
          @paths = case trailing
          when :forbidden then [base.empty? ? "/" : base]
          when :required then ["#{base}/"]
          else [base, "#{base}/"].reject(&:empty?)
          end.freeze
        end
        freeze
      end

      # The paths this pattern matches, if it has no params (so a path can be compared whole), else nil.
      attr_reader :paths

      # Params for a path split into +parts+ (its segments) and +trailing_slash+, or nil.
      def params(parts, trailing_slash)
        return if parts.size != @size
        return if trailing_slash ? @trailing == :forbidden : @trailing == :required

        params = nil
        index = 0
        while index < @size
          part = parts[index]
          if (literal = @literals[index])
            return unless part == literal
          else
            return if part.empty?

            (params ||= {})[@segments[index]] = part
          end
          index += 1
        end
        params || {}
      end
    end

    class IndexLane
      include Composites

      Candidate = Data.define(:entry, :pattern, :regexp, :simple)

      class Node
        # +candidates+ are the patterns indexed here; +reachable+, once finalized, are those plus every ancestor's, in
        # definition order: all the patterns a path reaching this node can match.
        attr_reader :children, :candidates, :reachable

        def initialize
          @children = {}
          @candidates = []
          @reachable = nil
        end

        def finalize!(inherited)
          @reachable = (inherited + @candidates).sort_by! { it.entry.index }.freeze
          @children.each_value { it.finalize!(@reachable) }
          @children.freeze
          @candidates.freeze
          freeze
        end
      end

      # A pattern segment that matches only itself. Anything else (params, splats, optional or escaped characters,
      # groups) ends the literal prefix.
      LITERAL_SEGMENT = /\A[\w\-.~]+\z/

      def initialize(simple: true)
        @root = Node.new
        @all = []
        @composite = false
        @simple = simple
      end

      def add(pattern, entry)
        simple = SimplePattern.for(pattern.to_s) if @simple && pattern.instance_of?(Mustermann::Sinatra)
        candidate = Candidate.new(entry:, pattern:, regexp: pattern.is_a?(Mustermann::Regular), simple:)
        node = literal_segments(pattern).reduce(@root) { |parent, segment| parent.children[segment] ||= Node.new }
        node.candidates << candidate
        @all << candidate
        @composite ||= entry.composite
      end

      def finalize!
        @root.finalize!([].freeze)
        @all.freeze
        freeze
      end

      def each_match(path)
        seen = [] if @composite
        # The path's segments, for simple patterns: only for a path Mustermann wouldn't decode, split once.
        plain = path.start_with?("/") && !path.include?("%") && !path.include?("?") && !path.include?("#")
        parts = nil
        trailing_slash = false

        candidates(path).each do |candidate|
          params = if candidate.pattern.equal?(EVERY_PATH)
            NO_PARAMS
          elsif candidate.simple && plain
            if (paths = candidate.simple.paths)
              NO_PARAMS if paths.include?(path)
            else
              parts, trailing_slash = split(path) unless parts
              candidate.simple.params(parts, trailing_slash)
            end
          elsif candidate.regexp
            Router.regexp_params(candidate.pattern, path)
          else
            candidate.pattern.params(path)
          end
          next unless params

          yield(candidate.entry.value, params) if first_sighting?(candidate.entry, seen)
        end
      end

      # The candidates for +path+ in definition order: those with no literal prefix, plus those under each literal
      # segment the path starts with. That's the deepest node the path reaches, whose list was merged at finalize, so
      # finding them allocates nothing but the segment strings.
      def candidates(path)
        return @all if path.include?("%") || !path.start_with?("/")

        node = @root
        position = 1

        until node.children.empty?
          segment_end = path.index("/", position) || path.size
          child = node.children[path[position...segment_end]] or break
          node = child
          break if segment_end >= path.size

          position = segment_end + 1
        end

        node.reachable
      end

      private

      # A path's segments, and whether it ends with "/": "/movie/550/" is [["movie", "550"], true], "/" is [[], true].
      def split(path)
        parts = path.split("/", -1)
        parts.shift
        trailing_slash = parts.last == ""
        parts.pop if trailing_slash
        [parts, trailing_slash]
      end

      def literal_segments(pattern)
        return [] unless pattern.instance_of?(Mustermann::Sinatra) # (EVERY_PATH and regexps sit at the root)

        source = pattern.to_s
        return [] unless source.start_with?("/")

        source.split("/", -1).drop(1).take_while { LITERAL_SEGMENT.match?(it) }
      end
    end

    class TrieLane
      include Composites

      RegexpCandidate = Data.define(:entry, :pattern)

      def initialize
        begin
          MustermannFixes.apply!
        rescue LoadError
          raise ArgumentError, "matcher: :trie needs Mustermann 4 (Mustermann::Set); the default :index works with 3 or 4"
        end
        # Ordered by Entry#index here rather than with strict_order, which computes every match and sorts them anyway.
        # No cache: it shares Match objects, and their params hashes, between requests.
        @set = Mustermann::Set.new(use_trie: true, use_cache: false)
        @regexps = []
        @composite = false
      end

      def add(pattern, entry)
        pattern = Mustermann.new(%r{.*}) if pattern.equal?(EVERY_PATH)
        if pattern.is_a?(Mustermann::Regular)
          @regexps << RegexpCandidate.new(entry:, pattern:)
        else
          @set.add(pattern, entry)
        end
        @composite ||= entry.composite
      end

      def finalize!
        @set.optimize!
        @regexps.freeze
        freeze
      end

      def each_match(path)
        seen = [] if @composite
        matches = @set.match_all(path) || []
        matches.sort_by! { it.value.index } if matches.size > 1
        regexp_position = 0

        matches.each do |match|
          regexp_position = yield_regexps_before(match.value.index, path, regexp_position, seen) { yield(*it) }
          yield(match.value.value, match.params) if first_sighting?(match.value, seen)
        end
        yield_regexps_before(Float::INFINITY, path, regexp_position, seen) { yield(*it) }
      end

      private

      # Yields regexp matches defined before +index+, and returns the position to continue from.
      def yield_regexps_before(index, path, position, seen)
        while position < @regexps.size && @regexps[position].entry.index < index
          candidate = @regexps[position]
          position += 1
          params = Router.regexp_params(candidate.pattern, path)
          yield([candidate.entry.value, params]) if params && first_sighting?(candidate.entry, seen)
        end
        position
      end
    end

    private_constant :IndexLane, :TrieLane, :Composites
  end
end
