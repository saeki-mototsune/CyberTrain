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

def upload_named(name, data)
  Cybertrain::UploadedFile.new(name, "image/png", data.b)
end

test "set_upload stores a file; upload is nil when absent, upload? says which" do
  p = Cybertrain::Params.new
  assert_nil p.upload("cover")
  refute p.upload?("cover")
  p.set_upload("cover", upload_named("a.png", "AAAA"))
  assert p.upload?("cover")
  assert p.upload?(:cover)
  up = p.upload(:cover)
  assert_equal false, up.nil?
  assert_equal "a.png", up.original_filename
  assert_equal 4, up.body_bytes.bytesize
  assert p.key?("cover")
  # A file is not a String, a list or a nested Params.
  assert_nil p["cover"]
  assert_equal [], p.list("cover")
  assert p.nested("cover").empty?
  assert_equal({}, p.to_h)
end

test "the nullable upload return works in an if, the way a controller uses it" do
  p = Cybertrain::Params.new
  p.set_upload("cover", upload_named("c.png", "1"))
  seen = "none"
  file = p.upload(:cover)
  seen = file.original_filename if file
  assert_equal "c.png", seen
  seen = "none"
  other = p.upload(:missing)
  seen = other.original_filename if other
  assert_equal "none", seen
  assert_equal "none", (other ? "some" : "none")
end

test "an empty file still counts as sent" do
  p = Cybertrain::Params.new
  p.set_upload("cover", Cybertrain::UploadedFile.blank)
  assert p.upload?("cover")
  assert p.upload("cover").empty?
  refute p.empty?
end

test "a file evicts a String, a list and a nested Params of the same name" do
  p = Cybertrain::Params.new
  p.set_value("a", "1")
  p.add_list_value("b", "2")
  p.child!("c").set_value("k", "v")
  p.set_upload("a", upload_named("a.png", "1"))
  p.set_upload("b", upload_named("b.png", "22"))
  p.set_upload("c", upload_named("c.png", "333"))
  assert_nil p["a"]
  assert_equal [], p.list("b")
  assert p.nested("c").empty?
  assert_equal "a.png", p.upload("a").original_filename
  assert_equal "b.png", p.upload("b").original_filename
  assert_equal "c.png", p.upload("c").original_filename
  assert_equal "{\"a\"=>#<Cybertrain::UploadedFile \"a.png\" 1 bytes>, \"b\"=>#<Cybertrain::UploadedFile \"b.png\" 2 bytes>, \"c\"=>#<Cybertrain::UploadedFile \"c.png\" 3 bytes>}", p.inspect
end

test "set_value, add_list_value and child! evict a file of the same name" do
  p = Cybertrain::Params.new
  p.set_upload("a", upload_named("a.png", "1"))
  p.set_value("a", "s")
  refute p.upload?("a")
  assert_nil p.upload("a")
  assert_equal "s", p["a"]

  p.set_upload("b", upload_named("b.png", "1"))
  p.add_list_value("b", "x")
  refute p.upload?("b")
  assert_equal ["x"], p.list("b")

  p.set_upload("c", upload_named("c.png", "1"))
  p.child!("c").set_value("k", "v")
  refute p.upload?("c")
  assert_equal "v", p.nested("c")["k"]

  # Last write wins between two files, too.
  p.set_upload("d", upload_named("one.png", "1"))
  p.set_upload("d", upload_named("two.png", "1"))
  assert_equal "two.png", p.upload("d").original_filename
end

test "set_upload_path nests like set_path and never appends" do
  p = Cybertrain::Params.new
  p.set_upload_path(["avatar"], upload_named("top.png", "1"))
  p.set_upload_path(["post", "cover"], upload_named("cover.png", "22"))
  p.set_path(["post", "title"], "hi")
  p.set_upload_path(["post", "deep", "img"], upload_named("deep.png", "333"))
  assert_equal "top.png", p.upload("avatar").original_filename
  post = p.require("post")
  assert_equal "hi", post["title"]
  assert_equal "cover.png", post.upload(:cover).original_filename
  assert_equal "deep.png", post.nested("deep").upload("img").original_filename
  # files[] has no list form: the second file replaces the first.
  p.set_upload_path(["files", ""], upload_named("f1.png", "1"))
  p.set_upload_path(["files", ""], upload_named("f2.png", "1"))
  assert_equal "f2.png", p.upload("files").original_filename
  assert_equal [], p.list("files")
  # A file under a key that was a String turns it into a nested Params
  # hop's leaf: the String is evicted by child!.
  p.set_value("form", "str")
  p.set_upload_path(["form", "doc"], upload_named("d.png", "1"))
  assert_nil p["form"]
  assert_equal "d.png", p.nested("form").upload("doc").original_filename
