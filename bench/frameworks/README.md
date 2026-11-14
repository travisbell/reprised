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
hanami-controller 2.3.2, all on Mustermann 3.1.1.

| workload | Reprise | Sinatra | Roda | Hanami |
|---|---|---|---|---|
| hello | 2.26 µs (13) | 5.01 (56) | **0.72** (11) | 14.82 (227) |
| params | 4.11 (24) | 7.62 (84) | **2.76** (36) | 13.39 (174) |
| filters | 4.14 (25) | 8.64 (101) | **1.30** (18) | 16.68 (247) |
| large table | 2.82 (15.5) | 161.49 (1,964) | **1.15** (15.5) | 15.53 (231) |
| 404 | 2.68 (14.3) | 349.17 (4,080) | 0.93 (12) | **0.92** (7.3) |
| erb | **6.85** (39) | 13.96 (122) | 7.95 (48) | n/a |

µs per request (allocations per request). Fastest in bold.

Reading it:

- **Reprise vs Sinatra:** about 2× faster on small apps, and 57× (large table) and 130× (404s) on many routes. Sinatra
  tries routes one by one, and a 404 tries them all.
- **Reprise vs Roda:** Roda is 2.5–3.3× faster outside templates. Its routing tree runs as the route block itself, with
  one object per request; Reprise has Sinatra's model to keep. Reprise renders ERB faster.
- **Hanami:** `Hanami::Action` dominates its cost (configuration read through `method_missing`, `Accept`
  negotiation). Its router alone is fast, as the 404s show.
