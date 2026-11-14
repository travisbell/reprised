# Reprise Router: Plan

A Rack 3 router with Sinatra's controller DSL, built for Ruby 4.0, Mustermann 4, and Falcon/Async. It keeps the parts of
Sinatra that controllers actually use, drops the rest, and is validated against TMDB's production Sinatra apps, so
those apps can move over with mostly mechanical changes.

**Status:** phases 0–4 are done: routing parity, the core app, controllers, rendering, and Async. Phase 5 (tooling) is
next.

### Decisions (2026-11-14)

| # | Decision |
|---|---|
| 1 | Class-based controllers: `class X < Reprise::Controller` |
| 2 | Route first, then filters scoped to their owner. Controller filters don't run when no route matches |
| 3 | Gem `reprise-router`, code under `lib/reprise/`, top-level module `Reprise`, `require "reprise"` |
| 4 | Apps that define everything on one reopened app class (`class API < Sinatra::Base` in many files) are first-class. Multi-verb `route`, `json`, `mime_type`, and `configure :env` are core |
| 5 | Tests use RSpec |
| 6 | Routing uses a literal-segment index over Mustermann patterns, not `Mustermann::Set`'s trie (phase 0, §3) |

---

## 1. Why

Sinatra's design was settled long before Rack 3, Falcon, fibers, or Ruby 4. Large modular Sinatra apps run into the
same problems:

- **Routing is a linear scan.** Every request tries routes in definition order until one matches. With about 1,100
  routes, a request for a route defined late tries hundreds of patterns, and every 404 tries all of them. Phase 0
  measured roughly 130–200 µs of routing per request on a production-sized table (§7).
- **Extensions flatten into one namespace.** `Sinatra::Extension` helpers from every module are mixed into the app,
  so every controller sees every other controller's helpers, and name collisions go unnoticed.
- **Rendering integrations are patched in.** Making ActionView helpers and Phlex work in Sinatra takes a custom output
  buffer, request monkey-patches, and stand-ins for Rails pieces such as `flash`.
- **Unused machinery is still paid for:** the `settings` proc chain, an app `dup` per request, Tilt, classic mode,
  built-in servers, `lock`/`threaded`, and template engines nobody uses.

In TMDB's two apps, almost all controller code uses a small surface: verb routes (many ending in `/?`), `provides:`,
a couple of custom conditions, pattern filters, error handlers by class and status, `halt`/`redirect`/`pass`, `erb` with
explicit layouts and locals, Phlex components, `content_type`/`cache_control`/`expires`, `send_file`, `session`, and
`cookies`. Streaming, `forward`, `etag`/`last_modified` helpers, `url()`, the `user_agent`/`host_name` conditions, and
non-ERB engines go unused. That decides what Reprise keeps (§3).

---

## 2. Design principles

1. **The controller DSL stays Sinatra-shaped.** Route bodies, `halt`, `redirect`, `params`, `erb :x, layout:, locals:`,
   `before`, `error`, and `provides:` all keep working unchanged. The diff happens at the edges: controller
   declaration, mounting, and conditions.
2. **Rack 3 is the interface, and Falcon is where it runs.** Real apps depend on a stack of Rack middleware (sessions,
   telemetry, feature flags, locale, ...), so a Protocol::HTTP-native core would give up that ecosystem. Instead, the
   router is written to behave well on Falcon: it is fiber-safe, frozen after boot, streams by default, and takes no
   locks.
3. **Everything is frozen after boot.** The route table, filters, handlers, and compiled templates freeze on
   `App.finalize!`. Each request allocates one scope object. There is no `settings` proc chain and no app `dup` per
   request.
4. **Optional parts are plugins.** ActionView, Phlex, OpenTelemetry, WebSocket, and SSE load only when you enable them.
   The core depends only on `rack` and `mustermann`.
5. **We use Ruby 4.0 features without making a show of it:** `Data.define` for value objects, pattern matching on
   matches, endless methods, `it`, and `Fiber[]` storage for request context. Route bodies compile to real methods
   (not `instance_exec`), so they run as methods of the request scope that YJIT/ZJIT can optimize.

---

## 3. Public API sketch

