# frozen_string_literal: true
# typed: ignore

module Iskra
  class FibersRegistry
    extend T::Sig

    def initialize
      @set = T.let(Set.new, T::Set[Fiber])
    end

    sig { params(fiber: Fiber).void }
    def add(fiber)
      @set.add(fiber)
    end

    sig { params(fiber: Fiber).void }
    def remove(fiber)
      @set.delete(fiber)
    end

    sig { params(fiber: Fiber).returns(T::Boolean) }
    def contains?(fiber)
      @set.include?(fiber)
    end
  end
end