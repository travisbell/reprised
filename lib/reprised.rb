# frozen_string_literal: true

require_relative "reprised/version"
require_relative "reprised/errors"
require_relative "reprised/async"
require_relative "reprised/negotiation"
require_relative "reprised/router"
require_relative "reprised/params"
require_relative "reprised/request"
require_relative "reprised/response"
require_relative "reprised/route"
require_relative "reprised/cookies"
require_relative "reprised/helpers"
require_relative "reprised/streaming"
require_relative "reprised/templates"
require_relative "reprised/dsl"
require_relative "reprised/controller"
require_relative "reprised/dispatch"
require_relative "reprised/app"

# A Sinatra-compatible Rack router for Ruby 4, built on Mustermann 4 and designed for Falcon and Async.
module Reprised
end
