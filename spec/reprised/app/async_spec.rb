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

  it "runs a route with a timeout without one, and warns, outside an Async server" do
    Reprised::RouteTimeout.instance_variable_set(:@warned, nil)
    mock_app { get("/slow", timeout: 0.01) { "done" } }

    expect { get "/slow" }.to output(/route timeouts need an Async server/).to_stderr
    expect(body).to eq("done")
  end
end
