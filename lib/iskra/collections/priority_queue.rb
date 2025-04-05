# frozen_string_literal: true
# typed: false

module Iskra
  module Collections
    class PriorityQueue
      attr_reader :size

      def initialize(&compare)
        @array   = []
        @compare = compare
        @size    = 0
      end

      def enqueue(element, priority)
        @array[@size] = [element, priority]
        @size += 1
        sift_up(size - 1)
      end

      def dequeue
        element_index = 0
        result = @array[element_index]

        if @size > 1
          @size -= 1
          @array[element_index] = @array[@size]
          sift_down(element_index)
        else
          @size = 0
        end

        @array[@size] = nil

        result
      end

      def peak
        @array.first
      end

      def clear
        @array = []
        @size = 0
      end

      def to_a
        @array.compact
      end

      def empty?
        size == 0
      end

      private

      def sift_up(element_index)
        index = element_index

        while !root?(index) && compare(index, parent_index(index))
          swap(index, parent_index(index))
          index = parent_index(index)
        end
      end

      def sift_down(element_index)
        index = element_index

        loop do
          left_index = left_child_index(index)
          right_index = right_child_index(index)

          if has_left_child(index) && compare(left_index, index)
            swap(index, left_index)
            index = left_index
          elsif has_right_child(index) && compare(right_index, index)
            swap(index, right_index)
            index = right_index
          else
            break
          end
        end
      end

      def swap(index1, index2)
        @array[index1], @array[index2] = @array[index2], @array[index1]
      end

      def compare(index1, index2)
        value1 = @array[index1]
        value2 = @array[index2]

        raise StandardError.new("index out of bound") if value1.nil? || value2.nil?

        _, priority1 = value1
        _, priority2 = value2

        @compare.call(priority1, priority2)
      end

      def has_parent(index)
        index >= 1
      end

      def parent_index(index)
        ((index - 1) / 2).floor
      end

      def has_left_child(index)
        left_child_index(index) < @size
      end

      def left_child_index(index)
        index * 2 + 1
      end

      def has_right_child(index)
        right_child_index(index) < @size
      end

      def right_child_index(index)
        index * 2 + 2
      end

      def root?(index)
        index == 0
      end
    end
  end
end