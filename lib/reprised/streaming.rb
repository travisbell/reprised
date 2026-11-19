# frozen_string_literal: true

require "json"

module Reprised
  # A streaming response body (Rack 3): the server calls it with the connection's stream once the response headers
  # are sent, and the block writes to it as it goes. Falcon sends each write as it's made.
  class Stream
    # What the block writes to.
    class Writer
      def initialize(stream)
        @stream = stream
        @closed = false
      end

      def <<(data)
        write(data)
        self
      end

      def write(data)
        @stream.write(data.to_s)
        @stream.flush if @stream.respond_to?(:flush)
      rescue StandardError => error
        raise unless Writer.disconnected?(error)

        @closed = true
        raise ClientDisconnected
      end

      def close
        return if @closed

        @closed = true
        @stream.close
      rescue StandardError => error
        raise unless Writer.disconnected?(error)
      end

      # Whether +error+ says the client has gone: a closed or reset socket, or under Falcon, protocol-http's
      # RemoteError ("Remote connection closed during flush!").
      def self.disconnected?(error)
        error.is_a?(IOError) || error.is_a?(Errno::EPIPE) || error.is_a?(Errno::ECONNRESET) ||
          (defined?(::Protocol::HTTP::RemoteError) && error.is_a?(::Protocol::HTTP::RemoteError)) || false
      end

      def closed? = @closed
    end

    # Raised in the stream's block when the client has gone away, ending the block. Rescued by the stream.
    class ClientDisconnected < StandardError; end

    def initialize(scope, &block)
      @scope = scope
      @params = scope.params.dup
      @block = block
    end

    def call(stream)
      writer = Writer.new(stream)
      Reprised.with_current(@scope) do
        @scope.instance_variable_set(:@params, @params)
        @block.call(writer)
      end
    rescue ClientDisconnected
      nil
    ensure
      writer&.close
    end
  end

  # Server-Sent Events, written to a Stream: `sse.event(:update, data)`.
  class EventStream
    # A client ends a line at "\r\n", "\n", or a "\r" on its own, so a field's value can't hold any of them: one would
    # start another field, or another event.
    LINE_BREAK = /[\r\n]/
    ID_BREAK = /[\r\n\0]/ # A client ignores an id with a null byte.
    private_constant :LINE_BREAK, :ID_BREAK

    def initialize(writer)
      @writer = writer
    end

    # Sends an event. +data+ that isn't a String is sent as JSON; a multi-line String becomes several data lines (split
    # at every line break a client reads as one, a lone "\r" included). A +name+ or +id+ with a line break raises an
    # ArgumentError, since it would let whoever chose it add fields or events of their own.
    def event(name = nil, data = nil, id: nil)
      message = +""
      message << "id: #{field(id, ID_BREAK, :id)}\n" if id
      message << "event: #{field(name, LINE_BREAK, :name)}\n" if name
      each_line(data.is_a?(String) ? data : JSON.generate(data)) { message << "data: #{it}\n" }
      @writer << message << "\n"
      self
    end

    def data(data, id: nil) = event(nil, data, id:)

    # A comment, which clients ignore: useful to keep the connection open through proxies. A multi-line one becomes
    # several comment lines.
    def comment(text = "")
      message = +""
      each_line(text.to_s) { message << ": #{it}\n" }
      message << ": \n" if message.empty?
      @writer << message << "\n"
      self
    end

    # How long the client waits before reconnecting, in milliseconds.
    def retry(milliseconds)
      @writer << "retry: #{Integer(milliseconds)}\n\n"
      self
    end

    def closed? = @writer.closed?

    private

    # Yields +text+'s lines, as String#each_line(chomp: true) does, with a lone "\r" ending a line too.
    def each_line(text, &)
      text.each_line(chomp: true) { |line| line.include?("\r") ? line.split("\r", -1).each(&) : yield(line) }
    end

    def field(value, breaks, name)
      value = value.to_s
      return value unless breaks.match?(value)

      raise ArgumentError, "an event's #{name} can't contain a line break#{" or null byte" if name == :id}: #{value.inspect}"
    end
  end

  module Helpers
    # Streams the response as the block writes it: `stream { |out| out << "chunk" }`. The block runs after the
    # route returns, when the server sends the body, with this request's params and Reprised.current. It ends when the
    # block returns or the client disconnects. (Sinatra's keep_open has no Rack 3 equivalent: to keep a stream open,
    # keep the block running.)
    def stream(_keep_open = false, &block)
      body(Stream.new(self, &block))
    end

    # Streams Server-Sent Events: `event_stream { |sse| sse.event(:update, data) }`.
    def event_stream(retry_after: nil, &block)
      content_type("text/event-stream")
      cache_control(:no_cache)
      headers["x-accel-buffering"] = "no" # nginx: don't buffer the stream
      stream do |writer|
        events = EventStream.new(writer)
        events.retry(retry_after) if retry_after
        block.call(events)
      end
    end
  end
end
