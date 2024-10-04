# frozen_string_literal: true
# typed: ignore

module Iskra
  class Executor
    extend T::Sig

    DEAD_FIBER_MSG = T.let("dead fiber called", String)
    private_constant :DEAD_FIBER_MSG

    sig { returns(Iskra::ThreadPool) }
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

    Success = Iskra::ExecResult::Success
    # private_constant :Success
    Failure = Iskra::ExecResult::Failure
    # private_constant :Failure
    Stack = Iskra::ExecutionStack
    private_constant :Stack

    sig {
      params(
        enable_diagnostics: T::Boolean,
        thread_pool:        T.nilable(Iskra::ThreadPool)
      ).void
    }
    def initialize(enable_diagnostics: false, thread_pool: nil)
      @enable_diagnostics = T.let(enable_diagnostics, T::Boolean)
      @finalizers_map     = T.let({}, T::Hash[Iskra::Task[T.untyped], T.proc.void])
      @finalizers_mutex   = Mutex.new
      @thread_pool        = T.let(
        thread_pool || Iskra::Executor.thread_pool,
        Iskra::ThreadPool
      )
    end

    sig { void }
    def shutdown!
      @thread_pool.shutdown
    end

    # Main execution loop responsible for executing tasks.
    def execute(task, preinitialized_fiber = nil, initial_fibers_tree = nil)
      fiber = preinitialized_fiber || build_new_fiber(task)
      if initial_fibers_tree
        fibers_tree    = initial_fibers_tree
        root_task_node = assert_subtree_presence!(initial_fibers_tree.find_by_task(task))
      else
        fibers_tree = Iskra::FibersDispatchTree.empty(task, fiber)
        root_task_node = fibers_tree
      end

      # Have to explicitly declare all these variables beforehand, since Sorbet
      # doesn't allow to initialize variables inside the loop
      latest_yield          = T.let(nil, T.untyped)
      next_resumed          = T.let(nil, T.untyped)
      current_yield         = T.let(nil, T.untyped)
      execution_result      = T.let(nil, T.untyped)
      current_fiber_subtree = T.let(nil, T.nilable(Iskra::FibersDispatchTree))
      subtask_fiber         = T.let(nil, T.nilable(Fiber))
      task_node             = T.let(nil, T.nilable(Iskra::FibersDispatchTree))
      initial_frame         = Stack::SuspendedTask.new(
        task:                  task,
        current_fiber_subtree: fibers_tree,
        fiber:                 fiber,
        latest_yield:          latest_yield,
        next_resumed:          next_resumed
      )
      stack = T.let([initial_frame], T::Array[Stack::Frame])

      loop do
        current_frame = stack.pop

        if root_task_node.canceled
          raise CancellationException.new("Canceled")
        end

        break execution_result if current_frame.nil?

        case current_frame
        when Stack::SuspendedTask
          current_task          = current_frame.task
          current_fiber         = current_frame.fiber
          current_fiber_subtree = current_frame.current_fiber_subtree
          latest_yield          = current_frame.latest_yield
          next_resumed          = current_frame.next_resumed
        when Stack::ResumeWithLatest
          next_frame = stack.pop
          case next_frame
          when Stack::SuspendedTask
            next_frame_updated = Stack::SuspendedTask.new(
              task:                  next_frame.task,
              fiber:                 next_frame.fiber,
              current_fiber_subtree: next_frame.current_fiber_subtree,
              latest_yield:          next_frame.latest_yield,
              next_resumed:          execution_result
            )
            stack.push(next_frame_updated)
          when Stack::ResumeWithLatest
            raise InternalError.new(InternalError::UNEXPECTED_FRAME_MSG)
          when Stack::SetIVar
            raise InternalError.new(InternalError::UNEXPECTED_FRAME_MSG)
          when nil
            break execution_result
          else
            T.absurd(next_frame)
          end

          next
        when Stack::SetIVar
          task_node = fibers_tree.find_by_task(current_frame.task)
          if task_node.nil?
            raise InternalError.new(InternalError::TASK_NOT_FOUND_MSG)
          else
            new_ivar = ::Concurrent::IVar.new
            new_ivar.set(execution_result)
            task_node.ivar = new_ivar
          end
        else
          T.absurd(current_frame)
        end

        execution_result = loop do
          begin
            if next_resumed.nil?
              current_yield = T.must(current_fiber).resume
            else
              current_yield = T.must(current_fiber).resume(next_resumed)
            end
            # [CANCELLATION] If current task is marked as cancelled should executor cancel it here
            case current_yield
            when Iskra::Dispatch
              # [CANCELLATION] If the task or parent task is interrupted
              # I think the best option would be to modify the tree.
              # So each node will have a state or an interruption flag.
              # The problem is, that tree will be accessed and modified concurrently
              # So I have to figure out how to in a thread safe manner
              # the execution should finish
              dispatched_task = current_yield.task
              case dispatched_task
              when Iskra::Async
                ivar  = ::Concurrent::IVar.new
                task_subtree = assert_subtree_presence!(
                  T.must(current_fiber_subtree).add_child(dispatched_task, nil, ivar)
                )
                @thread_pool.post(dispatched_task, ivar) do
                  begin
                    executor           = Iskra::Executor.new(thread_pool: @thread_pool)
                    @finalizers_mutex.synchronize do
                      @finalizers_map.each do |task, finalizer|
                        executor.register_finalizer(task, finalizer)
                        remove_finalizer(task)
                      end
                    end
                    subtask_fiber      = executor.build_new_fiber(dispatched_task)
                    task_subtree.fiber = subtask_fiber
                    ivar.set(executor.execute(dispatched_task, subtask_fiber, task_subtree))
                  rescue => e
                    ivar.set(Failure.new(e))
                  end
                end
              when Iskra::Task
                # saving current context
                stack.push(
                  Stack::SuspendedTask.new(
                    task:                  T.must(current_task),
                    fiber:                 T.must(current_fiber),
                    current_fiber_subtree: T.must(current_fiber_subtree),
                    latest_yield:          latest_yield,
                    next_resumed:          next_resumed
                  )
                )
                stack.push(Stack::SetIVar.new(task: dispatched_task))
                # pushing a new a task to the stack
                subtask_fiber  = build_new_fiber(dispatched_task)
                fibers_subtree = assert_subtree_presence!(
                  T.must(current_fiber_subtree).add_child(dispatched_task, subtask_fiber)
                )
                stack.push(
                  Stack::SuspendedTask.new(
                    task:                  dispatched_task,
                    fiber:                 subtask_fiber,
                    current_fiber_subtree: fibers_subtree,
                    latest_yield:          nil,
                    next_resumed:          nil
                  )
                )
                break
              end
              latest_yield = current_yield
              next_resumed = dispatched_task
            when Iskra::Await
              awaited_task = T.unsafe(current_yield.task)
              latest_yield = T.unsafe(current_yield)
              case awaited_task
              when Iskra::Async
                stack.push(
                  Stack::SuspendedTask.new(
                    task:                  T.must(current_task),
                    fiber:                 T.must(current_fiber),
                    current_fiber_subtree: T.must(current_fiber_subtree),
                    latest_yield:          latest_yield,
                    next_resumed:          next_resumed
                  )
                )
                subtree = T.must(current_fiber_subtree).find_by_task(awaited_task)
                ivar = assert_ivar_presence!(subtree)
                exec_result = @thread_pool.await(ivar, T.must(subtree))
                stack.push(Stack::ResumeWithLatest.new)
                break exec_result
              when Iskra::Task
                stack.push(
                  Stack::SuspendedTask.new(
                    task:                  T.must(current_task),
                    fiber:                 T.must(current_fiber),
                    current_fiber_subtree: T.must(current_fiber_subtree),
                    latest_yield:          latest_yield,
                    next_resumed:          next_resumed
                  )
                )

                task_node = T.must(current_fiber_subtree).find_by_task(awaited_task)
                if task_node.nil?
                  stack.push(Stack::ResumeWithLatest.new)
                  subtask_fiber = build_new_fiber(awaited_task)
                  fibers_subtree = assert_subtree_presence!(
                    T.must(current_fiber_subtree).add_child(awaited_task, subtask_fiber)
                  )
                  stack.push(
                    Stack::SuspendedTask.new(
                      task:                  T.must(awaited_task),
                      fiber:                 T.must(subtask_fiber),
                      current_fiber_subtree: T.must(fibers_subtree),
                      latest_yield:          nil,
                      next_resumed:          nil
                    )
                  )
                  break
                else
                  ivar = assert_ivar_presence!(T.must(current_fiber_subtree).find_by_task(awaited_task))
                  exec_result = T.must(ivar.value)
                  stack.push(Stack::ResumeWithLatest.new)
                  break exec_result
                end
              end
            when Iskra::Cancel
              interrupted_task = current_yield.task
              subtree = T.must(current_fiber_subtree).find_by_task(interrupted_task)
              if subtree
                subtree.each { |node| node.canceled = true }
              else
                # what if there's no subtree?
              end
            when Iskra::RegisterFinalizer
              finalized_task = current_yield.task
              finalizer      = current_yield.finalizer
              register_finalizer(finalized_task, finalizer)
            else
              latest_yield = current_yield
              next_resumed = nil
            end
          rescue => e
            # TODO: move this into FibersDispatchTree and optimize
            descendant_nodes = T.must(current_fiber_subtree).to_a - [current_fiber_subtree]
            dispatched_results_ivars = descendant_nodes.map(&:ivar).compact

            if is_dead_fiber_called?(e)
              results = dispatched_results_ivars.each { |ivar| @thread_pool.await(ivar, T.must(current_fiber_subtree)) }
              failure = results.find { |result| result.is_a?(Failure) }
              call_finalizer(task)
              if failure.nil?
                break Success.new(latest_yield)
              else
                break failure
              end
            else
              if e.is_a?(InternalError) && enable_diagnostics?
                dump_stack(stack)
              end
              dispatched_results_ivars.each(&:wait)
              call_finalizer(task)
              break Failure.new(e)
            end
          end
        end
      end
      execution_result
    rescue InternalError => e
      if enable_diagnostics?
        dump_stack(stack || [])
      end
      raise e
    ensure
      if task.is_a?(Iskra::TaskScope)
        clear_fibers_from_registry(fibers_tree)
      end
    end

    # Wraps a thunk into a fiber to enable yielding from .async, .task and #await!,
    # and adds created to registry thus allowing to figure if any yielding method
    # is called in concurrent scope
    sig { params(task: Iskra::Task[T.untyped]).returns(Fiber) }
    def build_new_fiber(task)
      Fiber.new { task.thunk.call }.tap { |fiber| fibers_registry.add(fiber) }
    end

    sig {
      params(
        task:      Iskra::Task[T.untyped],
        finalizer: T.proc.void
      ).void
    }
    def register_finalizer(task, finalizer)
      @finalizers_map[task] = finalizer
    end

    private

    sig { params(task: Iskra::Task[T.untyped]).returns(T::Boolean) }
    def remove_finalizer(task)
      if @finalizers_map.has_key?(task)
        @finalizers_map.delete(task)
        true
      else
        false
      end
    end

    sig { returns(T::Boolean) }
    def enable_diagnostics?
      @enable_diagnostics
    end

    sig { params(task: Iskra::Task[T.untyped]).void }
    def call_finalizer(task)
      finalizer = @finalizers_mutex.synchronize do
        finalizer = @finalizers_map[task]
        remove_finalizer(task)
        finalizer
      end
      if finalizer
        begin
          finalizer.call
        rescue
        end
      end
    end

    # TODO: use logger
    sig { params(stack: T::Array[Stack::Frame]).void }
    def dump_stack(stack)
      stack_dump = Iskra::ExecutionStackRenderer.new.render(stack, expand_trees: true)
      puts("Dumping execution stack:\n#{stack_dump}")
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

    sig { params(root: Iskra::FibersDispatchTree).void }
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
      error.is_a?(FiberError) && error.message == DEAD_FIBER_MSG
    end

    sig { returns(Iskra::FibersRegistry) }
    def fibers_registry
      Iskra::Executor.fibers_registry
    end

    sig { returns(Iskra::ThreadPool) }
    def self.thread_pool
      @thread_pool ||= Iskra::ThreadPool.new(min_threads: 4, max_threads: 4)
    end

    sig { returns(Iskra::FibersRegistry) }
    def self.fibers_registry
      @fibers_registry ||= Iskra::FibersRegistry.new
    end
  end
end