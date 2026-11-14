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
end

group :benchmark do
  gem "benchmark-ips"
end