```ruby
# app.rb
class App < Reprise::App
  plugin Reprise::Plugins::ActionView, helpers: [
    ActionView::Helpers::TagHelper, ActionView::Helpers::FormHelper # ...
  ]
  plugin Reprise::Plugins::Phlex, view_paths: %w[app/components app/views]
  plugin Reprise::Plugins::OpenTelemetry, skip_errors: [MyApp::NotFound]

  set :views, File.join(__dir__, "views")   # settings survive as a plain frozen key/value store

  helpers MyApp::Helpers::Session, MyApp::Helpers::Site   # global helpers: every controller sees these

  before { load_current_user }              # global filter: runs for every request
  error(MyApp::Maintenance) { erb :"errors/maintenance", layout: :"layouts/error" }
  error(404) { erb :"errors/404", layout: :"layouts/main" }

  condition(:takes_bson_id) { |*keys| keys.all? { BSON::ObjectId.legal?(params[it]) } }

  mount MovieController                     # `register` stays as an alias during migration
end

# controllers/movie_controller.rb
class MovieController < Reprise::Controller
  # Private to this controller: these are plain instance methods. `helpers do ... end` also works and means the same.
  private def load_movie = (@movie = Movie.find(params[:id]) or halt 404)

  before("/movie/:id/edit") { load_movie }  # runs only when the matched route belongs to this controller

  get "/movie/:id/?", provides: :html do
    load_movie
    erb :"movie/show", layout: :"layouts/main", locals: { movie: @movie }
  end

  get "/movie/:id/cast", provides: :html do
    phlex Pages::Movie::Cast.new(@movie), layout: :"layouts/main"
  end
end
```

### Controllers and private helpers

- `Reprise::App < Reprise::Controller`. The App is itself a controller that owns its own routes, filters, and methods.
  So an app that reopens one class across many files keeps that shape (`class API < Reprise::App`), and its class-body
  `def`s work in its own routes.
- `Reprise::Controller` is the per-request scope class. A request's scope is an instance of the matched route's
  controller (`Reprise::Dispatch` runs the request). Helpers are ordinary methods, so `private`, `super`, and
  `Module#prepend` all work as they normally do.
- **Global helpers live in the app's helpers module** (`App.helpers_module`). `helpers do ... end` and
  `helpers SomeModule` on the app add to it, and `mount` includes it in the controller. Controller methods sit above
  it in the ancestor chain, so a controller can override a global helper.
- The app also compiles its own routes, filters, error handlers, and conditions into that module. That's what lets
  them run in a controller's scope: Ruby only binds a method to instances of the class or module that defines it.
  Methods `def`ined in the app's class body aren't in the module, so they're visible to the app's own routes only.
- Templates render inside the scope instance. A view rendered by `MovieController` sees movie helpers plus the global
  ones, and no other controller's helpers. A shared layout that calls one controller's helper fails loudly
  (`NoMethodError`), which is the point.
- Requests that match no route get an app scope, with the global helpers only.
- When a candidate route belongs to another controller (after a failed condition, or a `pass`), the scope becomes an
  instance of that controller and takes over the previous scope's instance variables.
- A migration switch, `set :helper_isolation, false`, makes every controller's `helpers` blocks global (Sinatra's
  behavior), so an app can migrate first and fix cross-controller helper use afterwards. A controller's plain `def`s
  stay private either way.
- Controllers read the app's settings (`settings`). They can't `set` settings or `use` middleware, and a controller
  mounts in one app only.
- A controller's route options compile into conditions when the app is finalized, in the app's context. So its routes
  can use the app's named and Sinatra-style conditions, and an unknown option raises at `finalize!`.

### Filters

- There is one filter list, kept in definition order, as in Sinatra. Each filter records its owner (App or a
  controller).
- **Routing happens first, then filters.** A filter runs if its owner is the App or the matched route's controller,
  and its pattern matches. Definition order across App and controller filters is preserved exactly. `route` (the
  matched `Reprise::Route`) is available inside `before` filters.
- When no route matches, only App filters run. A controller filter no longer runs on a 404 path that happens to match
  its pattern (`before "/teams/*"` on `/teams/nope`). Global filters still run, so error pages get whatever the app's
  filters set up.
