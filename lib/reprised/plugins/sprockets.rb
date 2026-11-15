# frozen_string_literal: true

require "sprockets"

module Reprised
  module Plugins
    # A Sprockets asset pipeline: settings for the environment and its manifest, helpers that link to assets, and, in
    # development, serving the assets.
    #
    #   assets = Sprockets::Environment.new(root)
    #   assets.append_path("assets/stylesheets")
    #
    #   plugin Reprised::Plugins::Sprockets,
    #     environment: assets,
    #     manifest: Sprockets::Manifest.new(assets, "public/assets"),
    #     digest: production?
    #
    # It sets +assets+, +assets_prefix+, +assets_manifest+, and +assets_digest+, which the helpers read on each call, so
    # a later `set :assets_digest, true` (in a `configure` block, say) takes effect.
    #
    # With +serve+ (the default unless +digest+), it defines a `get "#{prefix}/*"` route that compiles assets on demand,
    # as Sinatra apps do. It takes its place among the app's routes, so routes defined before the plugin under the prefix
    # answer first, filters run, and a path Sprockets has no asset for gets its 404. Precompiled assets
    # (`Sprockets::Manifest#compile`) are better served by a CDN or a static file server. To serve assets ahead of the
    # app instead, put Server in config.ru.
    module Sprockets
      PREFIX = "/assets"

      def self.install(app, environment:, prefix: PREFIX, manifest: nil, digest: false, serve: !digest)
        prefix = prefix.chomp("/")
        app.set(:assets, environment)
        app.set(:assets_prefix, prefix)
        app.set(:assets_manifest, manifest)
        app.set(:assets_digest, digest)
        app.helpers(Helpers)
        return unless serve

        app.get("#{prefix}/*") do
          settings.assets.call(env.merge("SCRIPT_NAME" => "#{env["SCRIPT_NAME"]}#{prefix}", "PATH_INFO" => request.path_info.delete_prefix(prefix)))
        end
      end

      # Links to assets, in the app and its controllers.
      module Helpers
        # The URL path of an asset: its digest path from the manifest when +assets_digest+ is set and the manifest has
        # it, or else its logical path, under the prefix.
        def asset_path(source, _options = {})
          "#{settings.assets_prefix}/#{digest_path(source) || source}"
        end

        # Whether there's an asset at the logical path +source+: in the manifest, or found in the environment's paths.
        # It doesn't compile the asset.
        def asset_exists?(source)
          return true if digest_path(source)

          !settings.assets.resolve(source).first.nil?
        end

        private

        def digest_path(source)
          settings.assets_manifest&.assets&.[](source) if settings.assets_digest
        end
      end

      # Rack middleware that answers GET and HEAD requests under +prefix+ from a Sprockets environment, ahead of the app,
      # and passes everything else, including paths it has no asset for, to the app. So do paths with a null byte, which
      # Sprockets raises on.
      #
      #   use Reprised::Plugins::Sprockets::Server, environment: assets # in config.ru
      class Server
        METHODS = ["GET", "HEAD"].freeze

        def initialize(app, environment:, prefix: PREFIX)
          @app = app
          @environment = environment
          @prefix = prefix.chomp("/")
          @scope = "#{@prefix}/"
        end

        def call(env)
          path = env["PATH_INFO"]
          return @app.call(env) unless path.start_with?(@scope) && METHODS.include?(env["REQUEST_METHOD"])
          return @app.call(env) if path.include?("%00") || path.include?("\0")

          asset_env = env.merge("SCRIPT_NAME" => "#{env["SCRIPT_NAME"]}#{@prefix}", "PATH_INFO" => path.delete_prefix(@prefix))
          _, headers, body = response = @environment.call(asset_env)
          return response unless headers["x-cascade"] == "pass"

          body.close if body.respond_to?(:close)
          @app.call(env)
        end
      end
    end
  end
end
