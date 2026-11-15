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
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @closed = true
        raise ClientDisconnected
      end

      def close
        return if @closed

        @closed = true
        @stream.close
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        nil
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
    def initialize(writer)
      @writer = writer
    end

    # Sends an event. +data+ that isn't a String is sent as JSON; a multi-line String becomes several data lines.
    def event(name = nil, data = nil, id: nil)
      message = +""
      message << "id: #{id}\n" if id
      message << "event: #{name}\n" if name
      (data.is_a?(String) ? data : JSON.generate(data)).each_line(chomp: true) { message << "data: #{it}\n" }
      @writer << message << "\n"
      self
    end

    def data(data, id: nil) = event(nil, data, id:)

    # A comment line, which clients ignore: useful to keep the connection open through proxies.
    def comment(text = "")
      @writer << ": #{text}\n\n"
      self
    end

    # How long the client waits before reconnecting, in milliseconds.
    def retry(milliseconds)
      @writer << "retry: #{Integer(milliseconds)}\n\n"
      self
    end

    def closed? = @writer.closed?
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
