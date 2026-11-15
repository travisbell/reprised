# frozen_string_literal: true

class Demos
  module Components
    # A small label, rendered from Phlex components and from ERB (`<%= render Components::Badge.new("Comedy") %>`).
    class Badge < Phlex::HTML
      def initialize(text, tone: :plain)
        @text = text
        @tone = tone
      end

      def view_template
        span(class: "badge badge-#{@tone}") { @text }
      end
    end
  end
end
