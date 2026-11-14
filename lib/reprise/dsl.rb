# frozen_string_literal: true

require "rack/mime"

module Reprise
  # The class-level DSL, shared by apps and controllers: routes, filters, error handlers, conditions, settings, helpers,
  # and middleware. Definitions are recorded in order. When the app is finalized, their options compile into
  # conditions, in the app's context, and they compile into routers.
  module DSL
    VERBS = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "LINK", "UNLINK"].freeze

    # Sinatra settings Reprise doesn't act on: each belongs in config.ru middleware or is gone. Setting one warns.
    IGNORED_SETTINGS = [
      :app_file, :bind, :empty_path_info, :host_authorization, :lock, :logging, :method_override, :port, :protection,
      :public_dir, :public_folder, :quiet, :run, :server, :session_secret, :session_store,
      :sessions, :show_exceptions, :static, :static_cache_control, :static_headers, :strict_paths, :threaded, :traps
    ].freeze

    def self.extended(base)
      base.instance_variable_set(:@definitions, { routes: [], before: [], after: [] })
      base.instance_variable_set(:@errors, {})
      base.instance_variable_set(:@conditions, {})
      base.instance_variable_set(:@pending_conditions, [])
      base.instance_variable_set(:@middleware, [])
      base.instance_variable_set(:@extensions, [])
    end

    def inherited(subclass)
      super
      DSL.extended(subclass)
    end

    # -- Routes ---------------------------------------------------------------------------------------------------

    VERBS.each do |verb|
      define_method(verb.downcase) { |path, options = {}, &block| add_route(verb, path, options, block) }
    end

    # Defines one route for several verbs, and for each of several paths: `route :get, :post, "/session"`.
    # (Sinatra's own `route(verb, path, options)` is the one-verb form of this.)
    def route(*verbs, paths, **options, &block)
      verbs.each { |verb| Array(paths).each { |path| add_route(verb.to_s.upcase, path, options, block) } }
    end

    # The routes defined here, in order. (An app's `routes` is its whole table, mounted controllers' included.)
    def routes = definitions(:routes)

    # The routes, before filters, or after filters (+kind+ :routes, :before, :after) defined here, in order, with
    # Mount markers where controllers were mounted.
    def definitions(kind) = @definitions.fetch(kind)

    # A WebSocket endpoint: the block runs with the connection once the request is upgraded, in the request's scope.
    # Other requests for the path move on to the next route. Options go to async-websocket's Rack adapter (handler:,
    # protocols:, extensions:), and the app must run under an Async server, such as Falcon.
    #
    #   websocket "/live/:channel" do |connection|
    #     while (message = connection.read)
    #       connection.write(message)
    #       connection.flush
    #     end
    #   end
    def websocket(path, options = {}, **adapter_options, &block)
      raise ArgumentError, "websocket #{path} needs a block" unless block

      require "async/websocket/adapters/rack"
      adapter = ::Async::WebSocket::Adapters::Rack
      handler = compile_method("WEBSOCKET #{path}", block)
      condition { adapter.websocket?(env) }
      add_route("GET", path, options, proc {
        # The block runs once the connection is upgraded, after the route has returned, so it keeps the route's params.
        scope = self
        route_params = params
        halt(adapter.open(env, **adapter_options) do |connection|
          scope.instance_variable_set(:@params, route_params)
          Reprise.with_current(scope) { Action.call(handler, scope, [connection]) }
        end)
      })
    end

    # -- Filters --------------------------------------------------------------------------------------------------

    def before(path = nil, **options, &block) = add_filter(:before, path, options, block)
    def after(path = nil, **options, &block) = add_filter(:after, path, options, block)
    # The filters defined here, by type. (An app's `filters` include its mounted controllers'.)
    def filters = { before: definitions(:before), after: definitions(:after) }

    # -- Errors ---------------------------------------------------------------------------------------------------

    # Handles exceptions of the given classes, responses with the given statuses (or ranges of them), or, with no
    # arguments, any exception. The block may take the exception.
    def error(*keys, &block)
      ensure_definable!
      keys = keys.flat_map { Array(it) }
      keys << Exception if keys.empty?
      keys << NotFound if keys.include?(404)
      action = compile_method("ERROR #{keys.join(", ")}", block)
      keys.each { |key| (@errors[key] ||= []) << ErrorHandler.new(key:, action:, owner: self, source_location: block.source_location) }
    end

    def not_found(&) = error(404, &)
    def errors = @errors

    # -- Conditions -----------------------------------------------------------------------------------------------

    # With a name, defines a route option: `condition(:admin) { |level| current_user.level >= level }` makes
    # `get "/x", admin: 2` match only when the block doesn't return false. The block runs in the request's scope. An
    # app's conditions can be used by its controllers' routes.
    #
    # Without a name, adds the block as a condition of the next route defined, as Sinatra's `condition` does. This
    # is how Sinatra-style condition methods work: a class method calling `condition { ... }`, used as a route option.
    def condition(name = nil, &block)
      ensure_definable!
      if name
        @conditions[name.to_sym] = compile_method("condition #{name}", block)
      else
        @pending_conditions << Condition.new(name: nil, check: compile_method("condition", block), args: [].freeze)
      end
    end

    # -- Settings -------------------------------------------------------------------------------------------------

    # Sets a setting, readable as `settings.name` (and `name?`). A Proc value is called each time it's read, and
    # setting a Hash merges into a Hash already set, as in Sinatra.
    def set(option, value = (not_set = true), ignore_setter = false, &block)
      raise ArgumentError, "set takes a value or a block, not both" if block && !not_set

      if block
        value = block
        not_set = false
      end

      if not_set
        raise ArgumentError, "set takes an option and a value, or a Hash" unless option.respond_to?(:each)

        option.each { |key, val| set(key, val) }
        return self
      end

      return __send__("#{option}=", value) if respond_to?("#{option}=") && !ignore_setter
      if respond_to?(option) && !setting?(option)
        raise ArgumentError, "#{option} is a method of #{self}, not a setting; choose another name"
      end

      warn_ignored_setting(option)
      (@setting_names ||= []) << option.to_sym
      setter = ->(val) { set(option, val, true) }
      setter = ->(val) { set(option, val.is_a?(Hash) ? value.merge(val) : val, true) } if value.is_a?(Hash)

      singleton_class.class_exec do
        define_method("#{option}=", &setter)
        value.is_a?(Proc) ? define_method(option, &value) : define_method(option) { value }
        define_method("#{option}?") { !!__send__(option) } unless method_defined?("#{option}?")
      end
      self
    end

    # Whether +name+ was defined with `set`, here or in a superclass.
    def setting?(name)
      ancestors.any? { it.is_a?(Class) && it.instance_variable_get(:@setting_names)&.include?(name.to_sym) }
    end

    def enable(*options) = options.each { set(it, true) }
    def disable(*options) = options.each { set(it, false) }

    # Settings are read from the class: `settings.json_encoder`.
    def settings = self

    def development? = settings.environment == :development
    def production? = settings.environment == :production
    def test? = settings.environment == :test

    # Runs the block now if the app's environment is one of +envs+ (or if none are given).
    def configure(*envs)
      yield(self) if envs.empty? || envs.include?(settings.environment.to_sym)
    end

    # Registers a media type for an extension in Rack's registry (shared by every app), or looks one up.
    def mime_type(type, value = nil)
      return Negotiation.mime_type(type) unless value

      type = ".#{type}" unless type.to_s.start_with?(".")
      Rack::Mime::MIME_TYPES[type] = value
    end

    # -- Helpers, extensions, middleware --------------------------------------------------------------------------

    # Adds methods to routes, filters, and templates: the block's methods, and the given modules'. An app's helpers
    # are global: its controllers have them too. A controller's are its own (unless the app turns off
    # helper_isolation).
    def helpers(*modules, &block)
      helpers_module.module_eval(&block) if block
      helpers_module.include(*modules) if modules.any?
    end

    # The module holding this class's helpers, included in it.
    def helpers_module
      @helpers_module ||= Module.new.tap do |mod|
        owner = self
        mod.define_singleton_method(:inspect) { "#{owner}::Helpers" }
        include(mod)
      end
    end

    # Registers a Sinatra-style extension: a module extending the app, with an optional `registered(app)` hook. A
    # Controller class is mounted instead, so `register MovieController` keeps working.
    def register(*extensions, &block)
      extensions << Module.new(&block) if block
      extensions.each do |extension|
        next mount(extension) if extension.is_a?(Class) && extension < Controller
        @extensions << extension
        extend(extension)
        extension.registered(self) if extension.respond_to?(:registered)
      end
    end

    def extensions = @extensions

    # Reprise::App closes definitions once it's finalized.
    def finalized? = false

    # Wraps the app in Rack middleware, outermost first.
    def use(middleware, *args, **options, &block)
      ensure_definable!
      @middleware << [middleware, args, options, block]
    end

    def middleware = @middleware

    # -- Finalizing -----------------------------------------------------------------------------------------------

    # Compiles a route's or filter's options into conditions, looking for named conditions in this class and then in
    # +app+, so a controller's routes can use the app's. Called when the app is finalized.
    def compile_conditions(options, app)
      options.filter_map do |name, args|
        args = Array(args)
        if name == :provides
          Condition.new(name:, check: Controller.instance_method(:provides?), args: [args.flat_map { Negotiation.mime_types(it) }.freeze].freeze)
        elsif (method = find_condition(name) || app.find_condition(name))
          Condition.new(name:, check: method, args: args.freeze)
        elsif (definer = [self, app].find { it.respond_to?(name) })
          # A Sinatra-style condition method, which adds a condition with `condition { ... }`.
          definer.__send__(name, *args)
          definer.take_pending_conditions
        else
          raise ArgumentError, "unknown route option #{name.inspect} (#{self})"
        end
      end.flatten.freeze
    end

    def take_pending_conditions = @pending_conditions.slice!(0..).freeze

    def find_condition(name)
      ancestors.each do |ancestor|
        conditions = ancestor.instance_variable_get(:@conditions) if ancestor.is_a?(Class)
        return conditions[name] if conditions&.key?(name)
      end
      nil
    end

    private

    def add_route(verb, path, options, block)
      ensure_definable!
      raise ArgumentError, "#{verb} #{path} needs a block" unless block

      options = options.dup
      timeout = options.delete(:timeout)
      route = Route.new(
        verb:, path:, options: options.freeze, conditions: take_pending_conditions,
        action: compile_method("#{verb} #{path}", block), timeout:, owner: self, source_location: block.source_location
      )
      definitions(:routes) << route
      route
    end

    def add_filter(type, path, options, block)
      ensure_definable!
      raise ArgumentError, "#{type} filter needs a block" unless block

      @definitions[type] << Filter.new(
        type:, path:, options: options.dup.freeze, conditions: take_pending_conditions,
        action: compile_method("#{type.upcase} #{path || "*"}", block), owner: self, source_location: block.source_location
      )
    end

    # Compiles a block into an UnboundMethod, so it runs as a real method of the request scope, which is faster than
    # instance_exec. (Backtraces still show the block's own label, as in Sinatra.) An app compiles into its helpers
    # module, so its routes, filters, and handlers can also run in its controllers' scopes.
    def compile_method(name, block)
      target = compile_target
      target.define_method(name, &block)
      method = target.instance_method(name)
      target.remove_method(name)
      method
    end

    def compile_target = self

    def ensure_definable!
      raise FrozenError, "#{self} is finalized; define routes, filters, and handlers before the first request" if finalized?
    end

    def warn_ignored_setting(option)
      return unless IGNORED_SETTINGS.include?(option.to_sym) && !(@warned_settings ||= []).include?(option)

      @warned_settings << option
      Kernel.warn("Reprise: `set :#{option}` has no effect; use Rack middleware in config.ru instead", uplevel: 3)
    end
  end
end
