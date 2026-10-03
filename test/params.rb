require "cybertrain/params"
require "cybertrain/test"

test "set_value stores and reads a scalar" do
  p = Cybertrain::Params.new
  p.set_value("id", "1")
  assert_equal "1", p["id"]
  assert_equal "1", p[:id]
  assert_nil p["missing"]
end

test "add_list_value builds a list, absent key returns empty array" do
  p = Cybertrain::Params.new
  p.add_list_value("tags", "a")
  p.add_list_value("tags", "b")
  assert_equal ["a", "b"], p.list("tags")
  assert_equal ["a", "b"], p.list(:tags)
  assert_equal [], p.list("nope")
end

test "child! creates and returns a nested Params, nested() never stores" do
  p = Cybertrain::Params.new
  child = p.child!("post")
  child.set_value("title", "hi")
  assert_equal "hi", p.nested("post")["title"]
  # nested() on an absent key returns a fresh, empty Params and does not
  # add it to the parent.
  fresh = p.nested("absent")
  assert fresh.empty?
  refute p.key?("absent")
end

test "key? is true for scalars, lists and nested params" do
  p = Cybertrain::Params.new
  p.set_value("id", "1")
  p.add_list_value("tags", "a")
  p.child!("post").set_value("title", "hi")
  assert p.key?("id")
  assert p.key?("tags")
  assert p.key?("post")
  refute p.key?("nope")
end

test "inspect lists scalars, then lists, then nested, each in insertion order (Params has no keys)" do
  p = Cybertrain::Params.new
  p.set_value("b", "1")
  p.add_list_value("y", "1")
  p.child!("z")
  p.set_value("a", "2")
  p.add_list_value("x", "2")
  p.child!("w")
  assert_equal "{\"b\"=>\"1\", \"a\"=>\"2\", \"y\"=>[\"1\"], \"x\"=>[\"2\"], \"z\"=>{}, \"w\"=>{}}", p.inspect
  ["b", "a", "y", "x", "z", "w"].each { |k| assert p.key?(k) }
end

test "set_path assembles nested params from a Query.split_key-shaped path" do
  p = Cybertrain::Params.new
  p.set_path(["id"], "1")
  p.set_path(["tags", ""], "a")
  p.set_path(["tags", ""], "b")
  p.set_path(["post", "title"], "hi")
  p.set_path(["post", "tags", ""], "x")
  assert_equal "1", p["id"]
  assert_equal ["a", "b"], p.list("tags")
  assert_equal "hi", p.nested("post")["title"]
  assert_equal ["x"], p.nested("post").list("tags")
end

test "require returns the nested Params when present and non-empty" do
  p = Cybertrain::Params.new
  p.child!("post").set_value("title", "hi")
  post = p.require("post")
  assert_equal "hi", post["title"]
end

test "require raises ParameterMissing when absent or empty" do
  p = Cybertrain::Params.new
  msg = assert_raises("ParameterMissing") { p.require("post") }
  assert_equal "param is missing or the value is empty: post", msg

  p.child!("empty_post")
  msg2 = assert_raises("ParameterMissing") { p.require("empty_post") }
  assert_equal "param is missing or the value is empty: empty_post", msg2
end

test "permit returns only listed scalar keys that are present" do
  p = Cybertrain::Params.new
  p.set_value("title", "hi")
  p.set_value("body", "text")
  p.add_list_value("tags", "a")
  p.child!("author").set_value("name", "matz")
  permitted = p.permit("title", "tags", "author", "missing")
  assert_equal({ "title" => "hi" }, permitted)
end

test "merge! lets the other Params win on conflicts" do
  a = Cybertrain::Params.new
  a.set_value("id", "1")
  a.set_value("keep", "yes")
  a.add_list_value("tags", "a")
  a.child!("post").set_value("title", "old")

  b = Cybertrain::Params.new
  b.set_value("id", "2")
  b.add_list_value("tags", "b")
  b.child!("post").set_value("title", "new")

  a.merge!(b)

  assert_equal "2", a["id"]
  assert_equal "yes", a["keep"]
  assert_equal ["b"], a.list("tags")
  assert_equal "new", a.nested("post")["title"]
end

test "merge! deep-merges nested Params, keeping receiver-only keys" do
  a = Cybertrain::Params.new
  a.child!("post").set_value("a", "1")

  b = Cybertrain::Params.new
  b.child!("post").set_value("b", "2")

  a.merge!(b)

  assert_equal "1", a.nested("post")["a"]
  assert_equal "2", a.nested("post")["b"]
end

test "merge! does not alias other's lists or nested params" do
  a = Cybertrain::Params.new

  b = Cybertrain::Params.new
  b.add_list_value("t", "x")
  b.child!("c").set_value("k", "v")

  a.merge!(b)
  a.add_list_value("t", "y")
  a.child!("c").set_value("k2", "v2")

  assert_equal ["x"], b.list("t")
  assert_equal({ "k" => "v" }, b.nested("c").to_h)
  assert_equal "{\"t\"=>[\"x\"], \"c\"=>{\"k\"=>\"v\"}}", b.inspect
