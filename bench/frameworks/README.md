# Reprise vs Sinatra, Roda, and Hanami

`bench.rb` runs the same workloads on each framework, each written the way that framework is meant to be used, and
checks every app gives the expected response before measuring it.

```sh
cd bench/frameworks
bundle install
bundle exec ruby --yjit bench.rb
```

Each framework and workload runs in a process of its own, with a compacted heap. Time is the median of ten rounds after
a warm-up, through a full Rack call (the harness copies each request's env, as a server builds one). Allocations are per
request.

| workload | what it does |
|---|---|
| hello | `GET /` returns "Hello World" |
| params | `GET /users/42?fields=name,email` returns JSON of the route param and a query param |
| filters | a before filter sets the user, an after filter adds a header, the route uses both |
| large table | 500 resources, each with an index and a `/:id` route (1,000 routes), requested across the table |
| 404 | requests for paths none of the large table's routes match |
| erb | a layout, a template, and a partial over 20 items |

How each framework is set up:

- **Sinatra:** set up as tmdb-web runs it, with protection, logging, and static files off.
- **Roda:** uses `hash_branches` for the large table, its way to dispatch many routes, and `hooks` for filters. Its ERB
  app gets a one-line `erb` helper, because the shared templates call Sinatra's.
- **Hanami:** `hanami-router` with `Hanami::Action` classes whose formats are configured. Unconfigured, an action
  negotiates `Accept` against every MIME type Rack knows, about 700 allocations a request. The filters action passes
  the user on as an exposure, since actions are frozen and shared. There's no Hanami ERB result, because hanami-view
  isn't part of this bundle.

## Results (2026-11-14)

Ruby 4.0.9 with YJIT, Apple Silicon. Reprise 0.1.0, Sinatra 4.2.1, Roda 3.110.0, hanami-router 3.0.0 with
hanami-controller 2.3.2, all on Mustermann 3.1.1. Times under 3 µs vary by about ±10% between runs.

| workload | Reprise | Sinatra | Roda | Hanami |
|---|---|---|---|---|
| hello | 1.63 µs (13) | 4.94 (56) | **0.72** (11) | 14.65 (227) |
| params | 3.54 (24) | 7.60 (84) | **2.73** (36) | 13.18 (174) |
| filters | 3.38 (23) | 8.75 (101) | **1.29** (18) | 16.70 (247) |
| large table | 2.51 (15.5) | 162.29 (1,964) | **1.15** (15.5) | 15.48 (231) |
| 404 | 2.31 (13.3) | 350.71 (4,080) | 0.93 (12) | **0.96** (7.3) |
| erb | **6.04** (39) | 13.80 (122) | 8.00 (48) | n/a |

µs per request (allocations per request). Fastest in bold.

Reading it:

- **Reprise vs Sinatra:** 2–3× faster on small apps, and 65× (large table) and 150× (404s) on many routes. Sinatra
  tries routes one by one, and a 404 tries them all.
- **Reprise vs Roda:** Roda is 1.3–2.6× faster outside templates, and Reprise renders ERB about 25% faster. Roda's
  routing tree runs as part of the route block, with one object per request, plain-Hash headers, and nothing to skip.
  Reprise keeps Sinatra's model (filters, conditions, error handlers, `pass`, controller scopes, Rack::Headers'
  case-insensitive headers, and `Reprise.current`), and its remaining cost is spread across those. Closing it further
  would mean dropping one of them.
- **Hanami:** `Hanami::Action` dominates its cost (configuration read through `method_missing`, `Accept`
  negotiation). Its router alone is fast, as the 404s show.

Earlier on 2026-11-14, before the gap-closing pass, Reprise measured hello 2.26, params 4.11, filters 4.14, large table
2.82, 404 2.68, and erb 6.85.
