# Reprise Router

A Sinatra-compatible Rack router for Ruby 4, built on Mustermann 4 and designed for Falcon and Async.

**Status:** early. These work, and match Sinatra 4.2's routing, dispatch, and rendering on two production apps:

- the core app
- mountable controllers with private helpers
- ERB templates, with ActionView and Phlex plugins

Async features come next. See [PLAN.md](PLAN.md).

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
bundle exec rubocop
bundle exec rake spike   # routing and dispatch parity with Sinatra, see spike/README.md
```

Requires Ruby 4.0.
