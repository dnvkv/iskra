# frozen_string_literal: true
# typed: false

module Iskra
  module Collections
    class Queue
      class Node < Struct.new(:value, :next)
      end
      private_constant :Node

      attr_reader :size

      def initialize(initial: [])
        @head = nil
        @tail = nil
        @size = 0
        initial.each { |element| enqueue(element) }
      end

      def enqueue(element)
        if @head.nil?
          @head = Node.new(value: element, next: nil)
          @tail = @head
          @size += 1
        else
          @tail.next = Node.new(value: element, next: nil)
          @tail = @tail.next
          @size += 1
        end
      end

      def peak
        return if @head.nil?

        @head.value
      end

      def dequeue
        return if @size == 0
        return if @head.nil?

        element = @head.value
        @head = @head.next
        @size -= 1
        @tail = nil if @size == 0
        element
      end

      def empty?
        @size == 0
      end
    end
  end
end