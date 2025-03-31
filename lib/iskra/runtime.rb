# frozen_string_literal: true
# typed: true

require_relative "await_on"
require_relative "await"
require_relative "cancel"
require_relative "cancellation_exception"
require_relative "cede"
require_relative "channel"
require_relative "delay"
require_relative "dispatch"
require_relative "exec_result"
require_relative "fiber_state"
require_relative "fibers_dispatch_tree_renderer"
require_relative "fibers_dispatch_tree"
require_relative "fibers_registry"
require_relative "immediate_thread_pool"
require_relative "scheduler"
require_relative "signal_awake_on"
require_relative "thread_pool"

module Iskra
  class Runtime
    extend T::Sig

    DEAD_FIBER_MSG_OLD = T.let("dead fiber called", String)
    private_constant :DEAD_FIBER_MSG_OLD

    DEAD_FIBER_MSG = T.let("attempt to resume a terminated fiber", String)
    private_constant :DEAD_FIBER_MSG

    DEFAULT_MIN_THREADS = T.let(4, Integer)
    DEFAULT_MAX_THREADS = T.let(8, Integer)

    sig { returns(::Iskra::ThreadPool) }
    attr_reader :thread_pool

    include Kernel

    class InternalError < StandardError
      UNEXPECTED_FRAME_MSG = T.let(
        "Unexpected Frame: Expected instance Stack::SuspendedTask but Stack::ResumeWithLatest was found",
        String
      )
      AWAIT_NON_DISPATCH_MSG = T.let(
        "Unexpected error: Awaiting not dispatched task",
        String
      )
      TASK_NOT_FOUND_MSG = T.let(
        "Task is not found",
        String
      )
    end

    FiberState = ::Iskra::FiberState
    private_constant :FiberState
    Success = ::Iskra::ExecResult::Success
    private_constant :Success
    Failure = ::Iskra::ExecResult::Failure
    private_constant :Failure

    sig {
      params(
        scheduler:          ::Iskra::Scheduler,
        enable_diagnostics: T::Boolean,
        thread_pool:        T.nilable(::Iskra::ThreadPool)
      ).void
    }
    def initialize(
      scheduler: ::Iskra::Scheduler.new,
      enable_diagnostics: false,
      thread_pool: nil
    )
      @scheduler            = T.let(scheduler, ::Iskra::Scheduler)
      @enable_diagnostics   = T.let(enable_diagnostics, T::Boolean)
      @fibers_tree          = T.let(nil, T.nilable(::Iskra::FibersDispatchTree))
      @thread_pool = T.let(
        thread_pool || ::Iskra::Runtime.thread_pool,
        ::Iskra::ThreadPool
      )
    end

    sig { void }
    def shutdown!
      @thread_pool.shutdown
    end

    # Main execution loop responsible for executing tasks.
    def execute(task, preinitialized_fiber = nil, initial_fibers_tree = nil, debug: false)
      log("Started executing task #{task} label=#{task.label}")
      fiber = preinitialized_fiber || build_new_fiber(task)
      if initial_fibers_tree
        fibers_tree    = initial_fibers_tree
        root_task_node = assert_subtree_presence!(initial_fibers_tree.find_by_task(task))
      else
        ivar  = ::Concurrent::IVar.new
        fibers_tree = ::Iskra::FibersDispatchTree.empty(task, fiber, ivar)
        root_task_node = fibers_tree
      end
      @fibers_tree = fibers_tree

      # Following variables represent a state of a runtime loop.
      
      # Stores an active task (or coroutine, terms may be used interchangeably): the task is currently executed by the Iskra runtime.
      # Iskra runtime implements a cooperative multitasking, so a coroutine must yield control to the runtime ocassionally.
      # One of many responsiblities of the runtime is to select a next task to ensure fair distribution of processing time.
      # Given this runtime may suspend and resume tasks, so current_task may change even if a previous tasks isn't finished.
      # Before the loop is initializeed top level task, from which the execution is unrolled.
      current_task          = task
      # The task fiber, usually initialized in the runtime since it is required
      # to store all iskra's fiber in a registry to ensure that concurrent operations
      # are called inside a coroutine (or in run_blocking).
      current_fiber         = T.let(fiber, T.nilable(Fiber))

      # Stores a value, that current fiber will be resumed with during next iteration of the loop.
      # Primarily used to return a value from runtime to an Task#await! caller.
      next_resumed          = T.let(nil, T.untyped)
      # Store current yield of the current fiber
      # During each iteration of a runtime loop, the runtime resume current fiber, thus yielding execution to the coroutine fiber.
      # The coroutine fiber executes until the Fiber.yield call, which yields execution to the runtime with an optional value.
      # In case of couroutine fibers their yield value will be either a message to runtime (e.g. Iskra::Dispatch), or some value on coroutine finish.
      current_yield         = T.let(nil, T.untyped)
      # Stores a link to a node in a global coroutines tree that corresponds to an active task
      current_fiber_subtree = T.let(fibers_tree, T.nilable(::Iskra::FibersDispatchTree))
      subtask_fiber         = T.let(nil, T.nilable(Fiber))
      # Scheduler task context is required for suspending task.
      # When a task is suspended, all the corresponding runtime loop state is saved to a context,
      # and the context is saved to a scheduler, so the task can be resumed later.
      # 
      # Before the loop starts the context is initialized for a task that is passed as an argument.
      current_task_context  = T.let(
        ::Iskra::Scheduler::TaskContext.new(
          task: task,
          fiber: fiber,
          next_resumed: next_resumed,
          current_fiber_subtree: current_fiber_subtree,
        ),
        T.nilable(::Iskra::Scheduler::TaskContext)
      )

      # Set the state of the task to running.
      T.must(current_fiber_subtree).state_ref.change_to(FiberState::Running)

      # Start of the main runtime loop
      # Structure of the loop:
      # 
      loop do
        log("New runtime iteration start")
        if current_task_context.nil?
          current_task_context = @scheduler.next_task_to_execute
          break if current_task_context.nil?

          current_task          = current_task_context.task
          current_fiber         = current_task_context.fiber
          current_fiber_subtree = current_task_context.current_fiber_subtree
          next_resumed          = current_task_context.next_resumed

          log("Taking new task into work #{current_task} label=#{current_task.label}")
          T.must(current_fiber_subtree).state_ref.change_to(FiberState::Running)
        elsif @scheduler.yield_now?(current_task_context.task)
          suspended_task_data = ::Iskra::Scheduler::TaskContext.new(
            task:  current_task,
            fiber: T.must(current_fiber),
            current_fiber_subtree: current_fiber_subtree,
            next_resumed: next_resumed
          )
          @scheduler.add_task(suspended_task_data)
          T.must(current_fiber_subtree).state_ref.change_to(FiberState::Suspended)

          log("Suspending task #{current_task} label=#{current_task.label} due to scheduler signal")

          current_task_context = @scheduler.next_task_to_execute

          break if current_task_context.nil?

          log("Taking new task into work #{current_task} label=#{current_task.label}")

          current_task          = current_task_context.task
          current_fiber         = current_task_context.fiber
          current_fiber_subtree = current_task_context.current_fiber_subtree
          next_resumed          = current_task_context.next_resumed

          T.must(current_fiber_subtree).state_ref.change_to(FiberState::Running)
        end

        log("Executing #{task} label=#{current_task.label}")
        if next_resumed.nil?
          current_yield = T.must(current_fiber).resume
        else
          current_yield = T.must(current_fiber).resume(next_resumed)
        end
        # binding.pry

        @scheduler.increment_op_count
        log("Scheduler op count: #{@scheduler.op_count}")
        log("Scheduler current yield: #{current_yield}")
        case current_yield
        when ::Iskra::Dispatch
          dispatched_task = current_yield.task
          case dispatched_task
          when ::Iskra::Coroutine
            subtask_ivar  = ::Concurrent::IVar.new
            subtask_fiber  = build_new_fiber(dispatched_task)
            fibers_subtree = assert_subtree_presence!(
              T.must(current_fiber_subtree).add_child(dispatched_task, subtask_fiber, subtask_ivar)
            )
            @scheduler.add_task(
              ::Iskra::Scheduler::TaskContext.new(
                task:                  dispatched_task,
                fiber:                 subtask_fiber,
                current_fiber_subtree: fibers_subtree,
                next_resumed:          nil
              )
            )
          when ::Iskra::Async
            subtask_ivar  = ::Concurrent::IVar.new
            task_subtree = assert_subtree_presence!(
              T.must(current_fiber_subtree).add_child(dispatched_task, nil, subtask_ivar)
            )
            @thread_pool.post(dispatched_task, subtask_ivar) do
              begin
                runtime            = ::Iskra::Runtime.new(thread_pool: @thread_pool)
                subtask_fiber      = runtime.build_new_fiber(dispatched_task)
                task_subtree.fiber = subtask_fiber
                result = runtime.execute(dispatched_task, subtask_fiber, task_subtree)
                subtask_ivar.set(Success.new(result))
              rescue => e
                unless subtask_ivar.complete?
                  subtask_ivar.set(Failure.new(e))
                end
              end
            end
          when ::Iskra::ConcurrentScope
            subtask_ivar  = ::Concurrent::IVar.new
            subtask_fiber  = build_new_fiber(dispatched_task)
            fibers_subtree = assert_subtree_presence!(
              T.must(current_fiber_subtree).add_child(dispatched_task, subtask_fiber, subtask_ivar)
            )
            @scheduler.add_task(
              ::Iskra::Scheduler::TaskContext.new(
                task:                  dispatched_task,
                fiber:                 subtask_fiber,
                current_fiber_subtree: fibers_subtree,
                next_resumed:          nil
              )
            )
            suspended_task_data = ::Iskra::Scheduler::TaskContext.new(
              task:  current_task,
              fiber: T.must(current_fiber),
              current_fiber_subtree: current_fiber_subtree,
              next_resumed: next_resumed
            )
            @scheduler.add_task(suspended_task_data)
            @scheduler.set_awaiting(current_task, subtask_ivar)
            T.must(current_fiber_subtree).state_ref.change_to(FiberState::Suspended)
            current_task_context = nil
          end
          next_resumed = dispatched_task
        when ::Iskra::Await
          awaited_task = T.unsafe(current_yield.task)
          case awaited_task
          when ::Iskra::Task
            awaited_node = assert_subtree_presence!(fibers_tree.find_by_task(awaited_task))
            awaited_ivar = T.must(awaited_node.ivar)
            if awaited_ivar.complete?
              next_resumed = awaited_ivar.value
            else
              suspended_task_data = ::Iskra::Scheduler::TaskContext.new(
                task:  current_task,
                fiber: T.must(current_fiber),
                current_fiber_subtree: current_fiber_subtree,
                next_resumed: next_resumed
              )
              log("Suspending task #{current_task} label=#{current_task.label}")
              @scheduler.add_task(suspended_task_data)
              @scheduler.set_awaiting(current_task, awaited_ivar)
              T.must(current_fiber_subtree).state_ref.change_to(FiberState::Suspended)
              current_task_context = nil
            end
          end
        when ::Iskra::Cede
          next_resumed = nil
        when ::Iskra::Delay
          delay_time = T.unsafe(current_yield.time)
          # TODO use monotonic time
          awake_at = Time.now + delay_time
          suspended_task_data = ::Iskra::Scheduler::TaskContext.new(
            task:  current_task,
            fiber: T.must(current_fiber),
            current_fiber_subtree: current_fiber_subtree,
            next_resumed: next_resumed
          )
          @scheduler.add_delayed_task(suspended_task_data, awake_at)
          T.must(current_fiber_subtree).state_ref.change_to(FiberState::Suspended)
          current_task_context = nil

          next_resumed = nil
        when ::Iskra::Cancel
          canceled_task = T.unsafe(current_yield.task)
          canceled_subtree = assert_subtree_presence!(
            assert_subtree_presence!(fibers_tree).find_by_task(canceled_task)
          )
          canceled_subtree.descendants.each do |node|
            unless node.state_ref.state.completed?
              @scheduler.set_canceled(node.task)
              T.must(node.ivar).set(Failure.new(StandardError.new("Task is canceled")))
              node.state_ref.change_to(FiberState::Canceled)
            end
          end
          if canceled_task == current_task
            unless T.must(current_fiber_subtree).state_ref.state.completed?
              T.must(current_fiber_subtree).state_ref.change_to(FiberState::Canceled)
              T.must(T.must(current_fiber_subtree).ivar).set(Failure.new(StandardError.new("Task is canceled")))
            end
            current_task_context = nil
          else
            unless canceled_subtree.state_ref.state.completed?
              @scheduler.set_canceled(canceled_task)
              T.must(canceled_subtree.ivar).set(Failure.new(StandardError.new("Task is canceled")))
              canceled_subtree.state_ref.change_to(FiberState::Canceled)
            end
          end
          next_resumed = nil
        when ::Iskra::AwaitOn
          value = T.unsafe(current_yield.value)

          suspended_task_data = ::Iskra::Scheduler::TaskContext.new(
            task:  current_task,
            fiber: T.must(current_fiber),
            current_fiber_subtree: current_fiber_subtree,
            next_resumed: next_resumed
          )
          log("Suspending task #{current_task} label=#{current_task.label}")
          @scheduler.add_task(suspended_task_data)
          @scheduler.await_on(suspended_task_data.task, value)
          T.must(current_fiber_subtree).state_ref.change_to(FiberState::Suspended)
          current_task_context = nil

          next_resumed = nil
        when ::Iskra::SignalAwakeOn
          value = T.unsafe(current_yield.value)
          @scheduler.signal_awake_on(value)
          next_resumed = nil
        else
          next_resumed = nil
        end
      rescue => e
        subtree = assert_subtree_presence!(
          assert_subtree_presence!(current_fiber_subtree).find_by_task(T.must(current_task_context).task)
        )
        if current_task.is_a?(::Iskra::ConcurrentScope)
          if is_dead_fiber_called?(e)
            @scheduler.await_children_finished(
              T.must(current_task_context).task,
              subtree,
              Success.new(current_yield)
            )
            @scheduler.add_task(T.must(current_task_context))
            T.must(current_fiber_subtree).state_ref.change_to(FiberState::ScopeWaiting)
            current_task_context = nil
          else
            @scheduler.await_children_failed(
              T.must(current_task_context).task,
              subtree,
              Success.new(current_yield)
            )
            @scheduler.add_task(T.must(current_task_context))
            T.must(current_fiber_subtree).state_ref.change_to(FiberState::ScopeWaiting)
            current_task_context = nil

            if e.is_a?(InternalError) && enable_diagnostics?
              # TODO: add logging
            end
          end
        else
          if is_dead_fiber_called?(e)
            @scheduler.set_finished(T.must(current_task_context).task)
            subtree.state_ref.change_to(FiberState::Finished)
            log("Finishing task #{current_task} label=#{current_task.label}")
            T.must(subtree.ivar).set(Success.new(current_yield))
            current_task_context = nil
          else
            if e.is_a?(InternalError) && enable_diagnostics?
              # TODO: add logging
            end
            @scheduler.set_failed(T.must(current_task_context).task)
            log("Failing task #{current_task} label=#{current_task.label}")
            T.must(subtree.ivar).set(Failure.new(e))
            subtree.state_ref.change_to(FiberState::Failed)
            current_task_context = nil
          end
        end
      end

      T.must(root_task_node.ivar).value
    rescue InternalError => e
      if enable_diagnostics?
        # dump_stack(stack || [])
      end
      raise e
    ensure
      if task.is_a?(::Iskra::Coroutine)
        clear_fibers_from_registry(fibers_tree)
      end

      await_asyncs(fibers_tree)
    end

    sig { params(fibers_tree: ::Iskra::FibersDispatchTree).void }
    def await_asyncs(fibers_tree)
      descendants = fibers_tree.descendants
      descendants.each do |node|
        if node.task.is_a?(::Iskra::Async)
          ivar = node.ivar
          ivar.wait unless ivar.nil?
        end
      end
    end

    # Wraps a thunk into a fiber to enable yielding from .async, .task and #await!,
    # and adds created to registry thus allowing to figure if any yielding method
    # is called in concurrent scope
    sig { params(task: ::Iskra::Task[T.untyped]).returns(Fiber) }
    def build_new_fiber(task)
      Fiber.new { task.thunk.call }.tap { |fiber| fibers_registry.add(fiber) }
    end

    private

    sig { returns(T::Boolean) }
    def enable_diagnostics?
      @enable_diagnostics
    end

    sig { params(fibers_subtree: T.nilable(FibersDispatchTree)).returns(FibersDispatchTree) }
    def assert_subtree_presence!(fibers_subtree)
      if fibers_subtree.nil?
        raise InternalError.new("Unexpected error: Fiber is already being tracked")
      else
        fibers_subtree
      end
    end

    sig { params(fibers_subtree: T.nilable(FibersDispatchTree)).returns(::Concurrent::IVar) }
    def assert_ivar_presence!(fibers_subtree)
      if fibers_subtree.nil?
        raise InternalError.new(InternalError::AWAIT_NON_DISPATCH_MSG)
      else
        ivar = fibers_subtree.ivar
        if ivar.nil?
          raise InternalError.new(InternalError::AWAIT_NON_DISPATCH_MSG)
        else
          ivar
        end
      end
    end

    sig { params(root: ::Iskra::FibersDispatchTree).void }
    def clear_fibers_from_registry(root)
      root.each do |node|
        node_fiber = node.fiber
        if node_fiber
          fibers_registry.remove(node_fiber)
        end
      end
    end

    sig { params(error: Exception).returns(T::Boolean) }
    def is_dead_fiber_called?(error)
      error.is_a?(FiberError) && (error.message == DEAD_FIBER_MSG || error.message == DEAD_FIBER_MSG_OLD)
    end

    sig { returns(::Iskra::FibersRegistry) }
    def fibers_registry
      ::Iskra::Runtime.fibers_registry
    end

    # TODO: pass a loger instance to runtime
    sig { params(message: String).void }
    def log(message)
      puts(message) if enable_diagnostics?
    end

    sig { returns(::Iskra::ThreadPool) }
    def self.thread_pool
      @thread_pool ||= ::Iskra::ThreadPool.new(min_threads: DEFAULT_MIN_THREADS, max_threads: DEFAULT_MAX_THREADS)
    end

    sig { returns(::Iskra::FibersRegistry) }
    def self.fibers_registry
      @fibers_registry ||= ::Iskra::FibersRegistry.new
    end
  end
end
