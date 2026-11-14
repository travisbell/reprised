# Draft issue for sinatra/mustermann: `Mustermann::Set` trie mode disagrees with linear mode

**Status:** draft, not filed. Reproduction: [`mustermann-trie-repro.rb`](mustermann-trie-repro.rb) (`ruby docs/upstream/mustermann-trie-repro.rb`).

---

**Title:** `Mustermann::Set` with `use_trie` misses and mis-matches common Sinatra patterns (4.0.1)

In 4.0.1, a `Mustermann::Set` in trie mode returns different matches than the same set in linear mode for several
everyday Sinatra pattern forms. Trie mode is the default once a set holds 50 patterns, so the results change as a
set grows. Each case below adds one pattern to an empty set and compares `match_all` in both modes:

| Pattern | Path | Trie | Linear (correct) |
|---|---|---|---|
| `/movie/:id/?` | `/movie/550/` | no match | `{"id"=>"550"}` |
| `/movie/:id.json` | `/movie/550` | `{"id"=>"550"}` | no match |
| `/movie/:id.json` | `/movie/550.json` | `{"id"=>"550.json"}` | `{"id"=>"550"}` |
| `/account/?` | `/account` | no match | `{}` |
| `/account/*` | `/account/` | no match | `{"splat"=>[""]}` |
| `/tv/:id/edit/?*` | `/tv/1/edit/images` | no match | `{"id"=>"1", "splat"=>["images"]}` |
| `/tv/:id/edit/?*` | `/tv/1/edit` | no match | `{"id"=>"1", "splat"=>[""]}` |
| `/a/:b?` | `/a/` | no match | `{"b"=>nil}` |
| `/a/:b?/c` | `/a//c` | `{}` | `{"b"=>nil}` |

We found these by replaying two production Sinatra route tables (about 1,400 routes) through a `Set` and comparing
against Sinatra 4.2's own routing. With the trie, 1,460 of 132,570 requests reached a different route.

## Causes we've identified

**1. The single-capture fast path accepts edges that hold more than a capture** (`Trie#optimize!`). An edge
qualifies when its regexp *starts* with `\G(?<name>` and can't match `"/"`. That is also true of a capture compiled
together with the rest of its segment, for example `\G(?<id>[^/\?#]+)(?:/)?` or `\G(?<id>[^/\?#]+)(?:\.|%2E|%2e)…json`.
The fast path then takes the segment up to the next `/` and ignores the remainder. That causes rows 1–3.

A possible fix is to only take the fast path when the edge is exactly the default capture:

```ruby
fast = matcher.source == "\\G(?<#{name}>[^/\\?#]+)" ? name : nil
```

**2. Edges that can match the empty string are never tried at the end of the input** (`Trie#match`).
`return build_matches(...) if position >= string.size` runs before any dynamic edge is considered. So an optional
trailing separator (`(?:/)?`) or a splat that would match `""` can't complete a pattern when the path ends exactly
where that edge starts. That causes rows 4, 5 and 7.

**3. Not yet diagnosed:** rows 6, 8 and 9 (an optional separator before a trailing splat, and optional captures,
including `nil` captures missing from the params).

## Environment

mustermann 4.0.1, Ruby 4.0.9 (arm64-darwin). Reproduced in a clean `bundler/inline` environment.
