# frozen_string_literal: true

require "phlex"

module Reprised
  module Plugins
    # Phlex components in routes and templates.
    #
    #   plugin Reprised::Plugins::Phlex
    #
    #   get "/movie/:id" do
    #     phlex Pages::Movie.new(movie), layout: :"layouts/main", locals: { title: movie.title }
    #   end
    #
    # `render` also takes a component, in routes and in ERB (`<%= render Card.new(movie) %>`).
    #
    # Components get the request scope as `context[:reprised]`. With `rails: true` (which needs phlex-rails, and the
    # ActionView plugin), they render through an ActionView view context instead, so phlex-rails' helper adapters and
    # ActionView helpers work inside them.
    module Phlex
      module Methods
        # Renders +component+ (a Phlex component, or its class) and returns the HTML. With +layout+, the HTML is
        # yielded to that ERB layout, which gets +locals+ (or +assigns+).
        def phlex(component, layout: nil, **options)
          component = component.new if component.is_a?(Class)
          assigns = options[:assigns] || options[:locals] || {}
          output = settings.phlex_rails ? phlex_view_context(assigns).render(renderable: component) : component.call(context: { reprised: self })
          layout ? render(:erb, layout, { layout: false }, assigns) { output } : output
        end

        # Sinatra's render, which also renders a Phlex component.
        def render(engine, *args, **options, &block)
          return phlex(engine, **options) if Phlex.renderable?(engine)

          super(engine, *args, **options, &block)
        end

        private

        def phlex_view_context(assigns)
          @phlex_lookup_context ||= ::ActionView::LookupContext.new(settings.phlex_view_paths)
          settings.phlex_view_context_class.new(@phlex_lookup_context, assigns, self)
        end
      end

      # What phlex-rails needs from a Reprised request: ActionDispatch-style headers.
      module RequestHeaders
        def headers = @headers ||= ::ActionDispatch::Http::Headers.new(self)
      end

      def self.renderable?(object) = object.is_a?(::Phlex::SGML) || (object.is_a?(Class) && object < ::Phlex::SGML)

      def self.install(app, rails: false, view_paths: [])
        if rails
          require "action_dispatch"
          require "phlex/rails"
          Request.include(RequestHeaders)
          # Built once: a new ActionView::Base subclass and resolvers per request cost more than the render.
          app.set(:phlex_view_context_class, ::ActionView::Base.with_empty_template_cache)
          app.set(:phlex_view_paths, ::ActionView::PathSet.new(view_paths))
        end
        app.set(:phlex_rails, rails)
        app.helpers(Methods)
      end
    end
  end
end
