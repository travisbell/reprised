# frozen_string_literal: true

require "erubi"
require "erubi/capture_block"

module Reprise
  # A compiled ERB template. Erubi turns the source into Ruby once, and each set of local names compiles that into a
  # method, which renders by being called on the request scope, so templates see the scope's helpers and instance
  # variables (as Tilt's templates do, without Tilt).
  class Template
    # The Erubi options a template is compiled with. Everything else passed to `erb` is a rendering option.
    ENGINE_OPTIONS = [
      :bufval, :bufvar, :chain_appends, :engine_class, :escape, :escape_html, :escapefunc, :freeze,
      :freeze_template_literals, :literal_postfix, :literal_prefix, :outvar, :trim, :yield_returns_buffer
    ].freeze

    # Sinatra's defaults: no escaping, and the output buffer in @_out_buf. CaptureBlockEngine lets helpers that take
    # a block (`<%= form_tag do %>...<% end %>`) capture the block's output.
    DEFAULTS = { engine_class: Erubi::CaptureBlockEngine, bufvar: "@_out_buf", escape: false }.freeze

    LOCAL_NAME = /\A[a-z_][a-zA-Z0-9_]*\z/
    COMPILE_LOCK = Mutex.new
    private_constant :COMPILE_LOCK

    # Where compiled template methods are defined. Every request scope includes it, so they can be bound to any.
    module Methods; end

    attr_reader :path, :line, :mtime

    # +source+ is the template; +path+ and +line+ are where it came from, for backtraces.
    def initialize(source, path:, line: 1, options: {}, mtime: nil)
      options = DEFAULTS.merge(options)
      @bufvar = options.delete(:outvar) if options.key?(:outvar) && !options.key?(:bufvar)
      @bufvar ||= options[:bufvar]
      engine = options.delete(:engine_class)
      @ruby = engine.new(source, options.merge(bufvar: @bufvar)).src
      @path = path
      @line = line
      @mtime = mtime
      @methods = {}
    end

    # Renders on +scope+ with +locals+ as local variables, yielding to +block+ from `yield` in the template.
    def render(scope, locals = {}, &)
      keys = locals.keys
      method = @methods[keys] || compile(keys)
      method.bind_call(scope, locals, &)
    end

    private

    # Defines the method for this set of local names. The previous buffer is restored afterwards, since every template
    # writes to the same instance variable and templates render inside each other.
    def compile(keys)
      COMPILE_LOCK.synchronize do
        return @methods[keys] if @methods[keys]

        assignments = keys.map do |key|
          raise ArgumentError, "#{key.inspect} isn't a valid local variable name (in #{path})" unless LOCAL_NAME.match?(key.to_s)

          "#{key} = __locals[#{key.inspect}];"
        end.join
        name = :"__reprise_template_#{object_id}_#{@methods.size}"
        buffer = @bufvar.start_with?("@") ? @bufvar : nil
        source = +"def #{name}(__locals);#{assignments}"
        source << "__previous_buffer = #{buffer};" if buffer
        source << "begin;" << @ruby << "\nensure;#{"#{buffer} = __previous_buffer;" if buffer}end;end"
        # On the template's first line, so template line numbers stay right in backtraces.
        Methods.module_eval(source, path, line)
        method = Methods.instance_method(name)
        Methods.remove_method(name)
        @methods = @methods.merge(keys.dup.freeze => method).freeze
        method
      end
    end
  end

  # Rendering helpers: `erb`, `partial`, `render`, and `capture`, with Sinatra's semantics.
  module Templates
    # Marks a template's output with a content type (the content_type: option), used if nothing else sets one.
    module ContentTyped
      attr_accessor :content_type
    end

    # Renders the ERB template +template+: a Symbol names a file in the views directory ("movie/show" is
    # views/movie/show.erb), and a String is the template itself.
    #
    #   erb :"movie/show", layout: :"layouts/main", locals: { movie: }
    #
    # A route's template gets the layout views/layout.erb, if there is one, unless it passes `layout:` (false for
    # none). Templates rendered inside templates get no layout. The layout gets the template's locals too.
    def erb(template, options = {}, locals = {}, &) = render(:erb, template, options, locals, &)

    # Renders a template without a layout, passing locals as keywords: `partial "movie/_card", movie:`.
    def partial(name, options = nil, **locals, &)
      render(:erb, name.to_sym, { **options, layout: false, locals: { **locals } }, &)
    end

    # Sinatra's render. Only the :erb engine is built in.
    def render(engine, data, options = {}, locals = {}, &block)
      raise ArgumentError, "unknown template engine #{engine.inspect}; only :erb is built in" unless engine == :erb

      options = options.dup
      engine_options = settings.respond_to?(engine) ? settings.__send__(engine) : {}
      options.merge!(engine_options) { |_key, given, _setting| given }

      locals = options.delete(:locals) || locals || {}
      views = options.delete(:views) || settings.views
      layout = options[:layout]
      layout = false if layout.nil? && options.include?(:layout)
      eat_errors = layout.nil?
      layout = engine_options[:layout] if layout.nil? || (layout == true && engine_options[:layout] != false)
      layout = @__default_layout if layout.nil? || layout == true
      layout_options = options.delete(:layout_options) || {}
      content_type = options.delete(:content_type) || options.delete(:default_content_type)
      scope = options.delete(:scope) || self
      options.delete(:layout)
      # Set when this render is an implicit layout: a missing file then means "no layout", not an error.
      missing_is_fine = options.delete(:eat_errors)

      begin
        default_layout = @__default_layout
        @__default_layout = false
        template = self.class.app.template(data, options.slice(*Template::ENGINE_OPTIONS), views, eat_errors: missing_is_fine)
        output = template.render(scope, locals, &block)
      ensure
        @__default_layout = default_layout
      end

      if layout
        layout_options = options.merge(views:, layout: false, eat_errors:, scope:).merge!(layout_options)
        catch(:layout_missing) { return render(engine, layout, layout_options, locals) { output } }
      end

      if content_type
        output = +output
        output.extend(ContentTyped).content_type = content_type
      end
      output
    end

    # Renders the block into a string instead of the output, for helpers that take a block of template.
    def capture(*args, &block)
      buffer = instance_variable_get(settings.erb.fetch(:bufvar, Template::DEFAULTS[:bufvar]))
      buffer.respond_to?(:capture) ? buffer.capture(*args, &block) : yield(*args)
    end

    # Template lookup and caching, for the app class.
    module Lookup
      # The compiled template for +data+ (a Symbol naming a file in +views+, or a String of template source), cached
      # per app. With reload_templates on, a file is recompiled when it changes.
      def template(data, engine_options, views, eat_errors: false)
        key = [data, engine_options, views].freeze
        cached = template_cache[key]
        return cached if cached && !(settings.reload_templates? && stale?(cached))

        compiled = case data
        when Symbol then file_template(data, engine_options, views, eat_errors:)
        when String then Template.new(data, path: "(inline template)", options: engine_options)
        else raise ArgumentError, "can't render #{data.inspect}; pass a template name (Symbol) or source (String)"
        end
        @template_cache = template_cache.merge(key => compiled).freeze
        compiled
      end

      # Compiles every template in the views directory, so the first request for each doesn't. Run by finalize! when
      # precompile_templates is on (the default outside development and test).
      def precompile_views!
        views = settings.views
        engine_options = settings.erb.slice(*Template::ENGINE_OPTIONS)
        Dir.glob("**/*.erb", base: views).each do |file|
          template(file.delete_suffix(".erb").to_sym, engine_options, views)
        end
      end

      private

      def template_cache = @template_cache ||= {}.freeze

      def file_template(name, engine_options, views, eat_errors:)
        path = File.join(views, "#{name}.erb")
        throw(:layout_missing) if eat_errors && !File.exist?(path)

        source = File.read(path, mode: "rb").force_encoding(settings.default_encoding)
        Template.new(source, path:, options: engine_options, mtime: File.mtime(path))
      end

      def stale?(template) = template.mtime && File.exist?(template.path) && File.mtime(template.path) != template.mtime
    end
  end
end
