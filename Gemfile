# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rack-test"
  gem "rake"
  gem "rspec", "~> 3.13"
  gem "rubocop-shopify", require: false
end

# Optional integrations, exercised by the specs.
group :test do
  gem "actionview", "~> 8.1"
  gem "phlex", "~> 2.4"
  gem "phlex-rails", "~> 2.4"

  # Async features, and the integration specs that run Reprise under a real Falcon server.
  gem "async", "~> 2.46"
  gem "async-http", "~> 0.105"
  gem "async-safe", "~> 0.5"
  gem "async-websocket", "~> 0.30"
  gem "falcon", "~> 0.57"
end

group :benchmark do
  gem "benchmark-ips"
end
