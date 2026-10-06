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
end

Cybertrain::Test.run!