- **Scoping can silently drop a filter from a route**, when a controller filter's pattern also matches a route that
  belongs to another controller. `finalize!` reports every such overlap, by matching each route's pattern (expanded
  with sample values) against the other controllers' filters. `set :filter_overlap` picks what happens: `:warn` (the
  default), `:raise`, or `:ignore`. Moving to scoped filters therefore never silently removes one from a route.
- Error handlers: the matched controller's first, then the app's, for each key (an exception class, then its
  superclasses, then the status). They run in the request's scope, so they see the route's instance variables and
  helpers.
- `after` filters always run, including after `halt`, as in Sinatra.
- A filter's params, including a regexp filter's `params["captures"]`, are scoped to that filter. Sinatra leaks
  captures into the route that runs after it.

### Routing

- **Matcher: a literal-segment index over Mustermann 4 patterns** (`Reprise::Router`, `matcher: :index`). Each pattern
  is indexed by its leading literal segments (`/movie/:id` sits under `movie`). For a given path, the router tries only
  the patterns under the segments the path starts with, plus those with no literal prefix, in definition order. Each
  candidate is matched by its own Mustermann pattern, so matching is the same as Sinatra's and only the candidate
  list is shorter. Routes and filters both use it.
- **Not `Mustermann::Set`, for now.** Its trie in 4.0.1 mis-matches common Sinatra forms (`/a/?`, `/a/*` on `/a/`,
  `/:id.json`, `/tv/:id/edit/?*`). It sent 1,460 of 132,570 test requests to a different route. Its `strict_order`
  mode also computes every match before sorting, so it has no "first match" fast path. It stays available as
  `matcher: :trie` (experimental, partly patched in `Reprise::MustermannFixes`) for re-checking once upstream fixes it.
  The trie was only about 25% faster than the index. Draft issue: [docs/upstream/mustermann-trie.md](docs/upstream/mustermann-trie.md).
- Regexp routes and filters sit at the index root (no literal prefix), so they're tried for every path, in definition
  order.
- A path containing `%` tries every pattern, because Mustermann matches literals against their encoded forms
  (`/m%6Fvie`). That matches Sinatra exactly, at Sinatra's cost, for that rare path.
- `route :get, :post, "/path" do ... end` registers one body under several verbs. It replaces sinatra-contrib
  MultiRoute.
- HEAD falls back to GET. An optional `trailing_slash: :optional` app setting will make the `/?` suffix unnecessary.
  It's off by default for compatibility.
- `Route = Data.define(:verb, :pattern, :controller, :method_name, :conditions, :source_location)`. `App.routes`
  exposes the table. It backs `reprise routes` and can feed Falcon's `warmup`.
- Named routes and `path_for(:movie, id:)` via `Mustermann::Pattern#expand`. This is a later phase and optional.

### Conditions

- `provides:` is built in. It does content negotiation on `Accept` with Sinatra's exact semantics, and sets
  `content-type` on match. The one difference is that `Accept` entries of equal priority keep their header order.
- Custom conditions use `condition(:name) { |*args| ... }`. The block runs in the candidate's scope and fails the
  route only by returning `false`. Sinatra-style condition methods (a class method calling `condition { ... }`) and
  the anonymous `condition { }` before a route both still work.
