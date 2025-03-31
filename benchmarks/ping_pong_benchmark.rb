# frozen_string_literal: true
# typed: ignore

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'benchmark/ips'

include ::Iskra::Task::Mixin

include ::Iskra::Task::Mixin

Benchmark.ips do |x|
  run_blocking do
    concurrent do
      channel = ::Iskra::Channel[Integer].new

      concurrent do
        x.report("ping-pong") do
          producer = concurrent do
            channel.post(1).await!
          end
      
          consumer = concurrent do
            channel.receive.await!
          end
        end
      end.await!

      channel.close.await!
    end
  end
end