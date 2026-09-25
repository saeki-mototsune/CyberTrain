# SPIKE (throwaway): monomorphic INode AST + explicit tagged Value -- does Value win once AST dispatch is monomorphic?
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

T_NIL = 0
T_TRUE = 1
T_FALSE = 2
T_INT = 3
T_FLOAT = 4
T_STR = 5
T_ARR = 6
T_HASH = 7
T_TIME = 8
T_MODEL = 9

# Typed slots. Every slot gets a non-nil default of its own type so no slot is nullable/poly.
class Value
  attr_reader :tag, :int_v, :flt_v, :str_v, :arr_v, :hash_v, :time_v, :model_v
  def initialize(tag)
    @tag = tag
    @int_v = 0
    @flt_v = 0.0
    @str_v = ""
    @arr_v = EMPTY_VALUES
    @hash_v = EMPTY_VHASH
    @time_v = EPOCH
    @model_v = NULL_MODEL
  end
  def set_int(i) = @int_v = i
  def set_flt(f) = @flt_v = f
  def set_str(s) = @str_v = s
  def set_arr(a) = @arr_v = a
  def set_hash(h) = @hash_v = h
  def set_time(t) = @time_v = t
  def set_model(m) = @model_v = m
  def truthy? = @tag != T_NIL && @tag != T_FALSE
end

class NullModel < Model
end

EPOCH = Time.at(0)
NULL_MODEL = NullModel.new
EMPTY_VALUES = Array.new(0) { Value.new(0) }
EMPTY_VHASH = { "" => Value.new(0) }
EMPTY_VHASH.delete("")
V_NIL = Value.new(T_NIL)
V_TRUE = Value.new(T_TRUE)
V_FALSE = Value.new(T_FALSE)

def v_int(i)
  v = Value.new(T_INT)
  v.set_int(i)
  v
end
def v_str(s)
  v = Value.new(T_STR)
  v.set_str(s)
  v
end
def v_bool(b) = b ? V_TRUE : V_FALSE
def v_model(m)
  v = Value.new(T_MODEL)
  v.set_model(m)
  v
end
def v_arr(a)
  v = Value.new(T_ARR)
  v.set_arr(a)
  v
end
def v_time(t)
  v = Value.new(T_TIME)
  v.set_time(t)
  v
end
def v_hash(h)
  v = Value.new(T_HASH)
  v.set_hash(h)
  v
end

# Boundary: model attribute (poly) -> Value. Time tested before Array (Spinel is_a? bug).
def wrap(x)
  case x
  when nil then V_NIL
  when true then V_TRUE
  when false then V_FALSE
  when String then v_str(x)
  when Integer then v_int(x)
  when Float
    v = Value.new(T_FLOAT)
    v.set_flt(x)
    v
  when Time then v_time(x)
  when Model then v_model(x)
  when Array
    out = Array.new(0) { Value.new(0) }
    x.each { |e| out << wrap(e) }
    v_arr(out)
  else V_NIL
  end
end

def vs(v)
  t = v.tag
  if t == T_STR then v.str_v
  elsif t == T_INT then v.int_v.to_s
  elsif t == T_NIL then ""
  elsif t == T_TRUE then "true"
  elsif t == T_FALSE then "false"
  elsif t == T_FLOAT then v.flt_v.to_s
  elsif t == T_TIME then v.time_v.strftime("%Y-%m-%d")
  else "#<value>"
  end
end

def v_eq(a, b)
  return false if a.tag != b.tag
  t = a.tag
  if t == T_STR then a.str_v == b.str_v
  elsif t == T_INT then a.int_v == b.int_v
  elsif t == T_NIL || t == T_TRUE || t == T_FALSE then true
  elsif t == T_MODEL then a.model_v.equal?(b.model_v)
  else false
  end
end

def call_method(recv, sym, name, args)
  t = recv.tag
  if t == T_STR
    s = recv.str_v
    case sym
    when :upcase then v_str(s.upcase)
    when :downcase then v_str(s.downcase)
    when :strip then v_str(s.strip)
    when :size, :length then v_int(s.length)
    when :empty? then v_bool(s.empty?)
    when :to_s then recv
    else raise "undefined method #{name} for String"
    end
  elsif t == T_INT
    case sym
    when :to_s then v_str(recv.int_v.to_s)
    else raise "undefined method #{name} for Integer"
    end
  elsif t == T_ARR
    a = recv.arr_v
    case sym
    when :size, :length then v_int(a.size)
    when :empty? then v_bool(a.empty?)
    when :any? then v_bool(!a.empty?)
    when :first then a.empty? ? V_NIL : a[0]
    when :last then a.empty? ? V_NIL : a[a.size - 1]
    else raise "undefined method #{name} for Array"
    end
  elsif t == T_HASH
    h = recv.hash_v
    case sym
    when :fetch
      k = vs(args[0])
      h.key?(k) ? h[k] : V_NIL
    when :size then v_int(h.size)
    else raise "undefined method #{name} for Hash"
    end
  elsif t == T_TIME
    tm = recv.time_v
    case sym
    when :year then v_int(tm.year)
    when :month then v_int(tm.month)
    when :day then v_int(tm.day)
    when :strftime then v_str(tm.strftime(vs(args[0])))
    else raise "undefined method #{name} for Time"
    end
  elsif t == T_MODEL
    m = recv.model_v
    x = m.read_attribute(sym)
    x = m.read_association(sym) if x.nil?
    wrap(x)
  elsif t == T_NIL
    case sym
    when :nil? then V_TRUE
    else raise "undefined method #{name} for nil"
    end
  else
    raise "undefined method #{name}"
  end
