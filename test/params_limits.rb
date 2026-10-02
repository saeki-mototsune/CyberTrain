require "cybertrain/http/query"
require "cybertrain/params"
require "cybertrain/test"

# Request-parameter DoS limits: bracket nesting depth, pairs per parse, and
# eviction cost. Assertions are on results, never on time.

test "a key nested 10000 levels deep raises TooDeep instead of overflowing the stack" do
  key = "a" + ("[x]" * 10000)
  assert_raises("TooDeep") { Cybertrain::Query.split_key(key) }
  assert_raises("TooDeep") { Cybertrain::Query.parse(key + "=1") }
end

test "TooDeep and TooMany are StandardErrors (assert_raises rescues only those)" do
  msg = assert_raises("TooDeep") { Cybertrain::Query.split_key("a" + ("[x]" * 33)) }
  assert_equal "parameter nesting too deep (limit 32)", msg
  msg2 = assert_raises("TooMany") { Cybertrain::Query.parse((0..4096).map { |i| "k#{i}=1" }.join("&")) }
  assert_equal "too many parameters (limit 4096)", msg2
end

test "nesting exactly MAX_DEPTH deep parses, one more raises" do
  assert_equal 32, Cybertrain::Query::MAX_DEPTH
  ok = "a" + ("[x]" * 32)
  assert_equal 33, Cybertrain::Query.split_key(ok).length
  params = Cybertrain::Query.parse(ok + "=v")
  assert params.key?("a")
  assert_raises("TooDeep") { Cybertrain::Query.split_key("a" + ("[x]" * 33)) }
end

test "the deepest allowed key lands its value at the bottom" do
  params = Cybertrain::Query.parse("a" + ("[x]" * 31) + "[y]=v")
  node = params.nested("a")
  30.times { node = node.nested("x") }
  assert_equal "v", node.nested("x")["y"]
end

test "a malformed bracket run is still one plain key" do
  assert_equal ["a[b"], Cybertrain::Query.split_key("a[b")
  assert_equal ["a[b]c"], Cybertrain::Query.split_key("a[b]c")
  assert_equal ["a", "b", ""], Cybertrain::Query.split_key("a[b][]")
end

test "a deep key with a malformed tail is still one plain key, not TooDeep" do
  key = "a" + "[x]" * 100 + "[oops"
  assert_equal [key], Cybertrain::Query.split_key(key)
  params = Cybertrain::Query.parse("#{key}=1")
  assert_equal "1", params[key]
end

test "MAX_PAIRS pairs parse, one more raises TooMany" do
  assert_equal 4096, Cybertrain::Query::MAX_PAIRS
  ok = (0...4096).map { |i| "k#{i}=1" }.join("&")
  assert_equal 4096, Cybertrain::Query.parse(ok).keys.length
  too_many = ok + "&extra=1"
  assert_raises("TooMany") { Cybertrain::Query.parse(too_many) }
end

test "empty pairs do not count towards the limit" do
  qs = ("&" * 10000) + "a=1" + ("&" * 10000)
  assert_equal ["a"], Cybertrain::Query.parse(qs).keys
end

test "20000 key kind flips complete and keep the last write" do
  n = 20000
  # 40000 pairs would be over MAX_PAIRS, so drive Params directly with the
  # same flips a form body would cause.
  params = Cybertrain::Params.new
  n.times { |i| params.set_value("k#{i}", "1") }
  n.times { |i| params.add_list_value("k#{i}", "1") }
  assert_equal n, params.keys.length
  assert_nil params["k0"]
  assert_equal ["1"], params.list("k19999")
  n.times { |i| params.child!("k#{i}") }
  assert_equal n, params.keys.length
  assert_equal [], params.list("k0")
  assert params.nested("k5").empty?
end

test "flips within one parse keep Rack's last-write-wins" do
  params = Cybertrain::Query.parse("a=1&a[]=2&a[b]=3&c[]=1&c=2")
  assert_equal ["c", "a"], params.keys
  assert_equal "3", params.nested("a")["b"]
  assert_equal "2", params["c"]
end

test "set_path and merge! handle a 5000 level chain iteratively" do
  path = []
  5000.times { path << "x" }
  path << "leaf"
  a = Cybertrain::Params.new
  a.set_path(path, "1")
  b = Cybertrain::Params.new
  b.set_path(path, "2")
  a.merge!(b)
  node = a
  5000.times { node = node.nested("x") }
  assert_equal "2", node["leaf"]
end

Cybertrain::Test.run!
