# frozen_string_literal: true

require "action_view"

module Reprise
  module Plugins
    # ActionView's helpers in Reprise templates: `form_tag`, `tag.div`, `number_to_human`, and the rest.
    #
    #   plugin Reprise::Plugins::ActionView, helpers: [
    #     ActionView::Helpers::TagHelper, ActionView::Helpers::FormTagHelper, ActionView::Helpers::NumberHelper
    #   ]
    #
    # ERB templates then write to an ActionView output buffer in @output_buffer, so helpers that capture a block
    # (`<%= form_tag(path) do %>...<% end %>`) get the block's output, and their output isn't escaped twice. The
    # helpers are global: the app and all its controllers have them.
    module ActionView
      # An ActionView::OutputBuffer that Erubi's CaptureBlockEngine can write to: `<%= %>` appends as is (templates
      # don't escape by default, as in Sinatra) and `<%== %>` escapes.
      class Buffer < ::ActionView::OutputBuffer
        def |(other)
          @raw_buffer << h(other)
          self
        end

        def <<(value)
          @raw_buffer << value.to_s unless value.nil?
          self
        end

        private

        define_method(:h, ::Erubi.instance_method(:h))
      end

      # What ActionView's helpers expect of the object they're mixed into.
      module Context
        attr_accessor :output_buffer
      end

      def self.install(app, helpers: [])
        app.set(:erb, { engine_class: Erubi::CaptureBlockEngine, bufval: "::Reprise::Plugins::ActionView::Buffer.new", bufvar: "@output_buffer" })
        app.helpers(Context, *helpers)
      end
    end
  end
end
