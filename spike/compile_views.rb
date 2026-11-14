# frozen_string_literal: true

# Compiles every ERB template in a views directory with Reprise's template compiler, as the ActionView plugin
# configures it, and reports any that don't compile. Nothing is rendered, so the app's code isn't needed.
#
#   bundle exec ruby spike/compile_views.rb ~/workspace/tmdb-web/views

require "bundler/setup"
require_relative "../lib/reprise"
require_relative "../lib/reprise/plugins/action_view"

views = ARGV.fetch(0) { abort("usage: compile_views.rb VIEWS_DIR") }
options = {
  engine_class: Erubi::CaptureBlockEngine, bufval: "::Reprise::Plugins::ActionView::Buffer.new", bufvar: "@output_buffer"
}
failures = []
files = Dir.glob("**/*.erb", base: views).sort
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

files.each do |file|
  path = File.join(views, file)
  template = Reprise::Template.new(File.read(path, mode: "rb").force_encoding("utf-8"), path:, options:)
  template.__send__(:compile, [:example_local])
rescue SyntaxError, StandardError => e
  failures << [file, e.message.lines.first.strip]
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts format("%d templates compiled in %.2fs, %d failed", files.size, elapsed, failures.size)
failures.each { |file, message| puts "  #{file}: #{message}" }
exit(failures.empty? ? 0 : 1)
