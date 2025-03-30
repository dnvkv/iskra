# frozen_string_literal: true
# typed: true

require "mayak"

module Iskra
  class Scheduler
    extend T::Sig

    DEFAULT_MAX_OPS_BEFORE_YIELD = T.let(4, Integer)
    private_constant :DEFAULT_MAX_OPS_BEFORE_YIELD

    sig { returns(Integer) }
    attr_reader :op_count

    class TaskAlreadyInAwaiting < StandardError
      MSG = T.let("Task is already in `awaiting` state", String)
    end

    class TaskContext < T::Struct
      extend T::Sig

      const :task, ::Iskra::Task[T.untyped]
      const :fiber, Fiber
      const :latest_yield, T.untyped
      const :next_resumed, T.untyped
      const :current_fiber_subtree, T.nilable(::Iskra::FibersDispatchTree)

      sig { params(new_next_resumed: T.untyped).returns(TaskContext) }
      def with_next_resumed(new_next_resumed)
        TaskContext.new(
          task: task,
          fiber: fiber,
          latest_yield: latest_yield,
          next_resumed: new_next_resumed,
          current_fiber_subtree: current_fiber_subtree
        )
      end
    end

    sig { params(max_ops_before_yield: Integer).void }
    def initialize(max_ops_before_yield: DEFAULT_MAX_OPS_BEFORE_YIELD)
      @op_count             = T.let(0, Integer)
      @max_ops_before_yield = T.let(max_ops_before_yield, Integer)
      @queue = T.let(
        ::Mayak::Collections::Queue.new,
        ::Mayak::Collections::Queue[TaskContext]
      )
      @delayed_queue = T.let(
        ::Mayak::Collections::PriorityQueue.new { |a, b| a < b },
        ::Mayak::Collections::PriorityQueue[TaskContext, Time]
      )
      @finished = T.let(Set.new, T::Set[::Iskra::Task[T.untyped]])
      @failed = T.let(Set.new, T::Set[::Iskra::Task[T.untyped]])
      @canceled = T.let(Set.new, T::Set[::Iskra::Task[T.untyped]])
      @awaiting = T.let({}, T::Hash[::Iskra::Task[T.untyped], ::Concurrent::IVar])
      @tasks_awaiting_on = T.let({}, T::Hash[::Iskra::Task[T.untyped], T.untyped])
      @awaited_values = T.let({}, T::Hash[T.untyped, T::Array[::Iskra::Task[T.untyped]]])
      @resume_with = T.let({}, T::Hash[::Iskra::Task[T.untyped], T.untyped])
      @awaiting_children_finished = T.let(
        {},
        T::Hash[
          ::Iskra::Task[T.untyped],
          [FibersDispatchTree, T.untyped]
        ]
      )
      @awaiting_children_failed = T.let(
        {},
        T::Hash[
          ::Iskra::Task[T.untyped],
          [FibersDispatchTree, T.untyped]
        ]
      )
    end

    sig { params(current_task: ::Iskra::Task[T.untyped]).returns(T::Boolean) }
    def yield_now?(current_task)
      return true if @finished.include?(current_task)
      return true if @awaiting.include?(current_task)
      @op_count != 0 && @op_count % @max_ops_before_yield == 0
    end

    def increment_op_count
      @op_count += 1
    end

    sig { params(task_context: TaskContext).void }
    def add_task(task_context)
      @queue.enqueue(task_context)
    end

    sig { params(task_context: TaskContext, awake_at: Time).void }
    def add_delayed_task(task_context, awake_at)
      @delayed_queue.enqueue(task_context, awake_at)
    end

    sig { params(task: ::Iskra::Task[T.untyped]).void }
    def set_finished(task)
      @finished.add(task)
    end

    sig { params(task: ::Iskra::Task[T.untyped]).void }
    def set_failed(task)
      @failed.add(task)
    end

    sig {
      params(
        task: ::Iskra::Task[T.untyped],
        ivar: ::Concurrent::IVar
      ).void
    }
    def set_awaiting(task, ivar)
      if @awaiting.has_key?(task)
        raise TaskAlreadyInAwaiting.new(TaskAlreadyInAwaiting::MSG)
      end
      @awaiting[task] = ivar
    end

    sig { params(task: ::Iskra::Task[T.untyped]).void }
    def set_resumed(task)
      @awaiting.delete(task)
    end

    sig { params(task: ::Iskra::Task[T.untyped]).void }
    def set_canceled(task)
      @canceled.add(task)
    end

    sig {
      params(
        task: ::Iskra::Task[T.untyped],
        subtree: FibersDispatchTree,
        finish_value: T.untyped
      ).void
    }
    def await_children_finished(task, subtree, finish_value)
      @awaiting_children_finished[task] = [subtree, finish_value]
    end

    sig {
      params(
        task: ::Iskra::Task[T.untyped],
        subtree: FibersDispatchTree,
        finish_value: T.untyped
      ).void
    }
    def await_children_failed(task, subtree, finish_value)
      @awaiting_children_failed[task] = [subtree, finish_value]
    end

    sig { params(task: ::Iskra::Task[T.untyped], value: T.untyped).void }
    def await_on(task, value)
      @tasks_awaiting_on[task] = value
      awaited = @awaited_values[value]
      if awaited
        @awaited_values[value] = [*awaited, task]
      else
        @awaited_values[value] = [task]
      end
    end

    sig { params(value: T.untyped).void }
    def signal_awake_on(value)
      awaiting_tasks = @awaited_values[value]
      if awaiting_tasks
        task = awaiting_tasks.shift
        if task
          @tasks_awaiting_on.delete(task)
          if @tasks_awaiting_on.empty?
            @awaited_values.delete(value)
          end
        else
          @awaited_values.delete(value)
        end
      end
    end

    # Right now is if the main queue is empty and there are some tasks in delayed_queue
    # the scheduler will just keep iterating until some task is awaken thus wasting CPU resources
    # The solution can be simple, if there are no tasks in main queue, use #sleep to wait to the next task
    sig { returns(T.nilable(TaskContext)) }
    def next_task_to_execute
      loop do
        next_delayed = @delayed_queue.peak
        if !next_delayed.nil?
          next_task_context, next_awake_at = next_delayed
          if next_awake_at < Time.now
            @delayed_queue.dequeue
            break next_task_context
          end
        end
        if @queue.empty?
          if next_delayed.nil?
            break nil 
          else
            # main queue is empty, so no coroutines are currently executed except for suspended with delay
            # calling next here will cause sheduler to loop until next_awake_at, wasting cpu
            # it makes sense to sleep until next_awake_at
            # 
            # sleep_for = next_awake_at - Time.now
            # sleep(sleep_for)
            next
          end
        end
        task_context = T.must(@queue.dequeue)

        if @finished.include?(task_context.task)
          next
        elsif @failed.include?(task_context.task)
          next
        elsif @canceled.include?(task_context.task)
          next
        elsif @tasks_awaiting_on.include?(task_context.task)
          @queue.enqueue(task_context)
          next
        elsif (awaiting_children_finished = @awaiting_children_finished[task_context.task])
          subtree, success_value = awaiting_children_finished
          if subtree.all_descendants_completed?
            set_finished(task_context.task)
            subtree.state_ref.change_to(::Iskra::FiberState::Finished)
            T.must(subtree.ivar).set(success_value)
          else
            @queue.enqueue(task_context)
          end
        else
          awaiting_ivar = @awaiting[task_context.task]
          if awaiting_ivar
            if awaiting_ivar.complete?
              next_resumed = awaiting_ivar.value
              set_resumed(task_context.task)
              break task_context.with_next_resumed(next_resumed)
            else
              @queue.enqueue(task_context)
            end
          else
            break task_context
          end
        end
      end
    end
  end
end