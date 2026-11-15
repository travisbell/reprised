# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Run the demos (demos/) under Falcon, at http://localhost:9292 (PORT to change it)"
task :demos do
  # One worker, so the chat room's members all share a process.
  port = ENV.fetch("PORT", "9292")
  sh({ "RACK_ENV" => ENV.fetch("RACK_ENV", "development") },
    "bundle exec falcon serve --bind http://localhost:#{port} --count 1 --config demos/config.ru")
end

# The phase 0 spike: compares Reprised's routing with Sinatra's on TMDB's real route tables. Needs the apps checked
# out beside this repo (~/workspace/tmdb-web, ~/workspace/tmdb-api). See spike/README.md.
namespace :spike do
  APPS = ["tmdb-api", "tmdb-web"].freeze
  WORKSPACE = File.expand_path("..", __dir__)

  def unbundled(command, dir)
    Bundler.with_unbundled_env { sh("cd #{dir} && #{command}") }
  end

  # Where an app's Sinatra checkout is: TMDB_API_DIR / TMDB_WEB_DIR, or beside this repo. Once an app has moved to
  # Reprised, point its variable at a checkout (or worktree) that's still on Sinatra.
  def checkout(app) = ENV.fetch("#{app.upcase.tr("-", "_")}_DIR", "#{WORKSPACE}/#{app}")

  desc "Extract route tables from the TMDB apps"
  task :extract do
    APPS.each do |app|
      unbundled("bundle exec ruby #{__dir__}/spike/extract_routes.rb #{app} #{__dir__}/spike/fixtures/#{app}.routes.json",
        checkout(app))
    end
  end

  desc "Run the Sinatra oracle over each extracted table"
  task :oracle do
    APPS.each do |app|
      unbundled("bundle exec ruby sinatra_oracle.rb ../fixtures/#{app}.routes.json ../results/#{app}.oracle.jsonl",
        "#{__dir__}/spike/oracle")
    end
  end

  # tmdb-api defines everything on one app class, so only tmdb-web has controllers to split out.
  LEVELS = { "tmdb-api" => ["router", "app"], "tmdb-web" => ["router", "app", "controllers"] }.freeze

  desc "Compare Reprised with the oracle's results, at each level (MATCHER=index|trie)"
  task :diff do
    LEVELS.each do |app, levels|
      levels.each { |level| ruby("spike/differential.rb", app, ENV.fetch("MATCHER", "index"), level) }
    end
  end

  desc "Benchmark routing in Sinatra and Reprised"
  task :bench do
    APPS.each do |app|
      route_index = "#{WORKSPACE}/#{app}/lib/route_index.rb"
      env = File.exist?(route_index) ? "ROUTE_INDEX=#{route_index} " : ""
      unbundled("#{env}bundle exec ruby bench_sinatra.rb #{app}", "#{__dir__}/spike/oracle")
      ruby("bench/routing.rb", app)
    end
  end
end

desc "Extract, run the oracle, and compare"
task spike: ["spike:extract", "spike:oracle", "spike:diff"]
