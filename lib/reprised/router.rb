# frozen_string_literal: true

require "uri"
require "mustermann"
require "mustermann/regular"
require "mustermann/sinatra"
require_relative "mustermann_fixes"

module Reprised
  # Matches request paths against patterns in definition order, the way Sinatra tries routes, without trying every
  # pattern.
  #
  #   router = Reprised::Router.new
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
  #          definition order. A pattern made of literal segments and whole-segment params (nearly every route) is
  #          matched by the index itself, and needs no Mustermann pattern (see SimplePattern); any other is matched by
  #          its own Mustermann pattern. Either way matching is exactly what Sinatra does; only the candidate list is
  #          shorter. A path containing "%" tries every pattern, since Mustermann matches literals against their
  #          percent-encoded forms ("/m%6Fvie").
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
      # What was added to each lane, in order, until finalize! compares them.
      @additions = {}
      # The SimplePattern for each simple pattern String added, so lanes share one. (Until finalize!.)
      @simple_patterns = {}
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
      (@additions[lane] ||= []) << [pattern, value]
      @size += 1
      entry
    end

    # A lane with the same patterns and values as another, added in the same order, shares that lane rather than keep
    # a copy: an app's HEAD lane, when its get routes answer HEAD and it has no head routes of its own.
    def finalize!
      additions = @additions
      @additions = nil
      @simple_patterns = nil
      kept = []
      @lanes.keys.each do |lane|
        twin = kept.find { same_additions?(additions[it], additions[lane]) }
        twin ? @lanes[lane] = @lanes[twin] : kept << lane
      end
      kept.each { @lanes[it].finalize! }
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

    # Sinatra's params for a regexp pattern: its named captures, plus every capture, unescaped, as "captures". Without
    # named groups there are only the captures, from one match (Mustermann's params would match again).
    def self.regexp_params(pattern, path)
      if pattern.regexp.names.empty?
        return unless (match = pattern.regexp.match(path))

        captures = match.captures.map { URI_PARSER.unescape(it) if it }
        return captures.empty? ? {} : { "captures" => captures }
      end

      return unless (params = pattern.params(path))

      captures = pattern.match(path).captures.map { URI_PARSER.unescape(it) if it }
      params["captures"] = captures unless captures.empty?
      params
    end

    private

    def new_lane = @matcher == :trie ? TrieLane.new : IndexLane.new(simple: @pattern_options.empty?)

    def same_additions?(these, those)
      these.size == those.size && these.each_with_index.all? do |(pattern, value), i|
        pattern.equal?(those[i][0]) && value.equal?(those[i][1])
      end
    end

    # A Mustermann pattern for +pattern+, unless it's a String the index matcher matches as a SimplePattern (as nearly
    # every route is): that needs no Mustermann pattern at all, which saves its regexps and caches.
    def compile(pattern)
      return pattern if pattern.is_a?(Mustermann::Pattern)

      if pattern.is_a?(String) && @matcher == :index && @pattern_options.empty?
        simple = (@simple_patterns[pattern] ||= SimplePattern.for(pattern) || false)
        return simple if simple
      end
      Mustermann.new(pattern, **@pattern_options)
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

    # A Sinatra pattern made only of literal segments and whole-segment params, like "/tv/:id/season/:number/?". A plain
    # path (no "%", "?" or "#") is matched with a capture-free regexp, which allocates nothing (most candidates don't
    # match), and its params are taken only once it has. A path with "%" is matched segment by segment, each one
    # decoded, as Mustermann matches a literal in its percent-encoded forms too and decodes params. Either way the
    # params are what Mustermann would give, so a router needs no Mustermann pattern for it.
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

      # The paths this pattern matches, if it has no params (so a path can be compared whole), else nil.
      attr_reader :paths

      # The segments a router indexes it under: its literal segments, and nil for each param.
      def index_segments = @literals

      # A path it matches, with "x" for each param, as Mustermann's expand(:ignore) gives it (with an optional trailing
      # "/").
      def sample_path
        path = "/#{@segments.map { it.is_a?(Symbol) ? it.name : "x" }.join("/")}"
        @trailing == :forbidden || @segments.empty? ? path : "#{path}/"
      end

      # +segments+: Symbols for literal segments (as Symbols, so they can't be confused with param names) and Strings
      # for param names. +trailing+: whether the path may (:optional), must (:required), or mustn't (:forbidden) end
      # with "/".
      def initialize(segments, trailing)
        @segments = segments
        @size = segments.size
        @trailing = trailing
        @names = segments.grep(String).freeze
        literals = segments.map { it.is_a?(Symbol) ? it.name : nil }
        @literals = literals.freeze
        if @names.empty?
          base = segments.empty? ? "" : "/#{literals.join("/")}"
          @paths = case trailing
          when :forbidden then [base.empty? ? "/" : base]
          when :required then ["#{base}/"]
          else [base, "#{base}/"].reject(&:empty?)
          end.freeze
        end
        freeze
      end

      # Params for +path+ (one with "%"), or nil: each segment decoded, then compared with its literal or taken as its
      # param. A "?" or "#" can't be in any segment, and an encoded "/" stays in its segment, as in Mustermann.
      def decoded_params(path)
        return if !path.start_with?("/") || path.include?("?") || path.include?("#")

        trailing = path.length > 1 && path.end_with?("/")
        return if trailing ? @trailing == :forbidden : @trailing == :required && path != "/"

        segments = (trailing ? path[1...-1] : path[1..]).split("/", -1)
        return unless segments.size == @size

        params = {}
        segments.each_with_index do |segment, index|
          return if segment.empty?

          value = URI_PARSER.unescape(segment)
          if (literal = @literals[index])
            return unless value == literal
          else
            params[@segments[index]] = value
          end
        end
        params
      end

      # Params for +path+, a plain path that reached this pattern in a router's index, or nil. Reaching it, the path
      # matched each of its literal segments and had a segment for each param, so all that's left is that the path has no
      # more segments, and a trailing "/" only if the pattern allows one. (So there's no regexp to match, or to keep.)
      def params(path)
        length = path.bytesize
        position = 1
        @size.times do
          return if position > length # fewer segments

          segment_end = path.byteindex("/", position) || length
          return if segment_end == position # an empty one

          position = segment_end + 1
        end
        case length - position
        when -1 then return if @trailing == :required # no trailing "/"
        when 0 then return if @trailing == :forbidden # a trailing "/"
        else return # more segments
        end

        params = {}
        position = 1
        index = 0
        while index < @size
          segment_end = path.byteindex("/", position) || path.bytesize
          params[@segments[index]] = path.byteslice(position, segment_end - position) unless @literals[index]
          position = segment_end + 1
          index += 1
        end
        params
      end
    end

    class IndexLane
      include Composites

      # +check+ is the pattern's own regexp, for a match? test (no MatchData) before asking Mustermann for params.
      # +order+ is when it was added, which orders candidates exactly (an Array's patterns share their entry's index).
      Candidate = Data.define(:entry, :pattern, :regexp, :simple, :check, :order)

      class Node
        NO_CHILDREN = {}.freeze
        NO_CANDIDATES = [].freeze

        # +candidates+ are the patterns indexed here; +reachable+, once finalized, are those plus every ancestor's, in
        # definition order: all the patterns a path reaching this node can match. +wildcard+ is the child for any
        # non-empty segment (a whole-segment :param).
        attr_reader :children, :candidates, :reachable, :reachable_with_wildcard
        attr_accessor :wildcard

        def initialize
          @children = {}
          @wildcard = nil
          @candidates = []
          @reachable = nil
          @reachable_with_wildcard = nil
        end

        def leaf? = @children.empty? && @wildcard.nil?

        # +sibling+ is the parent's wildcard, if it has one. For a path whose last segment matches both this node and
        # it, both lists are merged here, once.
        def finalize!(inherited, sibling = nil)
          @reachable = (inherited + @candidates).sort_by!(&:order).freeze
          @reachable_with_wildcard = (@reachable | sibling.reachable).sort_by!(&:order).freeze if sibling
          @wildcard&.finalize!(@reachable)
          @children.each_value { it.finalize!(@reachable, @wildcard) }
          # A leaf (most nodes) shares one empty Hash and Array rather than keep its own.
          @children = @children.empty? ? NO_CHILDREN : @children.freeze
          @candidates = @candidates.empty? ? NO_CANDIDATES : @candidates.freeze
          freeze
        end
      end

      WILDCARD = Object.new.freeze

      # A pattern segment that matches only itself, and one that's a whole-segment param. Anything else (splats,
      # optional or escaped characters, groups) ends what's indexed.
      LITERAL_SEGMENT = /\A[\w\-.~]+\z/
      PARAM_SEGMENT = /\A:[A-Za-z_]\w*\z/

      # A regexp's literal segments: plain characters, each followed by a "/" that isn't optional.
      REGEXP_LITERAL_SEGMENT = /\G([A-Za-z0-9_~-]+)\/(?![?*+{])/
      MUSTERMANN_REGEXP = /\A\\A\(\?-mix:(.*)\)\\Z\z/m

      def initialize(simple: true)
        @root = Node.new
        @all = []
        @composite = false
        @simple = simple
      end

      def add(pattern, entry)
        simple = if pattern.is_a?(SimplePattern) then pattern
        elsif @simple && pattern.instance_of?(Mustermann::Sinatra) then SimplePattern.for(pattern.to_s)
        end
        check = pattern.regexp if pattern.respond_to?(:regexp)
        candidate = Candidate.new(entry:, pattern:, regexp: pattern.is_a?(Mustermann::Regular), simple:, check:, order: @all.size)
        node = index_segments(pattern).reduce(@root) do |parent, segment|
          segment.equal?(WILDCARD) ? (parent.wildcard ||= Node.new) : (parent.children[segment] ||= Node.new)
        end
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
        # Simple patterns match only paths Mustermann wouldn't decode.
        plain = path.start_with?("/") && !path.include?("%") && !path.include?("?") && !path.include?("#")

        candidates(path).each do |candidate|
          params = if candidate.pattern.equal?(EVERY_PATH)
            NO_PARAMS
          elsif candidate.simple && plain
            if (paths = candidate.simple.paths)
              NO_PARAMS if paths.include?(path)
            else
              candidate.simple.params(path)
            end
          elsif candidate.simple && candidate.pattern.equal?(candidate.simple)
            candidate.simple.decoded_params(path)
          elsif candidate.check && !candidate.check.match?(path)
            nil
          elsif candidate.regexp
            Router.regexp_params(candidate.pattern, path)
          else
            candidate.pattern.params(path)
          end
          next unless params

          yield(candidate.entry.value, params) if first_sighting?(candidate.entry, seen)
        end
      end

      # The candidates for +path+ in definition order: the patterns indexed at the nodes its segments lead to, through
      # literal children and wildcards. Usually the path follows one way, to a node whose list was merged at finalize,
      # so finding them allocates nothing but the segment strings. A path that could go both ways at a segment (a
      # literal child and a wildcard both fit) has its branches' lists merged.
      def candidates(path)
        return @all if path.include?("%") || !path.start_with?("/")

        length = path.bytesize
        node = @root
        position = 1

        until node.leaf?
          segment_end = path.byteindex("/", position) || length
          # (Assigned on every pass: a modifier `unless` would leave the last pass's node in place.)
          exact = node.children.empty? ? nil : node.children[path.byteslice(position, segment_end - position)]
          wild = segment_end > position ? node.wildcard : nil
          if exact && wild
            # Both fit the last segment (with perhaps a trailing "/"): that merge was made at finalize.
            return exact.reachable_with_wildcard if segment_end >= length - 1

            return branched(path, [exact, wild], segment_end, length)
          end

          child = exact || wild or break
          node = child
          break if segment_end >= length

          position = segment_end + 1
        end

        node.reachable
      end

      private

      # Follows every way the rest of the path leads from +nodes+ (which the segment ending at +segment_end+ reached),
      # and merges the lists of the nodes each way ends at.
      def branched(path, nodes, segment_end, length)
        ends = []
        while segment_end < length && !nodes.empty?
          position = segment_end + 1
          segment_end = path.byteindex("/", position) || length
          segment = nil
          following = []
          nodes.each do |node|
            exact = node.children.empty? ? nil : node.children[segment ||= path.byteslice(position, segment_end - position)]
            wild = segment_end > position ? node.wildcard : nil
            following << exact if exact
            following << wild if wild
            ends << node unless exact || wild
          end
          nodes = following
        end
        ends.concat(nodes)

        seen = {}.compare_by_identity
        ends.each_with_object([]) do |node, merged|
          node.reachable.each { |candidate| merged << candidate unless seen.key?(candidate) || !(seen[candidate] = true) }
        end.sort_by!(&:order)
      end

      # The segments a pattern is indexed under: its leading literal segments, and for a Sinatra pattern (with default
      # options), whole-segment params as wildcards, then any literal segments after them. A regexp is indexed by the
      # literal segments it starts with. Anything else sits at the root.
      def index_segments(pattern)
        case pattern
        when SimplePattern then pattern.index_segments.map { it || WILDCARD }
        when Mustermann::Sinatra
          return [] unless pattern.instance_of?(Mustermann::Sinatra) && (source = pattern.to_s).start_with?("/")

          segments = []
          source.split("/", -1).drop(1).each do |segment|
            if LITERAL_SEGMENT.match?(segment) then segments << segment
            elsif @simple && PARAM_SEGMENT.match?(segment) then segments << WILDCARD
            else break
            end
          end
          segments.pop while segments.last.equal?(WILDCARD) && !@simple
          segments
        when Mustermann::Regular then regexp_segments(pattern)
        else []
        end
      end

      def regexp_segments(pattern)
        # Mustermann keeps a regexp's "/" escaped; an escaped "/" is just a "/". (The prefix stops at the first character
        # that isn't a plain one, a backslash included, so nothing after it is misread.)
        inner = MUSTERMANN_REGEXP.match(pattern.regexp.source)&.[](1)&.gsub("\\/", "/")
        return [] unless inner&.start_with?("/") && !top_level_alternation?(inner)

        segments = []
        position = 1
        while (match = REGEXP_LITERAL_SEGMENT.match(inner, position))
          segments << match[1]
          position = match.end(0)
        end
        segments
      end

      # Whether +source+ has a "|" outside any group, which would let it match paths without its prefix.
      def top_level_alternation?(source)
        depth = 0
        escaped = false
        in_class = false
        source.each_char do |char|
          if escaped then escaped = false
          elsif char == "\\" then escaped = true
          elsif in_class then in_class = false if char == "]"
          elsif char == "[" then in_class = true
          elsif char == "(" then depth += 1
          elsif char == ")" then depth -= 1
          elsif char == "|" && depth.zero? then return true
          end
        end
        false
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
