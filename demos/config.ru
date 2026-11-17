# frozen_string_literal: true

# The demos, under Falcon: bundle exec rake demos (see README.md). The middleware and the reloading are in
# config/application.rb and config/environments/.

require_relative "config/environment"
DemosApplication.rackup(self)
