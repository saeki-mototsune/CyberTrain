# SPIKE (throwaway): does a monomorphic AST (one INode class, int kind, typed slots) + poly values beat the class-per-node AST under Spinel?
require_relative "tparse"
require_relative "models"

K_TEXT = 0
K_OUT = 1
K_RAW = 2
K_STMT = 3
K_IF = 4
K_EACH = 5
K_STR = 6
K_INT = 7
K_NIL = 8
K_TRUE = 9
K_FALSE = 10
K_VAR = 11
K_CALL = 12
K_HELPER = 13
K_AND = 14
K_OR = 15
K_EQ = 16
K_NE = 17
K_NOT = 18

class INode
  attr_reader :kind, :str, :int, :sym, :a, :kids, :kids2
  def initialize(kind, str, int, sym, a, kids, kids2)
    @kind = kind
    @str = str
    @int = int
    @sym = sym
    @a = a
    @kids = kids
    @kids2 = kids2
  end
end

def ilist = Array.new(0) { INode.new(0, "", 0, :x, nil, nil, nil) }
NO_KIDS = ilist
LEAF = INode.new(K_NIL, "", 0, :x, nil, NO_KIDS, NO_KIDS)
def mk(kind, str, int, sym, a, kids, kids2) = INode.new(kind, str, int, sym, a, kids, kids2)
def conv_list(nodes)
  out = ilist
  nodes.each { |n| out << conv(n) }
  out
end

# poly (class-per-node) AST -> monomorphic INode; poly dispatch happens once, at parse time
def conv(n)
  case n
  when TextNode then mk(K_TEXT, n.text, 0, :x, LEAF, NO_KIDS, NO_KIDS)
  when OutNode then mk(n.escape ? K_OUT : K_RAW, "", 0, :x, conv(n.expr), NO_KIDS, NO_KIDS)
  when StmtNode then mk(K_STMT, "", 0, :x, conv(n.expr), NO_KIDS, NO_KIDS)
  when IfNode then mk(K_IF, "", 0, :x, conv(n.cond), conv_list(n.then_body), conv_list(n.else_body))
  when EachNode then mk(K_EACH, n.var, 0, :x, conv(n.coll), conv_list(n.nodes), NO_KIDS)
  when StrLit then mk(K_STR, n.value, 0, :x, LEAF, NO_KIDS, NO_KIDS)
  when IntLit then mk(K_INT, "", n.value, :x, LEAF, NO_KIDS, NO_KIDS)
  when NilLit then LEAF
  when BoolLit then mk(n.value ? K_TRUE : K_FALSE, "", 0, :x, LEAF, NO_KIDS, NO_KIDS)
  when IVarRef then mk(K_VAR, n.name, 0, :x, LEAF, NO_KIDS, NO_KIDS)
  when LVarRef then mk(K_VAR, n.name, 0, :x, LEAF, NO_KIDS, NO_KIDS)
  when NotNode then mk(K_NOT, "", 0, :x, conv(n.expr), NO_KIDS, NO_KIDS)
  when BinNode
    k = n.op == "&&" ? K_AND : (n.op == "||" ? K_OR : (n.op == "==" ? K_EQ : K_NE))
    l = ilist
    l << conv(n.lhs)
    l << conv(n.rhs)
    mk(k, "", 0, :x, LEAF, l, NO_KIDS)
  when CallNode
    r = n.recv
    if r.nil?
      mk(K_HELPER, n.name, 0, n.sym, LEAF, conv_list(n.args), NO_KIDS)
    else
      mk(K_CALL, n.name, 0, n.sym, conv(r), conv_list(n.args), NO_KIDS)
    end
  else raise "bad node"
  end
