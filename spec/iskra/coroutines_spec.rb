# typed: false
# frozen_string_literal: true

require "spec_helper"

require_relative "../../lib/iskra/outside_of_conccurrent_scope_error"

describe "Iskra Corotines" do
  context "when calling outside of concurrent scope" do
    describe "Async#await!" do
      it "raises error" do
        async = ::Iskra::Async.new(label: nil) { 10 }
        expect { async.await! }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end

    describe "Async#cancel" do
      it "raises error" do
        async = ::Iskra::Async.new(label: nil) { 10 }
        expect { async.cancel }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end

    describe "Coroutine#await!" do
      it "raises error" do
        coroutine = ::Iskra::Coroutine.new(label: nil) { 10 }
        expect { coroutine.await! }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end

    describe "Coroutine#cancel" do
      it "raises error" do
        coroutine = ::Iskra::Coroutine.new(label: nil) { 10 }
        expect { coroutine.cancel }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end

    describe "ConcurrentScope#await!" do
      it "raises error" do
        scope = ::Iskra::ConcurrentScope.new(label: nil) { 10 }
        expect { scope.await! }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end

    describe "ConcurrentScope#cancel" do
      it "raises error" do
        scope = ::Iskra::ConcurrentScope.new(label: nil) { 10 }
        expect { scope.cancel }.to raise_error(::Iskra::OutsideOfConcurrentScopeError)
      end
    end
  end

  describe "coroutines" do
    include ::Iskra::Task::Mixin

    it "executes coroutine in concurrent block" do
      result = run_blocking do
        concurrent { "success" }
      end
      expect(result).to eq("success")
    end

    it "raises an error if it was raised by coroutine" do
      CorotuineError = Class.new(StandardError)

      expect {
        run_blocking do
          concurrent { raise CorotuineError.new("Error") }
        end
      }.to raise_error(CorotuineError)
    end

    it "executes all nested coroutines" do
      result = run_blocking do
        concurrent do
          buffer = []
          concurrent { buffer << "result" }
          concurrent { buffer << "result" }
          buffer
        end
      end
      expect(result).to eq(["result", "result"])
    end

    context "delays" do
      it "suspends for a specified time" do
        result = run_blocking do
          concurrent do
            starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            delay(0.1)
            ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            ending - starting
          end
        end

        expect(result > 0.1 && result < 0.11).to be_truthy
      end

      it "suspends coroutines during delays" do
        result = run_blocking do
          concurrent do
            buffer = []
            coroutine1 = concurrent do
              delay(0.2)
              buffer << 1
            end
        
            coroutine2 = concurrent do
              delay(0.1)
              buffer << 2
            end
            buffer
          end
        end

        expect(result).to eq([2, 1])
      end

      it "doesn't block with delay" do
        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = run_blocking do
          concurrent do
            concurrent { delay(0.1) }
            concurrent { delay(0.1) }
            concurrent { delay(0.1) }
          end
        end
        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = ending - starting
        expect(elapsed < 0.2).to be_truthy
      end
    end

    context "cede" do
      it "cedes execution to runtime" do
        result = run_blocking do
          concurrent do
            result = []

            concurrent do
              10_000.times { cede }
              result << 2
            end

            concurrent do
              result << 1
            end

            result
          end
        end

        expect(result).to eq([1, 2])
      end
    end

    context "awaiting" do
      it "allows to suspend coroutine with await" do
        result = run_blocking do
          concurrent do
            buffer = []
            c1 = concurrent do
              buffer << 1
            end
            c1.await!
            buffer << 2
            buffer
          end
        end

        expect(result).to eq([1, 2])
      end
    end

    context "async execution" do
      it "doesn't block the main thread" do
        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = run_blocking do
          concurrent do
            buffer = []
            async1 = async { sleep(0.1); buffer << 1 }
            async2 = async { sleep(0.1); buffer << 2 }
            async3 = async { sleep(0.1); buffer << 3 }
            async4 = async { sleep(0.1); buffer << 4 }
            buffer
          end
        end
        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = ending - starting

        expect(result.sort).to eq([1, 2, 3, 4])
        expect(elapsed < 0.2).to be_truthy
      end

      it "awaiting async execution" do
        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = run_blocking do
          concurrent do
            async1 = async do
              sleep(0.1)
              1
            end
            async2 = async do
              sleep(0.2)
              2
            end
            [async1.await!, async2.await!]
          end
        end
        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = ending - starting

        expect(result).to eq([1, 2])
        expect(elapsed < 0.3).to be_truthy
      end
    end

    context "concurrent scopes" do
      it "suspends parent coroutine until the scope is finished" do
        result = run_blocking do
          concurrent do
            buffer = []
            concurrent_scope do
              delay(0.1)
              buffer << 1
        
              delay(0.1)
              buffer << 2
            end
            buffer << 3
            buffer
          end
        end

        expect(result).to eq([1, 2, 3])
      end
    end

    context "channels" do
      it "passes values" do
        result = run_blocking do
          concurrent do
            channel = Iskra::Channel[String].new

            consumer = concurrent do
              channel.receive.await!
            end
        
            producer = concurrent do
              channel.post("Hello world!")
            end

            result = consumer.await!
        
            channel.close

            result
          end
        end

        expect(result).to eq("Hello world!")
      end

      describe "#with_channel" do
        it "provides a channel and closes it" do
          result = run_blocking do
            concurrent do
              channel = Iskra::Channel[String].new
              channel_result = with_channel(channel) do |inner_channel|
                consumer = concurrent { inner_channel.receive.await! }
                concurrent { inner_channel.post(:result) }
                consumer.await!
              end.await!
              [channel.closed?.await!, channel_result]
            end
          end
  
          expect(result).to eq([true, :result])
        end
      end
    end
  end
end