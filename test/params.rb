# cybertrain's strong parameters (require, permit, expect and
# ParameterMissing, added by reopening the layer's Params in
# cybertrain/params.rb). The Params structure itself is spinel-http's, and
# so are its cases (its test/params.rb).
require "cybertrain/params"
require "cybertrain/http/query"
require "cybertrain/test"

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

def params_from(text)
  Cybertrain::Query.parse(text)
end

test "expect returns the permitted shape" do
  p = params_from("article[title]=Hi&article[tags][]=a&article[tags][]=b&article[meta][source]=rss&article[admin]=1")
  h = p.expect(article: [:title, tags: [], meta: [:source]])
  assert_equal "Hi", h["title"]
  assert_equal ["a", "b"], h["tags"]
  assert_equal({ "source" => "rss" }, h["meta"])
  refute h.key?("admin")
end

test "expect raises 400's ParameterMissing for a missing key or a wrong shape" do
  assert_raises("ParameterMissing") { params_from("x=1").expect(article: [:title]) }
  assert_raises("ParameterMissing") { params_from("article=flat").expect(article: [:title]) }
  assert_raises("ParameterMissing") { params_from("article[title][]=x").expect(article: [meta: [:source]]) }
  msg = assert_raises("ParameterMissing") { params_from("").expect(article: [:title]) }
  assert_equal "param is missing or the value is empty or invalid: article", msg
end

test "expect raises when a nested Hash is sent where a list is expected" do
  msg = assert_raises("ParameterMissing") { params_from("article[tags][x]=1").expect(article: [tags: []]) }
  assert_equal "param is missing or the value is empty or invalid: article", msg
end

test "expect with a bare key answers a one-entry Hash, raising for a missing or non-String value" do
  assert_equal({ "id" => "3" }, params_from("id=3").expect(:id))
  msg = assert_raises("ParameterMissing") { params_from("x=1").expect(:id) }
  assert_equal "param is missing or the value is empty or invalid: id", msg
  assert_raises("ParameterMissing") { params_from("id[]=3").expect(:id) }
  assert_raises("ParameterMissing") { params_from("id[a]=3").expect(:id) }
end

test "expect with a list spec answers the list in a one-entry Hash" do
  assert_equal({ "tags" => ["a", "b"] }, params_from("tags[]=a&tags[]=b").expect(tags: []))
  msg = assert_raises("ParameterMissing") { params_from("tags[x]=a").expect(tags: []) }
  assert_equal "param is missing or the value is empty or invalid: tags", msg
  assert_raises("ParameterMissing") { params_from("tags=a").expect(tags: []) }
end

test "a filter that is not an Array, or an Array among the filters, is an ArgumentError" do
  msg = assert_raises("ArgumentError") { params_from("article[title]=Hi").expect(article: :title) }
  assert_equal "expect's filters for :article must be an Array (article: [:name] or article: []), got Symbol", msg
  # the same with no such key in the request: the code is wrong, not the request
  assert_raises("ArgumentError") { params_from("").expect(article: :title) }
  msg = assert_raises("ArgumentError") { params_from("meta[source]=rss").permit(meta: :source) }
  assert_equal "permit's filters for :meta must be an Array (meta: [:name] or meta: []), got Symbol", msg
  assert_raises("ArgumentError") { params_from("article[title]=Hi").expect(article: [[:title]]) }
  assert_raises("ArgumentError") { params_from("title=Hi").permit([:title]) }
end

test "expect drops an unlisted key inside a nested level" do
  h = params_from("article[meta][source]=rss&article[meta][secret]=x&article[title]=T").expect(article: [:title, meta: [:source]])
  assert_equal({ "source" => "rss" }, h["meta"])
  assert_equal "T", h["title"]
end

test "expect takes a spec of exactly one key" do
  msg = assert_raises("ArgumentError") { params_from("a[x]=1&b[y]=2").expect(a: [:x], b: [:y]) }
  assert_equal "expect takes a spec of one key, got 2", msg
end

test "expect never returns an uploaded file" do
  p = params_from("article[title]=Hi")
  p.set_upload_path(["article", "cover"], upload_named("c.png", "1"))
  h = p.expect(article: [:title, :cover])
  assert_equal({ "title" => "Hi" }, h)
  # a level that holds only the file permits nothing: missing
  q = Cybertrain::Params.new
  q.set_upload_path(["article", "cover"], upload_named("c.png", "1"))
  assert_raises("ParameterMissing") { q.expect(article: [:cover]) }
end

test "require(...).permit gains the nested and array forms" do
  h = params_from("post[title]=T&post[ids][]=1").require(:post).permit(:title, ids: [])
  assert_equal ["1"], h["ids"]
end

test "a list sent where a scalar is permitted is dropped, not coerced" do
  assert_equal({}, params_from("post[title][]=x").require(:post).permit(:title))
end

def upload_named(name, data)
  Cybertrain::UploadedFile.new(name, "image/png", data.b)
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
