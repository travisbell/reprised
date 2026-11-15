# frozen_string_literal: true

# A tour of Reprised, as one app: a controller per demo (controllers/), Phlex components (components/), ERB views
# (views/), and a stylesheet through Sprockets (assets/). demos/README.md says how to run it.

require "reprised"
require "reprised/plugins/action_view"
require "reprised/plugins/phlex"
require "reprised/plugins/sprockets"
require "async/barrier"
require "sprockets"

# The app's class comes first, so the files below can define its controllers and components inside it.
class Demos < Reprised::App
  set :root, __dir__
end

require_relative "movies"
require_relative "server_timing"
require_relative "components/badge"
require_relative "components/movie_card"
require_relative "components/movie_grid"
require_relative "controllers/routing_demo"
require_relative "controllers/streaming_demo"
require_relative "controllers/events_demo"
require_relative "controllers/chat_demo"
require_relative "controllers/forms_demo"
require_relative "controllers/components_demo"

class Demos
  # ActionView's helpers in every template and controller. Block helpers (`form_tag(...) do`) capture their blocks.
  plugin Reprised::Plugins::ActionView, helpers: [
    ActionView::Helpers::TagHelper,
    ActionView::Helpers::FormTagHelper,
    ActionView::Helpers::FormOptionsHelper,
    ActionView::Helpers::NumberHelper,
    ActionView::Helpers::TextHelper,
    ActionView::Helpers::DateHelper
  ]

  # `<%= %>` escapes, and `<%== %>` writes HTML as it is. Helper output and Phlex components aren't escaped twice.
  set :erb, { escape: true }

  plugin Reprised::Plugins::Phlex

  # Serves assets/ at /assets, compiling on demand. Its stylesheet is ERB, and links an image with asset_path.
  assets = Sprockets::Environment.new(root)
  assets.append_path(File.join(root, "assets", "stylesheets"))
  assets.append_path(File.join(root, "assets", "images"))
  plugin Reprised::Plugins::Sprockets, environment: assets

  # A plugin of the app's own, in server_timing.rb.
  plugin ServerTiming

  # Each demo, for the home page and the navigation: its path, title, and what it shows.
  DEMOS = [
    ["/routing", "Routing", "Patterns, params, conditions, provides:, pass, halt, error handlers, filters, and cookies."],
    ["/streaming", "Streaming", "A response streamed as it's written, route timeouts, Async::Barrier, and a stall."],
    ["/events", "Server-Sent Events", "A live clock that resumes where it left off, and a job's progress."],
    ["/chat", "WebSockets", "A chat room: a websocket route, broadcasting to everyone connected."],
    ["/forms", "Forms", "ActionView's form helpers, their blocks captured, with validation and a file upload."],
    ["/components", "Phlex", "Phlex components in an ERB layout, in ERB templates, and reading the request."]
  ].freeze

  helpers do
    # Standalone ActionView adds a utf8=✓ field to forms, which Rails apps turn off. This turns it off for this app's
    # forms only, rather than setting FormTagHelper.default_enforce_utf8 for every app in the process.
    def default_enforce_utf8 = false

    def page_title = [@title, "Reprised demos"].compact.join(" · ")
    def current_demo?(path) = request.path_info == path || request.path_info.start_with?("#{path}/")

    # Where a route is defined, for the footer: route.source_location, relative to demos/.
    def source_of(route)
      file, line = route.source_location
      "#{file.delete_prefix("#{settings.root}/")}:#{line}"
    end
  end

  get "/" do
    erb :index
  end

  mount RoutingDemo
  mount StreamingDemo
  mount EventsDemo
  mount ChatDemo
  mount FormsDemo
  mount ComponentsDemo

  # A 5xx's exception is logged with its backtrace (dump_errors), except the streaming demo's timeouts, which are
  # expected.
  def self.dump_errors!(exception, env)
    super unless exception.is_a?(Reprised::Timeout)
  end

  not_found do
    @title = "Not found"
    erb :not_found, locals: { message: "There's nothing at #{request.path_info}." }
  end
end
