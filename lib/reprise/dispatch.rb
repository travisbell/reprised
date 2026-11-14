# frozen_string_literal: true

module Reprise
  # Handles one request for an app.
  #
  # 1. Params are parsed (a malformed query or body is a 400).
  # 2. Routes are matched in definition order: patterns first, then conditions (`provides:` and custom ones), so
  #    conditions see the request but not what filters set. Each candidate is tried in the scope of the controller
  #    that defined it.
  # 3. Before filters run once, in the matched route's scope, right before its body: the app's, plus the matched
  #    controller's own, in definition order. If no route matches, the app's run anyway (in the app's scope), and the
  #    request is a 404.
  # 4. The route's body runs. `pass` moves on to the next matching route, `halt` stops with a response.
  # 5. After filters run, whatever happened, chosen the same way as before filters.
  #
  # Exceptions go to error handlers by class, then by status: the matched controller's first, then the app's. A
  # response status (`halt 404`) also goes to the status's handler when no exception was raised.
  #
  # The scope is an instance of the matched route's controller (or of the app), and is Reprise.current while the
  # request is handled. When a candidate belongs to another
  # controller, the scope becomes an instance of that one, taking over the previous scope's instance variables, so
  # what filters set survives a `pass` across controllers.
  class Dispatch
    NO_VALUES = [].freeze
    private_constant :NO_VALUES

    # Single-owner: one request, on one fiber. Async::Safe (when enabled) reports any concurrent use.
    ASYNC_SAFE = false

    attr_reader :scope

    def initialize(app, env)
      @app = app
      @scope = app.new(env)
      @route = nil
      @filtered = false
      @pinned_content_type = false
      # Until user code (a condition, filter, or route) has run, the scope holds only what Controller#initialize set,
      # so moving it to another controller needn't look for instance variables to carry over.
      @pristine = true
    end

    def call
      previous = Reprise.current
      Reprise.current = scope
      respond
    ensure
      Reprise.current = previous
    end

    private

    def respond
      invoke { dispatch! }
      invoke { error_block!(response.status) } unless env["reprise.error"]

      unless response["content-type"]
        if scope.body.is_a?(Array) && scope.body[0].respond_to?(:content_type)
          scope.content_type(scope.body[0].content_type)
        elsif (default = settings.default_content_type)
          scope.content_type(default)
        end
      end

      response.finish
    end

    def env = scope.env
    def request = scope.request
    def response = scope.response
    def settings = @app.settings

    def params = scope.params

    def dispatch!
      # Rack's params are the query's merged with the form body's. Without a body that's just the query's, and without
      # a query string either, there's nothing to parse.
      # (Without a content type, only a POST can have a form body.)
      request_params = if (env["CONTENT_TYPE"] || env["REQUEST_METHOD"] == "POST") && request.form_body?
        request.params
      elsif !env["QUERY_STRING"].to_s.empty?
        request.GET
      end
      request_params&.each { |key, value| params[key] = value.is_a?(String) ? force_encoding(value) : value }
      invoke { route! }
    rescue ::Exception => e # Every error, not just StandardError, goes through the error handlers, as in Sinatra.
      invoke { handle_exception!(e) }
    ensure
      begin
        filter!(:after)
      rescue ::Exception => e
        invoke { handle_exception!(e) } unless env["reprise.error"]
      end
    end

    def route!
      pass_block = nil

      @app.router.each(route_lane, path) do |route, route_params|
        response.delete_header("content-type") unless @pinned_content_type
        enter(route.owner)

        passed = with_params(route_params) do
          @pristine = false
          next unless conditions_met?(route)

          matched(route)
          before_filters! unless @filtered
          # Sinatra sets it as the route's body starts, so it's unset for a request a before filter turned away.
          env["sinatra.route"] = route.to_s if settings.sinatra_env
          catch(:pass) do
            route_eval { RouteTimeout.run(route, route.timeout) { run_action(route.action, route_params) } }
          end
        end

        pass_block = passed if passed
      end

      unless @filtered
        enter(@app)
        before_filters!
      end
      route_eval(&pass_block) if pass_block
      # Handled as if raised, without the cost of raising (and of the backtrace nothing reads).
      handle_exception!(NotFound.new)
    end

    def path = env["PATH_INFO"].to_s

    def route_lane
      method = env["REQUEST_METHOD"]
      method == "HEAD" && !@app.router.lane?("HEAD") ? "GET" : method
    end

    def matched(route)
      @route = route
      scope.instance_variable_set(:@route, route)
      env["reprise.route"] = route
    end

    # Makes the scope an instance of +owner+, the class that defined the route about to be tried: a controller, or for
    # the app's own routes, the app.
    def enter(owner)
      klass = owner <= App ? @app : owner
      return if scope.instance_of?(klass)

      previous = scope
      @scope = klass.allocate
      if @pristine
        Controller::STATE.each { @scope.instance_variable_set(it, previous.instance_variable_get(it)) }
      else
        previous.instance_variables.each { @scope.instance_variable_set(it, previous.instance_variable_get(it)) }
      end
      Reprise.current = @scope
    end

    # Runs before filters, and notes whether one set the content type, which then pins it: `provides` on a later
    # route must agree with it rather than replace it (as in Sinatra).
    def before_filters!
      @filtered = true
      content_type_before = response["content-type"]
      filter!(:before)
      @pinned_content_type = response["content-type"] != content_type_before
    end

    # Runs the filters of +type+ whose pattern matches: the app's, and the matched route's controller's.
    def filter!(type)
      @app.filter_router(type).each(:any, path) do |filter, filter_params|
        next unless filter.owner <= App || filter.owner == @route&.owner

        with_params(filter_params) do
          catch(:pass) do
            next unless conditions_met?(filter)

            run_action(filter.action, filter_params)
          end
        end
      end
    end

    def conditions_met?(definition) = definition.conditions.all? { it.met?(scope) }

    # Merges a route's or filter's pattern params into params while the block runs, keeping the request's params where
    # the pattern's are nil. Afterwards only the pattern's own keys are put back: each to the value it had before, or
    # removed if it had none. So changes the block makes to params last (a filter can add params for the route), as in
    # Sinatra, but a filter's :id can't erase the route's (Sinatra deletes the key). After an exception params are left
    # as they are, for the error handler.
    def with_params(extra)
      return yield if extra.empty?

      extra.delete("ignore")
      force_encoding(extra)
      # Merged into params in place, noting what was there before, rather than copying params for every route and
      # filter.
      current = params
      previous = nil
      extra.each do |key, value|
        if current.key?(key)
          (previous ||= {})[key] = current[key]
          current[key] = value unless value.nil?
        else
          current[key] = value
        end
      end
      failed = false
      yield
    rescue ::Exception
      failed = true
      raise
    ensure
      unless failed
        extra.each_key { |key| previous&.key?(key) ? current[key] = previous[key] : current.delete(key) }
      end
    end

    # Runs a route's or filter's compiled block, with its params as block arguments if it takes any: a regexp
    # pattern's captures, or the pattern's param values in order.
    def run_action(action, matched_params)
      return action.bind_call(scope) if action.arity.zero?

      values = matched_params["captures"] || matched_params.values
      action.bind_call(scope, *(values.any?(Array) ? values.flatten : values))
    end

    def route_eval = throw(:halt, yield)

    # Runs the block, catching `halt`, and applies what it returns to the response, as Sinatra does.
    def invoke(&)
      result = catch(:halt, &)

      result = [result] if result.is_a?(Integer) || result.is_a?(String)
      if result.is_a?(Array) && result.first.is_a?(Integer)
        result = result.dup
        scope.status(result.shift)
        scope.body(result.pop)
        scope.headers(*result)
      elsif result.respond_to?(:each)
        scope.body(result)
      end
      nil
    end

    def handle_exception!(boom)
      env["reprise.error"] = boom
      env["sinatra.error"] = boom if settings.sinatra_env
      http_status = boom.http_status if boom.is_a?(Error) && boom.respond_to?(:http_status)
      http_status = boom.code if boom.is_a?(Error) && http_status.nil? && settings.use_code? && boom.respond_to?(:code)
      scope.status(http_status&.between?(400, 599) ? http_status : 500)

      if scope.server_error?
        dump_errors!(boom) if settings.dump_errors?
      elsif scope.not_found?
        scope.headers["x-cascade"] = "pass" if settings.x_cascade?
      end

      if (result = error_block!(boom.class, boom) || error_block!(scope.status, boom))
        return result
      end

      if scope.not_found? || scope.bad_request?
        if boom.message && boom.message != boom.class.name
          scope.body(Rack::Utils.escape_html(boom.message))
        else
          scope.content_type("text/html")
          scope.body("<h1>#{scope.not_found? ? "Not Found" : "Bad Request"}</h1>")
        end
      end

      return unless scope.server_error?
      raise boom if settings.raise_errors?

      error_block!(Exception, boom)
    end

    # Runs the error handler for +key+ (an exception class, walking up to its superclasses, or a status): the scope's
    # controller's, or else the app's. Handlers for the same key run newest first; an older one runs only if every
    # newer one returns nil.
    # +boom+ is passed to handlers that take it.
    def error_block!(key, boom = nil)
      handlers = error_handlers(key)
      last = handlers.size - 1
      index = 0
      while index <= last
        result = Action.call(handlers[index].action, scope, boom ? [boom] : NO_VALUES)
        return result unless result.nil? && index < last

        index += 1
      end
      return false unless key.respond_to?(:superclass) && key.superclass < Exception

      error_block!(key.superclass, boom)
    end

    def error_handlers(key)
      controller = scope.class
      handlers = controller.error_handlers(key) unless controller <= App
      handlers.nil? || handlers.empty? ? @app.error_handlers(key) : handlers
    end

    def dump_errors!(boom) = @app.dump_errors!(boom, env)

    # Strings in +data+ (a String, Hash, or Array) re-tagged with the app's encoding, as Sinatra does. Hashes and
    # Arrays are updated in place; frozen strings are copied.
    def force_encoding(data, encoding = settings.default_encoding)
      case data
      when String then (data.frozen? ? data.dup : data).force_encoding(encoding)
      when Hash then data.transform_values! { force_encoding(it, encoding) }
      when Array then data.map! { force_encoding(it, encoding) }
      else data
      end
    end
  end
end
