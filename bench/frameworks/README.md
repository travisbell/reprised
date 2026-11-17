# Reprised vs Sinatra, Roda, and Hanami

`bench.rb` runs the same workloads on each framework, each written the way that framework is meant to be used, and
checks every app gives the expected response before measuring it.

```sh
cd bench/frameworks
bundle install
bundle exec ruby --yjit bench.rb
```

Each framework and workload runs in a process of its own, with a compacted heap, which builds its app. Time is the
median of ten rounds after a warm-up, through a full Rack call (the harness copies each request's env, as a server
builds one). Allocations are per request.

Memory is the Ruby heap, as `ObjectSpace.memsize_of_all` counts it after a full GC:

- **app:** what the heap holds for the app once it's built and has answered each of the workload's requests once,
  ready to serve. It's the app's routes, patterns, compiled blocks, and indexes, not the framework's code.
- **growth:** what the heap holds on to after the timed run, which a cache or a leak would show. Within ±10 KB is noise.
- **library:** what requiring the framework adds to a fresh Ruby that has loaded Bundler and Rack, in the heap and in
  resident memory (RSS). The median of three processes.

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

## Results (2026-11-17)

Ruby 4.0.9 with YJIT, Apple Silicon. Reprised 0.1.0, Sinatra 4.2.1, Roda 3.110.0, hanami-router 3.0.0 with
hanami-controller 2.3.2, all on Mustermann 3.1.1. Times under 3 µs vary by about ±10% between runs.

| workload | Reprised | Sinatra | Roda | Hanami |
|---|---|---|---|---|
| hello | 1.80 µs (13) | 5.06 (56) | **0.76** (11) | 15.09 (227) |
| params | 3.76 (24) | 7.72 (84) | **2.94** (36) | 13.91 (174) |
| filters | 3.58 (23) | 8.96 (101) | **1.32** (18) | 16.82 (247) |
| large table | 2.37 (15.5) | 167.08 (1,964) | **1.16** (15.5) | 16.21 (231) |
| 404 | 2.02 (13.3) | 366.39 (4,081) | 0.90 (12) | **0.87** (7.3) |
| erb | **6.27** (39) | 13.91 (122) | 8.48 (48) | n/a |

µs per request (allocations per request). Fastest in bold.

| memory | Reprised | Sinatra | Roda | Hanami |
|---|---|---|---|---|
| library: heap / RSS | 856 KB / 5.0 MB | 1.2 MB / 12.7 MB | **549 KB / 3.0 MB** | 923 KB / 5.3 MB |
| hello app | 11 KB | 28 KB | **8 KB** | 65 KB |
| erb app | **25 KB** | 40 KB | 51 KB | n/a |
| large table app (1,000 routes) | 1.1 MB | 3.5 MB | **157 KB** | 1.8 MB |
| growth after the timed run | none | none | none | none |

Reprised matches a route made of literal segments and whole-segment params with its own index, without a Mustermann
pattern (about 2.3 KB a route, which Sinatra holds); what a large app keeps, about 1 KB a route, is that index and each
route's compiled block. Roda's `hash_branches` keeps no patterns at all.
