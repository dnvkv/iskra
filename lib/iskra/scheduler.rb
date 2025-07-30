# frozen_string_literal: true
# typed: false

require_relative "collections/priority_queue"
require_relative "collections/queue"

module Iskra
  class Scheduler
    DEFAULT_MAX_OPS_BEFORE_YIELD = 4
    private_constant :DEFAULT_MAX_OPS_BEFORE_YIELD

    attr_reader :op_count

    class TaskAlreadyInAwaiting < StandardError
      MSG = "Task is already in `awaiting` state"
    end

    class TaskContext
      attr_reader :task
      attr_reader :fiber
      attr_reader :next_resumed
      attr_reader :previous_yield
      attr_reader :current_fiber_subtree

      def initialize(task:, fiber:, next_resumed:, previous_yield:, current_fiber_subtree:)
        @task                  = task
        @fiber                 = fiber
        @next_resumed          = next_resumed
        @previous_yield        = previous_yield
        @current_fiber_subtree = current_fiber_subtree
      end

      def with_next_resumed(new_next_resumed)
        TaskContext.new(
          task: task,
          fiber: fiber,
          next_resumed: new_next_resumed,
          current_fiber_subtree: current_fiber_subtree
        )
      end
    end

    def initialize(max_ops_before_yield: DEFAULT_MAX_OPS_BEFORE_YIELD)
      @op_count                   = 0
      @max_ops_before_yield       = max_ops_before_yield
      @queue                      = ::Iskra::Collections::Queue.new
      @delayed_queue              = ::Iskra::Collections::PriorityQueue.new { |a, b| a < b }
      @finished                   = Set.new
      @failed                     = Set.new
      @canceled                   = Set.new
      @awaiting                   = {}
      @tasks_awaiting_on          = {}
      @awaited_values             = {}
      @resume_with                = {}
      @awaiting_children_finished = {}
      @awaiting_children_failed   = {}
    end

    def yield_now?(current_task)
      return true if @finished.include?(current_task)
      return true if @awaiting.include?(current_task)
      @op_count != 0 && @op_count % @max_ops_before_yield == 0
    end

    def increment_op_count
      @op_count += 1
    end

    def add_task(task_context)
      @queue.enqueue(task_context)
    end

    def add_delayed_task(task_context, awake_at)
      @delayed_queue.enqueue(task_context, awake_at)
    end

    def set_finished(task)
      @finished.add(task)
    end

    def set_failed(task)
      @failed.add(task)
    end

    def set_awaiting(task, ivar)
      if @awaiting.has_key?(task)
        raise TaskAlreadyInAwaiting.new(TaskAlreadyInAwaiting::MSG)
      end
      @awaiting[task] = ivar
    end

    def set_resumed(task)
      @awaiting.delete(task)
    end

    def set_canceled(task)
      @canceled.add(task)
    end

    def await_children_finished(task, subtree, finish_value)
      @awaiting_children_finished[task] = [subtree, finish_value]
    end

    def await_children_failed(task, subtree, finish_value)
      @awaiting_children_failed[task] = [subtree, finish_value]
    end

    def await_on(task, value)
      @tasks_awaiting_on[task] = value
      awaited = @awaited_values[value]
      if awaited
        @awaited_values[value] = [*awaited, task]
      else
        @awaited_values[value] = [task]
      end
    end

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
        task_context = @queue.dequeue

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
            subtree.ivar.set(success_value)
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
              # If both queues are empty, and there's only one task which awaits on IVar
              # it makes sense to suspend current thred until IVar is complete to avoid unnecessary CPU
              # this is espially important taking into account that unecessary schedule work will interfere
              # with threads running CPU bound tasks in a thread pool.
              # 
              # If the second check is true, all coroutines in the queue is in awaiting state
              # in this case it makes sense to await until the next ivar will be complete, and the awaiting coroutine is resumed
              #
              # TODO: the optimization is not applied to a delayed queue, so if the queue is empty and there are delayed tasks
              # the scheduler will loop until the next delayed is resumed, or some awaiting task will be resumed.
              if @queue.empty? && @delayed_queue.empty?
                awaiting_ivar.wait
              elsif @queue.size < @awaiting.size && @delayed_queue.empty?
                aggregate_ivar = ::Concurrent::IVar.new
                @awaiting.values.each do |ivar|
                  ivar.add_observer { aggregate_ivar.try_set(true) }
                end
                aggregate_ivar.wait
              end
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