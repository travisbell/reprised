# Reprised

A Sinatra-compatible Rack router for Ruby 4, built on Mustermann and designed for Falcon and Async.

Reprised keeps the parts of Sinatra that apps actually use (routes, filters, conditions, `halt`, `pass`, `erb`, error
handlers) and drops the rest. Routing goes through an index rather than a linear scan, controllers get helpers of
their own, everything is frozen after boot, and the request scope is fiber-safe. Code written for Sinatra mostly runs
unchanged; the differences are at the edges, and are listed in [Coming from Sinatra](#coming-from-sinatra).

```ruby
require "reprised"

class App < Reprised::App
  before { @user = User.from_session(session) }

  get "/movie/:id", provides: :json do |id|
    json(Movie.find(id))
  end

  get "/movie/:id" do
    halt 404 unless (movie = Movie.find(params[:id]))
    "<h1>#{movie.title}</h1>"
  end

  error(Movie::NotFound) { not_found "No such movie" }
end

run App # config.ru
```

**Status:** early (0.1.0). Its routing, dispatch, and rendering are checked against Sinatra 4.2 on two production apps'
route tables (about 190,000 generated requests, with no unexplained differences), and the Async features are tested
under Falcon. See [PLAN.md](PLAN.md) for the design and what's next.

**Demos:** [demos/](demos) is a small app with a page for each feature: routing, streaming, Server-Sent Events,
WebSockets, ActionView forms, and Phlex components. `bundle exec rake demos` runs it under Falcon.

## Contents

- [Installing](#installing)
- [Routes](#routes)
- [Conditions](#conditions)
- [Params](#params)
- [Responses](#responses)
- [Filters](#filters)
- [Errors](#errors)
- [Controllers](#controllers)
- [Settings](#settings)
- [Templates](#templates)
- [Middleware and boot](#middleware-and-boot)
- [Async and Falcon](#async-and-falcon)
- [Plugins](#plugins): ActionView, Phlex, Sprockets, OpenTelemetry
- [Telemetry](#telemetry)
- [Listing routes](#listing-routes)
- [Reloading in development](#reloading-in-development)
- [Ractors](#ractors)
- [Coming from Sinatra](#coming-from-sinatra)
- [Performance](#performance)
- [Development](#development)

## Installing

Reprised needs Ruby 4.0 and Rack 3.2, and works with Mustermann 3.1 or 4.

```ruby
# Gemfile
gem "reprised", github: "travisbell/reprised"
```

```ruby
# config.ru
require "reprised"
require_relative "app"

run App
```

Any Rack 3 server runs it. Route timeouts, streaming as it's written, and WebSocket routes need an Async server such as
[Falcon](https://github.com/socketry/falcon): `bundle exec falcon serve`.

## Routes

A route is a verb, a path pattern, and a block. Routes are tried in the order they're defined, and the first that
matches answers.

```ruby
get "/" do
  "home"
end

post "/movies" do
  Movie.create(params[:title])
  redirect "/movies"
end

put("/movie/:id")    { ... }
patch("/movie/:id")  { ... }
delete("/movie/:id") { ... }
options("/")         { ... }
```

`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `link`, and `unlink` are all there.

**Patterns** are [Mustermann](https://github.com/sinatra/mustermann)'s Sinatra patterns:

| Pattern | Matches | Params |
|---|---|---|
| `/movie/:id` | `/movie/550` | `id: "550"` |
| `/movie/:id/?` | `/movie/550` and `/movie/550/` | `id: "550"` |
| `/movie/:id.json` | `/movie/550.json` | `id: "550"` |
| `/files/*` | `/files/a/b.txt` | `splat: ["a/b.txt"]` |
| `/files/*.*` | `/files/a/b.txt` | `splat: ["a/b", "txt"]` |
| `/search/?:query?` | `/search`, `/search/`, and `/search/fight` | `query: nil` or `"fight"` |
| `%r{/movie/(\d+)}` | `/movie/550` | `captures: ["550"]` |
| `["/movies", "/films"]` | either path | |

A block that takes arguments gets the pattern's params in order, or a regexp's captures:

```ruby
get("/movie/:id/season/:number") { |id, number| ... }
get(%r{/movie/(\d+)}) { |id| ... }
get("/files/*.*") { |path, extension| ... }
```

**HEAD** is answered by `get` routes, in their place among any `head` routes, with the body left off.

**Several verbs at once:** `route :get, :post, "/session" do ... end` defines the same block for each verb (and for
each path, if you pass an Array). As with sinatra-contrib's MultiRoute, its GET route doesn't answer HEAD unless you
list `:head` too.

**Route options** are conditions (below), plus `timeout:` (see [Async and Falcon](#async-and-falcon)):

```ruby
get "/movie/:id", provides: :json, timeout: 5 do ... end
```

**Moving on:** `pass` gives up on the current route and tries the next one that matches. `pass { "fallback" }` answers
with the block if nothing else does.

`route` (in a route, a filter, or a template) is the `Reprised::Route` answering the request, with its `verb`,
`pattern`, `options`, `owner`, and `source_location`. It's nil in a 404.

## Conditions

Options on a route are conditions: the route matches only if each one does. Conditions run while routes are being
matched, before any filter, so they see the request but not what filters set.

**`provides:`** matches when the client's `Accept` header accepts one of the given types, and sets the content type to
the one it prefers:

```ruby
get "/movie/:id", provides: :json do json(movie) end
get "/movie/:id", provides: [:html, :xml] do erb :movie end
```

It follows Sinatra's negotiation exactly, except that `Accept` entries of equal preference keep their order. If a
before filter sets a content type, a `provides:` route must include it.

**Named conditions** take the option's value as arguments, and run in the request's scope. A condition fails only by
returning `false`:

```ruby
condition(:admin) { |level| current_user&.level.to_i >= level }

get "/admin", admin: 2 do ... end
```

Sinatra-style condition methods work too: a class method that calls `condition { ... }`, used as a route option. So
does an anonymous `condition { ... }` just before a route, which applies to that route. An unknown option raises when
the app is finalized.

## Params

`params` holds the query string, the form body (or multipart upload), and the route's pattern params, merged. Its keys
are Strings, and Symbols work too, including in nested Hashes and in Hashes inside Arrays:

```ruby
get "/search" do
  params[:query]               # same as params["query"]
  params[:filters][:year]      # ?filters[year]=1999
  params.fetch(:page, 1)
end
```

A query or body that can't be parsed answers 400 (`Reprised::BadRequest`).

`request` is a `Reprised::Request` (a `Rack::Request`), with `accept`, `preferred_type`, `accept?(type)`, `secure?`,
`forwarded?`, `safe?`, and `idempotent?` added. `env` is the Rack env.

## Responses

**What a route returns** becomes the response, as in Sinatra:

| Returns | Response |
|---|---|
| a String | the body |
| an Integer | the status |
| `[status, body]` | both |
| `[status, headers, body]` | all three |
| anything with `#each` | the body, streamed from `#each` |

**Helpers**, in routes, filters, error handlers, and templates:

| Helper | Does |
|---|---|
| `halt 404`, `halt "body"`, `halt 401, "no"`, `halt 200, { "x-a" => "1" }, "body"` | stops and responds |
| `status 201`, `status` | sets or returns the status |
| `headers "x-a" => "1"`, `headers` | adds headers, or returns them |
| `body "text"`, `body { lazy }` | sets the body (a block is called when it's read) |
| `redirect "/movies"`, `redirect url, 301` | redirects and stops: 303 after a non-GET HTTP/1.1 request, 302 otherwise |
| `content_type :json`, `content_type "text/csv", charset: "utf-8"` | sets the content type, adding the charset to text types |
| `json(object)` | encodes as JSON (the `json_encoder` setting) and sets the content type |
| `cache_control :public, max_age: 60` | sets Cache-Control |
| `expires 300, :public` | sets Expires and Cache-Control's max-age |
| `send_file path, filename:, disposition:, type:, last_modified:, status:` | sends a file (ranges and HEAD included), or 404s |
| `attachment "report.csv"` | sets Content-Disposition, and the content type from the extension |
| `uri("/x")` (`url`, `to`) | an absolute URL, taking proxies into account |
| `mime_type :json` | the media type for an extension |
| `not_found "body"`, `error 403, "body"` | stops with that status |
| `success?`, `redirect?`, `client_error?`, `server_error?`, `not_found?`, ... | checks the status |
| `session` | `env["rack.session"]`; add a session middleware in config.ru |
| `logger` | `env["rack.logger"]` |
| `response` | the `Reprised::Response` (a `Rack::Response`) |

As in Sinatra, `Rack::Utils`' functions (`escape_html`, `escape`, `unescape`, `build_query`, `parse_query`, ...) are
there too, as private methods.

**Cookies:** `cookies` reads the request's cookies and sets new ones, as sinatra-contrib's does:

```ruby
cookies[:theme]                                   # read
cookies[:theme] = "dark"                          # set, with the defaults
cookies.set(:token, value: token, max_age: 3600, same_site: :lax)
cookies.delete(:theme)
```

New cookies are `httponly`, `secure` on HTTPS, for path `/`, and for the request's host (none for localhost). The
`cookie_options` setting adds to those defaults: `set :cookie_options, { same_site: :lax }`.

## Filters

`before` filters run before the matched route's block, and `after` filters after it, including after a `halt`. A
filter with a pattern runs only when the path matches it, and its pattern's params are in `params` while it runs.

```ruby
before { @user = current_user }
before("/admin/*") { halt 401 unless @user&.admin? }
after { headers "x-served-by" => "reprised" }
```

Routing happens first, then filters, in definition order. A before filter can read `route`, and can add params for the
route to use. When no route matches, the app's own filters still run (so error pages get what they set up), and the
request is a 404.

A filter can take conditions too: `before "/movie/:id", provides: :html do ... end`.

## Errors

Error handlers answer for an exception class or a response status, with the block's return value as the body:

```ruby
error(Movie::NotFound) { not_found "No such movie" }
error(404) { erb :"errors/404" }
error(500..599) { "Something went wrong" }
not_found { erb :"errors/404" }                  # error(404)

error do |boom|                                  # any exception
  ErrorReporter.notify(boom)                     # report it, but don't show its message to the client
  "Something went wrong"
end
```

- An exception goes to the handler for its class, then its superclasses, then its status. A response status
  (`halt 404`) goes to that status's handler.
- The matched controller's handlers come first, then the app's. Handlers for the same key run newest first, and an
  older one runs only if every newer one returns nil.
- Handlers run in the request's scope, with its helpers and instance variables. `error` (with no arguments) is the
  exception being handled, also in `env["reprised.error"]`.

**Statuses:** an exception answers 500, unless it's a `Reprised::Error` with an `http_status`:

```ruby
class Forbidden < Reprised::Error
  def http_status = 403
end
```

Reprised raises `Reprised::NotFound` (404), `Reprised::BadRequest` (400), and `Reprised::Timeout` (503). With the
`use_code` setting, a `Reprised::Error`'s `code` gives the status too.

**Settings** for errors:

- `raise_errors` (on in the test environment): an exception no handler answers is raised rather than answered with a
  500, so tests see it.
- `dump_errors` (on outside the test environment): a 5xx's exception is logged to `env["rack.errors"]`. Override
  `self.dump_errors!(exception, env)` on the app to log elsewhere, or to skip expected ones.
- `x_cascade` (on): a 404 has `x-cascade: pass`, so `Rack::Cascade` can try another app.

## Controllers

A controller is a group of routes with its own filters, error handlers, and helpers, mounted into an app:

```ruby
class MovieController < Reprised::Controller
  before("/movie/:id/edit") { require_editor }

  get "/movie/:id" do
    load_movie
    erb :"movie/show"
  end

  error(Movie::NotFound) { not_found "No such movie" }

  private def load_movie = (@movie = Movie.find(params[:id]) or halt 404)
end

class App < Reprised::App
  helpers SessionHelpers     # global: every controller has these
  mount MovieController      # its routes take this place in the app's order
  mount PersonController
end
```

- **Helpers are methods.** A request's scope is an instance of the matched route's controller, so a controller's
  methods (and its `helpers`) are visible to its own routes and templates only, alongside the app's helpers. `private`,
  `super`, and `prepend` work as they normally do, and a controller can override a global helper.
- **The app's helpers are global:** `helpers do ... end` and `helpers SomeModule` on the app reach every controller.
  `set :helper_isolation, false` makes controllers' `helpers` global too, as Sinatra extensions' are, which is useful
  while migrating. A controller's plain `def`s stay its own either way.
- **Filters are scoped:** a controller's filters run only for its own routes. The app's run for every request. A route
  reached by `pass` from another controller's route runs its own controller's before filters first, so a `pass` can't
  skip them.
- **Overlap check:** at boot, Reprised reports any controller filter whose pattern also matches another controller's
  route, since it won't run for that route as it would in Sinatra. Each pattern of an Array route is checked; a regexp
  route can't be, so it's listed as unchecked. `set :filter_overlap` to `:warn` (the default, printed whatever
  `$VERBOSE` is), `:raise`, or `:ignore`.
- **Settings are the app's:** controllers read them with `settings`, but can't `set` them or `use` middleware.
  A controller mounts in one app.
- **Conditions:** a controller's route options compile in the app's context, so they can use the app's conditions.

`Reprised::App` is itself a controller: an app's own routes, filters, and methods work the same way. That makes an app
defined across many files, all reopening the same class, a first-class layout:

```ruby
# routes/movies.rb
class API < Reprised::App
  get("/movie/:id") { ... }
end
```

`register` takes a Sinatra-style extension (a module, with an optional `registered(app)` hook), or a controller class,
which it mounts. An extension written with sinatra-contrib's `Sinatra::Extension` (routes, filters, error handlers,
and `configure` in the module's body) works with `extend Reprised::Extension` in its place: the calls are recorded and
replayed on each app that registers it.

```ruby
module ErrorPages
  extend Reprised::Extension

  error(404) { erb :not_found }
  configure(:production) { set :dump_errors, false }
end
```

## Settings

```ruby
class App < Reprised::App
  set :views, File.join(__dir__, "views")
  set :cache_ttl, 300
  set(:started_at) { Time.now }     # a block is called each time the setting is read
  enable :use_code                  # set :use_code, true
  disable :x_cascade

  configure :production, :staging do
    set :dump_errors, false
  end

  get("/ttl") { settings.cache_ttl.to_s }
end
```

`set :name, value` defines `settings.name`, `settings.name?`, and `settings.name=`. Setting a Hash setting again merges
into it. `set` refuses a name that's already one of the app's methods. `configure(*envs)` runs its block when the
environment matches, at definition time, and `development?`, `production?`, and `test?` check it.

| Setting | Default | |
|---|---|---|
| `environment` | `APP_ENV` or `RACK_ENV`, else `:development` | |
| `raise_errors` | in test | raise exceptions no handler answers ([Errors](#errors)) |
| `dump_errors` | outside test | log 5xx exceptions |
| `use_code` | `false` | take a status from a `Reprised::Error`'s `code` |
| `x_cascade` | `true` | `x-cascade: pass` on 404s |
| `default_encoding` | `"utf-8"` | the charset added to text content types |
| `default_content_type` | `"text/html"` | the content type when none is set |
| `add_charset` | text types, JavaScript, XML | content types that get the charset |
| `absolute_redirects` | `true` | redirect to absolute URLs |
| `prefixed_redirects` | `false` | add the script name to redirects |
| `json_encoder` | `JSON` | anything with `generate` or `encode`, or a method name to call |
| `json_content_type` | `:json` | `json`'s content type |
| `helper_isolation` | `true` | keep controllers' `helpers` to themselves |
| `filter_overlap` | `:warn` | what the boot-time filter check does |
| `root` | the working directory | |
| `views` | `root/views` | |
| `public_folder` | `root/public` | files served ahead of the routes |
| `static` | whether `public_folder` exists (at boot) | serve the public folder |
| `static_cache_control` | `false` | Cache-Control for public files: `[:public, { max_age: 3600 }]` |
| `static_headers` | `{}` | more headers for public files |
| `erb` | `{}` | options for every `erb` call |
| `reload_templates` | in development | recompile templates that change |
| `precompile_templates` | outside development and test | compile every template at boot |
| `mustermann_opts` | `{}` | options for every pattern |
| `matcher` | `:index` | `:trie` is an experimental alternative, on Mustermann 4 |
| `sinatra_env` | `false` | also set `env["sinatra.route"]` and `env["sinatra.error"]` |
| `cookie_options` | (none) | defaults for new cookies |

**Public files:** as in Sinatra, a GET or HEAD request for a file in the public folder is answered with the file
(`send_file`, with `static_cache_control` and `static_headers`) before any filter runs, and after filters don't run for
it. Paths are unescaped, and must stay inside the folder. Other requests, and paths with no file, go to the routes.

Sinatra's server, session, protection, and logging settings (`:sessions`, `:protection`, `:logging`, `:port`, `:lock`,
`:threaded`, and the rest) do nothing in Reprised, and warn when set: use Rack middleware in config.ru instead.

## Templates

ERB is built in, compiled with Erubi. A template renders as a method of the request scope, so it sees the route's
helpers and instance variables.

```ruby
get "/movie/:id" do
  @movie = Movie.find(params[:id])
  erb :"movie/show", layout: :"layouts/main", locals: { cast: @movie.cast }
end
```

- `erb :name` renders `views/name.erb`; a String is template source (`erb "<%= 1 + 1 %>"`). As in Sinatra, a name can
  reach outside the views directory (`erb :"../shared/card"`), and a String is code: never take either from a request.
- A route's template gets `views/layout.erb` as its layout, if that file exists. `layout: :name` picks another, and
  `layout: false` uses none. Templates rendered inside templates get no layout, and the layout gets the template's
  locals.
- `<%= %>` doesn't escape and `<%== %>` does, as in Sinatra. For a new app, `set :erb, { escape: true }` is the safer
  default: `<%= %>` escapes, and `<%== %>` writes HTML as it is. With the ActionView plugin, helper output (an
  `html_safe` string) isn't escaped again either way, as in Rails.
- Locals are local variables in the template, and the whole Hash is `locals` (`locals.key?(:title)`), as in Tilt.
  Constants resolve in the app class and its ancestors, its helpers among them, as they do in Sinatra's.
- `partial "movie/_card", movie:` renders without a layout, with locals as keywords. `render :erb, :name, options`
  is Sinatra's form. `capture { ... }` renders a block of template to a String, for helpers that take one.
- Options per call: `layout:`, `locals:`, `views:`, `scope:`, `content_type:`, `layout_options:`, and Erubi's own.
  `set :erb, { ... }` sets defaults for every call.
- Templates are cached per app. `reload_templates` recompiles a file when it changes; `precompile_templates` compiles
  every `.erb` in the views directory at boot.

Tilt and other template engines aren't included. The [ActionView](#actionview) and [Phlex](#phlex) plugins cover
ActionView helpers and components.

## Middleware and boot

`use` wraps the app in Rack middleware, outermost first:

```ruby
class App < Reprised::App
  use Rack::Deflater
end
```

Middleware that belongs to the whole server (sessions, protection, request logging) goes in config.ru:

```ruby
use Rack::Session::Cookie, secret: ENV.fetch("SESSION_SECRET") # the rack-session gem
run App
```

**Finalizing:** the first request finalizes the app: its routes, filters, and handlers compile into frozen routers, the
middleware stack is built, and (with `precompile_templates`) templates compile. After that, nothing more can be
defined. Call `App.finalize!` at boot (before forking workers, or in Falcon's `warmup`) to do it up front.

`App.routes` and `App.filters` are the finalized tables, mounted controllers included. `env["reprised.route"]` is the
matched route, and `env["reprised.error"]` the exception handled, for middleware to read.

## Async and Falcon

**`Reprised.current`** is the request scope handling the current request, from anywhere in it: a service object, a Phlex
component, or a task the route started. It's kept in fiber storage, which Async tasks inherit, so it works across an
`Async::Barrier`:

```ruby
get "/movie/:id" do
  barrier = Async::Barrier.new
  movie = barrier.async { Movie.find(params[:id]) }
  credits = barrier.async { Credits.for(params[:id]) }
  erb :movie, locals: { movie: movie.wait, credits: credits.wait }
ensure
  barrier&.stop
end

class Credits
  # Called from a Barrier task, it still reaches the request.
  def self.for(id) = Credit.where(movie_id: id, language: Reprised.current.params[:language])
end
```

**Timeouts:** `get "/report", timeout: 5` runs the route under the request's Async task with a timeout. Running over
raises `Reprised::Timeout` (503), which error handlers can catch. Without an Async server the route runs untimed, with a
warning once.

**Streaming** uses Rack 3 streaming bodies, which Falcon sends as they're written:

```ruby
get "/export" do
  content_type "text/csv"
  stream do |out|
    Movie.find_each { out << it.to_csv }
  end
end
```

The block runs once the server sends the response, with the request's params and `Reprised.current`. It ends when the
block returns or the client disconnects.

**Server-Sent Events:**

```ruby
get "/updates" do
  event_stream(retry_after: 3000) do |sse|
    updates.each { sse.event(:update, it, id: it[:id]) }   # non-String data is sent as JSON
    sse.comment("still here")
  end
end
```

It sets `text/event-stream`, `cache-control: no-cache`, and `x-accel-buffering: no`.

**WebSockets** are routes, with the [async-websocket](https://github.com/socketry/async-websocket) gem:

```ruby
websocket "/ws/:channel" do |connection|
  while (message = connection.read)
    connection.write(message)
    connection.flush
  end
end
```

The route matches only upgrade requests; others for the path move on to the next route. The block runs in the
request's scope, with the route's params, once the connection is upgraded. Options (`handler:`, `protocols:`,
`extensions:`) go to async-websocket's Rack adapter.

Browsers send cookies with a WebSocket handshake from any site, and neither Reprised nor async-websocket checks its
`Origin`. A socket that relies on the session should check it, in a before filter:

```ruby
helpers do
  def same_origin? = env["HTTP_ORIGIN"].nil? || env["HTTP_ORIGIN"] == "#{request.scheme}://#{request.host_with_port}"
end

before("/ws/*") { halt 403 unless same_origin? }
```

Reprised takes no locks while serving requests: routers and templates are frozen, or replaced atomically. Its Falcon
specs run with [Async::Safe](https://github.com/socketry/async-safe) enabled.

**A faster Rack adapter for Falcon:** `Reprised::Falcon::Adapter` turns Falcon's requests into Rack envs, as Falcon's
default adapter (protocol-rack's) does. The env it builds is the same, key for key, in about 40% of the time and an
eighth of the allocations: a request with 15 headers takes 2.2 µs and 10 allocations, against 5.6 µs and 79. That's
about 4 µs off every request, for any Rack app. To use it, include its environment after Falcon's in `falcon.rb`:

```ruby
require "falcon/environment/rack"
require "reprised/falcon"

service "app.localhost" do
  include Falcon::Environment::Rack
  include Reprised::Falcon::Environment
end
```

A `middleware` block in the service can still wrap it with `super()`. Outside `falcon-host`, use
`Falcon::Server.protocol_middleware(Reprised::Falcon::Adapter.new(app))`. `bench/adapter.rb` measures both adapters.

## Plugins

Plugins are optional, and load only when you use them: `plugin Reprised::Plugins::Name, **options`.

A plugin is any module with `install(app, **options)`, so an app can package its own routes, settings, helpers, and
error handlers the same way:

```ruby
module ErrorPages
  def self.install(app)
    app.error(404) { erb :not_found }
    app.error(500) { erb :oops }
  end
end

plugin ErrorPages
```

### ActionView

ActionView's helpers in ERB templates (`form_tag`, `tag.div`, `number_to_human`, ...), with block helpers capturing
their blocks and nothing escaped twice. Needs the actionview gem.

```ruby
require "reprised/plugins/action_view"

plugin Reprised::Plugins::ActionView, helpers: [
  ActionView::Helpers::TagHelper, ActionView::Helpers::FormTagHelper, ActionView::Helpers::NumberHelper
]
```

The helpers are global. ERB writes to an ActionView-compatible buffer in `@output_buffer`. Templates don't escape
`<%= %>` unless you `set :erb, { escape: true }`; either way, `html_safe` helper output isn't escaped twice.

### Phlex

[Phlex](https://www.phlex.fun) components in routes and in ERB:

```ruby
require "reprised/plugins/phlex"

plugin Reprised::Plugins::Phlex

get "/movie/:id" do
  phlex Pages::Movie.new(movie), layout: :"layouts/main", locals: { title: movie.title }
end
```

`render` takes a component too, in routes and templates (`<%= render Card.new(movie) %>`). With a layout, the ERB
layout `yield`s the component's HTML. Components get the request scope as `context[:reprised]`, and through
`Reprised.current`. Their HTML is `html_safe` when ActiveSupport is loaded (with the ActionView plugin, say), so ERB
doesn't escape it with `escape: true`. With `rails: true` (phlex-rails and the ActionView plugin), components render
through an ActionView view context, so phlex-rails' helper adapters work.

### Sprockets

A [Sprockets](https://github.com/rails/sprockets) asset pipeline: settings, helpers, and serving in development.

```ruby
require "reprised/plugins/sprockets"

assets = Sprockets::Environment.new(root)
assets.append_path("assets/stylesheets")

plugin Reprised::Plugins::Sprockets,
  environment: assets,
  manifest: Sprockets::Manifest.new(assets, "public/assets"),
  digest: production?
```

- It sets `assets`, `assets_prefix`, `assets_manifest`, and `assets_digest`, which its helpers read on each call.
- `asset_path("site.css")` gives the manifest's digest path when digests are on, or else `/assets/site.css`.
  `asset_exists?` checks without compiling the asset.
- Assets get `asset_path` too, and with it Sprockets' `image_path`, `font_path`, and the rest, for an ERB stylesheet's
  `url(<%= asset_path("logo.svg") %>)`. It gives the asset's digest path when digests are on, and links the asset, so
  compiling the manifest writes it too. A path with no asset stays under the root, and a URL as it is. This replaces
  the sprockets-helpers gem.
- With `serve:` (the default unless `digest:`), it defines a `get "/assets/*"` route that compiles assets on demand.
  Routes defined before the plugin under the prefix answer first, and a missing asset gets Sprockets' 404.
  `Reprised::Plugins::Sprockets::Server` is the middleware form, for config.ru, which answers ahead of the app.

### OpenTelemetry

Names the request's span after its route, and records server errors on it, with
opentelemetry-instrumentation-rack's span for the request:

```ruby
require "reprised/plugins/open_telemetry"

plugin Reprised::Plugins::OpenTelemetry, skip_errors: [MyApp::Maintenance]
```

The span gets `http.route` (`/movie/:id`) and the name `GET /movie/:id`, unless `span_name:` (a callable taking the
route) says otherwise. A 5xx's exception is recorded on the span, which is marked as an error, unless the exception is
one of `skip_errors` (or a subclass).

## Telemetry

Opt-in, and not loaded by `require "reprised"`:

- **Request metrics:** `app.requests` and `app.request.duration`.
- **An access log line per request**, labelled by route pattern, at info (warn for a 4xx, and error for a 5xx).
- **A stall detector** that logs when the event loop is blocked, naming the requests in flight.
- **Reactor lag:** how late the event loop resumes (`reactor.lag`).

Metrics go through the OpenTelemetry metrics API, and are no-ops until you configure an SDK meter provider. Logs go
through Console.

```ruby
require "reprised/plugins/telemetry"

class App < Reprised::App
  plugin Reprised::Plugins::Telemetry,
    requests: { labels: ->(env) { { client: env["myapp.client"] } }, skip_paths: ["/healthcheck"] },
    stalls: { threshold: 1.0 },
    reactor_lag: true
end
```

Or put the middleware in config.ru, so it also records what other middleware answers:

```ruby
require "reprised/telemetry"

use Reprised::Telemetry::StallDetector
use OpenTelemetry::Instrumentation::Rack::Middlewares::Stable::TracerMiddleware
use Reprised::Telemetry::Requests # below the tracer: its log line carries the trace id, and is written after the span ends
```

`Reprised::Telemetry::Requests` takes these options:

| Option | |
|---|---|
| `filter:` | which requests to record |
| `labels:` | extra labels for the counter and the log line |
| `fields:` | extra fields for the log line only |
| `skip_paths:` | paths not to record |
| `histogram_labels:` | which labels the duration histogram gets |
| `log:` | `false` for metrics only, or a callable taking `(env, message, fields)` |
| `log_sample:` | the percentage of requests to log; every 5xx is logged |
| `request_id:` | the env key holding the request id |
| `query_filter:` | which query params to filter out of the log line |

`Requests.log_level(status)` gives a custom `log:` callable the same choice of level.

It needs the `opentelemetry-metrics-api` and `console` gems (Falcon brings `console`). Give your meter provider Reprised's
histogram buckets with `Reprised::Telemetry::Metrics.add_views(provider)`.

## Listing routes

```sh
bundle exec reprised routes                     # the app in ./app.rb
bundle exec reprised routes -r ./boot.rb MyApp  # require files first, and name the app
bundle exec reprised routes -f compact -g movie # "file:line VERB pattern" lines, filtered
```

Routes are listed in the order they're tried, with each one's controller, `provides`, and source location.

## Reloading in development

`Reprised::Reloader` reloads the app's code when it changes, before the next request. It waits for the requests in
flight to finish, and holds new ones until the reload is done, so no request sees half-loaded code. It reloads with a
[Zeitwerk](https://github.com/fxn/zeitwerk) loader, and can also reload an app defined in plain required files, such as
one class reopened across several files. It needs no file-watcher thread: each request checks the files the app has
loaded, and their directories.

```ruby
# config.ru
if ENV["RACK_ENV"] == "development"
  require "reprised/reloader"
  run Reprised::Reloader.new("App", loader:)                                   # App is loaded by Zeitwerk
  # run Reprised::Reloader.new("API", loader:, files: ["app.rb", "routes/*.rb"]) # or defined in required files
else
  run App
end
```

The loader needs `enable_reloading` before its `setup`. A reload that raises (a syntax error, say) answers with the
error, and is tried again with the next request. config.ru and its middleware aren't reloaded. The stall detector
doesn't report the time spent loading code.

## Ractors

`App.ractorize!` makes an app shareable with other Ractors, so a Ractor server (such as
[Kino](https://github.com/yaroslav/kino)) can run it in several at once: the app is built once, at boot, and handed to
each worker Ractor. Ractors are experimental in Ruby 4.0, and so is this.

```ruby
App.ractorize! # at boot, once every app is defined
```

It compiles the app's blocks again from shareable copies, freezes its settings, keeps the caches Reprised fills while it
serves requests per Ractor, and freezes Rack's and Mustermann's globals (with Rack's own `rack/ractorize` where the
installed Rack has it). Whatever can't be shared is listed in one `Reprised::RactorError`: a block and the variable it
uses, or the path to the object that can't be frozen.

- Route, filter, and error handler blocks may use the local variables around them only if their values are frozen, and
  may not assign to them. Helpers defined with `def` are fine; methods an app defines from blocks aren't.
- Middleware is frozen, so middleware that changes its own state as it serves requests can't be shared.
- Templates should be precompiled (`precompile_templates`, the default outside development and test).
- Rack's media types and other globals are frozen for the whole process, so register media types before.
- The Reloader, telemetry, and the Sprockets plugin don't run in other Ractors yet.

## Coming from Sinatra

Most route code moves over unchanged. What changes:

- **Declaring and mounting:** `class App < Reprised::App` for `Sinatra::Base`, and `class X < Reprised::Controller` with
  `mount X` for an extension of routes. `register` still works, and mounts controller classes.
- **Helpers and filters are scoped to their controller** (see [Controllers](#controllers)). `set :helper_isolation,
  false` gives Sinatra's global helpers while you migrate, and the overlap check reports filters that scoping changes.
  To turn isolation on, run the specs with it on to find helpers one controller calls from another, and move those into
  modules: included with `helpers SharedHelpers` by the controllers that use them, or in the app's `helpers` if every
  controller does. Moving a `helpers do` block into a module changes how its constants resolve: constants the
  controller defines aren't found from the module, and a module beside it can shadow a top-level class (a
  `Helpers::Session` module for the `Session` model).
- **Routing happens before filters.** Conditions run while routes are matched, so they don't see what filters set, and a
  controller's filters don't run on a 404.
- **Errors:** `Reprised::NotFound` for `Sinatra::NotFound`, and `env["reprised.error"]` (or `error` in a handler) for
  `env["sinatra.error"]`. `set :sinatra_env, true` also sets `env["sinatra.route"]` and `env["sinatra.error"]` for
  middleware written for Sinatra. The [OpenTelemetry](#opentelemetry) plugin replaces
  opentelemetry-instrumentation-sinatra's tracer middleware.
- **Multi-verb routes and `json`** are built in, replacing sinatra-contrib's MultiRoute and JSON. So are `cookies` and
  `configure`, and `Reprised::Extension` stands in for sinatra-contrib's `Sinatra::Extension`. Once migrated, an
  extension can become a [plugin](#plugins).
- **Reloading in development:** a file watcher that only reloads Zeitwerk leaves the app's routes on the old controller
  classes. [`Reprised::Reloader`](#reloading-in-development) reloads the app too, between requests.
- **Settings** are methods on the app (`settings.views`). The public folder is served as in Sinatra. Server, session,
  protection, and logging settings are gone; use Rack middleware in config.ru.
- **Helpers' class methods:** a helper module that adds class methods to what includes it (`ActiveSupport::Concern`'s
  `ClassMethods`) gives them to the app and its controllers, so `self.class.full_sanitizer` works in any route.
- **Specs that stub the app's instances** (`allow_any_instance_of(App)`) need the controller instead: a controller's
  routes run in an instance of the controller.
- **Protection isn't on by default.** Sinatra adds `Rack::Protection` (frame options, origin checks, JSON CSRF, path
  traversal, IP spoofing, and XSS headers) unless it's disabled, and host authorization in development. Reprised doesn't.
  To keep Sinatra's defaults, add the rack-protection gem and, in config.ru:

  ```ruby
  require "rack/protection"

  # Sinatra's setup. With a session middleware above it, leave out without_session (Sinatra does when sessions are on).
  use Rack::Protection, reaction: :drop_session, without_session: true
  ```
- **Not included:** classic (top-level) apps, `run!`, Tilt and non-ERB engines, inline templates, `forward`, `back`,
  `etag`, and `last_modified` (use `Rack::ConditionalGet` and `Rack::ETag`), and the `host_name`, `user_agent`, and
  `agent` conditions.
- **Small differences:** `Accept` entries of equal preference keep their order in `provides:`. A filter's `:id` param
  doesn't replace the route's own, and a regexp filter's `captures` don't leak into the route.

## Performance

Microseconds per request through a full Rack call (allocations per request), on Ruby 4.0.9 with YJIT, Apple Silicon.
Each framework is used the way it's meant to be; the setup and the harness are in [bench/frameworks](bench/frameworks).

| Workload | Reprised | Sinatra 4.2 | Roda | Hanami |
|---|---|---|---|---|
| hello | 1.63 (13) | 4.94 (56) | **0.72** (11) | 14.65 (227) |
| params | 3.54 (24) | 7.60 (84) | **2.73** (36) | 13.18 (174) |
| filters | 3.38 (23) | 8.75 (101) | **1.29** (18) | 16.70 (247) |
| 1,000 routes | 2.51 (15.5) | 162.29 (1,964) | **1.15** (15.5) | 15.48 (231) |
| 404 | 2.31 (13.3) | 350.71 (4,080) | 0.93 (12) | **0.96** (7.3) |
| ERB | **6.04** (39) | 13.80 (122) | 8.00 (48) | n/a |

Reprised is 2–3× faster than Sinatra on small apps, and much faster with many routes, since Sinatra tries routes one by
one and a 404 tries them all. Roda is faster outside templates. Reprised spends what's left on Sinatra's model: filters,
conditions, error handlers, `pass`, controller scopes, and case-insensitive headers.

## Development

```sh
bundle install
bundle exec rspec
ASYNC_SAFE=1 bundle exec rspec spec/falcon   # Falcon integration specs, checking for unsafe concurrent access
bundle exec rubocop
bundle exec rake spike                       # routing and dispatch parity with Sinatra, see spike/README.md
bundle exec rake demos                       # the demos app, at http://localhost:9292
```

CI also runs the specs on Mustermann 3.1: `MUSTERMANN_VERSION="~> 3.1" bundle install`.
