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
    # Single-owner: one request, on one fiber. Async::Safe (when enabled) reports any concurrent use.
    ASYNC_SAFE = false

    attr_reader :scope

    def initialize(app, env)
      @app = app
      @scope = app.new(env)
      @route = nil
      @filtered = false
      @pinned_content_type = false
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

    def params=(value)
      scope.instance_variable_set(:@params, value)
    end

    def dispatch!
      params.merge!(request.params).each { |key, value| params[key] = force_encoding(value) if value.is_a?(String) }
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

      @app.router.each(route_lane, request.path_info) do |route, route_params|
        response.delete_header("content-type") unless @pinned_content_type
        enter(route.owner)

        passed = with_params(route_params) do
          next unless conditions_met?(route)

          matched(route)
          before_filters! unless @filtered
          catch(:pass) do
            route_eval { RouteTimeout.run(route, route.timeout) { Action.call(route.action, scope, block_values(route_params)) } }
          end
        end

        pass_block = passed if passed
      end

      unless @filtered
        enter(@app)
        before_filters!
      end
      route_eval(&pass_block) if pass_block
      raise NotFound
    end

    def route_lane
      method = request.request_method
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
      previous.instance_variables.each { @scope.instance_variable_set(it, previous.instance_variable_get(it)) }
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
      @app.filter_router(type).each(:any, request.path_info) do |filter, filter_params|
        next unless filter.owner <= App || filter.owner == @route&.owner

        with_params(filter_params) do
          catch(:pass) do
            next unless conditions_met?(filter)

            Action.call(filter.action, scope, block_values(filter_params))
          end
        end
      end
    end

    def conditions_met?(definition) = definition.conditions.all? { it.met?(scope) }

    # Merges route or filter params into params while the block runs, keeping the request's params where the pattern's
    # are nil, and restores them afterwards. After an exception they're kept, for the error handler.
    def with_params(extra)
      return yield if extra.empty?

      extra.delete("ignore")
      original = params
      force_encoding(extra)
      self.params = original.merge(extra) { |_key, given, matched| matched || given }
      failed = false
      yield
    rescue ::Exception
      failed = true
      raise
    ensure
      self.params = original if original && !failed
    end

    # A route block's arguments: a regexp pattern's captures, or the pattern's param values in order.
    def block_values(route_params) = route_params["captures"] || route_params.values.flatten

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
    def error_block!(key, *block_params)
      handlers = error_handlers(key)
      handlers.each_with_index do |handler, index|
        result = Action.call(handler.action, scope, block_params)
        return result unless result.nil? && index < handlers.size - 1
      end
      return false unless key.respond_to?(:superclass) && key.superclass < Exception

      error_block!(key.superclass, *block_params)
    end

    def error_handlers(key)
      controller = scope.class
      handlers = controller.error_handlers(key) unless controller <= App
      handlers.nil? || handlers.empty? ? @app.error_handlers(key) : handlers
    end

    def dump_errors!(boom)
      message = boom.detailed_message(highlight: false)
      details = []
      if (match = message.match(/\A(.*?)(?: \(#{Regexp.quote(boom.class.to_s)}\))?\n/))
        details = match.post_match.lines(chomp: true)
        message = match[1]
      end
      env["rack.errors"]&.puts(["#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} - #{boom.class} - #{message}:", *details, *boom.backtrace].join("\n\t"))
    end

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
