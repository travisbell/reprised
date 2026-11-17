# frozen_string_literal: true

module Reprised
  # A route as defined: what it matches, its options (compiled into +conditions+ when the app is finalized), the
  # method its block compiled to, and its timeout in seconds, if any. +owner+ is the App or Controller that defined it.
  # +head+ is whether it also answers HEAD, as a GET route defined with `get` does (and one defined with `route` doesn't,
  # as in Sinatra::MultiRoute).
  Route = Data.define(:verb, :path, :options, :conditions, :action, :timeout, :owner, :source_location, :head) do
    def to_s = "#{verb} #{pattern}"

    # The path as written: a pattern ("/movie/:id"), a regexp's source, or an Array's patterns joined with " | ".
    # This is what telemetry reports as the route (http.route), so ids don't make every request its own series.
    def pattern = Route.pattern_for(path)

    def self.pattern_for(path)
      case path
      when Regexp then path.source
      when Array then path.map { pattern_for(it) }.join(" | ")
      else path.to_s
      end
    end

    def inspect = "#<Reprised::Route #{self} #{source_location&.join(":")}>"
  end

  # A before or after filter. +path+ is nil for one that applies to every request. +overlap+ is true for a controller's
  # filter that means to match other controllers' routes too (`overlap: :ok`), so the overlap check leaves it out.
  Filter = Data.define(:type, :path, :options, :conditions, :action, :owner, :source_location, :overlap) do
    def to_s = "#{type} #{path ? Route.pattern_for(path) : "*"}"
  end

  # Where a controller was mounted among an app's routes and filters. Its definitions take this place when the app is
  # finalized, as a Sinatra extension's do when it's registered.
  Mount = Data.define(:controller)

  # An error handler, for an exception class or a status code.
  ErrorHandler = Data.define(:key, :action, :owner, :source_location)

  # A condition a route or filter needs: a compiled method and the arguments it was given (provides: "json" gives
  # the provides condition its media types), passed only if its block takes any. Met unless the method returns false.
  Condition = Data.define(:name, :check, :args) do
    def met?(scope) = Action.call(check, scope, args) != false
  end

  # Calls a compiled route, filter, condition, or error handler block on a scope, passing +values+ as block arguments
  # if the block takes any (as Sinatra does with captures).
  module Action
    def self.call(action, scope, values) = action.arity.zero? ? action.bind_call(scope) : action.bind_call(scope, *values)
  end
end
