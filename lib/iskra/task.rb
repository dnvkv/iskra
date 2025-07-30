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
          puts raise @_exec_result.error
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
