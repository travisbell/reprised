# frozen_string_literal: true

RSpec.describe Reprised::Negotiation do
  def accept(header) = described_class.parse_accept(header)

  describe ".parse_accept" do
    it "orders media ranges by quality, then specificity, then parameters" do
      types = accept("*/*;q=0.8, text/*, application/json;q=0.9, text/html;level=1, text/html").map(&:type)

      expect(types).to eq(["text/html", "text/html", "text/*", "application/json", "*/*"])
    end

    it "keeps ranges of equal priority in header order" do
      expect(accept("text/html,application/xhtml+xml,image/webp").map(&:type))
        .to eq(["text/html", "application/xhtml+xml", "image/webp"])
    end

    it "accepts anything when the header is missing or empty" do
      expect(accept(nil).map(&:type)).to eq(["*/*"])
      expect(accept("").map(&:type)).to eq(["*/*"])
    end

    it "reads quoted parameters" do
      expect(accept('text/html;profile="a\"b";q=0.5').first)
        .to have_attributes(type: "text/html", params: { "profile" => 'a"b' }, q: 0.5)
    end
  end

  describe ".preferred_type" do
    it "picks the first type the best media range accepts" do
      browser = accept("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")

      expect(described_class.preferred_type(browser, ["application/json"])).to eq("application/json")
      expect(described_class.preferred_type(browser, ["application/json", "text/html"])).to eq("text/html")
    end

    it "matches wildcards" do
      expect(described_class.preferred_type(accept("text/*"), ["application/json", "text/csv"])).to eq("text/csv")
    end

    it "returns nil when nothing is acceptable" do
      expect(described_class.preferred_type(accept("text/html"), ["application/json"])).to be_nil
    end

    it "returns the first type for a header with no media ranges" do
      expect(described_class.preferred_type(accept("garbage"), ["application/json"])).to eq("application/json")
    end
  end

  describe ".mime_types" do
    it "resolves extensions and pairs XML and JavaScript types, as Sinatra does" do
      expect(described_class.mime_types(:json)).to eq(["application/json"])
      expect(described_class.mime_types("html")).to eq(["text/html"])
      expect(described_class.mime_types(:js)).to eq(["text/javascript", "application/javascript"])
      expect(described_class.mime_types("application/merge-patch+json")).to eq(["application/merge-patch+json"])
    end
  end
end
