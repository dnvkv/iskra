# frozen_string_literal: true
# typed: true

module Iskra
  class Delay < T::Struct
    const :time, T.any(Float, Integer)
  end
end
