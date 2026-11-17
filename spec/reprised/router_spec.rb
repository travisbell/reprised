# frozen_string_literal: true

RSpec.describe Reprised::Router do
  def router(matcher: :index, &block)
    described_class.new(matcher:).tap do |router|
      router.instance_exec(&block)
      router.finalize!
    end
  end

  def values(router, path, lane: "GET") = router.each(lane, path).map { |value, _| value }

  describe "with the index matcher" do
    it "yields every match in definition order, as Sinatra tries routes" do
      routes = router do
        add("GET", "/movie/:id", :show)
        add("GET", "/movie/new", :new)
        add("GET", "/*", :catch_all)
        add("GET", "/movie/:id/?", :show_slash)
      end

      expect(values(routes, "/movie/new")).to eq([:show, :new, :catch_all, :show_slash])
      expect(values(routes, "/movie/new/")).to eq([:catch_all, :show_slash])
    end

    it "returns Sinatra's params" do
      routes = router do
        add("GET", "/movie/:id", :show)
        add("GET", "/tv/:id/edit/?*", :tv_edit)
        add("GET", "/a/:b?", :optional)
      end

      expect(routes.each("GET", "/movie/caf%C3%A9").to_a).to eq([[:show, { "id" => "café" }]])
      expect(routes.each("GET", "/tv/1/edit/images/posters").to_a)
        .to eq([[:tv_edit, { "id" => "1", "splat" => ["images/posters"] }]])
      expect(routes.each("GET", "/a/").to_a).to eq([[:optional, { "b" => nil }]])
    end

    it "matches the patterns Mustermann 4.0.1's trie misses" do
      routes = router do
        add("GET", "/account/?", :optional_slash)
        add("GET", "/account/*", :empty_splat)
        add("GET", "/movie/:id.json", :suffix)
      end

      expect(values(routes, "/account")).to eq([:optional_slash])
      expect(values(routes, "/account/")).to eq([:optional_slash, :empty_splat])
      expect(values(routes, "/movie/550")).to eq([])
      expect(routes.each("GET", "/movie/550.json").to_a).to eq([[:suffix, { "id" => "550" }]])
    end

    it "orders regexp patterns among the others by definition" do
      routes = router do
        add("GET", "/tv/:id", :tv)
        add("GET", %r{/tv/season/([0-9]+)(.*)}, :season_redirect)
        add("GET", "/tv/season/:number", :season)
      end

      expect(routes.each("GET", "/tv/season/2").to_a)
        .to eq([[:season_redirect, { "captures" => ["2", ""] }], [:season, { "number" => "2" }]])
      expect(values(routes, "/tv/season")).to eq([:tv])
    end

    it "gives regexp patterns their named and positional captures" do
      routes = router { add("GET", %r{/invites/(?<code>[^/]+)/(?:accept|decline)}, :invite) }

      expect(routes.each("GET", "/invites/abc%20d/accept").to_a)
        .to eq([[:invite, { "code" => "abc d", "captures" => ["abc d"] }]])
    end

    it "matches an Array of patterns once, at its first matching pattern" do
      routes = router do
        add(:before, ["/team/?", "/team/*"], :team)
        add(:before, /.*/, :everything)
      end

      expect(routes.each(:before, "/team/").to_a).to eq([[:team, {}], [:everything, {}]])
      expect(routes.each(:before, "/team/2024").to_a).to eq([[:team, { "splat" => ["2024"] }], [:everything, {}]])
    end

    it "tries every pattern for a percent-encoded path, which Mustermann matches against literals" do
      routes = router { add("GET", "/movie/:id", :show) }

      expect(values(routes, "/m%6Fvie/550")).to eq([:show])
    end

    it "treats an empty path as /" do
      routes = router { add("GET", "/", :root) }

      expect(values(routes, "")).to eq([:root])
    end

    it "keeps lanes apart" do
      routes = router do
        add("GET", "/movie/:id", :get)
        add("POST", "/movie/:id", :post)
      end

      expect(values(routes, "/movie/1", lane: "POST")).to eq([:post])
      expect(values(routes, "/movie/1", lane: "DELETE")).to eq([])
      expect(routes.lanes).to eq(["GET", "POST"])
    end

    it "matches simple patterns by segment exactly as Mustermann does" do
      patterns = [
        "/", "/movie", "/movie/", "/movie/?", "/movie/:id", "/movie/:id/?", "/movie/:id/cast", "/tv/:id/season/:number/?",
        "/manifest.json", "/a/:b/:c", "/a/:id/b/:id", "/:slug", "/u/:user_name-x"
      ]
      paths = [
        "/", "//", "/movie", "/movie/", "/movie//", "/movie/550", "/movie/550/", "/movie/550/cast", "/movie/550/cast/",
        "/movie/5.5", "/tv/1/season/2", "/tv/1/season/2/", "/tv//season/2", "/manifest.json", "/manifestxjson",
        "/a/1/2", "/a/1/b/2", "/caf%C3%A9", "/movie/caf%C3%A9", "/movie/a?b", "/MOVIE/1", "movie/1", "",
        # Percent-encoded: literals in their encoded forms, params decoded (an encoded "/" staying in its segment)
        "/m%6Fvie/550", "/m%6fvie/550/c%61st", "/movie/a%2Fb", "/movie/550%2F", "/movie%2F550", "/movie/%zz", "/movie/%",
        "/movie/a%20b/cast", "/t%76/1/season/2/", "/movie/550%23x", "/movie/550#x", "/u/b%6Fb-x"
      ]
      patterns.each do |pattern|
        # Mustermann 3 refuses some (a repeated capture name); there's nothing to compare for those.
        next unless (Mustermann.new(pattern) rescue nil)

        routes = router { add("GET", pattern, pattern) }
        paths.each do |path|
          expected = Mustermann.new(pattern).params(path.empty? ? "/" : path)
          expect(routes.each("GET", path).to_a.dig(0, 1)).to eq(expected), "#{pattern} on #{path.inspect}"
        end
      end
    end

    it "builds no Mustermann pattern for a simple pattern, only for the others" do
      routes = router do
        add("GET", "/movie/:id/?", :show)
        add("GET", "/files/*", :files)
      end
      candidates = routes.instance_variable_get(:@lanes)["GET"].instance_variable_get(:@all)

      expect(candidates.map { it.pattern.class }).to eq([Reprised::Router::SimplePattern, Mustermann::Sinatra])
    end

    it "matches a filter without a path everywhere" do
      routes = router { add(:before, Reprised::Router::EVERY_PATH, :everywhere) }

      expect(routes.each(:before, "/anything/at/all").to_a).to eq([[:everywhere, {}]])
      expect(routes.each(:before, "").to_a).to eq([[:everywhere, {}]])
    end

    it "indexes past params, and finds every pattern when a segment could be a literal or a param" do
      routes = router do
        add("GET", "/movie/:id", :show)
        add("GET", "/movie/popular", :popular)
        add("GET", "/movie/:id/cast", :cast)
        add("GET", "/movie/popular/cast", :popular_cast)
        add("GET", "/movie/:id/?", :show_slash)
        add("GET", "/movie/*", :splat)
      end

      expect(values(routes, "/movie/popular")).to eq([:show, :popular, :show_slash, :splat])
      expect(values(routes, "/movie/popular/")).to eq([:show_slash, :splat])
      expect(values(routes, "/movie/popular/cast")).to eq([:cast, :popular_cast, :splat])
      expect(values(routes, "/movie/550/cast")).to eq([:cast, :splat])
      expect(values(routes, "/movie/")).to eq([:splat])
    end

    it "indexes a regexp by the literal segments it starts with, and only those" do
      routes = router do
        add("GET", %r{/preferences/(.*)}, :preferences)
        add("GET", %r{/newsletter/?(.*)}, :newsletter)
        add("GET", %r{/a|/b/(.*)}, :alternation)
      end

      expect(values(routes, "/preferences/profile")).to eq([:preferences])
      lane = routes.instance_variable_get(:@lanes)["GET"]
      expect(lane.instance_variable_get(:@root).candidates.map { it.entry.value }).to eq([:newsletter, :alternation])
      expect(values(routes, "/preferencesx")).to eq([])
      expect(values(routes, "/newsletters")).to eq([:newsletter])
      expect(values(routes, "/a")).to eq([:alternation])
    end

    it "finds segments by byte in a path with multibyte characters" do
      routes = router do
        add("GET", "/person/:name/credits", :credits)
        add("GET", "/person/:name", :person)
      end

      expect(routes.each("GET", "/person/café/credits").to_a).to eq([[:credits, { "name" => "café" }]])
      expect(routes.each("GET", "/person/café".b).to_a.map(&:first)).to eq([:person])
    end

    it "only indexes literal segments" do
      routes = router do
        add("GET", "/movie/new?", :optional_char)
        add("GET", "/movie(/:id)?", :optional_group)
        add("GET", "/movie/:id/cast", :cast)
      end

      expect(values(routes, "/movie/ne")).to eq([:optional_char, :optional_group])
      expect(values(routes, "/movie/new")).to eq([:optional_char, :optional_group])
      expect(values(routes, "/movie")).to eq([:optional_group])
      expect(values(routes, "/movie/5/cast")).to eq([:cast])
    end
  end

  describe "#find" do
    it "returns the first match the block accepts, trying the rest when it doesn't" do
      routes = router do
        add("GET", "/movie/:id", :html)
        add("GET", "/movie/:id", :json)
      end

      expect(routes.find("GET", "/movie/1") { |value, _| value == :json }).to eq([:json, { "id" => "1" }])
      expect(routes.find("GET", "/movie/1") { false }).to be_nil
      expect(routes.find("GET", "/nope") { true }).to be_nil
    end

    it "stops at the first accepted match" do
      routes = router do
        add("GET", "/movie/:id", :first)
        add("GET", "/movie/:id", :second)
      end
      tried = []

      routes.find("GET", "/movie/1") { |value, _| tried << value }

      expect(tried).to eq([:first])
    end
  end

  it "can't be changed once finalized" do
    routes = router { add("GET", "/", :root) }

    expect { routes.add("GET", "/x", :x) }.to raise_error(FrozenError)
  end

  it "shares a lane that has the same patterns and values as another, in the same order" do
    movie = "/movie/:id"
    routes = router do
      add("GET", movie, :show)
      add("HEAD", movie, :show)
      add("GET", "/movie", :index)
      add("HEAD", "/movie", :index)
    end
    lanes = routes.instance_variable_get(:@lanes)

    expect(lanes["HEAD"]).to be(lanes["GET"])
    expect(values(routes, "/movie/550", lane: "HEAD")).to eq([:show])
  end

  it "keeps a lane of its own when it differs from the others" do
    routes = router do
      add("GET", "/movie/:id", :show)
      add("HEAD", "/movie/:id", :show)
      add("HEAD", "/movie/:id", :head_only)
    end
    lanes = routes.instance_variable_get(:@lanes)

    expect(lanes["HEAD"]).not_to be(lanes["GET"])
    expect(values(routes, "/movie/550", lane: "HEAD")).to eq([:show, :head_only])
    expect(values(routes, "/movie/550", lane: "GET")).to eq([:show])
  end

  it "rejects unknown matchers" do
    expect { described_class.new(matcher: :linear) }.to raise_error(ArgumentError, /unknown matcher/)
  end

  describe "with the trie matcher", if: Gem.loaded_specs["mustermann"].version >= Gem::Version.new("4") do
    it "yields matches in definition order" do
      routes = router(matcher: :trie) do
        add("GET", "/movie/:id", :show)
        add("GET", "/movie/new", :new)
        add("GET", %r{/movie/.*}, :regexp)
        add("GET", "/*", :catch_all)
      end

      expect(values(routes, "/movie/new")).to eq([:show, :new, :regexp, :catch_all])
    end
  end
end
