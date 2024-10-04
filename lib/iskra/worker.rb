# frozen_string_literal: true
# typed: ignore

module Iskra
  class Worker
    extend T::Sig

    module Message
      extend T::Helpers
      sealed!
    end

    class Stop
      include Message
    end

    class IdleTest
      include Message
    end

    class Enqueue < T::Struct
      include Message
      const :task, T.proc.void
    end

    sig { returns(Thread) }
    attr_reader :thread

    sig { params(pool: Iskra::ThreadPool, id: Integer).void }
    def initialize(pool, id)
      # instance variables accessed only under pool's lock so no need to sync here again
      @worker_queue  = T.let(Queue.new, Queue)
      @pool   = T.let(pool, Iskra::ThreadPool)
      @thread = T.let(create_worker(@worker_queue, pool, pool.idletime), Thread)

      if @thread.respond_to?(:name=)
        @thread.name = [pool.name, 'worker', id].compact.join('-')
      end
    end

    sig { params(message: Message).void }
    def <<(message)
      @worker_queue << message
    end

    sig { void }
    def stop
      @worker_queue << Stop.new
    end

    sig { void }
    def kill
      @thread.kill
    end

    private

    sig {
      params(
        queue:    Queue,
        pool:     Iskra::ThreadPool,
        idletime: T.any(Float, Integer)
      ).returns(Thread)
    }
    def create_worker(queue, pool, idletime)
      Thread.new(queue, pool, idletime) do |th_queue, th_pool, th_idletime|
        last_message = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        catch(:stop) do
          loop do
            case message = T.cast(th_queue.pop, Message)
            when IdleTest
              if (Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_message) > th_idletime
                th_pool.remove_busy_worker(self)
                throw :stop
              else
                th_pool.worker_not_old_enough(self)
              end
            when Stop
              th_pool.remove_busy_worker(self)
              throw :stop
            when Enqueue
              task = message.task
              run_task(th_pool, task)
              last_message = Process.clock_gettime(Process::CLOCK_MONOTONIC)

              th_pool.ready_worker(self)
            else
              T.absurd(message)
            end
          end
        end
      end
    end

    # TODO: use logger
    sig {
      params(
        pool: Iskra::ThreadPool,
        task: Proc
      ).void
    }
    def run_task(pool, task)
      task.call
      pool.worker_task_completed
    rescue => ex
      puts ex
    rescue Exception => ex
      puts ex
      pool.worker_died(self)
      throw :stop
    end
  end
end