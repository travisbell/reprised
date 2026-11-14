# Reprise Router

A Sinatra-compatible Rack router for Ruby 4, built on Mustermann 4 and designed for Falcon and Async.

**Status:** early. These work, and match Sinatra 4.2's routing, dispatch, and rendering on two production apps:

- the core app
- mountable controllers with private helpers
- ERB templates, with ActionView and Phlex plugins
- Async features: `Reprise.current` for the request from any fiber, per-route timeouts, streaming, Server-Sent
  Events, and WebSocket routes, all tested under Falcon

Tooling (route listing, OpenTelemetry) comes next. See [PLAN.md](PLAN.md).

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

## Development

```sh
bundle install
bundle exec rspec
ASYNC_SAFE=1 bundle exec rspec spec/falcon   # Falcon integration specs, checking for unsafe concurrent access
bundle exec rubocop
bundle exec rake spike   # routing and dispatch parity with Sinatra, see spike/README.md
```

Requires Ruby 4.0.
