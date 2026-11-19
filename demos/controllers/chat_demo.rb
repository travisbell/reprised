# frozen_string_literal: true

require "json"

class Demos
  # A chat room over WebSockets. A websocket route matches only upgrade requests, and its block runs, in the request's
  # scope, once the connection is open.
  class ChatDemo < Reprised::Controller
    # Everyone connected to this process. (The demos run one Falcon worker, so everyone shares it. An app with more would
    # broadcast through Redis or the like.)
    class Room
      def initialize
        @connections = Set.new
      end

      def size = @connections.size

      def join(connection)
        @connections << connection
        yield
      ensure
        @connections.delete(connection)
      end

      def broadcast(message)
        payload = JSON.generate(message)
        @connections.to_a.each do |connection|
          connection.write(payload)
          connection.flush
        rescue IOError, SystemCallError, Protocol::WebSocket::Error
          @connections.delete(connection)
        end
      end
    end

    ROOM = Room.new

    # Browsers send cookies with a WebSocket handshake from any site, so a websocket route turns away another site's
    # (Reprised::CSRF's cross-origin check, a 403).
    error(Reprised::CrossOriginRequest) { "Not from this site" }

    get "/chat" do
      @title = "WebSockets"
      erb :chat
    end

    websocket "/chat/socket" do |connection|
      name = params[:name].to_s.strip[0, 24]
      name = "Guest #{rand(100..999)}" if name.empty?
      ROOM.join(connection) do
        ROOM.broadcast(type: "joined", name:, count: ROOM.size)
        while (message = connection.read)
          text = message.to_str.strip[0, 500]
          ROOM.broadcast(type: "message", name:, text:) unless text.empty?
        end
      end
    ensure
      ROOM.broadcast(type: "left", name:, count: ROOM.size)
    end
  end
end
