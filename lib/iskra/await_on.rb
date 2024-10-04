# frozen_string_literal: true
# typed: true

module Iskra
  class AwaitOn < T::Struct
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    const :value, A
  end
end