# frozen_string_literal: true

require "rack/mock"

RSpec.describe Reprise::Request do
  def env_with(query) = Rack::MockRequest.env_for("/").merge("QUERY_STRING" => query.b)
  def query_params(query) = described_class.new(env_with(query)).GET
  def rack_params(query) = Rack::Request.new(env_with(query)).GET

  # Strings' encodings, which == ignores for ASCII strings.
  def encodings(value)
    case value
    when Hash then value.to_h { [encodings(it[0]), encodings(it[1])] }
    when Array then value.map { encodings(it) }
    when String then value.encoding
    else value
    end
  end

  it "parses query strings as Rack does, plain ones without Rack's parser" do
    queries = [
      "page=2", "language=en-US&page=2", "a=1&a=2", "flag", "flag&page=2", "a=b=c", "a=&b", "&&a=1&&", "a.b=1",
      "x~y=z", "list=1,2,3", "t=10:30", "a%20b=c", "a=b+c", "a=%E2%9C%93", "a[]=1&a[]=2", "a[b]=1", "a=1;b=2",
      "=1", "=", "a b=1", "café=1", "#{"a=1&" * 300}b=2"
    ]

    queries.each do |query|
      expect(query_params(query)).to eq(rack_params(query)), query.inspect
      expect(query_params(query).map { [encodings(it[0]), encodings(it[1])] })
        .to eq(rack_params(query).map { [encodings(it[0]), encodings(it[1])] }), query.inspect
    end
  end

  it "keeps the parsed params for later calls, as Rack does" do
    request = described_class.new(Rack::MockRequest.env_for("/?page=2"))

    expect(request.GET).to equal(request.GET)
    expect(request.env["rack.request.query_hash"]).to eq("page" => "2")
  end

  it "turns a query Rack can't parse into a BadRequest" do
    expect { query_params("a[]=1&a[b]=2") }.to raise_error(Reprise::BadRequest, /Invalid query parameters/)
  end
end
