# frozen_string_literal: true
# typed: ignore

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'benchmark/ips'

include ::Iskra::DSL::Mixin

Benchmark.ips do |x|
  x.report("run_blocking") do
    run_blocking do
      concurrent { }
    end
  end
end