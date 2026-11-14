# frozen_string_literal: true

# Profiles one bench/perf.rb workload with stackprof: where time goes (cpu) or where objects are allocated (object).
#
#   bundle exec ruby --yjit bench/profile.rb api           # cpu
#   bundle exec ruby --yjit bench/profile.rb api object    # allocations

require "stackprof"

name = ARGV[0] || "api"
mode = ARGV[1] || "cpu"
ARGV.clear
require_relative "perf"

app, envs = Bench::WORKLOADS.fetch(name) { abort("unknown workload #{name}; one of #{Bench::WORKLOADS.keys.join(", ")}") }.call
GC.start
GC.compact
# Requests, cycling through the workload's.
call = ->(count) { count.times { |index| app.call(envs[index % envs.size].dup).last.then { it.close if it.respond_to?(:close) } } }
call.(20_000) # warm up

iterations = Integer(ENV.fetch("N") { mode == "object" ? 2_000 : 30_000 })
# GC stays on: turned off, the heap grows until page faults land wherever objects happen to be allocated. GC time
# shows as its own frames.
GC.start
profile = StackProf.run(mode: mode.to_sym, interval: mode == "object" ? 1 : 20) { call.(iterations) }
report = StackProf::Report.new(profile)
puts "#{name}, #{mode}, #{iterations} requests"
report.print_text(false, 30)
