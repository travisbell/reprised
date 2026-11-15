# Phase 0 spike: Reprised routing vs Sinatra on TMDB's route tables

This checks that Reprised picks the same route as Sinatra 4.2, with the same params and content type and the same
filters, for every route tmdb-web and tmdb-api define. It also measures what that routing costs.

```sh
bundle exec rake spike          # extract → oracle → diff (needs ~/workspace/tmdb-web and ~/workspace/tmdb-api)
TMDB_API_DIR=../api-sinatra bundle exec rake spike   # extract from a checkout still on Sinatra, once the app has moved
bundle exec rake spike:diff     # re-compare only, after changing lib/reprised (MATCHER=trie to try the trie)
bundle exec rake spike:bench    # Sinatra vs Reprised routing cost
```

| Step | File | Bundle | Output |
|---|---|---|---|
| Extract | `extract_routes.rb` | the app's own (it boots the app) | `fixtures/<app>.routes.json`: every route and filter, in Sinatra's order, with options and source |
| Oracle | `oracle/sinatra_oracle.rb` | `oracle/Gemfile` (Sinatra 4.2.1, Mustermann 3.1.1) | `results/<app>.oracle.jsonl`: Sinatra's decision for each generated request |
| Diff | `differential.rb` (with `table.rb`, `app_table.rb`) | this gem's (Mustermann 4) | differences, grouped; exits 1 if any. Runs at three levels: `router` (the router directly), `app` (a `Reprised::App` built from the table, called through Rack), and `controllers` (the same, with each controller file's definitions in its own mounted `Reprised::Controller`) |
| Bench | `oracle/bench_sinatra.rb`, `../bench/routing.rb`; `oracle/bench_templates.rb`, `../bench/templates.rb` | both | µs per request |
| Compile views | `compile_views.rb VIEWS_DIR` | this gem's | compiles every `.erb` with the ActionView plugin's options; reports failures |

The oracle runs in its own bundle because Sinatra 4.2 requires Mustermann ~> 3.0.

**`fixtures/` and `results/` hold TMDB's private route tables and are gitignored.** Don't commit them, and don't
quote routes from them in committed files.

## The corpus

For every pattern, the corpus expands it with values chosen to collide: `550`, `550-fight-club`, a BSON id, `new` (a
static sibling), `café`, and `a/b` for splats. It adds a trailing-slash variant of each path, plus hand-picked paths
for the regexp routes (kept privately in `fixtures/<app>.extra_paths.json`) and some 404s (`""`, `//`, `/m%6Fvie/550`). Every path is sent with every verb (plus HEAD) and
five Accept headers (browser, jQuery JSON, JSON, `*/*`, none). That's 58,275 requests for tmdb-api and 132,570 for
tmdb-web. The corpus reaches every tmdb-api route and 1,145 of tmdb-web's 1,146.

## Results (2026-11-14)

With the index matcher, there are **no unexplained differences** in either app, at either level. At the app level,
status, route, params, content type, and the filters run all match. The one known difference is intended:

- **Filter captures don't leak.** Sinatra's `process_route` restores the params a filter's pattern added, but not
  `params["captures"]`, so a regexp filter's captures leak into the route after it (2,460 tmdb-web requests, from one
  regexp filter). Reprised scopes them to the filter. Neither app reads captures outside the filter or route that set
  them.

At the controllers level (tmdb-web only, since tmdb-api defines everything on one app class), filters are scoped to
their controller. The report classifies each filter difference that scoping explains. There are two kinds: 19,470
404s where controller filters no longer run, and 20 requests on one route where another controller's filter matched.
The boot-time `filter_overlap` check reports that overlap too. Nothing else differs.

With the trie matcher, 1,460 tmdb-web requests reach a different route. See
[docs/upstream/mustermann-trie.md](../docs/upstream/mustermann-trie.md).

Routing cost per request, with route and filter bodies that do nothing:

| | Sinatra 4.2.1 | Sinatra minus 1-route baseline | Reprised index | Reprised trie |
|---|---|---|---|---|
| tmdb-web, one request per route (1,145) | 212.0 µs | ~201 µs | **16.7 µs** | 12.8 µs |
| tmdb-web, 404s (200) | 142.4 µs | ~132 µs | **6.5 µs** | 5.2 µs |
| tmdb-api, one request per route (243) | 79.1 µs | ~69 µs (RouteIndex: 42.1 total) | **8.9 µs** | 7.3 µs |
| tmdb-api, 404s (200) | 50.3 µs | ~40 µs (RouteIndex: 68.6 total) | **5.3 µs** | 5.6 µs |

A full Rack call through each framework (2026-11-14, after phase 1; see PLAN.md's performance pass for where it is
now: 211.7 → 17.1 µs on tmdb-web routed, 78.1 → 12.3 µs on tmdb-api, same harness):

| | Sinatra 4.2.1 | Reprised::App |
|---|---|---|
| tmdb-web, one request per route | 220.3 µs | **39.9 µs** |
| tmdb-web, 404s | 147.1 µs | **20.8 µs** |
| tmdb-api, one request per route | 80.5 µs | **23.0 µs** |
| tmdb-api, 404s | 53.1 µs | **19.5 µs** |

The router columns in the first table time routing alone: finding the route with its conditions, plus the before and after filters
that apply. The Sinatra columns time a full Rack call, so subtracting the baseline approximates its routing share.
Sampling one request per route weights routes defined late as heavily as routes defined early. That's not the shape
of production traffic, so these figures show relative cost and aren't a forecast of production latency.
