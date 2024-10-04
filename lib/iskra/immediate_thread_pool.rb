# frozen_string_literal: true
# typed: ignore

module Iskra
  class ImmediateThreadPool < ThreadPool
    extend T::Sig

    sig {
      params(
        min_threads:     Integer,
        max_threads:     Integer,
        idletime:        T.any(Float, Integer),
        max_queue:       Integer,
        synchronous:     T::Boolean,
        fallback_policy: FallbackPolicy,
        gc_interval:     T.nilable(Integer),
        name:            T.nilable(String),
        auto_terminate:  T::Boolean
      ).void
    }
    def initialize(
      min_threads:     DEFAULT_MIN_POOL_SIZE,
      max_threads:     DEFAULT_MAX_POOL_SIZE,
      idletime:        DEFAULT_THREAD_IDLETIMEOUT,
      max_queue:       DEFAULT_MAX_QUEUE_SIZE,
      synchronous:     DEFAULT_SYNCHRONOUS,
      fallback_policy: DEFAULT_FALLBACK_POLICY,
      gc_interval:     nil,
      name:            nil,
      auto_terminate:  true
    )
      @shutdown = false
      @stop_event    = T.let(::Concurrent::Event.new, ::Concurrent::Event)
      @stopped_event = T.let(::Concurrent::Event.new, ::Concurrent::Event)
    end

    sig {
      params(
        task:  Iskra::Task[T.untyped],
        ivar:  ::Concurrent::IVar,
        thunk: T.proc.void
      ).returns(T::Boolean)
    }
    def post(task, ivar, &thunk)
      return false if @shutdown

      thunk.call
      true
    end

    sig { params(ivar: ::Concurrent::IVar, fibers_subtree: Iskra::FibersDispatchTree).returns(T.untyped) }
    def await(ivar, fibers_subtree)
      T.must(ivar.value)
    end

    sig { returns(T::Boolean) }
    def shutdown
      @stop_event.set
      @shutdown = true
    end
  end
end