# frozen_string_literal: true

require "reprised/cli"
require "tmpdir"

RSpec.describe Reprised::CLI do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def write_app(name)
    File.write("app.rb", <<~RUBY)
      class #{name}MovieController < Reprised::Controller
        get("/movie/:id", provides: :json) { "" }
        get("/movie/:id") { "" }
      end

      class #{name} < Reprised::App
        get("/") { "" }
        mount #{name}MovieController
      end
    RUBY
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = described_class.start(args, out:, err:)
    [status, out.string, err.string]
  end

  it "lists the app's routes in order, with controller and source, from ./app.rb" do
    write_app("CliTableApp")

    status, out, = run_cli("routes", "CliTableApp")

    expect(status).to eq(0)
    expect(out).to eq(<<~TABLE)
      Verb  Pattern     Provides  Controller                  Source
      GET   /                     CliTableApp                 app.rb:7
      GET   /movie/:id  json      CliTableAppMovieController  app.rb:2
      GET   /movie/:id            CliTableAppMovieController  app.rb:3
      3 routes
    TABLE
  end

  it "prints one route per line with --format compact, and filters with --grep" do
    write_app("CliCompactApp")

    _, out, = run_cli("routes", "--format", "compact", "--grep", "movie", "CliCompactApp")

    expect(out).to eq("app.rb:2 GET /movie/:id\napp.rb:3 GET /movie/:id\n")
  end

  it "requires files given with -r" do
    File.write("web.rb", %(class CliRequiredApp < Reprised::App; get("/up") { "" }; end\n))

    _, out, = run_cli("routes", "-r", "web.rb", "-f", "compact", "CliRequiredApp")

    expect(out).to eq("web.rb:1 GET /up\n")
  end

  it "explains what's wrong" do
    expect(run_cli("routes", "Nope")).to match([1, "", /uninitialized constant Nope/])
    expect(run_cli("routes", "String")).to match([1, "", /isn't a Reprised::App/])
    expect(run_cli("nope")).to match([1, "", /Usage: reprised routes/])
  end
end
