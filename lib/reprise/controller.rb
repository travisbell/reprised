# frozen_string_literal: true

module Reprise
  # The request scope: an instance handles one request. Routes, filters, error handlers, helpers, and templates all
  # run as its methods.
  #
  # A request goes:
  #
  # 1. Params are parsed (a malformed query or body is a 400).
  # 2. Routes are matched in definition order. Patterns are matched first, then conditions (`provides:` and custom
  #    ones), so conditions see the request but not what filters set.
  # 3. Before filters run, once, right before the first matching route's body. If no route matches, they run anyway,
  #    and then the request is a 404.
  # 4. The route's body runs. `pass` moves on to the next matching route, `halt` stops with a response.
  # 5. After filters run, whatever happened.
  #
  # Exceptions go to error handlers by class, then by status. A response status (`halt 404`) also goes to the status's
  # handler when no exception was raised.
  class Controller
    extend DSL
    include Helpers

    attr_reader :env, :request, :response, :params

    # The Route answering this request, set once one matches (also during before filters). nil for a 404.
    attr_reader :route

    def initialize(env)
      @env = env
      @request = Request.new(env)
      @response = Response.new
      @params = Params.new
      @route = nil
      @pinned_content_type = false
    end

    def settings = self.class.settings

    # Handles the request and returns the Rack response.
    def call!
      invoke { dispatch! }
      invoke { error_block!(response.status) } unless env["reprise.error"]

      unless response["content-type"]
        if body.is_a?(Array) && body[0].respond_to?(:content_type)
          content_type(body[0].content_type)
        elsif (default = settings.default_content_type)
          content_type(default)
        end
      end

      response.finish
    end

    private

    def dispatch!
      @params.merge!(request.params).each do |key, value|
        @params[key] = force_encoding(value) if value.is_a?(String)
      end

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
      filtered = false
      pass_block = nil

      self.class.router.each(route_lane, request.path_info) do |route, route_params|
        response.delete_header("content-type") unless @pinned_content_type

        passed = with_params(route_params) do
          next unless conditions_met?(route)

          @route = route
          env["reprise.route"] = route
          unless filtered
            filtered = true
            before_filters!
          end

          catch(:pass) { route_eval { Action.call(route.action, self, block_values(route_params)) } }
        end

        pass_block = passed if passed
      end

      before_filters! unless filtered
      route_eval(&pass_block) if pass_block
      route_missing
    end

    def route_lane
      method = request.request_method
      method == "HEAD" && !self.class.router.lane?("HEAD") ? "GET" : method
    end

    # Runs before filters, and notes whether one set the content type, which then pins it: `provides` on a later
    # route must agree with it rather than replace it (as in Sinatra).
    def before_filters!
      content_type_before = response["content-type"]
      filter!(:before)
      @pinned_content_type = response["content-type"] != content_type_before
    end

    def filter!(type)
      self.class.filter_router(type).each(:any, request.path_info) do |filter, filter_params|
        with_params(filter_params) do
          catch(:pass) do
            next unless conditions_met?(filter)

            Action.call(filter.action, self, block_values(filter_params))
          end
        end
      end
    end

    def conditions_met?(definition) = definition.conditions.all? { it.met?(self) }

    # Merges route or filter params into params while the block runs, keeping the request's params where the pattern's
    # are nil, and restores them afterwards. After an exception they're kept, for the error handler.
    def with_params(extra)
      return yield if extra.empty?

      extra.delete("ignore")
      original = @params
      force_encoding(extra)
      @params = @params.merge(extra) { |_key, given, matched| matched || given }
      failed = false
      yield
    rescue ::Exception
      failed = true
      raise
    ensure
      @params = original if original && !failed
    end

    # A route block's arguments: a regexp pattern's captures, or the pattern's param values in order.
    def block_values(route_params) = route_params["captures"] || route_params.values.flatten

    def route_eval = throw(:halt, yield)

    def route_missing = raise(NotFound)

    # Runs the block, catching `halt`, and applies what it returns to the response, as Sinatra does.
    def invoke(&)
      result = catch(:halt, &)

      result = [result] if result.is_a?(Integer) || result.is_a?(String)
      if result.is_a?(Array) && result.first.is_a?(Integer)
        result = result.dup
        status(result.shift)
        body(result.pop)
        headers(*result)
      elsif result.respond_to?(:each)
        body(result)
      end
      nil
    end

    def handle_exception!(boom)
      env["reprise.error"] = boom
      http_status = boom.http_status if boom.is_a?(Error) && boom.respond_to?(:http_status)
      http_status = boom.code if boom.is_a?(Error) && http_status.nil? && settings.use_code? && boom.respond_to?(:code)
      status(http_status&.between?(400, 599) ? http_status : 500)

      if server_error?
        dump_errors!(boom) if settings.dump_errors?
      elsif not_found?
        headers["x-cascade"] = "pass" if settings.x_cascade?
      end

      if (result = error_block!(boom.class, boom) || error_block!(status, boom))
        return result
      end

      if not_found? || bad_request?
        if boom.message && boom.message != boom.class.name
          body(Rack::Utils.escape_html(boom.message))
        else
          content_type("text/html")
          body("<h1>#{not_found? ? "Not Found" : "Bad Request"}</h1>")
        end
      end

      return unless server_error?
      raise boom if settings.raise_errors?

      error_block!(Exception, boom)
    end

    # Runs the error handler for +key+ (an exception class, walking up to its superclasses, or a status). Handlers for
    # the same key run newest first; an older one runs only if every newer one returns nil.
    def error_block!(key, *block_params)
      handlers = self.class.error_handlers(key)
      handlers.each_with_index do |handler, index|
        result = Action.call(handler.action, self, block_params)
        return result unless result.nil? && index < handlers.size - 1
      end
      return false unless key.respond_to?(:superclass) && key.superclass < Exception

      error_block!(key.superclass, *block_params)
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

    # The provides: condition. Matches when the client accepts one of +types+, and sets the content type to it, unless
    # a before filter already set one, which must then be among +types+.
    def provides?(types)
      if (current = response["content-type"])
        types.include?(current) || types.include?(current[/^[^;]+/])
      elsif (preferred = request.preferred_type(types))
        content_type(preferred)
        true
      else
        false
      end
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
