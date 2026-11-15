# frozen_string_literal: true

class Demos
  # Server-Sent Events: event_stream sets the headers, and its block sends events until it returns or the client goes.
  class EventsDemo < Reprised::Controller
    STEPS = ["Finding the reels", "Restoring the frames", "Adding the score", "Writing the subtitles"].freeze

    get "/events" do
      @title = "Server-Sent Events"
      erb :events
    end

    # A clock, an event a second, until the browser goes away. Each event has an id, and a browser that reconnects
    # sends the last it had (Last-Event-ID), so the count carries on. retry_after: is how long it waits to reconnect.
    get "/events/clock" do
      tick = Integer(env.fetch("HTTP_LAST_EVENT_ID", "0"), exception: false) || 0
      event_stream(retry_after: 1000) do |sse|
        loop do
          tick += 1
          sse.event(:tick, { tick:, time: Time.now.strftime("%H:%M:%S") }, id: tick) # Data that isn't a String is JSON.
          sleep(1)
        end
      end
    end

    # A job's progress, then a done event, which tells the page to close the stream.
    get "/events/progress" do
      event_stream do |sse|
        0.step(100, 5) do |percent|
          sse.event(:progress, { percent:, step: STEPS[[percent * STEPS.size / 100, STEPS.size - 1].min] })
          sleep(0.15)
        end
        sse.event(:done, "Restored")
      end
    end
  end
end
