# Reprised demos

One small Reprised app that shows what Reprised does, a page per feature, running under Falcon:

```sh
bundle install
bundle exec rake demos        # http://localhost:9292, or PORT=9300 bundle exec rake demos
```

It uses the gems in the repo's Gemfile, so there's nothing else to install. Each page's footer names the route that
answered it, and the file and line where that route is defined.

| Demo | What it shows | Code |
|---|---|---|
| [Routing](http://localhost:9292/routing) | Patterns and params, a named condition, `provides:` choosing HTML or JSON, `pass`, `halt`, an error class with its own status, a controller's error handler and filter, `route :get, :post`, and cookies | [routing_demo.rb](controllers/routing_demo.rb) |
| [Streaming](http://localhost:9292/streaming) | A response streamed as it's written, lookups run concurrently with `Async::Barrier` and reaching the request with `Reprised.current`, a route `timeout:`, and a route that blocks the event loop, for the stall detector | [streaming_demo.rb](controllers/streaming_demo.rb) |
| [Server-Sent Events](http://localhost:9292/events) | `event_stream`: a clock that carries on from `Last-Event-ID` when the browser reconnects, and a job's progress | [events_demo.rb](controllers/events_demo.rb) |
| [WebSockets](http://localhost:9292/chat) | A chat room: a `websocket` route, broadcasting to everyone connected, with an `Origin` check | [chat_demo.rb](controllers/chat_demo.rb) |
| [Forms](http://localhost:9292/forms) | The ActionView plugin: form helpers whose blocks are captured, a block helper of the controller's own, validation with a 422, redirecting after a POST, and a file upload | [forms_demo.rb](controllers/forms_demo.rb), [forms.erb](views/forms.erb) |
| [Phlex](http://localhost:9292/components) | The Phlex plugin: a page component in the ERB layout, reading the request through `context[:reprised]`, and components rendered from ERB | [components_demo.rb](controllers/components_demo.rb), [components/](components) |

And throughout:

- **Controllers:** each demo is a `Reprised::Controller`, mounted in [app.rb](app.rb). Its filters, helpers, and error
  handlers are its own: the forms demo's `field` helper, for one, isn't there in the others.
- **Escaping:** the app sets `set :erb, { escape: true }`, so `<%= %>` escapes. Helper output and Phlex components
  aren't escaped twice.
- **Sprockets:** the stylesheet ([demos.css.erb](assets/stylesheets/demos.css.erb)) is ERB, served through the
  Sprockets plugin, and gets its logo's URL from `asset_path`.
- **A plugin of the app's own:** [server_timing.rb](server_timing.rb) adds a `Server-Timing` header to every response,
  which your browser's network panel shows.
- **Telemetry:** [config.ru](config.ru) logs a line per request, labelled with its route's pattern, and the stall
  detector logs a request that blocks the event loop (try the streaming demo's last button).
- **Reloading:** in development, `Reprised::Reloader` reloads the app when a file here changes. Edit one and refresh.
- **Listing routes:** `bundle exec reprised routes -r ./demos/app.rb Demos`.

The chat room and the forms' suggestions live in memory, in one process. That's why `rake demos` runs a single Falcon
worker. [spec/demos_spec.rb](../spec/demos_spec.rb) runs through every demo, under Falcon for the streaming, SSE, and
WebSocket ones.
