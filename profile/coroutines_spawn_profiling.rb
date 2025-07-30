# frozen_string_literal: true
# typed: ignore

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'stackprof'

include ::Iskra::DSL::Mixin

profile = StackProf.run(mode: :wall, raw: true) do
  run_blocking do
    concurrent do
      100.times { concurrent { } }
    end
  end
end

File.write('tmp/stackprof.json', JSON.generate(profile))
