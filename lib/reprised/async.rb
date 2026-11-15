# frozen_string_literal: true

module Reprised
  # A route took longer than its `timeout:`. Answers 503, and can be handled with `error(Reprised::Timeout)`.
  class Timeout < Error
    def http_status = 503
  end

  # The request scope handling the current request, from anywhere in it: a service, a Phlex component, or a task in
  # an Async::Barrier the route started. nil outside a request.
  #
  # It's kept in fiber storage, which fibers (and so Async tasks) inherit from the fiber that created them.
  def self.current = Fiber[CURRENT]

  CURRENT = :__reprised_current_scope
  private_constant :CURRENT

  # Runs the block with +scope+ as Reprised.current, restoring the previous one afterwards.
  def self.with_current(scope)
    previous = Fiber[CURRENT]
    Fiber[CURRENT] = scope
    yield
  ensure
    Fiber[CURRENT] = previous
  end

  def self.current=(scope)
    Fiber[CURRENT] = scope
  end

  # Route timeouts (`get "/x", timeout: 5`), enforced by the request's Async task, so they need an Async server such
  # as Falcon. Without one, the route runs without a timeout, and a warning is given once.
  module RouteTimeout
    class << self
      def run(route, seconds, &)
        return yield unless seconds && (task = current_task)

        # Rescued here, not for the whole method: Async is only loaded once a route has a timeout.
        begin
          task.with_timeout(seconds, &)
        rescue ::Async::TimeoutError
          raise Timeout, "#{route} took longer than #{seconds}s"
        end
      end

      private

      def current_task
        require "async"
        ::Async::Task.current?.tap do |task|
          unless task || @warned
            @warned = true
            Kernel.warn("Reprised: route timeouts need an Async server (such as Falcon); running without them")
          end
        end
      end
    end
  end
end