end

test "merge! preserves inspect ordering: receiver order first, then other's new keys" do
  a = Cybertrain::Params.new
  a.set_value("keep", "yes")
  a.add_list_value("tags", "a")
  a.child!("post").set_value("title", "old")

  b = Cybertrain::Params.new
  b.set_value("id", "2")
  b.set_value("keep", "no")
  b.add_list_value("tags", "b")
  b.add_list_value("extra", "z")
  b.child!("post").set_value("title", "new")
  b.child!("author").set_value("name", "matz")

  a.merge!(b)

  ["keep", "id", "tags", "extra", "post", "author"].each { |k| assert a.key?(k) }
  assert_equal(
    "{\"keep\"=>\"no\", \"id\"=>\"2\", \"tags\"=>[\"b\"], \"extra\"=>[\"z\"], " \
      "\"post\"=>{\"title\"=>\"new\"}, \"author\"=>{\"name\"=>\"matz\"}}",
    a.inspect
  )
end

test "a name can only be one kind at a time: last write wins, like Rack" do
  p = Cybertrain::Params.new
  p.set_value("a", "1")
  p.add_list_value("a", "2")
  assert_nil p["a"]
  assert_equal ["2"], p.list("a")
  assert p.key?("a")
  assert_equal({}, p.to_h)

  p.child!("a").set_value("b", "3")
  assert_equal [], p.list("a")
  assert_equal "3", p.nested("a")["b"]
  assert p.key?("a")
  assert_equal [], p.list("a")

  p.set_value("a", "4")
  assert_equal "4", p["a"]
  assert p.nested("a").empty?
  assert p.key?("a")
  assert_equal({ "a" => "4" }, p.to_h)
end

test "to_h returns only scalars, empty? and inspect are deterministic" do
  p = Cybertrain::Params.new
  assert p.empty?
  p.set_value("id", "1")
  p.add_list_value("tags", "a")
  p.add_list_value("tags", "b")
  p.child!("post").set_value("title", "x")
  refute p.empty?
  assert_equal({ "id" => "1" }, p.to_h)
  assert_equal "{\"id\"=>\"1\", \"tags\"=>[\"a\", \"b\"], \"post\"=>{\"title\"=>\"x\"}}", p.inspect
end

def read_only_sample
  p = Cybertrain::Params.new
  p.set_value("id", "1")
  p.add_list_value("tags", "a")
  p.child!("post").set_value("title", "hi")
  p.child!("post").child!("meta").set_value("k", "v")
  p.read_only!
end

test "read_only! marks the Params and every nested child, and returns self" do
  p = Cybertrain::Params.new
  refute p.read_only?
  p.child!("a").child!("b").set_value("k", "v")
  p.child!("c")
  assert p.read_only!.equal?(p)
  assert p.read_only?
  assert p.nested("a").read_only?
  assert p.nested("a").nested("b").read_only?
  assert p.nested("c").read_only?
  # An absent key is a fresh, empty, writable Params that is never stored.
  refute p.nested("absent").read_only?
end

test "every mutator of a read-only Params raises RuntimeError and changes nothing" do
  p = read_only_sample
  msg = assert_raises("RuntimeError") { p.set_value("x", "1") }
  assert_includes msg, "request parameters are read-only"
  assert_includes msg, "Params.new.merge!(request.query_params)"
  assert_raises("RuntimeError") { p.set_value("id", "2") }
  assert_raises("RuntimeError") { p.add_list_value("tags", "b") }
  assert_raises("RuntimeError") { p.add_list_value("fresh", "b") }
  assert_raises("RuntimeError") { p.child!("post") }
  assert_raises("RuntimeError") { p.child!("fresh") }
  assert_raises("RuntimeError") { p.set_path(["x"], "1") }
  assert_raises("RuntimeError") { p.set_path(["x", ""], "1") }
  assert_raises("RuntimeError") { p.set_path(["post", "title"], "no") }
  assert_raises("RuntimeError") { p.set_path([], "no") }
  assert_raises("RuntimeError") { p.merge!(Cybertrain::Params.new) }
  other = Cybertrain::Params.new
  other.set_value("y", "2")
  assert_raises("RuntimeError") { p.merge!(other) }
  # Nested children are read-only too, however they are reached.
  assert_raises("RuntimeError") { p.nested("post").set_value("title", "no") }
  assert_raises("RuntimeError") { p.nested("post").nested("meta").set_value("k", "no") }
  assert_equal "{\"id\"=>\"1\", \"tags\"=>[\"a\"], \"post\"=>{\"title\"=>\"hi\", \"meta\"=>{\"k\"=>\"v\"}}}", p.inspect
end

