# frozen_string_literal: true

require "json"
require "time"
require "rack/files"
require "rack/mime"
require "rack/utils"

module Reprise
  # Response helpers available in routes, filters, error handlers, and templates. Each behaves as its Sinatra (or
  # sinatra-contrib) namesake.
  module Helpers
    # Characters escaped in a Content-Disposition filename (https://html.spec.whatwg.org/#multipart-form-data).
    FILENAME_ESCAPES = { '"' => "%22", "\r" => "%0D", "\n" => "%0A" }.freeze

    NO_PARAMS = {}.freeze
    private_constant :NO_PARAMS

    # Stops processing and responds with +response+: a status, a body, [status, body], [status, headers, body], or
    # anything that responds to #each.
    def halt(*response)
      response = response.first if response.length == 1
      throw(:halt, response)
    end

    # Gives up on this route and tries the next one that matches. With a block, the block answers if nothing else does.
    def pass(&block)
      throw(:pass, block)
    end

    def status(value = nil)
      response.status = Rack::Utils.status_code(value) if value
      response.status
    end

    # Sets or returns the body. A block is evaluated lazily, when the body is read.
    def body(value = nil, &block)
      if block
        def block.each = yield(call)
        response.body = block
      elsif value
        unless headers.empty? || env["REQUEST_METHOD"] == "HEAD" || value.is_a?(Rack::Files::BaseIterator)
          headers.delete("content-length")
        end
        response.body = value
      else
        response.body
      end
    end

    def headers(hash = nil)
      response.headers.merge!(hash) if hash
      response.headers
    end

    # Redirects to +uri+ and halts: 303 for a non-GET HTTP/1.1 request, 302 otherwise, unless a status is given.
    # The Location is absolute, with the request's scheme and host, unless the absolute_redirects setting is off.
    def redirect(uri, *args)
      http_version = env["SERVER_PROTOCOL"] || env["HTTP_VERSION"]
      status(http_version == "HTTP/1.1" && env["REQUEST_METHOD"] != "GET" ? 303 : 302)
      response["location"] = uri(uri.to_s, settings.absolute_redirects?, settings.prefixed_redirects?)
      halt(*args)
    end

    # An absolute URL for +addr+ (default: the current path), taking proxies into account.
    def uri(addr = nil, absolute = true, add_script_name = true)
      return addr if addr.to_s.match?(/\A[a-z][a-z0-9+.-]*:/i)

      host = +""
      if absolute
        host << "http#{"s" if request.secure?}://"
        host << (request.forwarded? || request.port != (request.secure? ? 443 : 80) ? request.host_with_port : request.host)
      end
      parts = [host]
      parts << request.script_name.to_s if add_script_name
      parts << (addr || request.path_info).to_s
      File.join(parts)
    end
    alias_method :url, :uri
    alias_method :to, :uri

    # With no arguments, the exception being handled (in an error handler), or nil. With a status (and an optional
    # body), halts with it, as Sinatra's `error 403`.
    def error(code = nil, body = nil)
      return env["reprise.error"] if code.nil?

      if code.respond_to?(:to_str)
        body = code.to_str
        code = 500
      end
      response.body = body unless body.nil?
      halt(code)
    end

    def not_found(body = nil) = error(404, body)

    def session = request.session
    def logger = request.logger
    def cookies = @cookies ||= Cookies.new(request, response, settings)

    def mime_type(type) = Negotiation.mime_type(type)

    # Sets the content type from a media type or extension (:json, "text/csv"), adding the app's default charset to
    # text and a few other types (the add_charset setting). With no arguments, returns the current content type.
    def content_type(type = nil, params = NO_PARAMS)
      return response["content-type"] unless type
      # The same few types are set request after request: with no parameters, the header is worked out once per app.
      return response["content-type"] = settings.content_type_for(type) { build_content_type(type, {}) } if params.empty?

      response["content-type"] = build_content_type(type, params.dup)
    end

    private def build_content_type(type, params)
      default = params.delete(:default)
      media_type = mime_type(type) || default
      raise ArgumentError, format("Unknown media type: %p", type) if media_type.nil?

      media_type = media_type.dup
      unless params.include?(:charset) || settings.add_charset.none? { it === media_type }
        params[:charset] = params.delete("charset") || settings.default_encoding
      end
      params.delete(:charset) if media_type.include?("charset")
      unless params.empty?
        media_type << ";" << params.map { |key, value| "#{key}=#{value.to_s.match?(/[";,]/) ? value.inspect : value}" }.join(";")
      end
      media_type.freeze
    end

    # Sets Content-Disposition, and the content type from the filename's extension if none is set.
    def attachment(filename = nil, disposition = :attachment)
      response["content-disposition"] = disposition.to_s.dup
      return unless filename

      response["content-disposition"] << format('; filename="%s"', File.basename(filename).gsub(/["\r\n]/, FILENAME_ESCAPES))
      extension = File.extname(filename)
      content_type(extension) unless response["content-type"] || extension.empty?
    end

    # Halts with the file at +path+ as the body (ranges and HEAD included), or 404 if it doesn't exist.
    def send_file(path, opts = {})
      if opts[:type] || !response["content-type"]
        content_type(opts[:type] || File.extname(path), default: "application/octet-stream")
      end

      disposition = opts[:disposition]
      filename = opts[:filename]
      disposition = :attachment if disposition.nil? && filename
      filename = path if filename.nil?
      attachment(filename, disposition) if disposition
      response["last-modified"] = time_for(opts[:last_modified]).httpdate if opts[:last_modified]

      status, file_headers, file_body = Rack::Files.new(Dir.pwd).serving(request, path)
      file_headers.each { |key, value| headers[key] ||= value }
      headers["content-length"] = file_headers["content-length"]
      halt(opts[:status] ? Integer(opts[:status]) : status, file_body)
    rescue Errno::ENOENT
      not_found
    end

    # Sets Cache-Control from directives (:public, :no_cache) and values (max_age: 60).
    def cache_control(*values)
      if values.last.is_a?(Hash)
        hash = values.pop
        hash.reject! { |_key, value| value == false }
        hash.reject! { |key, value| values << key if value == true }
      else
        hash = {}
      end

      values.map! { it.to_s.tr("_", "-") }
      hash.each do |key, value|
        key = key.to_s.tr("_", "-")
        value = value.to_i if ["max-age", "s-maxage"].include?(key)
        values << "#{key}=#{value}"
      end

      response["cache-control"] = values.join(", ") if values.any?
    end

    # Sets Expires and Cache-Control max-age, +amount+ seconds (or until a Time) from now, plus any other directives.
    def expires(amount, *values)
      values << {} unless values.last.is_a?(Hash)

      if amount.is_a?(Integer)
        time = Time.now + amount
        max_age = amount
      else
        time = time_for(amount)
        max_age = time - Time.now
      end

      values.last.merge!(max_age:) { |_key, given, computed| given || computed }
      cache_control(*values)
      response["expires"] = time.httpdate
    end

    # Encodes +object+ as JSON with the json_encoder setting and sets the content type, as sinatra-contrib's json.
    def json(object, options = NO_PARAMS)
      content_type(options[:content_type] || settings.json_content_type)
      encoder = options[:json_encoder] || settings.json_encoder
      return encoder.encode(object) if encoder.respond_to?(:encode)
      return encoder.generate(object) if encoder.respond_to?(:generate)
      raise ArgumentError, "#{encoder} does not respond to #generate nor #encode" unless encoder.is_a?(Symbol)

      object.__send__(encoder)
    end

    def informational? = status.between?(100, 199)
    def success? = status.between?(200, 299)
    def redirect? = status.between?(300, 399)
    def client_error? = status.between?(400, 499)
    def server_error? = status.between?(500, 599)
    def not_found? = status == 404
    def bad_request? = status == 400

    private

    def time_for(value)
      if value.is_a?(Integer) then Time.at(value)
      elsif value.respond_to?(:to_time) then value.to_time
      else Time.parse(value.to_s)
      end
    end
  end
end
