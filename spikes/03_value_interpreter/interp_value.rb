# SPIKE (throwaway): does a tree-walking template interpreter over an explicit tagged Value class compile under Spinel, and is it faster than plain poly values?
require_relative "tparse"
require_relative "models"

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
  case n
  when StrLit then v_str(n.value)
  when IntLit then v_int(n.value)
  when NilLit then V_NIL
  when BoolLit then v_bool(n.value)
  when IVarRef then env.key?(n.name) ? env[n.name] : V_NIL
  when LVarRef then env.key?(n.name) ? env[n.name] : V_NIL
  when NotNode then v_bool(!eval_expr(n.expr, env).truthy?)
  when BinNode
    op = n.op
    if op == "&&"
      l = eval_expr(n.lhs, env)
      l.truthy? ? eval_expr(n.rhs, env) : l
    elsif op == "||"
      l = eval_expr(n.lhs, env)
      l.truthy? ? l : eval_expr(n.rhs, env)
    elsif op == "=="
      v_bool(v_eq(eval_expr(n.lhs, env), eval_expr(n.rhs, env)))
    else
      v_bool(!v_eq(eval_expr(n.lhs, env), eval_expr(n.rhs, env)))
    end
  when CallNode
    args = Array.new(0) { Value.new(0) }
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
    s = vs(eval_expr(n.expr, env))
    out << (n.escape ? html_escape(s) : s)
  when StmtNode then eval_expr(n.expr, env)
  when IfNode
    if eval_expr(n.cond, env).truthy?
      exec_body(n.then_body, env, out)
    else
      exec_body(n.else_body, env, out)
    end
  when EachNode
    coll = eval_expr(n.coll, env)
    raise "each on non-Array" unless coll.tag == T_ARR
    coll.arr_v.each do |item|
      env[n.var] = item
      exec_body(n.nodes, env, out)
    end
    env.delete(n.var)
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
tree = parse_template(File.read(File.join(__dir__, "posts.html.erb")))
t1 = now_s
puts "parse: #{((t1 - t0) * 1_000_000).round(1)} us, top-level nodes=#{tree.size}"

a = render(tree, env)
b = render_hand(title, nav, posts, owner, note)
if a == b
  puts "output identical: #{a.bytesize} bytes"
else
  File.write(File.join(__dir__, "out_value.html"), a)
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
puts "interp(Value): #{iters} renders #{ti.round(3)} s = #{(ti / iters * 1_000_000).round(1)} us/render"
puts "hand:          #{iters} renders #{th.round(3)} s = #{(th / iters * 1_000_000).round(1)} us/render"
puts "ratio interp/hand = #{(ti / th).round(2)}  (checksum #{total})"
