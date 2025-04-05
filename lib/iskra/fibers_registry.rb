# frozen_string_literal: true
# typed: true

module Iskra
  class FibersRegistry
    def initialize
      @set = Set.new
    end

    def add(fiber)
      @set.add(fiber)
    end

    def remove(fiber)
      @set.delete(fiber)
    end

    def contains?(fiber)
      @set.include?(fiber)
    end
  end
end