- **Conditions are part of matching, so they run before filters.** They see the request, but not what filters set.
  A content type set by a before filter doesn't affect which route is chosen first, but it's kept across `pass`, and
  later `provides:` routes must agree with it (Sinatra's pinning).
- Dropped: `host_name:`, `user_agent:`/`agent:`.

### Scope API

| Kept | Dropped |
|---|---|
| `params` (indifferent, as `Reprise::Params`), block args from captures, `:splat`, `:captures` | `settings` as a proc-backed object (now a frozen hash, `settings[:key]` / `settings.key`) |
| `request`, `response`, `env`, `session`, `cookies` (built in, replacing sinatra-contrib) | `forward`, `stream` (replaced, §4), `last_modified`, `etag` (use `Rack::ConditionalGet`) |
| `halt`, `pass`, `redirect`, `status`, `headers`, `body`, `content_type`, `mime_type` | `back`, `uri`/`url`/`to` (only `path_for` if wanted) |
| `cache_control`, `expires`, `send_file`, `attachment`, `json` | `enable :sessions`, `:static`, `:protection`, `:logging`, `:show_exceptions`, `:lock`, `:threaded`, `run!`, classic mode / `Sinatra::Delegator`, inline templates |
| `error` (the current exception; replaces `env["sinatra.error"]`), `route` | Tilt and all non-ERB engines |
| `configure(*envs) { }`: runs the block when `RACK_ENV` matches, at class-definition time | `set :public_folder`/`:static` (use `Rack::Static` in `config.ru`) |
| `raise_errors` setting (re-raise in test instead of handling), `Reprise::NotFound` (replaces `Sinatra::NotFound`) | |

Static files, protection, sessions, and the dev error page belong in `config.ru` middleware.

`halt` and `pass` stay `throw`/`catch` based. It's fast, and it's what route bodies already expect.

---

## 4. Falcon + Async at the ground level

- **`Reprise.current` is the request scope, kept in fiber storage** (`Fiber[]`). Dispatch sets it, follows the scope
  into the matched controller, and restores the previous value afterwards. Async tasks inherit fiber storage, so
  services, Phlex components, and the tasks of an `Async::Barrier` a route starts can all reach the request without
  passing it along. Nothing uses `Thread.current`.
- **Concurrency is async's own `Barrier`** (`Barrier do |barrier| ... end`, from the async gem). It's already
  structured: children are waited for, and stopped on exit or on an exception. A Reprise `concurrently` would only
  duplicate it, so there isn't one. What Reprise guarantees is that `Reprise.current` works inside it.
- **Timeouts per route:** `get "/x", timeout: 5` runs the route body under the request's Async task's
  `with_timeout`. Overrunning raises `Reprise::Timeout` (503), which error handlers can catch. Without an Async server
  the route runs untimed, with a warning once. Async is only loaded when a route has a timeout.
- **Streaming uses Rack 3 streaming bodies** (`body.call(stream)`), which Falcon sends as they're written:
  - `stream { |out| out << chunk }` runs once the server sends the body, with the request's params and
    `Reprise.current`. A disconnected client ends the block. Sinatra's `keep_open` has no Rack 3 equivalent: to keep
    a stream open, keep the block running.
  - `event_stream { |sse| sse.event(:update, data, id:) }` provides Server-Sent Events: `data`, `comment`, and
    `retry` too, with `text/event-stream`, `no-cache`, and `x-accel-buffering: no`.
- **WebSockets as routes:** `websocket "/ws/:channel", **adapter_options do |connection| ... end` defines a GET route
  that matches only upgrade requests. Others fall through to the next route. The block runs in the request's scope,
  with the route's params, once the connection is upgraded. Options (`handler:`, `extensions:`, `protocols:`) go to
  async-websocket's Rack adapter.
- **Fiber safety:** routers and templates are frozen or replaced atomically. `Reprise::Dispatch` is marked
  single-owner for Async::Safe. CI runs the Falcon integration specs with Async::Safe enabled.
- **Later:** early flush for ERB/Phlex layouts (send `<head>` before the route's queries finish), and the native
  Protocol::HTTP adapter (phase 8).

## 5. Rendering

### ERB (core)

- `Reprise::Template` compiles a template with Erubi once, and each set of local names compiles that into a method.
  Rendering calls the method on the request scope, so templates see its helpers and instance variables. There's no
  Tilt.
- The default engine is `Erubi::CaptureBlockEngine`, so a helper that takes a block of template (`<%= box do %>...
  <% end %>`) can `capture` it.
- Sinatra's semantics are kept:
  - `<%= %>` doesn't escape and `<%== %>` does, unless `escape: true` (per call, or in `set :erb`).
  - The buffer is `@_out_buf`, saved and restored around nested renders.
  - `erb :name, layout:, locals:` takes `layout: false`.
  - A route's template gets `views/layout.erb` if that file exists, and goes without if it doesn't.
  - Templates rendered inside templates get no layout.
  - The layout gets the template's locals.
  - A String is inline template source.
  - `content_type:` marks the output.
  - `set :erb, ...` options merge into every call.
- `partial :name, **locals, &block` is built in: a template with no layout, whose locals are passed as keywords.
- Templates are cached per app. With `reload_templates` (the default in development), a changed file is recompiled.
  With `precompile_templates` (the default outside development and test), `finalize!` compiles every `.erb` in the
  views directory up front.
- Template line numbers are kept in backtraces.
- `set` refuses a name that's already one of the app's methods, so a setting can't silently replace part of the app.

### ActionView plugin

- `plugin Reprise::Plugins::ActionView, helpers: [...]` makes ERB write to an ActionView-compatible output buffer in
  `@output_buffer`, so block helpers (`form_tag do`, `tag.div do`) capture their blocks and helper output isn't
  escaped twice.
- It adds the given ActionView helper modules to the global helpers.
- ActionView's own defaults apply: standalone ActionView emits the `utf8` enforcer input that Rails apps turn off.

### Phlex plugin

- `plugin Reprise::Plugins::Phlex` adds `phlex(component, layout:, locals:)`, and makes `render` take a component, in
  routes and in ERB (`<%= render Card.new(movie) %>`). With a layout, the ERB layout `yield`s the component's output
  and gets the locals.
- Components get the request scope as `context[:reprise]`.
- With `rails: true` (phlex-rails and the ActionView plugin), components render through a memoized ActionView view
  context class and a per-request lookup context, so phlex-rails' helper adapters work. That also gives the request
  ActionDispatch-style `headers`.
- After phase 4, components will reach the request through `Reprise.current` too.

## 6. Gem layout

```
reprise-router/
  reprise-router.gemspec        # name "reprise-router"; required_ruby_version ">= 4.0"; deps: rack ~> 3.2, mustermann ~> 4.0
  lib/reprise.rb                # require "reprise"; module Reprise
  lib/reprise/
    app.rb                      # Rack entry (#call), mount, plugin, finalize!/freeze
    controller.rb               # controllers and the per-request scope
    dispatch.rb                 # the request flow: routing, filters, errors, scope hand-off
    dsl.rb                      # get/post/.../before/after/error/condition/helpers/set
    router.rb                   # lanes (verbs, filters) + literal-segment index over Mustermann patterns
    negotiation.rb              # Accept parsing, preferred_type, mime_types (Sinatra semantics, stable sort)
    mustermann_fixes.rb         # self-testing patches for Mustermann bugs
    route.rb  filter.rb         # Data.define value objects
    conditions.rb               # provides + custom registry
    params.rb                   # indifferent params
    request.rb  response.rb     # thin Rack::Request / Rack::Response subclasses
    templates.rb                # Template (Erubi compiler), erb/partial/render/capture, lookup + cache
    async.rb                    # Reprise.current (Fiber[]), route timeouts, Reprise::Timeout
    streaming.rb                # Stream (Rack 3 streaming body), EventStream, stream/event_stream helpers
    plugins/{action_view,phlex}.rb   # (opentelemetry: phase 5)
    test.rb                     # Rack::Test helpers, route assertions
  spec/                         # RSpec + Rack::Test; Falcon integration specs under spec/falcon
  .github/workflows/ci.yml      # lint, specs, Falcon specs under Async::Safe
  spike/                        # routing parity harness against real Sinatra apps
  bench/                        # routing benchmarks
```

The target is a core under about 2,500 lines. Sinatra's `base.rb` alone is about 2,100.

---

## 7. Phases

**0. Spike. Done 2026-11-14.** See [spike/README.md](spike/README.md) and run it with `bundle exec rake spike`.
- Extracted the route tables of two production Sinatra apps: about 1,150 routes and 24 filters, and about 240 routes
  and 7 filters.
- **Differential test:** 190,845 generated requests through Sinatra 4.2.1 and Reprise. With the index matcher there
  are **no unexplained differences** in route, params, content type, or filters run. The one intended difference is
  that a regexp filter's `params["captures"]` no longer leaks into the route after it.
- **Routing cost with empty bodies:** ~201 µs → 16.7 µs per routed request and ~132 µs → 6.5 µs per 404 on the larger
  app, ~69 µs → 8.9 µs on the smaller.
- Found nine cases where Mustermann 4.0.1's trie mis-matches, from at least three causes (two diagnosed). That decided
  the index matcher.
- Carried into phase 1: the differential harness stays as the regression suite for every routing change.

**1. Core. Done 2026-11-14.** `Reprise::App` and its request scope (`Reprise::Controller`):
- routes, filters, error handlers, `provides:`, and custom conditions
- params (`Reprise::Params`), Request, and Response
- the scope helpers (`halt`, `pass`, `redirect`, `content_type`, `cache_control`, `expires`, `send_file`,
  `attachment`, `json`, `cookies`, `session`, ...)
- Sinatra-style `set`, `configure`, `helpers`, `register`, and `use`
- `finalize!`, which compiles everything into frozen routers

There are 102 specs, ported from the Sinatra behaviors kept. The differential test now also runs at the app level:
each table is replayed into a `Reprise::App`, and all 190,845 requests go through Rack. Status, route, params,
content type, and filters all match Sinatra, with no unexplained differences.

A full Rack call with empty bodies costs 220 µs → 40 µs per routed request and 147 µs → 21 µs per 404 on the larger
app, and 81 µs → 23 µs on the smaller one.

Deferred: `trailing_slash: :optional`, and `stream` (phase 4).

**2. Controllers. Done 2026-11-14.**
- `Reprise::Controller`, `mount` (and `register` for controller classes), and global and private helpers.
- `helper_isolation`, filters scoped to their controller, the `filter_overlap` check, and controller-first error
  handlers.
- Conditions compiled in the app's context, and scope hand-off across controllers. The request flow moved into
  `Reprise::Dispatch`.
- 122 specs.
- **Real-structure check:** a third differential level rebuilds the larger app the way it's actually organized, with
  56 mounted controllers. On all 132,570 requests, every filter difference from Sinatra is one scoping predicts: 19,470
  404s where controller filters no longer run, and 20 requests on one route where another controller's filter matched.
  That one is the same overlap the earlier manual audit found, and the boot-time check reports it.
- Mounting controllers costs about 2 µs per request.

**3. Rendering. Done 2026-11-14.**
- ERB templates, `partial`, `render`, and `capture`, plus the ActionView and Phlex (plain and `rails: true`) plugins.
- 147 specs.
- **All 699 of the larger app's templates compile** under Reprise with the ActionView plugin's options, in 0.22 s
  (`spike/compile_views.rb`).
- A layout + template + 20-item partial through a full Rack call costs **22.7 µs, against 81.6 µs** for Sinatra 4.2
  with Tilt.
- Erubi became a runtime dependency. ActionView, Phlex, and phlex-rails are optional.

**4. Async. Done 2026-11-14.**
- `Reprise.current`, route timeouts, `stream`, `event_stream`, and `websocket` routes. `concurrently` was dropped in
  favor of async's own `Barrier`.
- 159 specs, including Falcon integration specs. Those run against a real server: concurrent requests, Barrier tasks
  seeing `Reprise.current`, progressive streaming, SSE, timeouts as 503 through error handlers, and WebSocket upgrade,
  echo, and adapter options.
- The whole suite passes with Async::Safe enabled, and a deliberate concurrent use of a `Dispatch` is caught.
- CI workflow added.

**5. Tooling.** `App.routes` and `reprise routes`, the OpenTelemetry plugin (span name, `http.route`, error skip
  list), and optional `env` compatibility keys (`sinatra.route`/`sinatra.error`) for middleware that reads them.

**6–7. Migrating TMDB's apps.** The smaller app goes first as the dry run. Both migrations use a codemod for
  controller declarations and mounting, the phase 0 differential test, each app's spec suite, and a shadow mode:
  Sinatra serves the request, Reprise computes its match, and we log any disagreement before cutting over. The
  app-specific notes are kept out of this repo.

**8. Post-v1 (committed, not optional):** a native `Protocol::HTTP` adapter for Falcon-only apps that skips the Rack
  env translation. Before starting it, benchmark how much of per-request time the Rack translation actually costs.

---

## 8. Open questions

1. **The `Reprise` constant:** the unrelated `reprise` gem on RubyGems probably uses the same top-level module. It's
   harmless unless both are loaded in one process, which is unlikely, but worth knowing before a public release.
