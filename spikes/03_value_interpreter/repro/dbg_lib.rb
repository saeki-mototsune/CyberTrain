# SPIKE (throwaway): does a tree-walking template interpreter over plain polymorphic Ruby values compile under Spinel, and how fast is it?
require_relative "../tparse"
require_relative "../models"

def truthy(v) = !(v.nil? || v == false)

def to_s_value(v)
  case v
  when String then v
  when Integer then v.to_s
  when Float then v.to_s
  when nil then ""
  when true then "true"
  when false then "false"
  when Time then v.strftime("%Y-%m-%d")
  else v.to_s
  end
end

def call_method(recv, sym, name, args)
  case recv
  when String
    case sym
    when :upcase then recv.upcase
    when :downcase then recv.downcase
    when :strip then recv.strip
    when :size, :length then recv.length
    when :empty? then recv.empty?
    when :to_s then recv
    else raise "undefined method #{name} for String"
    end
  when Integer
    case sym
    when :to_s then recv.to_s
    else raise "undefined method #{name} for Integer"
    end
  when Array
    case sym
    when :size, :length then recv.size
    when :empty? then recv.empty?
    when :any? then !recv.empty?
    when :first then recv.first
    when :last then recv.last
    else raise "undefined method #{name} for Array"
    end
  when Hash
    case sym
    when :fetch then recv[args[0]]
    when :size then recv.size
    else recv[name]
    end
  when Time
    case sym
    when :year then recv.year
    when :month then recv.month
    when :day then recv.day
    when :strftime then recv.strftime(args[0])
    else raise "undefined method #{name} for Time"
    end
  when Model
    v = recv.read_attribute(sym)
    v = recv.read_association(sym) if v.nil?
    v
  when nil
    case sym
    when :nil? then true
    else raise "undefined method #{name} for nil"
    end
  else
    raise "undefined method #{name}"
  end
end

def call_helper(sym, name, args)
  case sym
  when :pluralize then pluralize(args[0], args[1])
  when :link_to then link_to(args[0], args[1])
  when :h, :html_escape then html_escape(to_s_value(args[0]))
  else raise "undefined helper #{name}"
  end
end

def eval_expr(n, env)
  case n
  when StrLit then n.value
  when IntLit then n.value
  when NilLit then nil
  when BoolLit then n.value
  when IVarRef then env[n.name]
  when LVarRef then env[n.name]
  when NotNode then !truthy(eval_expr(n.expr, env))
  when BinNode
    case n.op
    when "&&"
      l = eval_expr(n.lhs, env)
      truthy(l) ? eval_expr(n.rhs, env) : l
    when "||"
      l = eval_expr(n.lhs, env)
      truthy(l) ? l : eval_expr(n.rhs, env)
    when "=="
      eval_expr(n.lhs, env) == eval_expr(n.rhs, env)
    else
      eval_expr(n.lhs, env) != eval_expr(n.rhs, env)
    end
  when CallNode
    args = []
    n.args.each { |a| args << eval_expr(a, env) }
    r = n.recv
    if r.nil?
      call_helper(n.sym, n.name, args)
    else
      call_method(eval_expr(r, env), n.sym, n.name, args)
    end
  else
    raise "bad expr node"
  end
end

def exec_body(nodes, env, out)
  nodes.each { |n| exec_node(n, env, out) }
end

def exec_node(n, env, out)
  case n
  when TextNode then out << n.text
  when OutNode
    s = to_s_value(eval_expr(n.expr, env))
    out << (n.escape ? html_escape(s) : s)
  when StmtNode then eval_expr(n.expr, env)
  when IfNode
    if truthy(eval_expr(n.cond, env))
      exec_body(n.then_body, env, out)
    else
      exec_body(n.else_body, env, out)
    end
  when EachNode
    coll = eval_expr(n.coll, env)
    if coll.is_a?(Array)
      coll.each do |item|
        env[n.var] = item
        exec_body(n.body, env, out)
      end
      env.delete(n.var)
    else
      raise "each on non-Array"
    end
  end
end

def render(tree, env)
  out = String.new
  exec_body(tree, env, out)
  out
end