end

def call_helper(sym, name, args)
  case sym
  when :pluralize then v_str(pluralize(args[0].int_v, vs(args[1])))
  when :link_to then v_str(link_to(vs(args[0]), vs(args[1])))
  when :h, :html_escape then v_str(html_escape(vs(args[0])))
  else raise "undefined helper #{name}"
  end
end

def eval_expr(n, env)
  k = n.kind
  if k == K_CALL
    args = Array.new(0) { Value.new(0) }
    n.kids.each { |a| args << eval_expr(a, env) }
    call_method(eval_expr(n.a, env), n.sym, n.str, args)
  elsif k == K_VAR then env.key?(n.str) ? env[n.str] : V_NIL
  elsif k == K_STR then v_str(n.str)
  elsif k == K_INT then v_int(n.int)
  elsif k == K_HELPER
    args = Array.new(0) { Value.new(0) }
    n.kids.each { |a| args << eval_expr(a, env) }
    call_helper(n.sym, n.str, args)
  elsif k == K_NIL then V_NIL
  elsif k == K_TRUE then V_TRUE
  elsif k == K_FALSE then V_FALSE
  elsif k == K_NOT then v_bool(!eval_expr(n.a, env).truthy?)
  elsif k == K_AND
    l = eval_expr(n.kids[0], env)
    l.truthy? ? eval_expr(n.kids[1], env) : l
  elsif k == K_OR
    l = eval_expr(n.kids[0], env)
    l.truthy? ? l : eval_expr(n.kids[1], env)
  elsif k == K_EQ then v_bool(v_eq(eval_expr(n.kids[0], env), eval_expr(n.kids[1], env)))
  elsif k == K_NE then v_bool(!v_eq(eval_expr(n.kids[0], env), eval_expr(n.kids[1], env)))
  else raise "bad expr kind #{k}"
  end
end

def exec_body(nodes, env, out)
  nodes.each do |n|
    k = n.kind
    if k == K_TEXT then out << n.str
    elsif k == K_OUT then out << html_escape(vs(eval_expr(n.a, env)))
    elsif k == K_RAW then out << vs(eval_expr(n.a, env))
    elsif k == K_IF
      if eval_expr(n.a, env).truthy?
        exec_body(n.kids, env, out)
      else
        exec_body(n.kids2, env, out)
      end
    elsif k == K_EACH
      coll = eval_expr(n.a, env)
      raise "each on non-Array" unless coll.tag == T_ARR
      coll.arr_v.each do |item|
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

# env: Hash[String, Value]; nested: Array of Hash of Value, Array of Model
nav_v = Array.new(0) { Value.new(0) }
nav.each do |h|
  hv = { "" => V_NIL }
  hv.delete("")
  h.each { |k, s| hv[k] = v_str(s) }
  nav_v << v_hash(hv)
end
env = { "" => V_NIL }
env.delete("")
env["@title"] = v_str(title)
env["@nav"] = v_arr(nav_v)
env["@posts"] = wrap(posts)
env["@owner"] = v_model(owner)
env["@footer_note"] = v_str(note)
env["@count"] = v_int(50)

t0 = now_s
tree = conv_list(parse_template(File.read(File.join(__dir__, "posts.html.erb"))))
t1 = now_s
puts "parse: #{((t1 - t0) * 1_000_000).round(1)} us, top-level nodes=#{tree.size}"

a = render(tree, env)
b = render_hand(title, nav, posts, owner, note)
if a == b
  puts "output identical: #{a.bytesize} bytes"
else
  File.write(File.join(__dir__, "out_vmono.html"), a)
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
puts "interp(Value+mono): #{iters} renders #{ti.round(3)} s = #{(ti / iters * 1_000_000).round(1)} us/render"
puts "hand:          #{iters} renders #{th.round(3)} s = #{(th / iters * 1_000_000).round(1)} us/render"
puts "ratio interp/hand = #{(ti / th).round(2)}  (checksum #{total})"
