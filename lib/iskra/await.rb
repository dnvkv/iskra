# frozen_string_literal: true
# typed: strict

module Iskra
  class Await < T::Struct
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    const :task, ::Iskra::Task[A]
  end
end