test "every reader of a read-only Params still works" do
  p = read_only_sample
  assert_equal "1", p["id"]
  assert_equal "1", p[:id]
  assert_equal ["a"], p.list("tags")
  assert_equal "hi", p.nested("post")["title"]
  assert_equal "v", p.nested("post").nested("meta")["k"]
  assert p.key?("post")
  refute p.key?("nope")
  ["id", "tags", "post"].each { |k| assert p.key?(k) }
  assert_equal "hi", p.require("post")["title"]
  assert_equal({ "id" => "1" }, p.permit("id", "nope"))
  assert_equal({ "id" => "1" }, p.to_h)
  refute p.empty?
  assert Cybertrain::Params.new.read_only!.empty?
end

test "Params.new.merge!(read_only) is writable and independent of its source" do
  src = read_only_sample
  copy = Cybertrain::Params.new.merge!(src)
  refute copy.read_only?
  refute copy.nested("post").read_only?
  refute copy.nested("post").nested("meta").read_only?
  copy.set_value("id", "9")
  copy.add_list_value("tags", "z")
  copy.nested("post").set_value("title", "changed")
  copy.nested("post").nested("meta").set_value("k", "w")
  copy.set_path(["post", "extra"], "e")
  copy.child!("new").set_value("n", "1")
  assert_equal "9", copy["id"]
  assert_equal ["a", "z"], copy.list("tags")
  assert_equal "changed", copy.nested("post")["title"]
  # The read-only source saw none of it.
  assert_equal "1", src["id"]
  assert_equal ["a"], src.list("tags")
  assert_equal "hi", src.nested("post")["title"]
  assert_equal "v", src.nested("post").nested("meta")["k"]
  refute src.nested("post").key?("extra")
  refute src.key?("new")
  assert src.read_only?
  assert src.nested("post").read_only?
end

test "read_only! is one flag per tree: a nested node seals its whole tree, copies and strangers are separate" do
  a = Cybertrain::Params.new
  a.set_path(["x", "y", "z"], "1")
  b = Cybertrain::Params.new.merge!(a)
  other = Cybertrain::Params.new
  # Sealing a deep node seals the tree it is in, root included ...
  a.nested("x").nested("y").read_only!
  assert a.read_only?
  assert a.nested("x").read_only?
  assert_raises("RuntimeError") { a.set_value("late", "1") }
  # ... but not a merged copy (its own tree) nor an unrelated Params.
  refute b.read_only?
  refute b.nested("x").read_only?
  refute other.read_only?
  b.set_path(["x", "y", "w"], "2")
  assert_equal "2", b.nested("x").nested("y")["w"]
  refute a.nested("x").nested("y").key?("w")
  # A child created by set_path after the parent is writable shares its tree,
  # so sealing the root afterwards covers it.
  b.set_path(["p", "q"], "3")
  b.read_only!
  assert b.nested("p").read_only?
  assert_raises("RuntimeError") { b.nested("p").set_value("q", "4") }
end

# A sealed tree is shared by every holder, so what it hands out must be
# copies: a String is mutable, an Array too.
def mutate_scalar(params)
  params["id"] << "XYZ"
  nil
end

def mutate_list(params)
  params.list("tags") << "evil"
  params.list("tags")[0] << "XYZ"
  nil
end

test "a read-only Params hands out copies: mutating a returned String or list changes nothing" do
  p = read_only_sample
  mutate_scalar(p)
  mutate_list(p)
  p.to_h["id"] << "XYZ"
  p.permit("id")["id"] << "XYZ"
  p.nested("post")["title"] << "XYZ"
  p.nested("post").list("none") << "evil"
  assert_equal "1", p["id"]
  assert_equal ["a"], p.list("tags")
  assert_equal "hi", p.nested("post")["title"]
  assert_equal({ "id" => "1" }, p.to_h)
  assert_equal "{\"id\"=>\"1\", \"tags\"=>[\"a\"], \"post\"=>{\"title\"=>\"hi\", \"meta\"=>{\"k\"=>\"v\"}}}", p.inspect
  assert_nil p["nope"]
  assert_equal [], p.list("nope")
end

test "merge! copies Strings: the merged tree shares none with its source" do
  src = Cybertrain::Params.new
  src.set_value("q", "1")
  src.add_list_value("t", "a")
  src.child!("c").set_value("k", "v")
  dst = Cybertrain::Params.new.merge!(src)
  dst["q"] << "XYZ"
  dst.list("t")[0] << "XYZ"
  dst.nested("c")["k"] << "XYZ"
  # Only the source is asserted: whether the appends stuck on dst is the
  # runtime's business (under Spinel a String read out of a Params does not
  # take an in-place `<<`, NOTES rule 55); what matters is that src is intact.
  assert_equal "1", src["q"]
  assert_equal ["a"], src.list("t")
  assert_equal "v", src.nested("c")["k"]
  # The same from a read-only source (the request caches).
  sealed = read_only_sample
  copy = Cybertrain::Params.new.merge!(sealed)
  copy["id"] << "XYZ"
  copy.list("tags")[0] << "XYZ"
  assert_equal "1", sealed["id"]
  assert_equal ["a"], sealed.list("tags")
end

Cybertrain::Test.run!
