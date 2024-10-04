# typed: true

class Fiber
  extend T::Sig

  sig { params(blk: T.proc.returns(T.untyped)).void }
  def initialize(&blk)
  end

  sig { returns(Fiber) }
  def self.current;
  end
end