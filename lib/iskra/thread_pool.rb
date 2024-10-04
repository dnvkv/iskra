# frozen_string_literal: true
# typed: ignore

# Implementation is mostly taken from concurrent_ruby Concurrent::RubyExecutorService
module Iskra
  class ThreadPool
    extend T::Sig

    Worker = Iskra::Worker
    private_constant :Worker

    class FallbackPolicy < T::Enum
      enums do
        Abort      = new
        Discard    = new
        CallerRuns = new
      end
    end

    DEFAULT_MAX_POOL_SIZE      = T.let(2_147_483_647, Integer)
    DEFAULT_MIN_POOL_SIZE      = T.let(0, Integer)
    DEFAULT_MAX_QUEUE_SIZE     = T.let(0, Integer)
    DEFAULT_THREAD_IDLETIMEOUT = T.let(60, Integer)
    DEFAULT_SYNCHRONOUS        = T.let(false, T::Boolean)
    DEFAULT_FALLBACK_POLICY    = T.let(FallbackPolicy::Abort, FallbackPolicy)

    sig { returns(T.nilable(String)) }
    attr_accessor :name

    class ExecutableCtx < T::Struct
      const :thunk, T.proc.void
      const :task, Iskra::Task[T.untyped]
      const :ivar, ::Concurrent::IVar
    end

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
      @stop_event    = T.let(::Concurrent::Event.new, ::Concurrent::Event)
      @stopped_event = T.let(::Concurrent::Event.new, ::Concurrent::Event)

      @__Lock__      = T.let(::Mutex.new, ::Mutex)
      @__Condition__ = T.let(::ConditionVariable.new, ConditionVariable)

      raise ArgumentError.new("`synchronous` cannot be set unless `max_queue` is 0") if synchronous && max_queue > 0
      raise ArgumentError.new("`max_threads` cannot be less than #{DEFAULT_MIN_POOL_SIZE}") if max_threads < DEFAULT_MIN_POOL_SIZE
      raise ArgumentError.new("`max_threads` cannot be greater than #{DEFAULT_MAX_POOL_SIZE}") if max_threads > DEFAULT_MAX_POOL_SIZE
      raise ArgumentError.new("`min_threads` cannot be less than #{DEFAULT_MIN_POOL_SIZE}") if min_threads < DEFAULT_MIN_POOL_SIZE
      raise ArgumentError.new("`min_threads` cannot be more than `max_threads`") if min_threads > max_threads

      synchronize do
        @min_length      = T.let(min_threads, T.nilable(Integer))
        @max_length      = T.let(max_threads, T.nilable(Integer))
        @idletime        = T.let(idletime, T.nilable(T.any(Integer, Float)))
        @max_queue       = T.let(max_queue, T.nilable(Integer))
        @synchronous     = T.let(synchronous, T.nilable(T::Boolean))
        @fallback_policy = T.let(fallback_policy, T.nilable(FallbackPolicy))

        @pool     = T.let([], T.nilable(T::Array[Worker])) # all workers
        @threads  = T.let(Set.new, T.nilable(T::Set[Thread])) # threads set for a fast look up
        @ready    = T.let([], T.nilable(T::Array[Worker])) # used as a stash (most idle worker is at the start)
        @queue    = T.let([], T.nilable(T::Array[ExecutableCtx])) # used as queue
        @awaiting = T.let({}, T.nilable(T::Hash[Thread, ::Concurrent::IVar]))
        @interrupted_set = T.let(Set.new, T.nilable(T::Set[Iskra::Task[T.untyped]]))

        # @ready or @queue is empty at all times
        @scheduled_task_count = T.let(0, T.nilable(Integer))
        @completed_task_count = T.let(0, T.nilable(Integer))
        @largest_length       = T.let(0, T.nilable(Integer))
        @workers_counter      = T.let(0, T.nilable(Integer))
        @initial_pid          = Process.pid

        @gc_interval  = T.let(
          gc_interval || (T.must(@idletime) / 2.0).to_i,
          T.nilable(Integer)
        )
        @next_gc_time = T.let(
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + T.must(@gc_interval),
          T.nilable(T.any(Integer, Float))
        )
      end
    end

    sig { returns(Integer) }
    def max_length
      T.must(@max_length)
    end

    sig { returns(Integer) }
    def min_length
      T.must(@min_length)
    end

    sig { returns(T.any(Float, Integer)) }
    def idletime
      T.must(@idletime)
    end

    sig { returns(Integer) }
    def max_queue
      T.must(@max_queue)
    end

    sig { returns(T::Boolean) }
    def synchronous
      T.must(@synchronous)
    end

    sig {
      params(
        task:  Iskra::Task[T.untyped],
        ivar:  ::Concurrent::IVar,
        thunk: T.proc.void
      ).returns(T::Boolean)
    }
    def post(task, ivar, &thunk)
      # [INTERRUPTIONS] check whether a task or its parent is interrupted
      synchronize do
        # If the executor is shut down, reject this task
        return handle_fallback(thunk) unless running?
        unsafe_execute(ExecutableCtx.new(thunk: thunk, task: task, ivar: ivar))
        true
      end
    end

    sig { returns(T::Boolean) }
    def shutdown
      synchronize do
        break unless running?
        T.must(@stop_event).set
        unsafe_shutdown_execution
      end
      true
    end

    sig { returns(T::Boolean) }
    def kill
      synchronize do
        break if shutdown?
        T.must(@stop_event).set
        T.must(@pool).each(&:kill)
        T.must(@pool).clear
        T.must(@ready).clear
        T.must(@stopped_event).set
      end
      true
    end

    # NOTE: one possible tactic is to track whether a thread is running a task
    # that awaiting on specific ivar. Then before awaiting we may assess whether all
    # other threads are currently awaiting on some ivars that have associated tasks in a queue.
    # In that case we need to find a corresponding task in a queue, remove it from there
    # and call it inline.
    sig {
      params(
        ivar:           ::Concurrent::IVar,
        fibers_subtree: Iskra::FibersDispatchTree
      ).returns(T.untyped)
    }
    def await(ivar, fibers_subtree)
      if !T.must(@threads).include?(Thread.current)
        T.unsafe(ivar.value)
      else
        non_awaiting_count = length - T.must(@awaiting).length
        if non_awaiting_count != 1
          tracked_await(ivar)
        else
          # delete_if is O(n) which is not super effective
          # I think using Deq on top of hash to allow O(1) access by ivar should do the trick
          # On other hand though that will require synchronization of @queue since the thread pool instance
          # is accessed from multiple threads
          # it doesn't require synchronization right now since delete_if is atomic (as any C-method)
          executable_ctx = T.must(@queue).delete_if { |ctx| ctx.ivar == ivar }.first
          if executable_ctx.nil?
            tracked_await(ivar)
          else
            # TODO: this is functionality from Executor, but it should be here
            # ThreadPool and Executor should be refactored to clearly separate responsibilities
            begin
              thread_pool = Iskra::ImmediateThreadPool.new
              executor    = Iskra::Executor.new(thread_pool: thread_pool)
              task = executable_ctx.task
              subtask_fiber = executor.build_new_fiber(task)
              fibers_subtree.fiber = subtask_fiber
              # [CANCELLATION] Should it cancel here?
              ivar.set(executor.execute(task, subtask_fiber, fibers_subtree))
            rescue => e
              ivar.set(Iskra::ExecResult::Failure.new(e))
            end
            ivar.value
          end
        end
      end
    end

    sig { params(timeout: T.nilable(T.any(Integer, Float))).returns(T::Boolean) }
    def wait_for_termination(timeout = nil)
      T.must(@stopped_event).wait(timeout)
    end

    sig { returns(Integer) }
    def largest_length
      synchronize { T.must(@largest_length) }
    end

    sig { returns(Integer) }
    def scheduled_task_count
      synchronize { T.must(@scheduled_task_count) }
    end

    sig { returns(Integer) }
    def completed_task_count
      synchronize { T.must(@completed_task_count) }
    end

    sig { returns(T::Boolean) }
    def can_overflow?
      synchronize { unsafe_limited_queue? }
    end

    sig { returns(Integer) }
    def length
      synchronize { T.must(@pool).length }
    end

    sig { returns(Integer) }
    def queue_length
      synchronize { T.must(@queue).length }
    end

    sig { returns(Integer) }
    def remaining_capacity
      synchronize do
        if unsafe_limited_queue?
          T.must(@max_queue) - T.must(@queue).length
        else
          -1
        end
      end
    end

    sig { params(worker: Worker).returns(T::Boolean) }
    def remove_busy_worker(worker)
      synchronize { unsafe_remove_busy_worker(worker) }
    end

    sig { params(worker: Worker).void }
    def ready_worker(worker)
      synchronize { unsafe_ready_worker(worker) }
    end

    sig { params(worker: Worker).returns(T::Boolean) }
    def worker_not_old_enough(worker)
      synchronize { unsafe_worker_not_old_enough(worker) }
    end

    def worker_died(worker)
      synchronize { unsafe_worker_died(worker) }
    end

    sig { void }
    def worker_task_completed
      synchronize do
        @completed_task_count = @completed_task_count.to_i + 1
      end
    end

    private

    sig { params(ivar: ::Concurrent::IVar).returns(T.untyped) }
    def tracked_await(ivar)
      T.must(@awaiting)[Thread.current] = ivar
      result = T.unsafe(ivar.value)
      T.must(@awaiting).delete(Thread.current)
      result
    end

    sig { returns(T::Boolean) }
    def unsafe_limited_queue?
      @max_queue != 0
    end

    sig { params(executable_ctx: ExecutableCtx).void }
    def unsafe_execute(executable_ctx)
      unsafe_reset_if_forked

      if unsafe_assign_worker(executable_ctx.thunk) || unsafe_enqueue(executable_ctx)
        @scheduled_task_count = @scheduled_task_count.to_i + 1
      else
        handle_fallback(executable_ctx.thunk)
      end

      if T.unsafe(@next_gc_time) < Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unsafe_prune_pool
      end
    end

    sig { void }
    def unsafe_shutdown_execution
      unsafe_reset_if_forked

      if T.must(@pool).empty?
        # nothing to do
        T.must(@stopped_event).set
      end

      if T.must(@queue).empty?
        # no more tasks will be accepted, just stop all workers
        T.must(@pool).each(&:stop)
      end
    end

    sig { params(task: T.proc.void).returns(T::Boolean) }
    def unsafe_assign_worker(task)
      # keep growing if the pool is not at the minimum yet
      worker = (T.must(@ready).pop if T.must(@pool).size >= T.must(@min_length)) || unsafe_add_busy_worker
      if worker
        # [CANCELLATION] Or should it cancel here?
        worker << Worker::Enqueue.new(task: task)
        true
      else
        false
      end
    rescue ThreadError
      # Raised when the operating system refuses to create the new thread
      return false
    end

    sig { params(executable_ctx: ExecutableCtx).returns(T::Boolean) }
    def unsafe_enqueue(executable_ctx)
      return false if @synchronous

      if !unsafe_limited_queue? || T.must(@queue).size < T.must(@max_queue)
        # [CANCELLATION] Or should it cancel here?
        T.must(@queue) << executable_ctx
        true
      else
        false
      end
    end

    sig { params(worker: Worker).void }
    def unsafe_worker_died(worker)
      unsafe_remove_busy_worker(worker)
      replacement_worker = unsafe_add_busy_worker
      if replacement_worker
        unsafe_ready_worker(replacement_worker)
      end
    end

    sig { returns(T.nilable(Worker)) }
    def unsafe_add_busy_worker
      return if T.must(@pool).size >= T.must(@max_length)

      @workers_counter = @workers_counter.to_i + 1
      worker = Worker.new(self, T.must(@workers_counter))
      T.must(@pool) << worker
      T.must(@threads).add(worker.thread)
      if T.must(@pool).length > T.must(@largest_length)
        @largest_length = T.must(@pool).length
      end
      worker
    end

    sig { params(worker: Worker).void }
    def unsafe_ready_worker(worker)
      # [CANCELLATION] Or should it cancel here?
      executable_ctx = T.must(@queue).shift
      if executable_ctx
        worker << Worker::Enqueue.new(task: executable_ctx.thunk)
      else
        # stop workers when !running?, do not return them to @ready
        if running?
          T.must(@ready).push(worker)
        else
          worker.stop
        end
      end
    end

    sig { params(worker: Worker).returns(T::Boolean) }
    def unsafe_worker_not_old_enough(worker)
      T.must(@ready).unshift(worker)
      true
    end

    sig { params(worker: Worker).returns(T::Boolean) }
    def unsafe_remove_busy_worker(worker)
      T.must(@pool).delete(worker)
      T.must(@stopped_event).set if T.must(@pool).empty? && !running?
      true
    end

    sig { void }
    def unsafe_prune_pool
      return if T.must(@pool).size <= T.must(@min_length)

      last_used = T.must(@ready).shift
      last_used << Worker::IdleTest.new if last_used

      @next_gc_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + T.must(@gc_interval)
    end

    sig { void }
    def unsafe_reset_if_forked
      if Process.pid != @initial_pid
        T.must(@queue).clear
        T.must(@ready).clear
        T.must(@pool).clear
        @scheduled_task_count = 0
        @completed_task_count = 0
        @largest_length       = 0
        @workers_counter      = 0
        @initial_pid          = Process.pid
      end
    end

    def shutdown?
      synchronize { @stopped_event.set? }
    end

    class RejectedExecutionError < StandardError
    end

    # TODO: use logger
    sig { params(task: T.proc.void).returns(T::Boolean) }
    def handle_fallback(task)
      fallback_policy = T.must(@fallback_policy)
      case fallback_policy
      when FallbackPolicy::Abort
        raise RejectedExecutionError
      when FallbackPolicy::Discard
        false
      when FallbackPolicy::CallerRuns
        begin
          task.call
        rescue => ex
          # let it fail
          puts ex
        end
        true
      else
        T.absurd(fallback_policy)
      end
    end

    sig { returns(T::Boolean) }
    def running?
      synchronize { !@stop_event.set? }
    end

    sig {
      type_parameters(:Value)
        .params(blk: T.proc.returns(T.type_parameter(:Value)))
        .returns(T.type_parameter(:Value))
    }
    def synchronize(&blk)
      if @__Lock__.owned?
        blk.call
      else
        @__Lock__.synchronize { blk.call }
      end
    end
  end
end
