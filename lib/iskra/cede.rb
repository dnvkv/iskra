# frozen_string_literal: true
# typed: true

module Iskra
  class Cede
    extend T::Sig

    Instance = T.let(
      ::Iskra::Cede.new,
      ::Iskra::Cede
    )
  end
end
