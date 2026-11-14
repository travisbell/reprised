# frozen_string_literal: true

require "optparse"

module Reprise
  # The `reprise` command.
  #
  #   reprise routes                       # the routes of the app in ./app.rb
  #   reprise routes -r ./environment App  # require files first, and name the app
  #   reprise routes --format compact      # "file:line VERB pattern" per line, for grep
  #   reprise routes --grep movie
  class CLI
    USAGE = <<~USAGE
      Usage: reprise routes [options] [APP]

      Lists an app's routes in the order they're tried, with the controller and source of each.
      APP is the app's class name (App, MyApp::Web). Without it, the only Reprise::App subclass is used.

    USAGE

    def self.start(argv = ARGV, out: $stdout, err: $stderr) = new(out:, err:).run(argv)

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      command = argv.shift
      return usage(command ? 1 : 0) unless command == "routes"

      routes(argv)
    rescue OptionParser::ParseError, ArgumentError, LoadError, NameError => e
      @err.puts("reprise: #{e.message}")
      1
    end

    private

    def usage(status)
      (status.zero? ? @out : @err).puts(USAGE + "Commands:\n    routes    List an app's routes\n")
      status
    end

    def routes(argv)
      options = { requires: [], format: "table", grep: nil }
      parser = OptionParser.new do |opts|
        opts.banner = USAGE
        opts.on("-r", "--require FILE", "Require FILE first (repeatable). Default: ./app.rb, if it exists") { options[:requires] << it }
        opts.on("-f", "--format FORMAT", ["table", "compact"], "table (default) or compact: file:line VERB pattern") { options[:format] = it }
        opts.on("-g", "--grep PATTERN", "Only routes whose verb, pattern, or controller match PATTERN") { options[:grep] = Regexp.new(it, Regexp::IGNORECASE) }
      end
      name = parser.parse(argv).first

      requires = options[:requires].empty? && File.exist?("app.rb") ? ["./app.rb"] : options[:requires]
      requires.each { require(File.expand_path(it)) }
      app = name ? Object.const_get(name) : find_app
      raise ArgumentError, "#{name} isn't a Reprise::App" unless app.is_a?(Class) && app < App

      rows = app.routes.map { row(it, app) }
      rows.select! { |row| row.values_at(:verb, :pattern, :owner).any? { options[:grep].match?(it) } } if options[:grep]
      options[:format] == "compact" ? print_compact(rows) : print_table(rows)
      0
    end

    def find_app
      apps = ObjectSpace.each_object(Class).select { it < App && it.name }
      apps.reject! { |candidate| apps.any? { it < candidate } } # the most derived apps
      raise ArgumentError, "no Reprise::App found; require it with -r" if apps.empty?
      raise ArgumentError, "several apps found (#{apps.map(&:name).sort.join(", ")}); name one" if apps.size > 1

      apps.first
    end

    def row(route, app)
      file, line = route.source_location
      types = route.options[:provides]
      {
        verb: route.verb,
        pattern: route.pattern,
        owner: route.owner <= App ? app.name.to_s : (route.owner.name || "(anonymous controller)"),
        provides: types ? Array(types).join(",") : "",
        source: file ? "#{relative(file)}:#{line}" : ""
      }
    end

    def relative(file) = file.start_with?("#{Dir.pwd}/") ? file.delete_prefix("#{Dir.pwd}/") : file

    def print_compact(rows)
      rows.each { @out.puts("#{it[:source]} #{it[:verb]} #{it[:pattern]}") }
    end

    def print_table(rows)
      columns = [:verb, :pattern, :provides, :owner, :source]
      headers = { verb: "Verb", pattern: "Pattern", provides: "Provides", owner: "Controller", source: "Source" }
      widths = columns.to_h { |column| [column, [headers[column].size, *rows.map { it[column].size }].max] }
      format_row = ->(row) { columns.map { row[it].ljust(widths[it]) }.join("  ").rstrip }

      @out.puts(format_row.(headers))
      rows.each { @out.puts(format_row.(it)) }
      @out.puts("#{rows.size} route#{"s" unless rows.size == 1}")
    end
  end
end
