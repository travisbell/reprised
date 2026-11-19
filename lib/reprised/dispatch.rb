# frozen_string_literal: true

require "rack/method_override"
require "uri"

module Reprised
  # Handles one request for an app.
  #
  # 1. Params are parsed (a malformed query or body is a 400).
  # 2. Routes are matched in definition order: patterns first, then conditions (`provides:` and custom ones), so
  #    conditions see the request but not what filters set. Each candidate is tried in the scope of the controller
  #    that defined it.
  # 3. Before filters run once, in the matched route's scope, right before its body: the app's, plus the matched
  #    controller's own, in definition order. If no route matches, the app's run anyway (in the app's scope), and the
  #    request is a 404.
  # 4. The route's body runs. `pass` moves on to the next matching route, `halt` stops with a response. A route in
  #    another controller runs that controller's before filters first, so `pass` can't skip a controller's filters.
  # 5. After filters run, whatever happened: the app's, and those of each controller whose before filters ran.
  #
  # Exceptions go to error handlers by class, then by status: the matched controller's first, then the app's. A
  # response status (`halt 404`) also goes to the status's handler when no exception was raised.
  #
  # The scope is an instance of the matched route's controller (or of the app), and is Reprised.current while the
  # request is handled. When a candidate belongs to another
  # controller, the scope becomes an instance of that one, taking over the previous scope's instance variables, so
  # what filters set survives a `pass` across controllers.
  class Dispatch
    NO_VALUES = [].freeze
    NOT_FOUND_BODY = "<h1>Not Found</h1>"
    BAD_REQUEST_BODY = "<h1>Bad Request</h1>"
    private_constant :NO_VALUES, :NOT_FOUND_BODY, :BAD_REQUEST_BODY

    # Single-owner: one request, on one fiber. Async::Safe (when enabled) reports any concurrent use.
    ASYNC_SAFE = false

    attr_reader :scope

    def initialize(app, env)
      @app = app
      @runtime = app.runtime
      @scope = app.new(env)
      @route = nil
      @filtered = false
      @static = false
      # The controllers whose filters run for this request: each one a matched route belonged to. A shared empty Array
      # until there's one (filter_owner!), so a request for the app's own routes doesn't allocate it.
      @filter_owners = NO_VALUES
      @pinned_content_type = false
      # Until user code (a condition, filter, or route) has run, the scope holds only what Controller#initialize set,
      # so moving it to another controller needn't look for instance variables to carry over.
      @pristine = true
    end

    def call
      previous = Reprised.current
      Reprised.current = scope
      result = respond
      # A HEAD response keeps its headers (content-length included) and drops its body, as Rack::Head does.
      if env["REQUEST_METHOD"] == "HEAD"
        result[2].close if result[2].respond_to?(:close)
        result[2] = NO_VALUES
      end
      result
    ensure
      Reprised.current = previous
    end

    private

    def respond
      dispatch!
      invoke { error_block!(response.status) } if @runtime.status_handlers && !env["reprised.error"]

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
      override_method! if @runtime.method_override && env["REQUEST_METHOD"] == "POST"
      if @runtime.public_folder && (env["REQUEST_METHOD"] == "GET" || env["REQUEST_METHOD"] == "HEAD") && (file = static_file)
        @static = true
        return invoke { static!(file) }
      end
      invoke { route! }
    rescue ::Exception => e # Every error, not just StandardError, goes through the error handlers, as in Sinatra.
      invoke { handle_exception!(e) }
    ensure
      begin
        # A halt from an after filter applies too, so they run in invoke (when there are any). A public file skips
        # them, as it skipped the before filters.
        if @static
          nil
        elsif (filters = @runtime.after)
          invoke { run_unconditional(filters) } unless filters.empty?
        else
          invoke { filter!(:after) }
        end
      rescue ::Exception => e
        invoke { handle_exception!(e) } unless env["reprised.error"]
      end
    end

    def route!
      pass_block = nil

      @app.router.each(env["REQUEST_METHOD"], route_path) do |route, route_params|
        response.delete_header("content-type") unless @pinned_content_type || response.headers.empty?
        enter(route.owner)

        passed = with_params(route_params) do
          @pristine = false
          next unless route.conditions.empty? || conditions_met?(route)

          matched(route)
          check_forgery!(route) if @runtime.csrf || route.csrf || route.websocket
          if !@filtered
            matched_before_filters!
          elsif !(route.owner <= App) && !@filter_owners.include?(route.owner)
            controller_filters!(route.owner)
          end
          # Sinatra sets it as the route's body starts, so it's unset for a request a before filter turned away.
          env["sinatra.route"] = route.to_s if @runtime.sinatra_env
          catch(:pass) do
            if route.timeout
              route_eval { RouteTimeout.run(route, route.timeout) { run_action(route.action, route_params) } }
            else
              route_eval { run_action(route.action, route_params) }
            end
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

    # The path routes and filters are matched against: the path, without its trailing slash when strict_paths is off
    # (as Sinatra does; "/" stays).
    def route_path
      path = self.path
      return path if @runtime.strict_paths || path.length < 2 || !path.end_with?("/")

      path.delete_suffix("/")
    end

    # Reprised::CSRF's checks, once a route matches and before its before filters, so a forged request runs none of
    # the app's code but its error handler: the cross-origin check, unless the route opts out, and the token, if the
    # route needs one. A token the route asks for is checked whatever the csrf setting, :report included, and so is a
    # websocket route's upgrade, which a browser makes with the user's cookies from any site's page.
    def check_forgery!(route)
      mode = @runtime.csrf || (route.websocket && true)
      if mode && route.csrf != false && (route.websocket || CSRF.unsafe?(env)) &&
          (reason = CSRF.cross_origin(env, @runtime.csrf_trusted_origins))
        error = CrossOriginRequest.new(reason)
        raise error unless mode == :report

        @app.report_forged_request!(error, env)
      end
      scope.verify_csrf_token! if route.csrf == :token
    end

    # The exception page's body for +boom+, with its content type set, or nil for a client it isn't shown to (or if it
    # can't render, which leaves the exception to the error handlers).
    def exception_page(boom)
      return unless ExceptionPage.allowed?(env, @runtime.show_exceptions_from)

      body, type = ExceptionPage.new(boom, scope, root: @runtime.root, editor: @runtime.editor).render(request)
      scope.content_type(type)
      body
    rescue StandardError => error
      env["rack.errors"]&.puts("Reprised: the exception page failed: #{error.class}: #{error.message}")
      nil
    end

    # Sinatra's method_override, by Rack::MethodOverride's rules: a POST's _method form param, or else its
    # X-HTTP-Method-Override header, names the request's method, if it's an HTTP method. The original is kept in
    # env["rack.methodoverride.original_method"]. It's applied once the params are parsed, so a body that doesn't parse
    # is a 400, as any other.
    def override_method!
      method = (request.POST["_method"] if request.form_body?) || env["HTTP_X_HTTP_METHOD_OVERRIDE"]
      method = method.to_s.upcase
      return unless Rack::MethodOverride::HTTP_METHODS.include?(method)

      env[Rack::RACK_METHODOVERRIDE_ORIGINAL_METHOD] = env["REQUEST_METHOD"]
      env["REQUEST_METHOD"] = method
    end

    # The file in the public folder the path names, as Sinatra finds it: unescaped, with no null bytes, and inside the
    # folder.
    def static_file
      folder = @runtime.public_folder
      file = "#{folder}#{URI::RFC2396_PARSER.unescape(path)}"
      return unless Rack::Utils.valid_path?(file)

      file = File.expand_path(file)
      file if file.start_with?("#{folder}/") && File.file?(file)
    end

    # Serves a public file, before any filter runs, with the static_cache_control and static_headers settings.
    def static!(file)
      env["reprised.static_file"] = file
      env["sinatra.static_file"] = file if @runtime.sinatra_env
      scope.cache_control(*@runtime.static_cache_control) if @runtime.static_cache_control
      scope.headers(@runtime.static_headers) unless @runtime.static_headers.empty?
      scope.send_file(file, disposition: nil)
    end

    def matched(route)
      @route = route
      scope.instance_variable_set(:@route, route)
      env["reprised.route"] = route
    end

    # Makes the scope an instance of +owner+, the class that defined the route about to be tried: a controller, or for
    # the app's own routes, the app.
    def enter(owner)
      klass = @runtime.scope_classes[owner] || (owner <= App ? @app : owner)
      return if scope.instance_of?(klass)

      previous = scope
      @scope = klass.allocate
      if @pristine
        Controller::STATE.each { @scope.instance_variable_set(it, previous.instance_variable_get(it)) }
      else
        previous.instance_variables.each { @scope.instance_variable_set(it, previous.instance_variable_get(it)) }
      end
      Reprised.current = @scope
    end

    # Runs before filters, and notes whether one set the content type, which then pins it: `provides` on a later
    # route must agree with it rather than replace it (as in Sinatra).
    def before_filters!
      @filtered = true
      filter_owner!(@route.owner) if @route && !(@route.owner <= App)
      filters = @runtime.before
      return if filters&.empty?

      content_type_before = response["content-type"]
      filters ? run_unconditional(filters) : filter!(:before)
      @pinned_content_type = response["content-type"] != content_type_before
    end

    # The before filters, for the route just matched. Sinatra runs them before matching, so a content type the route's
    # conditions chose (provides:) isn't set while they run: it's put back after, unless a filter set one. A filter that
    # halts leaves the response without it, as in Sinatra.
    def matched_before_filters!
      return before_filters! unless (chosen = response["content-type"])

      response.delete_header("content-type")
      before_filters!
      response["content-type"] ||= chosen
    end

    def filter_owner!(owner)
      @filter_owners = [] if @filter_owners.frozen?
      @filter_owners << owner
    end

    # Runs +owner+'s before filters, for a route of another controller than the one whose filters have run (as after
    # `pass`): they'd have run had its route matched first. The app's have run already, and don't run again.
    def controller_filters!(owner)
      filter_owner!(owner)
      return if @runtime.before # Every before filter is the app's.

      content_type_before = response["content-type"]
      filter!(:before, owner)
      @pinned_content_type ||= response["content-type"] != content_type_before
    end

    # Filters that apply to every request run in order, with no matching and no params to merge. Returns nil: in
    # invoke, a return value would become the body.
    def run_unconditional(actions)
      actions.each { |action| catch(:pass) { Action.call(action, scope, NO_VALUES) } }
      nil
    end

    # Runs the filters of +type+ whose pattern matches: the app's, and those of the controllers whose routes matched
    # (or only +owner+'s). A controller's filter runs in its own controller's scope; the scope is the matched route's
    # again afterwards.
    def filter!(type, owner = nil)
      home = @route&.owner || @app
      @app.filter_router(type).each(:any, route_path) do |filter, filter_params|
        if owner
          next unless filter.owner == owner
        else
          next unless filter.owner <= App || @filter_owners.include?(filter.owner)
        end
        enter(filter.owner) unless filter.owner <= App

        with_params(filter_params) do
          catch(:pass) do
            next unless conditions_met?(filter)

            run_action(filter.action, filter_params)
          end
        end
      end
    ensure
      enter(home) if home
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
      env["reprised.error"] = boom
      env["sinatra.error"] = boom if @runtime.sinatra_env
      http_status = boom.http_status if boom.is_a?(Error) && boom.respond_to?(:http_status)
      http_status = boom.code if boom.is_a?(Error) && http_status.nil? && @runtime.use_code && boom.respond_to?(:code)
      scope.status(http_status&.between?(400, 599) ? http_status : 500)

      if scope.server_error?
        dump_errors!(boom) if @runtime.dump_errors
        if @runtime.show_exceptions == true && (page = exception_page(boom))
          return page
        end
      elsif scope.not_found?
        scope.headers["x-cascade"] = "pass" if @runtime.x_cascade
      end

      if (result = error_block!(boom.class, boom) || error_block!(scope.status, boom))
        return result
      end

      if scope.not_found? || scope.bad_request?
        if boom.message && boom.message != boom.class.name
          scope.body(Rack::Utils.escape_html(boom.message))
        else
          scope.content_type("text/html")
          scope.body(scope.not_found? ? NOT_FOUND_BODY : BAD_REQUEST_BODY)
        end
      end

      return unless scope.server_error?
      if @runtime.show_exceptions == :after_handler && (page = exception_page(boom))
        return page
      end
      raise boom if @runtime.raise_errors

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
      return @app.error_handlers(key) if controller.equal?(@app)

      handlers = controller.error_handlers(key)
      handlers.empty? ? @app.error_handlers(key) : handlers
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
