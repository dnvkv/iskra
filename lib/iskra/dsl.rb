# frozen_string_literal: true
# typed: true

require_relative "runtime"

module Iskra
  module DSL
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
        type_parameters(:A, :B)
          .params(
            channel: Iskra::Channel[T.type_parameter(:B)],
            label: T.nilable(String),
            blk: T.proc.params(arg0: Iskra::Channel[T.type_parameter(:B)]).returns(T.type_parameter(:A))
          ).returns(::Iskra::Coroutine[T.type_parameter(:A)])
      }
      def with_channel(channel, label: nil, &blk)
        concurrent(label: label) do
          result = concurrent { blk.call(channel) }.await!
          channel.close
          result
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
          .params(label: T.nilable(String), blk: T.proc.returns(T.type_parameter(:A)))
          .returns(T.type_parameter(:A))
      }
      def blocking!(label: nil, &blk)
        async(label: label, &blk).await!
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
        # TOOD: should initiate a fibers registry and perform a clean up later
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

    extend Mixin
  end
end