end

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
  # WORKAROUND: a poly-boxed Time answers is_a?(Array) == true in Spinel 2026.09.12; test Time first.
  when Time
    case sym
    when :year then recv.year
    when :month then recv.month
    when :day then recv.day
    when :strftime then recv.strftime(args[0])
    else raise "undefined method #{name} for Time"
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
  k = n.kind
  if k == K_CALL
    args = []
    n.kids.each { |a| args << eval_expr(a, env) }
    call_method(eval_expr(n.a, env), n.sym, n.str, args)
  elsif k == K_VAR then env[n.str]
  elsif k == K_STR then n.str
  elsif k == K_INT then n.int
  elsif k == K_HELPER
    args = []
    n.kids.each { |a| args << eval_expr(a, env) }
    call_helper(n.sym, n.str, args)
  elsif k == K_NIL then nil
  elsif k == K_TRUE then true
  elsif k == K_FALSE then false
  elsif k == K_NOT then !truthy(eval_expr(n.a, env))
  elsif k == K_AND
    l = eval_expr(n.kids[0], env)
    truthy(l) ? eval_expr(n.kids[1], env) : l
  elsif k == K_OR
    l = eval_expr(n.kids[0], env)
    truthy(l) ? l : eval_expr(n.kids[1], env)
  elsif k == K_EQ then eval_expr(n.kids[0], env) == eval_expr(n.kids[1], env)
  elsif k == K_NE then eval_expr(n.kids[0], env) != eval_expr(n.kids[1], env)
  else raise "bad expr kind #{k}"
  end
end

def exec_body(nodes, env, out)
  nodes.each do |n|
    k = n.kind
    if k == K_TEXT then out << n.str
    elsif k == K_OUT then out << html_escape(to_s_value(eval_expr(n.a, env)))
    elsif k == K_RAW then out << to_s_value(eval_expr(n.a, env))
    elsif k == K_IF
      if truthy(eval_expr(n.a, env))
        exec_body(n.kids, env, out)
      else
        exec_body(n.kids2, env, out)
      end
    elsif k == K_EACH
      coll = eval_expr(n.a, env)
      raise "each on non-Array" unless coll.is_a?(Array)
      coll.each do |item|
        env[n.str] = item
        exec_body(n.kids, env, out)
      end
      env.delete(n.str)
    elsif k == K_STMT then eval_expr(n.a, env)
    end
  end
end

def render(tree, env)
  out = String.new
  exec_body(tree, env, out)
  out
end
# ---------- main ----------
iters = (ARGV[0] || "10000").to_i
posts = build_posts
nav = [{ "label" => "Home", "url" => "/" }, { "label" => "About & Contact", "url" => "/about?a=1&b=2" }]
owner = User.new("Matz <admin>")
title = "My Blog"
note = "(c) 2026 'cybertrain'"

env = {}
env["@title"] = title
env["@nav"] = nav
env["@posts"] = posts
env["@owner"] = owner
env["@footer_note"] = note
env["@count"] = 50

t0 = now_s
tree = conv_list(parse_template(File.read(File.join(__dir__, "posts.html.erb"))))
t1 = now_s
puts "parse: #{((t1 - t0) * 1_000_000).round(1)} us, top-level nodes=#{tree.size}"

a = render(tree, env)
b = render_hand(title, nav, posts, owner, note)
if a == b
  puts "output identical: #{a.bytesize} bytes"
else
  File.write(File.join(__dir__, "out_mono.html"), a)
  File.write(File.join(__dir__, "out_hand.html"), b)
  puts "MISMATCH interp=#{a.bytesize} hand=#{b.bytesize}"
end

total = 0
t0 = now_s
iters.times { total += render(tree, env).bytesize }
ti = now_s - t0
t0 = now_s
iters.times { total += render_hand(title, nav, posts, owner, note).bytesize }
th = now_s - t0
puts "interp(mono): #{iters} renders #{ti.round(3)} s = #{(ti / iters * 1_000_000).round(1)} us/render"
puts "hand:         #{iters} renders #{th.round(3)} s = #{(th / iters * 1_000_000).round(1)} us/render"
puts "ratio interp/hand = #{(ti / th).round(2)}  (checksum #{total})"
