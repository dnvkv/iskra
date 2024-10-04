# frozen_string_literal: true
# typed: true

module Iskra
  class FibersDispatchTree
    extend T::Sig

    sig { returns(::Iskra::Task[T.untyped]) }
    attr_reader :task

    sig { returns(T::Array[FibersDispatchTree]) }
    attr_reader :children

    sig { returns(T.nilable(Fiber)) }
    attr_accessor :fiber

    sig { returns(T.nilable(::Concurrent::IVar)) }
    attr_accessor :ivar

    sig { returns(T::Boolean) }
    attr_accessor :canceled

    sig { returns(::Iskra::FiberState::Ref) }
    attr_reader :state_ref

    sig {
      params(
        task:  ::Iskra::Task[T.untyped],
        fiber: T.nilable(Fiber),
        ivar:  T.nilable(::Concurrent::IVar)
      ).returns(FibersDispatchTree)
    }
    def self.empty(task, fiber, ivar = nil)
      FibersDispatchTree.new(
        task:     task,
        fiber:    fiber,
        children: [],
        ivar:     ivar
      )
    end

    sig {
      params(
        task:     ::Iskra::Task[T.untyped],
        fiber:    T.nilable(Fiber),
        children: T::Array[FibersDispatchTree],
        ivar:     T.nilable(::Concurrent::IVar)
      ).void
    }
    def initialize(task:, fiber:, children:, ivar:)
      @task     = T.let(task, ::Iskra::Task[T.untyped])
      @fiber    = T.let(fiber, T.nilable(Fiber))
      @children = T.let(children, T::Array[FibersDispatchTree])
      @state_ref = ::Iskra::FiberState::Ref.new(
        ::Iskra::FiberState::Pending
      )
      @ivar = T.let(ivar, T.nilable(::Concurrent::IVar))
      @children_task_map = T.let(
        @children.map { |child| [child.task, child] }.to_h,
        T::Hash[::Iskra::Task[T.untyped], FibersDispatchTree]
      )
    end

    sig { returns(::Iskra::FiberState) }
    def state
      state_ref.state
    end

    sig { returns(T::Array[FibersDispatchTree]) }
    def descendants
      to_a - [self]
    end

    sig { returns(T::Boolean) }
    def all_descendants_completed?
      descendants.all? { |node| node.state_ref.state.finished? || node.state_ref.state.failed? }
    end

    sig {
      params(
        task:  ::Iskra::Task[T.untyped],
        fiber: T.nilable(Fiber),
        ivar:  T.nilable(::Concurrent::IVar)
      ).returns(T.nilable(FibersDispatchTree))
    }
    def add_child(task, fiber, ivar = nil)
      return nil if @children_task_map.include?(task)

      subtree = FibersDispatchTree.empty(task, fiber, ivar)
      @children.push(subtree)
      @children_task_map[task] = subtree
      subtree
    end

    # TODO: consider adding caching across all nodes
    sig {
      params(
        blk: T.proc.params(arg0: FibersDispatchTree).returns(T::Boolean)
      ).returns(T.nilable(FibersDispatchTree))
    }
    def find(&blk)
      return self if blk.call(self)

      queue    = T.let([], T::Array[FibersDispatchTree])
      explored = T.let(Set.new, T::Set[FibersDispatchTree])

      explored.add(self)
      queue.push(self)

      until queue.empty?
        node = T.must(queue.shift)

        return node if blk.call(node)

        node.children.each do |child|
          unless explored.include?(child)
            explored.add(child)
            queue.push(child)
          end
        end
      end
    end

    sig {
      params(
        task: ::Iskra::Task[T.untyped]
      ).returns(T.nilable(FibersDispatchTree))
    }
    def find_by_task(task)
      return @children_task_map[task] if @children_task_map.key?(task)
      find { |node| node.task == task }
    end

    sig { params(blk: T.proc.params(arg0: FibersDispatchTree).void).void }
    def each(&blk)
      added    = T.let(Set.new, T::Set[FibersDispatchTree])
      queue    = T.let([], T::Array[FibersDispatchTree])

      blk.call(self)
      added.add(self)
      queue.push(self)

      until queue.empty?
        node = T.must(queue.shift)

        node.children.each do |child|
          unless added.include?(child)
            added.add(child)
            blk.call(child)
            queue.push(child)
          end
        end
      end
    end

    sig { returns(T::Array[FibersDispatchTree]) }
    def to_a
      result = []
      each { |node| result << node }
      result
    end

    sig { returns(T::Boolean) }
    def leaf?
      @children.empty?
    end
  end
end