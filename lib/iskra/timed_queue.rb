# frozen_string_literal: true
# typed: ignore

module Iskra
  class TimedQueue
    extend T::Sig
    extend T::Generic

    class TimeoutError < ThreadError
    end

    Value = type_member

    sig { params(limit: T.nilable(Integer)).void }
    def initialize(limit: nil)
      raise ArgumentError.new("max_queue is less than zero") if !@limit.nil? && @limit < 0

      @elements = T.let([], T::Array[Value])
      @limit    = T.let(limit, T.nilable(Integer))
      @mutex    = T.let(Mutex.new, Mutex)
      @cond_var = T.let(ConditionVariable.new, ConditionVariable)
    end

    sig { params(value: Value).returns(T::Boolean) }
    def enqueue(value)
      @mutex.synchronize do
        if !@limit.nil? && @limit != 0 && @elements.length == @limit
          return false
        end
        @elements << value
        @cond_var.signal
        true
      end
    end
    alias << enqueue

    sig { params(blocking: T::Boolean, timeout: T.nilable(Float)).returns(Value) }
    def dequeue(blocking: true, timeout: nil)
      if timeout.nil?
        dequeue_without_timeout(blocking)
      else
        dequeue_with_timeout(blocking, timeout)
      end
    end
    alias pop dequeue

    sig { returns(Integer) }
    def length
      @mutex.synchronize { @elements.length }
    end

    sig { void }
    def clear
      @mutex.synchronize { @elements.clear }
    end

    private

    sig { params(blocking: T::Boolean).returns(Value) }
    def dequeue_without_timeout(blocking)
      @mutex.synchronize do
        if blocking
          while @elements.empty?
            @cond_var.wait(@mutex)
          end
        end
        raise ThreadError.new("The queue is empty") if @elements.empty?
        @elements.shift
      end
    end

    sig { params(blocking: T::Boolean, timeout: Float).returns(Value) }
    def dequeue_with_timeout(blocking, timeout)
      @mutex.synchronize do
        if blocking
          timeout_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          remaining_time = timeout_time - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          while @elements.empty? && remaining_time > 0
            @cond_var.wait(@mutex, timeout)
            remaining_time = timeout_time  - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
        raise TimeoutError.new("The queue is empty") if @elements.empty?
      end
    end
  end
end
