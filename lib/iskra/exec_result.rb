# frozen_string_literal: true
# typed: true

module Iskra
  class ExecResult
    class Success < ExecResult
      attr_reader :value

      def initialize(value)
        @value = value
      end
    end

    class Failure < ExecResult
      attr_reader :error

      def initialize(error)
        @error = error
      end
    end
  end
end
