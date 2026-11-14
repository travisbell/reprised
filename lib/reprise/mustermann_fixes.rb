# frozen_string_literal: true

require "mustermann"

module Reprise
  # Fixes for bugs in the Mustermann release Reprise depends on. Each one is applied only if a self-test shows the
  # loaded Mustermann still has the bug, so they switch themselves off once a fixed release is installed.
  module MustermannFixes
    # Mustermann 4.0.1's trie matches an edge holding a single capture with a fast path that takes the rest of the
    # path segment, without regexp. It decides an edge qualifies when the edge's regexp *starts* with the capture and
    # can't match "/" on its own, which is also true of a capture followed by more pattern in the same segment. The
    # fast path then ignores that remainder:
    #
    #   "/movie/:id/?"     never matches "/movie/550/" (the optional slash is never consumed)
    #   "/movie/:id.json"  matches "/movie/550", and matches "/movie/550.json" with id "550.json"
    #
    # The fix only takes the fast path for an edge that is exactly the default capture and nothing else.
    module TrieFastPath
      def optimize!
        super
        return unless @dynamic_entries

        @dynamic_entries = @dynamic_entries.map do |matcher, node, names, fast_name|
          fast_name = nil if fast_name && matcher.source != "\\G(?<#{fast_name}>[^/\\?#]+)"
          [matcher, node, names, fast_name]
        end.freeze
      end
    end

    class << self
      def apply!
        return if @applied

        require "mustermann/set"
        @applied = true
        Mustermann::Set.const_get(:Trie).prepend(TrieFastPath) if trie_fast_path_broken?
      end

      def trie_fast_path_broken?
        set = Mustermann::Set.new(use_trie: true, use_cache: false)
        set.add("/a/:id/?", :optional_slash)
        set.add("/b/:id.json", :suffix)
        set.match("/a/1/").nil? || !set.match("/b/1").nil?
      end
    end
  end
end
