# frozen_string_literal: true

RSpec.describe Reprised::MustermannFixes, if: Gem.loaded_specs["mustermann"].version >= Gem::Version.new("4") do
  it "fixes the trie's fast path for a capture followed by more pattern" do
    described_class.apply!
    set = Mustermann::Set.new(use_trie: true, use_cache: false)
    set.add("/movie/:id.json", :json)
    set.add("/movie/:id/?", :html)

    expect(set.match_all("/movie/550").map(&:value)).to eq([:html])
    expect(set.match_all("/movie/550/").map(&:value)).to eq([:html])
    expect(set.match("/movie/550.json")).to have_attributes(value: :json, params: { "id" => "550" })
    expect(described_class.trie_fast_path_broken?).to be(false)
  end
end
