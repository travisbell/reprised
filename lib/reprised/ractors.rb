# frozen_string_literal: true

require "uri"

module Reprised
  # Running an app in several Ractors, as a Ractor server (such as Kino) does: the app is built once, in the main
  # Ractor, made shareable, and handed to each worker Ractor.
  #
  #   App.ractorize!   # at boot, once every app is defined
  #
  # App.ractorize! finalizes the app, then:
  #
  # - compiles its routes', filters', error handlers', and conditions' blocks again from shareable copies. A block may
  #   use the local variables around it only if their values are frozen (shareable), and may not assign to them.
  # - freezes each setting's current value, and redefines its reader to return it.
  # - keeps the caches Reprised fills while it serves requests (content types, error handlers, Accept headers,
  #   templates) per Ractor.
  # - builds the state Mustermann patterns build lazily, and freezes Rack's and Mustermann's globals (Rack's own
  #   rack/ractorize, where the installed Rack has it).
  # - makes the routers, the middleware stack, and the app's definitions shareable.
  #
  # Whatever can't be shared is listed in one Reprised::RactorError: a block with the variable it captures, or the path
  # to an object that can't be frozen (a middleware holding a Mutex, say). A setting whose value can't be shared is
  # only a warning, since most are read at boot: reading it from another Ractor raises.
  #
  # Rack's globals are frozen for the whole process, so `mime_type` and Rack::Mime::MIME_TYPES can't change afterwards.
  # The Reloader, telemetry, and the Sprockets plugin don't run in other Ractors.
  module Ractors
    class << self
      def ractorize!(app)
        return app if app.ractorized?

        app.finalize!
        RackGlobals.share!
        MustermannGlobals.share!
        errors = []
        settings_warnings = []
        Recompiler.new(errors).recompile(app)
        settings_warnings.concat(Settings.share!(app))
        Caches.install(app)
        errors.concat(share_state(app))
        raise RactorError, report(app, errors) unless errors.empty?

        Kernel.warn(settings_report(app, settings_warnings), uplevel: 1) unless settings_warnings.empty?
        app.instance_variable_set(:@ractorized, true)
        app
      end

      # A Ractor-local cache for +owner+ (an app or controller class), by +name+.
      def local(owner, name)
        caches = (Ractor.current[:reprised_caches] ||= {}.compare_by_identity)
        (caches[owner] ||= {})[name] ||= {}
      end

      private

      # Every class an app's requests read: the app, its app ancestors, and its controllers.
      def owners(app) = [app, *app.ancestors.select { it.is_a?(Class) && it < App && it != app }, *app.controllers].uniq

      def share_state(app)
        owners(app).flat_map do |owner|
          owner.instance_variables.filter_map do |name|
            value = owner.instance_variable_get(name)
            next if Ractor.shareable?(value)

            Ractor.make_shareable(value)
            nil
          rescue Ractor::Error, Ractor::IsolationError, ArgumentError, TypeError => error
            "#{owner}.#{name}#{Unshareable.describe(value, error)}"
          end
        end
      end

      def report(app, errors)
        "#{app} can't be shared with other Ractors:\n  #{errors.join("\n  ")}"
      end

      def settings_report(app, names)
        "Reprised: #{app}'s settings #{names.join(", ")} can't be shared with other Ractors, so only the main Ractor " \
          "can read them"
      end
    end

    # Compiles the app's blocks again from shareable copies, and rebuilds its routers, runtime, and stack.
    class Recompiler
      def initialize(errors)
        @errors = errors
        @recompiled = {}.compare_by_identity
      end

      def recompile(app)
        routes = app.instance_variable_get(:@routes).map { recompile_definition(it) }.freeze
        filters = app.instance_variable_get(:@filters).transform_values { |list| list.map { recompile_definition(it) }.freeze }.freeze
        Ractors.send(:owners, app).each do |owner|
          errors = owner.instance_variable_get(:@errors)
          errors&.each_key { |key| errors[key] = errors[key].map { recompile_definition(it) } }
          definitions = owner.instance_variable_get(:@definitions)
          definitions&.each_key { |kind| definitions[kind] = definitions[kind].map { recompile_definition(it) } }
          conditions = owner.instance_variable_get(:@conditions)
          conditions&.each_key { |name| conditions[name] = shareable(conditions[name]) }
        end
        app.instance_variable_set(:@routes, routes)
        app.instance_variable_set(:@filters, filters)
        app.instance_variable_set(:@router, app.send(:build_router, routes) { |route| route.head ? [route.verb, "HEAD"] : route.verb })
        app.instance_variable_set(:@filter_routers, filters.transform_values { app.send(:build_router, it) }.freeze)
        app.instance_variable_set(:@error_handlers, app.errors.transform_values { it.reverse.freeze }.freeze)
        app.instance_variable_set(:@runtime, app.send(:build_runtime))
        app.instance_variable_set(:@stack, app.send(:build_stack, shareable: true))
        MustermannGlobals.prepare(app.instance_variable_get(:@router))
        app.instance_variable_get(:@filter_routers).each_value { MustermannGlobals.prepare(it) }
      end

      private

      def recompile_definition(definition)
        return definition unless definition.is_a?(Route) || definition.is_a?(Filter) || definition.is_a?(ErrorHandler)

        changes = {}
        changes[:action] = shareable(definition.action) if definition.respond_to?(:action)
        if definition.respond_to?(:conditions)
          changes[:conditions] = definition.conditions.map { it.with(check: shareable(it.check)) }.freeze
        end
        definition.with(**changes)
      end

      # The method compiled again from a shareable copy of its block, or itself if it wasn't compiled from a block.
      def shareable(method)
        @recompiled.fetch(method) do
          @recompiled[method] = method
          block = DSL.compiled_blocks[method]
          next method unless block

          copy = begin
            Ractor.shareable_proc(&block)
          rescue Ractor::IsolationError, ArgumentError => error
            @errors << "#{method.name} (#{block.source_location&.join(":")}): #{error.message}"
            next method
          end
          target = method.owner
          target.define_method(method.name, &copy)
          @recompiled[method] = target.instance_method(method.name).tap { target.remove_method(method.name) }
        end
      end
    end

    # Settings' current values, frozen, with readers that return them.
    module Settings
      def self.share!(app)
        names = app.ancestors.select { it.is_a?(Class) && it <= App }.flat_map { it.instance_variable_get(:@setting_names) || [] }.uniq
        names.filter_map do |name|
          value = app.public_send(name)
          begin
            Ractor.make_shareable(value)
          rescue Ractor::Error, Ractor::IsolationError, ArgumentError, TypeError
            next name
          end
          reader = Ractor.shareable_proc { value }
          predicate = Ractor.shareable_proc { value ? true : false }
          set_predicate = app.method(:"#{name}?").owner.singleton_class? if app.respond_to?(:"#{name}?")
          app.singleton_class.class_exec do
            define_method(name, &reader)
            define_method(:"#{name}?", &predicate) if set_predicate
          end
          nil
        end
      end
    end

    # Per-Ractor versions of the caches Reprised fills as it serves requests, installed on a ractorized app.
    module Caches
      def self.install(app)
        app.erb_defaults
        app.instance_variables.each { app.remove_instance_variable(it) if [:@content_types, :@error_lookup].include?(it) }
        app.singleton_class.prepend(AppCaches)
        app.ancestors.each do |ancestor|
          next unless ancestor.is_a?(Class) && ancestor < App && ancestor != app

          ancestor.remove_instance_variable(:@error_lookup) if ancestor.instance_variable_defined?(:@error_lookup)
          ancestor.singleton_class.prepend(AppErrorLookup)
        end
        app.controllers.each do |controller|
          controller.remove_instance_variable(:@error_lookup) if controller.instance_variable_defined?(:@error_lookup)
          controller.singleton_class.prepend(ControllerErrorLookup)
        end
        Reprised::Negotiation.singleton_class.prepend(NegotiationCaches) unless Reprised::Negotiation.singleton_class < NegotiationCaches
      end

      module AppErrorLookup
        def error_handlers(key)
          return super unless finalized?

          lookup = Ractors.local(self, :error_handlers)
          lookup.fetch(key) { lookup[key] = find_error_handlers(key) }
        end
      end

      module ControllerErrorLookup
        def error_handlers(key)
          return super unless app&.finalized?

          lookup = Ractors.local(self, :error_handlers)
          lookup.fetch(key) { lookup[key] = errors.fetch(key, Controller::NO_HANDLERS).reverse.freeze }
        end
      end

      module AppCaches
        include AppErrorLookup

        def content_type_for(type)
          cache = Ractors.local(self, :content_types)
          cache.fetch(type) do
            cache.clear if cache.size >= 256
            cache[type] = yield
          end
        end

        private

        # The templates compiled at boot (frozen), plus those this Ractor compiled since.
        def default_templates_for(views)
          local = Ractors.local(self, :default_templates)
          local.fetch(views) { local[views] = @default_templates&.[](views)&.dup || {} }
        end

        def template_cache
          local = Ractors.local(self, :template_cache)
          local.empty? && @template_cache ? local.merge!(@template_cache) : local
        end

        def cache_template(key, compiled) = template_cache[key] = compiled
      end

      # Negotiation's caches are constants, shared by every app, so once an app is ractorized each Ractor keeps its own.
      module NegotiationCaches
        def parse_accept(header)
          return super if header.nil? || header.empty?

          cache = Ractors.local(Reprised::Negotiation, :accept)
          cache.fetch(header) do
            cache.clear if cache.size >= Reprised::Negotiation::ACCEPT_CACHE_SIZE
            cache[header] = send(:parse, header)
          end
        end

        def preferred_type(accept, types)
          return send(:choose_type, accept, types) unless accept.frozen? && types.frozen?

          cache = Ractors.local(Reprised::Negotiation, :preferred)
          by_types = (cache[accept] ||= {}.compare_by_identity)
          by_types.fetch(types) do
            cache.clear if cache.size >= Reprised::Negotiation::ACCEPT_CACHE_SIZE
            by_types[types] = send(:choose_type, accept, types)
          end
        end
      end
    end

    # Rack's globals: its constants (Rack::Mime::MIME_TYPES, Rack::Utils::HTTP_STATUS_CODES, and the rest) and the
    # class-level settings a request reads, frozen. Rack's main branch does much the same in rack/ractorize, which is
    # required first when the installed Rack has it.
    module RackGlobals
      PRIVATE_CONSTANTS = {
        "Rack::Request::Helpers" => [:AUTHORITY, :FORWARDED_SCHEME_HEADERS],
        "Rack::Utils" => [:ALLOWED_FORWARDED_PARAMS, :VALID_COOKIE_KEY, :OBSOLETE_SYMBOLS_TO_STATUS_CODES, :OBSOLETE_SYMBOL_MAPPINGS]
      }.freeze

      def self.share!
        begin
          require "rack/ractorize"
        rescue LoadError
          nil
        end
        Ractors.share_constants(::Rack)
        PRIVATE_CONSTANTS.each { |owner, names| names.each { Ractors.share_constant(owner, it) } }
        Ractor.make_shareable(::Rack::Utils.default_query_parser)
        ::Rack::Request.forwarded_priority = Ractor.make_shareable(::Rack::Request.forwarded_priority)
        ::Rack::Request.x_forwarded_proto_priority = Ractor.make_shareable(::Rack::Request.x_forwarded_proto_priority)
        share_ip_filter
      end

      # Rack 3.2's default ip_filter captures a Regexp it doesn't freeze; the same filter, with it frozen.
      def self.share_ip_filter
        filter = ::Rack::Request.ip_filter
        return if Ractor.shareable?(filter)

        Ractor.make_shareable(filter)
      rescue Ractor::IsolationError, ArgumentError
        raise unless filter.binding.local_variable_defined?(:trusted_proxies)

        proxies = Ractor.make_shareable(filter.binding.local_variable_get(:trusted_proxies))
        ::Rack::Request.ip_filter = Ractor.shareable_lambda { |ip| proxies.match?(ip) }
      end
    end

    # Mustermann's globals, and the state its patterns build the first time they're used.
    module MustermannGlobals
      PRIVATE_CONSTANTS = { "Mustermann::Pattern" => [:ALWAYS_ARRAY] }.freeze
      # Mustermann unescapes captures with a parser in a class variable, which other Ractors can't read.
      URI_PARSER = Ractor.make_shareable(URI::RFC2396_Parser.new)

      module Unescape
        private def unescape(string, decode = uri_decode)
          return string unless decode && string && string.include?("%")

          URI_PARSER.unescape(string)
        end
      end

      def self.share!
        Ractors.share_constants(::Mustermann)
        PRIVATE_CONSTANTS.each { |owner, names| names.each { Ractors.share_constant(owner, it) } }
        ::Mustermann::Pattern.prepend(Unescape) unless ::Mustermann::Pattern < Unescape
      end

      # Mustermann 4's per-pattern caches of matches, as WeakKeyMaps.
      MATCH_CACHES = [:@match_cache, :@peek_cache].freeze

      # Builds what a router's patterns build lazily when matching, and drops their caches, which can't be shared: the
      # AST cache (a WeakMap), which isn't needed once they're built, and Mustermann 4's match caches (WeakKeyMaps),
      # which they match without (as `cache: false` does).
      def self.prepare(router, seen = {}.compare_by_identity)
        return if seen[router] || router.is_a?(Module) || Ractor.shareable?(router)

        seen[router] = true
        if router.is_a?(::Mustermann::Pattern)
          router.send(:param_converters) if router.respond_to?(:param_converters, true)
          router.send(:except_regexp) if router.respond_to?(:except_regexp, true)
          router.remove_instance_variable(:@ast_cache) if router.instance_variable_defined?(:@ast_cache)
          MATCH_CACHES.each do |name|
            next unless router.instance_variable_defined?(name) && !Ractor.shareable?(router.instance_variable_get(name))

            router.instance_variable_set(name, false)
          end
        end
        router.instance_variables.each { prepare(router.instance_variable_get(it), seen) }
        case router
        when Array then router.each { prepare(it, seen) }
        when Hash then router.each { |pair| pair.each { prepare(it, seen) } }
        when Data, Struct then router.to_h.each_value { prepare(it, seen) }
        end
      end
    end

    # Makes the constants under +namespace+ (and its own modules, loading any that autoload) shareable.
    def self.share_constants(namespace, seen = {}.compare_by_identity)
      return if seen[namespace]

      seen[namespace] = true
      namespace.constants(false).each do |name|
        value = namespace.const_get(name, false)
        if value.is_a?(Module)
          share_constants(value, seen) if value.name&.start_with?("#{namespace.name}::")
        elsif !Ractor.shareable?(value)
          Ractor.make_shareable(value)
        end
      rescue NameError, LoadError, Ractor::Error
        next
      end
    end

    def self.share_constant(owner, name)
      owner = Object.const_get(owner)
      value = owner.const_get(name)
      Ractor.make_shareable(value) unless Ractor.shareable?(value)
    rescue NameError
      nil
    end

    # Finds why an object can't be shared: the path to the first thing in it that can't be.
    module Unshareable
      NEVER = [ObjectSpace::WeakMap, ObjectSpace::WeakKeyMap, Thread::Mutex, Thread::Queue, Thread, IO, Monitor].freeze

      # " → @lock holds Thread::Mutex, which can't be shared", or Ruby's own message.
      def self.describe(value, error)
        path, culprit = find(value)
        return ": #{error.message}" unless culprit

        where = culprit.is_a?(Proc) ? " (#{culprit.source_location&.join(":")})" : ""
        "#{path}#{path.empty? ? " is" : " holds"} #{culprit.class}#{where}, which can't be shared"
      end

      def self.find(root)
        seen = {}.compare_by_identity
        queue = [[root, ""]]
        until queue.empty?
          object, path = queue.shift
          next if seen[object] || object.is_a?(Module) || Ractor.shareable?(object)

          seen[object] = true
          return [path, object] if never?(object)

          children(object).each { |name, child| queue << [child, "#{path}#{name}"] }
        end
        [nil, nil]
      end

      def self.never?(object)
        return true if NEVER.any? { object.is_a?(it) }
        return false unless object.is_a?(Proc)

        Ractor.shareable_proc(&object)
        false
      rescue Ractor::IsolationError, ArgumentError
        true
      end

      def self.children(object)
        children = object.instance_variables.map { [" → #{it}", object.instance_variable_get(it)] }
        case object
        when Array then children.concat(object.each_with_index.map { |child, index| ["[#{index}]", child] })
        when Hash then children.concat(object.map { |key, child| ["[#{key.inspect[0, 40]}]", child] })
        when Data, Struct then children.concat(object.to_h.map { |key, child| [".#{key}", child] })
        end
        children
      end
    end
  end
end
