# frozen_string_literal: true
# typed: true


module Iskra
  class FibersDispatchTreeRenderer
    extend T::Sig

    sig {
      params(
        tree:        ::Iskra::FibersDispatchTree,
        indentation: Integer
      ).returns(String)
    }
    def render(tree, indentation: 0)
      buffer = String.new
      buffer << with_indentation("#{tree.to_s}\n", indentation)
      buffer << with_indentation("<task=#{tree.task.to_s}>\n", indentation + 1)
      buffer << with_indentation("<fiber=#{tree.fiber.to_s}>\n", indentation + 1)
      buffer << with_indentation("<ivar=#{tree.ivar.to_s}>\n", indentation + 1)
      buffer << with_indentation("<children>\n", indentation + 1)
      tree.children.each do |child_node|
        buffer << render(child_node, indentation: indentation + 2)
      end
      buffer << with_indentation("</children>\n", indentation + 1)
      buffer << with_indentation("#{tree.to_s}\n", indentation)
    end

    private

    sig {
      params(
        string:      String,
        indentation: Integer
      ).returns(String)
    }
    def with_indentation(string, indentation)
      "#{"  " * indentation}#{string}"
    end
  end
end