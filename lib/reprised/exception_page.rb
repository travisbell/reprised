# frozen_string_literal: true

require "erubi"
require "ipaddr"
require "json"

module Reprised
  # The development exception page, shown for a 5xx's exception when the show_exceptions setting is on (as it is in
  # development): the exception and its causes, the backtrace with the source around each of the app's frames, the local
  # variables where it was raised, and the request. Clients that don't take HTML (XHR, JSON) get it as plain text.
  #
  # Local variables come from a TracePoint on :raise, enabled once an app with show_exceptions is finalized, which keeps
  # the binding of the frame each exception is raised in.
  class ExceptionPage
    TEMPLATE = File.join(__dir__, "exception_page.html.erb")
    # Context shown around a frame's line.
    SOURCE_LINES = 6
    # Longest an inspected value is shown.
    MAX_INSPECT = 600
    # Params, headers, and cookies whose values are masked.
    SENSITIVE = /pass(word)?|secret|token|api_?key|auth|cookie|session|csrf|otp/i
    EDITORS = {
      vscode: "vscode://file%{file}:%{line}",
      cursor: "cursor://file%{file}:%{line}",
      zed: "zed://file%{file}:%{line}",
      rubymine: "x-mine://open?file=%{file}&line=%{line}",
      textmate: "txmt://open?url=file://%{file}&line=%{line}",
      sublime: "subl://open?url=file://%{file}&line=%{line}",
      macvim: "mvim://open?url=file://%{file}&line=%{line}"
    }.freeze
    LOOPBACK = ["127.0.0.0/8", "::1/128"].freeze

    Frame = Data.define(:path, :line, :label, :app) do
      def to_s = "#{path}:#{line}:in '#{label}'"
    end

    class << self
      # Keeps the binding each exception is raised in (its frame's local variables), from now on. Idempotent.
      def capture_bindings!
        @capture ||= TracePoint.new(:raise) do |trace|
          error = trace.raised_exception
          next if error.frozen? || error.instance_variable_defined?(:@__reprised_binding)

          error.instance_variable_set(:@__reprised_binding, trace.binding)
        end
        @capture.enable unless @capture.enabled?
      end

      # Whether +env+'s client (REMOTE_ADDR, not a forwarded address a client could set) is one of +allowed+.
      def allowed?(env, allowed)
        address = IPAddr.new(env["REMOTE_ADDR"].to_s)
        address = address.native
        allowed.any? { it.include?(address) }
      rescue IPAddr::Error
        false
      end

      def ranges(addresses) = Array(addresses).map { IPAddr.new(it.to_s) }.freeze

      # The page's compiled template.
      def template
        @template ||= begin
          source = Erubi::Engine.new(File.read(TEMPLATE), escape: true, bufvar: "@_out", freeze: true).src
          Class.new { class_eval("def render(page); #{source}; end", TEMPLATE, 0) }.new
        end
      end
    end

    attr_reader :exception, :scope

    def initialize(exception, scope, root:, editor: nil)
      @exception = exception
      @scope = scope
      @root = File.expand_path(root.to_s)
      @editor = editor.is_a?(Symbol) ? EDITORS.fetch(editor) { raise ArgumentError, "unknown editor #{editor.inspect}: use #{EDITORS.keys.join(", ")}, or a URL template" } : editor
    end

    # The body and its content type: HTML for a browser, plain text for anything else.
    def render(request)
      return [text, "text/plain"] if request.xhr? || !accepts_html?(request)

      [ExceptionPage.template.render(self), "text/html"]
    end

    def env = scope.env
    def request = scope.request
    def route = env["reprised.route"]

    # The exception and its causes, outermost first.
    def chain
      chain = []
      error = exception
      while error && chain.size < 10 && !chain.include?(error)
        chain << error
        error = error.cause
      end
      chain
    end

    def message(error)
      error.detailed_message(highlight: false)
    rescue StandardError
      error.message.to_s
    end

    def frames(error)
      locations = error.backtrace_locations
      return locations.map { frame(it.absolute_path || it.path, it.lineno, it.label) } if locations

      Array(error.backtrace).map { |line| frame(*line.match(/\A(.+?):(\d+)(?::in [`'](.*)')?\z/)&.captures || [line, 0, nil]) }
    end

    def frame(path, line, label) = Frame.new(path: path.to_s, line: line.to_i, label: label.to_s, app: app_file?(path.to_s))

    # The lines around +frame+'s, as [number, text], or nil without a readable file.
    def source(frame)
      return unless frame.line.positive? && File.file?(frame.path) && File.size(frame.path) < 2_000_000

      lines = File.readlines(frame.path, chomp: true)
      first = [frame.line - SOURCE_LINES, 1].max
      last = [frame.line + SOURCE_LINES, lines.size].min
      (first..last).map { [it, lines[it - 1]] }
    rescue SystemCallError, ArgumentError
      nil
    end

    def relative(path) = path.start_with?("#{@root}/") ? path.delete_prefix("#{@root}/") : path

    def editor_url(frame)
      return unless @editor && frame.path.start_with?("/")

      format(@editor, file: frame.path, line: frame.line)
    end

    # The local variables (and self's instance variables) where +error+ was raised, as [name, inspected value]. None for
    # an exception raised inside Ruby (<internal:...>, as Integer() is): those are its variables, not the app's.
    def locals(error)
      binding = binding_for(error)
      return [] unless binding && !binding.source_location&.first.to_s.start_with?("<internal:")

      receiver = binding.receiver
      variables = binding.local_variables.map { [it.to_s, inspect_value(binding.local_variable_get(it))] }
      variables + instance_variables(receiver).map { [it.to_s, inspect_value(receiver.instance_variable_get(it))] }
    rescue StandardError
      []
    end

    # Where the exception was raised, as the binding saw it: its file and line.
    def raised_at(error) = binding_for(error)&.source_location

    def params = masked(scope.params.to_h)

    # The params as JSON, with values JSON can't hold (an upload's Tempfile) inspected.
    def params_text = JSON.pretty_generate(jsonable(params))
    def headers = masked(env.select { |key, _| key.start_with?("HTTP_") }.to_h { |key, value| [key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-"), value] })

    def session_keys
      session = env["rack.session"]
      session.respond_to?(:keys) ? session.keys.map(&:to_s) : []
    rescue StandardError
      []
    end

    # The env apart from the headers (shown already), with secrets masked: the session and cookies, and sensitive params
    # in the query string and the parsed params.
    def rack_env
      env.reject { |key, _| key.start_with?("HTTP_") }.sort_by(&:first).map do |key, value|
        [key, key.match?(SENSITIVE) ? "[masked]" : inspect_value(masked_value(key, value))]
      end
    end

    # The request's URL, with sensitive params in its query masked.
    def url = masked_query(request.url)

    def inspect_value(value)
      text = value.inspect
      text.length > MAX_INSPECT ? "#{text[0, MAX_INSPECT]}…" : text
    rescue Exception => error
      "#<#{value.class} (inspect raised #{error.class})>"
    end

    # Everything on the page, as plain text: for clients that don't take HTML, and the page's Copy button.
    def text
      out = +""
      chain.each_with_index do |error, index|
        out << (index.zero? ? "" : "\nCaused by: ") << "#{error.class}: #{message(error)}\n"
        frames(error).each { out << "  #{it}\n" }
      end
      out << "\n#{request.request_method} #{url}"
      out << "\nRoute: #{route} (#{route.owner}#{" #{route.source_location&.join(":")}" if route.source_location})" if route
      if (variables = locals(exception)).any?
        out << "\n\nLocal variables:\n"
        variables.each { |name, value| out << "  #{name} = #{value}\n" }
      end
      out << "\nParams: #{params_text}\n" unless params.empty?
      out
    end

    private

    def accepts_html?(request)
      accept = request.get_header("HTTP_ACCEPT").to_s
      accept.empty? || accept.include?("text/html") || accept.include?("*/*") && !accept.include?("application/json")
    end

    # A file of the app's own: under the root, but not a gem's.
    def app_file?(path)
      path.start_with?("#{@root}/") && !path.include?("/vendor/") && !path.include?("/gems/") && !path.include?("/bundler/")
    end

    def binding_for(error)
      error.instance_variable_get(:@__reprised_binding) if error.instance_variable_defined?(:@__reprised_binding)
    end

    # The receiver's instance variables, apart from a request scope's own (its env, request, response, and params).
    def instance_variables(receiver)
      names = receiver.instance_variables.reject { it.to_s.start_with?("@_") }
      receiver.is_a?(Controller) ? names - Controller::STATE : names
    end

    def jsonable(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, jsonable(item)] }
      when Array then value.map { jsonable(it) }
      when String, Numeric, true, false, nil then value
      else inspect_value(value)
      end
    end

    # +query+ (or a URL) with the values of sensitive params masked.
    def masked_query(query)
      query.gsub(/([^&=?]+)=([^&]*)/) { (key = Regexp.last_match(1)).match?(SENSITIVE) ? "#{key}=[masked]" : Regexp.last_match(0) }
    end

    def masked(hash)
      hash.to_h do |key, value|
        key = key.to_s
        [key, key.match?(SENSITIVE) ? "[masked]" : masked_value(key, value)]
      end
    end

    def masked_value(key, value)
      if value.is_a?(Hash) then masked(value)
      elsif value.is_a?(String) && key.match?(/QUERY_STRING|REQUEST_URI|query_string/) then masked_query(value)
      else value
      end
    end
  end
end
