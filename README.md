# Reprise Router

A Sinatra-compatible Rack router for Ruby 4, built on Mustermann 4 and designed for Falcon and Async.

**Status:** early. Phase 0 (routing parity with Sinatra on TMDB's route tables) is done. The app and controller layer
comes next. See [PLAN.md](PLAN.md).

```ruby
require "reprise"

router = Reprise::Router.new
router.add("GET", "/movie/:id", :show)
router.add("GET", "/movie/new", :new)
router.finalize!

router.find("GET", "/movie/new") { |route, params| route == :new } # => [:new, {}]
```

## Development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec rake spike   # routing parity with Sinatra on TMDB's route tables, see spike/README.md
```

Requires Ruby 4.0.
