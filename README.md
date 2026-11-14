# Reprise Router

A Sinatra-compatible Rack router for Ruby 4, built on Mustermann 4 and designed for Falcon and Async.

**Status:** early. These work, and match Sinatra 4.2's routing, dispatch, and rendering on two production apps:

- the core app
- mountable controllers with private helpers
- ERB templates, with ActionView and Phlex plugins, and a Sprockets plugin for assets
- Async features: `Reprise.current` for the request from any fiber, per-route timeouts, streaming, Server-Sent
  Events, and WebSocket routes, all tested under Falcon

- Tooling: `reprise routes`, an OpenTelemetry plugin, and Sinatra-compatible env keys for existing middleware
- Opt-in telemetry: request metrics and an access log, an event-loop stall detector, and reactor lag

See [PLAN.md](PLAN.md).

```ruby
require "reprise"

class App < Reprise::App
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

## Listing routes

```sh
bundle exec reprise routes                     # the app in ./app.rb
bundle exec reprise routes -r ./boot.rb MyApp  # require files first, and name the app
bundle exec reprise routes -f compact -g movie # "file:line VERB pattern" lines, filtered
```

## Telemetry

Opt-in, and not loaded by `require "reprise"`. Request metrics (`app.requests`, `app.request.duration`) and an access
log line per request, labelled by route pattern; a stall detector that logs when the event loop is blocked, naming the
requests in flight; and the loop's lag (`reactor.lag`). Metrics go through the OpenTelemetry metrics API, and are no-ops
until you configure an SDK meter provider. Logs go through Console.

```ruby
require "reprise/plugins/telemetry"

class App < Reprise::App
  plugin Reprise::Plugins::Telemetry,
    requests: { labels: ->(env) { { client: env["myapp.client"] } }, skip_paths: ["/healthcheck"] },
    stalls: { threshold: 1.0 },
    reactor_lag: true
end
```

Or put the middleware in config.ru, so it also records what other middleware answers:

```ruby
require "reprise/telemetry"

use Reprise::Telemetry::StallDetector
use OpenTelemetry::Instrumentation::Rack::Middlewares::Stable::TracerMiddleware
use Reprise::Telemetry::Requests # below the tracer: its log line carries the trace id, and is written after the span ends
```

It needs the `opentelemetry-metrics-api` and `console` gems (Falcon brings `console`). Give your meter provider Reprise's
histogram buckets with `Reprise::Telemetry::Metrics.add_views(provider)`.

## Development

```sh
bundle install
bundle exec rspec
ASYNC_SAFE=1 bundle exec rspec spec/falcon   # Falcon integration specs, checking for unsafe concurrent access
bundle exec rubocop
bundle exec rake spike   # routing and dispatch parity with Sinatra, see spike/README.md
```

Requires Ruby 4.0.
