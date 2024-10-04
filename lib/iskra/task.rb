# frozen_string_literal: true
# typed: ignore

module Iskra
  class Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    sealed!
    abstract!

    sig { returns(T.proc.returns(A)) }
    attr_reader :thunk

    sig { params(thunk: T.proc.returns(A)).void }
    def initialize(&thunk)
      @thunk = thunk
    end

    sig { abstract.params(executor: T.nilable(Iskra::Executor)).returns(A) }
    def run!(executor = nil)
    end

    sig { abstract.void }
    def interrupt
    end

    sig { returns(Iskra::Executor) }
    def default_executor
      Iskra::Task.default_executor
    end

    sig { returns(Iskra::Executor) }
    def self.default_executor
      @default_executor ||= Iskra::Executor.new
    end

    private

    sig { returns(T::Boolean) }
    def child_fiber?
      Iskra::Executor.fibers_registry.contains?(Fiber.current)
    end

    module Mixin
      extend T::Sig

      # Creates a concurrent scope, which groups async calls and keeps track
      # of all spawned asynchronous tasks and achieves structured concurrency.
      # That means, concurrent scope created by .task defines life-time scope
      # of each asynchronous computation spawned in the task itself.
      #
      # include Iskra::TaskBuilder::Mixin
      #
      # effect = task {
      #   buffer = []
      #   async1 = async { sleep 1; buffer << 1 }
      #   async2 = async { sleep 2; buffer << 2 }
      #   async3 = async { sleep 3; buffer << 3 }
      #   buffer
      # }
      # effect.run! # [1, 2, 3]
      #
      # That means, the each when effect.await! is completed, all .async
      # spawned in the .task are completed.
      #
      # Represents lazy computation, thus not starting execution right away.
      # To start execution, #await!, #await, or #execute! must be called
      # TODO: consider moving that into a constructor
      sig {
        type_parameters(:A)
          .params(blk: T.proc.returns(T.type_parameter(:A)))
          .returns(Iskra::TaskScope[T.type_parameter(:A)])
      }
      def task(&blk)
        task = Iskra::TaskScope.new(&blk)
        if Iskra::Executor.fibers_registry.contains?(Fiber.current)
          dispatch = Iskra::Dispatch.new(task: task)
          Fiber.yield(dispatch)
          task
        else
          task
        end
      end

      sig {
        type_parameters(:A)
          .params(blk: T.proc.returns(T.type_parameter(:A)))
          .returns(Iskra::Task[T.type_parameter(:A)])
      }
      def async(&blk)
        task = Iskra::Async.new(&blk)
        if Iskra::Executor.fibers_registry.contains?(Fiber.current)
          Fiber.yield(Dispatch.new(task: task))
          task
        else
          Iskra::TaskScope.new { async(&blk) }
        end
      end

      sig {
        params(task: Iskra::Task[T.untyped], blk: T.proc.void).void
      }
      def finalizer(task)
        if Iskra::Executor.fibers_registry.contains?(Fiber.current)
          Fiber.yield(RegisterFinalizer.new(task: task, finalizer: blk))
        end
      end
    end
  end

  class TaskScope < Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    sig(:final) { override.params(executor: T.nilable(Iskra::Executor)).returns(A) }
    def run!(executor = nil)
      if defined?(@_exec_result)
        case @_exec_result
        when Iskra::Executor::Success
          success_value = @_exec_result.value
          T.cast(success_value, A)
        else
          raise @_exec_result.error
        end
      end

      @_exec_result = begin
        current_executor = executor || default_executor

        if child_fiber?
          Fiber.yield(Iskra::Await.new(task: self))
        else
          result = current_executor.execute(self)
          T.cast(result, A)
        end
      end

      case @_exec_result
      when Iskra::Executor::Success
        success_value = @_exec_result.value
        T.cast(success_value, A)
      else
        raise @_exec_result.error
      end
    end

    sig { returns(Dry::Monads::Result[Exception, A]) }
    def run
      success = run!
      Dry::Monads::Result::Success.new(success)
    rescue Exception => error
      Dry::Monads::Result::Failure.new(error)
    end

    sig { override.void }
    def interrupt
    end
  end

  class Async < Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    # Awaits on executing of the effect.
    # If an effect is running inside of any concurrent scope (current fiber was spawned
    # in an executor), yields execution to executor, which awaits until the effect is executed
    # and return either a success value or an error
    # If task is awaited in a fiber that wasn't spawned in an executor, it's
    # executes that task right away in current thread (may block the thread)
    sig { returns(A) }
    def await!
      if defined?(@_exec_result)
        case @_exec_result
        when Iskra::Executor::Success
          success_value = @_exec_result.value
          T.cast(success_value, A)
        else
          raise @_exec_result.error
        end
      end

      @_exec_result = begin
        if child_fiber?
          Fiber.yield(Await.new(task: self))
        else
          raise "Called outside concurrent scope"
        end
      end

      case @_exec_result
      when Iskra::Executor::Success
        success_value = @_exec_result.value
        T.cast(success_value, A)
      else
        raise @_exec_result.error
      end
    end

    sig(:final) { override.params(executor: T.nilable(Iskra::Executor)).returns(A) }
    def run!(executor = nil)
      await!
    end

    sig { override.void }
    def interrupt
      if child_fiber?
        Fiber.yield(Iskra::Cancel.new(task: self))
      end
    end
  end
end
