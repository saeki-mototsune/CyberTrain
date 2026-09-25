# SPIKE (throwaway): W1 seed-then-clear - empty [] ivars in two node classes, frames aliasing them
class Node; end
class T < Node; def initialize(t) = @t = t; def t = @t; end
class I < Node
  attr_reader :then_body, :else_body
  def initialize(c)
    @c = c
    @then_body = [Node.new]; @then_body.clear
    @else_body = [Node.new]; @else_body.clear
  end
end
class Frame
  attr_accessor :body, :ifn
  def initialize(body, ifn) ; @body = body; @ifn = ifn; end
end
root = [Node.new]; root.clear
stack = [Frame.new(root, nil)]
%w[t if t else t end].each do |w|
  top = stack.last
  if w == "if"
    n = I.new(w); top.body << n; stack << Frame.new(n.then_body, n)
  elsif w == "else"
    top.body = top.ifn.else_body
  elsif w == "end"
    stack.pop
  else
    top.body << T.new(w)
  end
end
puts root.size