end

test "require succeeds for a form that sent only a file" do
  p = Cybertrain::Params.new
  p.set_upload_path(["post", "cover"], upload_named("only.png", "1"))
  refute p.empty?
  assert_equal "only.png", p.require(:post).upload(:cover).original_filename
  refute p.require(:post).empty?
end

test "permit never returns a file" do
  p = Cybertrain::Params.new
  p.set_value("title", "hi")
  p.set_upload("cover", upload_named("c.png", "1"))
  permitted = p.permit("title", "cover")
  assert_equal({ "title" => "hi" }, permitted)
  assert_equal({ "title" => "hi" }, p.to_h)
end

test "merge! carries files across, evicting and nesting like the other kinds" do
  a = Cybertrain::Params.new
  a.set_value("avatar", "string")
  a.set_upload("keep", upload_named("keep.png", "1"))
  a.child!("post").set_upload("old", upload_named("old.png", "1"))

  b = Cybertrain::Params.new
  b.set_upload("avatar", upload_named("new.png", "22"))
  b.child!("post").set_upload("cover", upload_named("cover.png", "333"))
  b.set_value("keep", "now a string")

  a.merge!(b)
  assert_nil a["avatar"]
  assert_equal "new.png", a.upload("avatar").original_filename
  refute a.upload?("keep")
  assert_equal "now a string", a["keep"]
  assert_equal "old.png", a.nested("post").upload("old").original_filename
  assert_equal "cover.png", a.nested("post").upload("cover").original_filename
  # other is left alone.
  assert_equal "new.png", b.upload("avatar").original_filename
  assert_equal "cover.png", b.nested("post").upload("cover").original_filename
  assert_equal "{\"keep\"=>\"now a string\", \"post\"=>{\"old\"=>#<Cybertrain::UploadedFile \"old.png\" 1 bytes>, \"cover\"=>#<Cybertrain::UploadedFile \"cover.png\" 3 bytes>}, \"avatar\"=>#<Cybertrain::UploadedFile \"new.png\" 2 bytes>}", a.inspect
end

test "merge! lets the other's list replace a file of the same name" do
  a = Cybertrain::Params.new
  a.set_upload("tags", upload_named("tags.png", "1"))
  b = Cybertrain::Params.new
  b.add_list_value("tags", "x")
  a.merge!(b)
  refute a.upload?("tags")
  assert_equal ["x"], a.list("tags")
end

test "uploads are inspected after scalars, lists and nested Params" do
  p = Cybertrain::Params.new
  p.set_upload("f", upload_named("f.png", "1"))
  p.set_value("s", "1")
  p.add_list_value("l", "1")
  p.child!("n")
  assert_equal "{\"s\"=>\"1\", \"l\"=>[\"1\"], \"n\"=>{}, \"f\"=>#<Cybertrain::UploadedFile \"f.png\" 1 bytes>}", p.inspect
end

test "a file's bytes survive the Params unchanged (NUL and high bytes)" do
  p = Cybertrain::Params.new
  data = "\x00\xFF\x00PNG\x80".b
  p.set_upload_path(["post", "bin"], Cybertrain::UploadedFile.new("bin.dat", "", data))
  got = p.require(:post).upload(:bin)
  assert_equal 7, got.body_bytes.bytesize
  assert_equal 0, got.body_bytes.getbyte(0)
  assert_equal 255, got.body_bytes.getbyte(1)
  assert_equal 128, got.body_bytes.getbyte(6)
end

Cybertrain::Test.run!
