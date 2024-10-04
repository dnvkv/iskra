# frozen_string_literal: true
# typed: ignore

module Iskra
  class RegisterFinalizer < T::Struct
    extend T::Sig
    extend T::Generic
    extend T::Helpers

    A = type_member

    const :task, Iskra::Task[A]
    const :finalizer, T.proc.void
  end
end