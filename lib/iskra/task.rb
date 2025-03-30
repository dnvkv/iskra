# frozen_string_literal: true
# typed: true

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

    sig { returns(T.nilable(String)) }
    attr_reader :label

    sig { params(label: T.nilable(String), thunk: T.proc.returns(A)).void }
    def initialize(label: nil, &thunk)
      @label = label
      @thunk = thunk
    end

    sig { returns(::Iskra::Runtime) }
    def default_runtime
      ::Iskra::Task.default_runtime
    end

    sig { returns(::Iskra::Runtime) }
    def self.default_runtime
      @default_executor ||= ::Iskra::Runtime.new
    end

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
        when ::Iskra::ExecResult::Success
          success_value = @_exec_result.value
          T.cast(success_value, A)
        else
          raise @_exec_result.error
        end
      end

      @_exec_result = begin
        if child_fiber?
          Fiber.yield(::Iskra::Await.new(task: self))
        else
          raise OutsideOfConcurrentScopeError.new("Called outside concurrent scope")
        end
      end

      case @_exec_result
      when ::Iskra::ExecResult::Success
        success_value = @_exec_result.value
        T.cast(success_value, A)
      else
        raise @_exec_result.error
      end
    end

    sig { void }
    def cancel
      if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
        Fiber.yield(::Iskra::Cancel.new(task: self))
      else
        raise OutsideOfConcurrentScopeError.new("Invalid call to #cancel outside of concurrent context")
      end
    end

    private

    sig { returns(T::Boolean) }
    def child_fiber?
      ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
    end

    module Mixin
      extend T::Sig

      include Kernel

      sig {
        type_parameters(:A)
          .params(label: T.nilable(String), blk: T.proc.returns(T.type_parameter(:A)))
          .returns(::Iskra::Coroutine[T.type_parameter(:A)])
      }
      def concurrent(label: nil, &blk)
        task = ::Iskra::Coroutine.new(label: label, &blk)
        if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
          dispatch = ::Iskra::Dispatch.new(task: task)
          Fiber.yield(dispatch)
          task
        else
          task
        end
      end

      sig { params(time: T.any(Float, Integer)).void }
      def delay(time)
        if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
          Fiber.yield(::Iskra::Delay.new(time: time))
        else
          raise OutsideOfConcurrentScopeError.new("Invalid call to #delay outside of concurrent context")
        end
      end

      sig {
        type_parameters(:A)
          .params(label: T.nilable(String), blk: T.proc.returns(T.type_parameter(:A)))
          .returns(::Iskra::ConcurrentScope[T.type_parameter(:A)])
      }
      def concurrent_scope(label: nil, &blk)
        task = ::Iskra::ConcurrentScope.new(label: label, &blk)
        if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
          dispatch = ::Iskra::Dispatch.new(task: task)
          Fiber.yield(dispatch)
          task
        else
          task
        end
      end

      sig {
        type_parameters(:A)
          .params(label: T.nilable(String), blk: T.proc.returns(T.type_parameter(:A)))
          .returns(::Iskra::Task[T.type_parameter(:A)])
      }
      def async(label: nil, &blk)
        task = ::Iskra::Async.new(label: label, &blk)
        if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
          Fiber.yield(Dispatch.new(task: task))
          task
        else
          ::Iskra::Coroutine.new(label: label) { async(&blk) }
        end
      end

      sig {
        type_parameters(:A)
          .params(blk: T.proc.returns(T.type_parameter(:A)))
          .returns(T.type_parameter(:A))
      }
      def blocking!(&blk)
        async(&blk).await!
      end

      sig { void }
      def cede
        if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
          Fiber.yield(Cede::Instance)
        else
          raise OutsideOfConcurrentScopeError.new("Invalid call to #cede outside of concurrent context")
        end
      end

      sig(:final) {
        type_parameters(:A)
          .params(
            runtime: T.nilable(::Iskra::Runtime),
            debug: T::Boolean,
            blk: T.proc.returns(::Iskra::Task[T.type_parameter(:A)])
          ).returns(T.type_parameter(:A))
      }
      def run_blocking(runtime = nil, debug: false, &blk)
        default_runtime = ::Iskra::Task.default_runtime
        current_runtime = runtime || default_runtime
        task = blk.call

        result = current_runtime.execute(task, debug: debug)
        case result
        when ::Iskra::ExecResult::Success
          success_value = result.value
          T.cast(success_value, T.type_parameter(:A))
        else
          raise result.error
        end
      end
    end
  end

  class Coroutine < Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member
  end

  class Async < Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member
  end

  class ConcurrentScope < Task
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member
  end
end
