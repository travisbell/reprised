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

    # Adds +pattern+ (a String, Regexp, Mustermann::Pattern, or an Array of them) to +lane+, associated with +value+.
    # Patterns are tried in the order they were added.
    def add(lane, pattern, value)
      raise FrozenError, "can't add to a finalized router" if frozen?

      patterns = Array(pattern).map { compile(it) }
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

    def new_lane = @matcher == :trie ? TrieLane.new : IndexLane.new

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

    class IndexLane
      include Composites

      Candidate = Data.define(:entry, :pattern, :regexp)

      class Node
        attr_reader :children, :candidates

        def initialize
          @children = {}
          @candidates = []
        end

        def freeze
          @children.each_value(&:freeze).freeze
          @candidates.freeze
          super
        end
      end

      # A pattern segment that matches only itself. Anything else (params, splats, optional or escaped characters,
      # groups) ends the literal prefix.
      LITERAL_SEGMENT = /\A[\w\-.~]+\z/

      def initialize
        @root = Node.new
        @all = []
        @composite = false
      end

      def add(pattern, entry)
        candidate = Candidate.new(entry:, pattern:, regexp: pattern.is_a?(Mustermann::Regular))
        node = literal_segments(pattern).reduce(@root) { |parent, segment| parent.children[segment] ||= Node.new }
        node.candidates << candidate
        @all << candidate
        @composite ||= entry.composite
      end

      def finalize!
        @root.freeze
        @all.freeze
        freeze
      end

      def each_match(path)
        seen = [] if @composite

        candidates(path).each do |candidate|
          params = candidate.regexp ? Router.regexp_params(candidate.pattern, path) : candidate.pattern.params(path)
          next unless params

          yield(candidate.entry.value, params) if first_sighting?(candidate.entry, seen)
        end
      end

      # The candidates for +path+ in definition order: those with no literal prefix, plus those under each literal
      # segment the path starts with.
      def candidates(path)
        return @all if path.include?("%") || !path.start_with?("/")

        lists = nil
        node = @root
        position = 1

        until node.children.empty?
          segment_end = path.index("/", position) || path.size
          node = node.children[path[position...segment_end]] or break
          (lists ||= [@root.candidates]) << node.candidates unless node.candidates.empty?
          break if segment_end >= path.size

          position = segment_end + 1
        end

        lists ? lists.flatten.sort_by! { it.entry.index } : @root.candidates
      end

      private

      def literal_segments(pattern)
        return [] unless pattern.instance_of?(Mustermann::Sinatra)

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
