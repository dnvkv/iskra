# frozen_string_literal: true
# typed: ignore

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'benchmark'
require "benchmark/ips"

include ::Iskra::Task::Mixin

Benchmark.ips do |x|
  run_blocking do
    concurrent do
      x.report("coroutine spawn") { concurrent { } }
    end
  end

  run_blocking do
    concurrent do
      x.report("async spawn") { async { } }
    end
  end

  run_blocking do
    concurrent do
      x.report("scope spawn") { concurrent_scope { } }
    end
  end

  x.compare!
end

puts ""
puts ""

Benchmark.ips do |x|
  run_blocking do
    concurrent do
      x.report("coroutine spawn batch") { 100_000.times { concurrent { } } }
    end
  end

  run_blocking do
    concurrent do
      x.report("async spawn batch") { 100_000.times { async { } } }
    end
  end

  run_blocking do
    concurrent do
      x.report("scope spawn batch") { 100_000.times { concurrent_scope { } } }
    end
  end

  x.compare!
end
