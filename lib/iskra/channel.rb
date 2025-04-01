# frozen_string_literal: true
# typed: true

module Iskra
  class Channel
    extend T::Sig
    extend T::Generic

    Value = type_member

    include ::Iskra::Task::Mixin

    class OnFull < T::Enum
      enums do
        Drop  = new
        Wait  = new
        Raise = new
      end
    end

    sig { returns(T.nilable(Integer)) }
    attr_reader :max_size

    sig { params(max_size: T.nilable(Integer), on_full: OnFull::Drop).void }
    def initialize(max_size: nil, on_full: OnFull::Drop)
      @max_size = T.let(max_size, T.nilable(Integer))
      @on_full  = T.let(on_full, OnFull)
      @buffer   = T.let([], T::Array[Value])
      @closed   = T.let(false, T::Boolean)
    end

    sig { params(element: Value).returns(::Iskra::Task[T::Boolean]) }
    def post(element)
      dispatch_task(label: "channel-post") do
        signal = T.let(nil, T.nilable(::Iskra::SignalAwakeOn[T.untyped]))
        if @closed
          raise StandardError.new("Attempting to post to closed channel")
        elsif !bounded?
          @buffer.unshift(element)
          if @buffer.size == 1
            signal = ::Iskra::SignalAwakeOn.new(value: self)
            Fiber.yield(signal)
          end
          T.cast(true, T::Boolean)
        else
          if @buffer.size == max_size
            case @on_full
            when OnFull::Drop
              T.cast(false, T::Boolean)
            when OnFull::Wait
              loop do
                await = ::Iskra::AwaitOn.new(value: self)
                Fiber.yield(await)
                if @buffer.size < T.must(@max_size)
                  @buffer.unshift(element)
                  if @buffer.size == 1
                    signal = ::Iskra::SignalAwakeOn.new(value: self)
                    Fiber.yield(signal)
                  end
                  break T.cast(true, T::Boolean)
                end
              end
            when OnFull::Raise
              raise StandardError.new("Posting into a full channel")
            else
              T.absurd(@on_full)
            end
          else
            @buffer.unshift(element)
            if @buffer.size == 1
              signal = ::Iskra::SignalAwakeOn.new(value: self)
              Fiber.yield(signal)
            end
            T.cast(true, T::Boolean)
          end
        end
      end
    end

    sig { params(timeout: T.nilable(T.any(Float, Integer))).returns(::Iskra::Task[Value]) }
    def receive(timeout: nil)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dispatch_task(label: "channel-receive") do
        if @closed
          raise StandardError.new("Attempting to post to closed channel")
        else
          if @buffer.size == 0
            loop do
              await = ::Iskra::AwaitOn.new(value: self)
              Fiber.yield(await)
              if @buffer.size > 0
                element = @buffer.pop
                if bounded? && @buffer.size == (T.must(@max_size) - 1)
                  signal = ::Iskra::SignalAwakeOn.new(value: self)
                  Fiber.yield(signal)
                end
                break T.must(element)
              end
              current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if timeout && (current_time - start_time) > timeout
                raise StandardError.new("Timeout error")
              end
            end
          else
            element = @buffer.pop
            if bounded? && @buffer.size == (T.must(@max_size) - 1)
              signal = ::Iskra::SignalAwakeOn.new(value: self)
              Fiber.yield(signal)
            end
            T.must(element)
          end
        end
      end
    end

    sig { returns(::Iskra::Task[T::Boolean]) }
    def close
      dispatch_task do
        raise StandardError.new("Attempt to close already closed channel") if @closed
        @closed = true
        T.cast(true, T::Boolean)
      end
    end

    sig { returns(::Iskra::Task[T::Boolean]) }
    def closed?
      dispatch_task { @closed }
    end

    sig { returns(::Iskra::Task[Integer]) }
    def size
      dispatch_task { @buffer.size }
    end

    sig { returns(::Iskra::Task[T::Boolean]) }
    def empty?
      dispatch_task { @buffer.size > 0 }
    end

    sig { returns(::Iskra::Task[T::Boolean]) }
    def full?
      dispatch_task do
        if bounded?
          @buffer.size == @max_size
        else
          false
        end
      end
    end

    sig { returns(T::Boolean) }
    def bounded?
      !@max_size.nil?
    end

    private

    sig {
      type_parameters(:A)
        .params(label: T.nilable(String), blk: T.proc.returns(T.type_parameter(:A)))
        .returns(::Iskra::Coroutine[T.type_parameter(:A)])
    }
    def dispatch_task(label: nil, &blk)
      task = ::Iskra::Coroutine.new(label: label, &blk)
      if ::Iskra::Runtime.fibers_registry.contains?(Fiber.current)
        dispatch = ::Iskra::Dispatch.new(task: task)
        Fiber.yield(dispatch)
        task
      else
        task
      end
    end
  end
end
