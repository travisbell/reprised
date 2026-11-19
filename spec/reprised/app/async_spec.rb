# frozen_string_literal: true

RSpec.describe "Reprised.current and streaming" do
  it "is the request scope during the request, and nil after" do
    mock_app do
      before { response["x-filter"] = Reprised.current.equal?(self).to_s }
      get("/") { erb "<%= Reprised.current.equal?(self) %>" }
    end

    get "/"

    expect([body, response_headers["x-filter"]]).to eq(["true", "true"])
    expect(Reprised.current).to be_nil
  end

  it "follows the scope into the matched route's controller" do
    movies = Class.new(Reprised::Controller) { get("/movie") { Reprised.current.class.equal?(self.class).to_s } }
    mock_app { mount movies }

    get "/movie"

    expect(body).to eq("true")
  end

  it "streams a body the block writes, with the request's params" do
    mock_app do
      get("/count/:to") do
        stream do |out|
          1.upto(params[:to].to_i) { out << "#{it}," }
          out << Reprised.current.class.name.to_s.empty?.to_s
        end
      end
    end

    get "/count/3"

    expect(body).to eq("1,2,3,true")
    expect(response_headers).not_to include("content-length")
  end

  it "ends a stream's block when the client has gone, as Falcon reports it, without raising" do
    require "protocol/http/error"
    written = []
    mock_app do
      get("/events") do
        event_stream do |sse|
          loop do
            sse.comment("tick")
            written << :tick
          end
        ensure
          written << :ended
        end
      end
    end
    gone = Object.new
    gone.define_singleton_method(:write) { |_data| raise Protocol::HTTP::RemoteError, "Remote connection closed during flush!" }
    gone.define_singleton_method(:close) { raise Protocol::HTTP::RemoteError, "Remote connection closed!" }

    _status, _headers, stream = app.call(Rack::MockRequest.env_for("/events"))

    expect { stream.call(gone) }.not_to raise_error
    expect(written).to eq([:ended])
  end

  it "streams Server-Sent Events" do
    mock_app do
      get("/events") do
        event_stream(retry_after: 2000) do |sse|
          sse.event(:update, { id: 550 }, id: 1)
          sse.data("line one\nline two")
          sse.comment("keepalive")
        end
      end
    end

    get "/events"

    expect(response_headers["content-type"]).to eq("text/event-stream;charset=utf-8")
    expect(response_headers["cache-control"]).to eq("no-cache")
    expect(body).to eq(
      "retry: 2000\n\n" \
      "id: 1\nevent: update\ndata: {\"id\":550}\n\n" \
      "data: line one\ndata: line two\n\n" \
      ": keepalive\n\n"
    )
  end

  it "keeps an event's data to its data lines, whatever line breaks it holds" do
    mock_app do
      get("/events") do
        event_stream do |sse|
          sse.data("hello\revent: admin\rdata: injected")
          sse.data("crlf\r\nevent: admin")
          sse.comment("one\rtwo\nthree")
          sse.comment
        end
      end
    end

    get "/events"

    expect(body).to eq(
      "data: hello\ndata: event: admin\ndata: data: injected\n\n" \
      "data: crlf\ndata: event: admin\n\n" \
      ": one\n: two\n: three\n\n" \
      ": \n\n"
    )
  end

  it "won't send an event name or id with a line break, which would add fields of its own" do
    events = Reprised::EventStream.new(+"")

    expect { events.event("update\nevent: admin", "x") }.to raise_error(ArgumentError, /name can't contain a line break/)
    expect { events.event(:update, "x", id: "1\rdata: evil") }.to raise_error(ArgumentError, /id can't contain/)
    expect { events.event(:update, "x", id: "1\0") }.to raise_error(ArgumentError, /line break or null byte/)
  end

  it "runs a route with a timeout without one, and warns, outside an Async server" do
    Reprised::RouteTimeout.instance_variable_set(:@warned, nil)
    mock_app { get("/slow", timeout: 0.01) { "done" } }

    expect { get "/slow" }.to output(/route timeouts need an Async server/).to_stderr
    expect(body).to eq("done")
  end
end
