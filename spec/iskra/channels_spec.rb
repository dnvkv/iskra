# typed: false
# frozen_string_literal: true

require "spec_helper"

describe "Iskra Channel" do
  include ::Iskra::Task::Mixin
  
  describe "suspensions" do
    it "suspends when receiving from an empty channel" do
      result = run_blocking do
        concurrent do
          buffer = []

          channel = Iskra::Channel[Integer].new
          concurrent do
            delay(0.1)
            buffer << 1
            channel.post(1).await!
          end
          channel.receive.await!
          buffer << 2
          channel.close
          buffer
        end
      end

      expect(result).to eq([1, 2])
    end

    it "suspends when posting to a full channel" do
      result = run_blocking do
        concurrent do
          buffer = []

          channel = Iskra::Channel[Integer].new(max_size: 1, on_full: Iskra::Channel::OnFull::Wait)
          concurrent do
            delay(0.1)
            buffer << 1
            channel.receive.await!
          end
          channel.post(1).await!
          channel.post(1).await!
          buffer << 2
          channel.close
          buffer
        end
      end

      expect(result).to eq([1, 2])
    end
  end

  describe "synchronization" do
    it ""
  end

  describe "backpressure" do
    
  end
end