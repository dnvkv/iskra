# frozen_string_literal: true
# typed: true

module Iskra
  class FiberState < T::Enum
    extend T::Sig

    enums do
      Pending      = new("pending")
      Running      = new("running")
      Suspended    = new("suspended")
      ScopeWaiting = new("scope_waiting")
      Canceled     = new("canceled")
      Finished     = new("finished")
      Failed       = new("failed")
    end

    sig { returns(T::Boolean) }
    def pending?
      case self
      when ::Iskra::FiberState::Pending then true
      else false
      end
    end

    sig { returns(T::Boolean) }
    def running?
      case self
      when ::Iskra::FiberState::Running then true
      else false
      end
    end

    sig { returns(T::Boolean) }
    def suspended?
      case self
      when ::Iskra::FiberState::Suspended then true
      else false
      end
    end

    def scope_waiting?
      case self
      when ::Iskra::FiberState::ScopeWaiting then true
      else false
      end
    end

    def canceled?
      case self
      when ::Iskra::FiberState::Canceled then true
      else false
      end
    end

    sig { returns(T::Boolean) }
    def finished?
      case self
      when ::Iskra::FiberState::Finished then true
      else false
      end
    end

    sig { returns(T::Boolean) }
    def failed?
      case self
      when ::Iskra::FiberState::Failed then true
      else false
      end
    end

    def completed?
      canceled? || finished? || failed?
    end

    class Ref
      extend T::Sig

      class InvalidTransitionError < StandardError
      end

      sig { returns(::Iskra::FiberState) }
      attr_reader :state

      sig { params(state: ::Iskra::FiberState).void }
      def initialize(state)
        @state = T.let(state, ::Iskra::FiberState)
      end

      sig { params(new_state: ::Iskra::FiberState).returns(Ref) }
      def change_to(new_state)
        case @state
        when Pending
          case new_state
          when Pending      then raise invalid_transition_error(@state, new_state)
          when Running      then @state = new_state
          when Suspended    then raise invalid_transition_error(@state, new_state)
          when ScopeWaiting then raise invalid_transition_error(@state, new_state)
          when Canceled     then @state = new_state
          when Finished     then raise invalid_transition_error(@state, new_state)
          when Failed       then raise invalid_transition_error(@state, new_state)
          else
            T.absurd(new_state)
          end
        when Running
          case new_state
          when Pending      then raise invalid_transition_error(@state, new_state)
          when Running      then raise invalid_transition_error(@state, new_state)
          when Suspended    then @state = new_state
          when ScopeWaiting then @state = new_state
          when Canceled     then @state = new_state
          when Finished     then @state = new_state
          when Failed       then @state = new_state
          else
            T.absurd(new_state)
          end
        when Suspended
          case new_state
          when Pending      then raise invalid_transition_error(@state, new_state)
          when Running      then @state = new_state
          when Suspended    then raise invalid_transition_error(@state, new_state)
          when ScopeWaiting then raise invalid_transition_error(@state, new_state)
          when Canceled     then @state = new_state
          when Finished     then raise invalid_transition_error(@state, new_state)
          when Failed       then raise invalid_transition_error(@state, new_state)
          else
            T.absurd(new_state)
          end
        when ScopeWaiting
          case new_state
          when Pending      then raise invalid_transition_error(@state, new_state)
          when Running      then raise invalid_transition_error(@state, new_state)
          when Suspended    then raise invalid_transition_error(@state, new_state)
          when ScopeWaiting then raise invalid_transition_error(@state, new_state)
          when Canceled     then @state = new_state
          when Finished     then @state = new_state
          when Failed       then @state = new_state
          else
            T.absurd(new_state)
          end
        when Finished
          raise invalid_transition_error(@state, new_state)
        when Failed
          raise invalid_transition_error(@state, new_state)
        when Canceled
          raise invalid_transition_error(@state, new_state)
        else
          T.absurd(@state)
        end
        self
      end

      private

      def invalid_transition_error(from, to)
        InvalidTransitionError.new("Invalid transition from `#{from.serialize}` to `#{to.serialize}`")
      end
    end
  end
end
