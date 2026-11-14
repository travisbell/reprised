# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# The phase 0 spike: compares Reprise's routing with Sinatra's on TMDB's real route tables. Needs the apps checked
# out beside this repo (~/workspace/tmdb-web, ~/workspace/tmdb-api). See spike/README.md.
namespace :spike do
  APPS = ["tmdb-api", "tmdb-web"].freeze
  WORKSPACE = File.expand_path("..", __dir__)

  def unbundled(command, dir)
    Bundler.with_unbundled_env { sh("cd #{dir} && #{command}") }
  end

  desc "Extract route tables from the TMDB apps"
  task :extract do
    APPS.each do |app|
      unbundled("bundle exec ruby #{__dir__}/spike/extract_routes.rb #{app} #{__dir__}/spike/fixtures/#{app}.routes.json",
        "#{WORKSPACE}/#{app}")
    end
  end

  desc "Run the Sinatra oracle over each extracted table"
  task :oracle do
    APPS.each do |app|
      unbundled("bundle exec ruby sinatra_oracle.rb ../fixtures/#{app}.routes.json ../results/#{app}.oracle.jsonl",
        "#{__dir__}/spike/oracle")
    end
  end

  desc "Compare Reprise with the oracle's results (MATCHER=index|trie)"
  task :diff do
    APPS.each { |app| ruby("spike/differential.rb", app, ENV.fetch("MATCHER", "index")) }
  end

  desc "Benchmark routing in Sinatra and Reprise"
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
