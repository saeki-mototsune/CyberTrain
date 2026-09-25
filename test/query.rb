require "cybertrain/http/query"
require "cybertrain/test"

test "parse decodes scalars, lists, nested params and bare flags" do
  params = Cybertrain::Query.parse("a=1&b[]=2&b[]=3&post[title]=hi&flag")
  assert_equal "1", params["a"]
  assert_equal ["2", "3"], params.list("b")
  assert_equal "hi", params.nested("post")["title"]
  assert_equal "", params["flag"]
end

test "parse decodes '+' as space and percent-escapes" do
  params = Cybertrain::Query.parse("q=hello+world&name=%E6%9D%BE%E6%9C%AC")
  assert_equal "hello world", params["q"]
  assert_equal "松本", params["name"]
end

test "parse of a malformed percent-escape does not raise (Spinel diverges from CRuby, which raises ArgumentError)" do
  params = Cybertrain::Query.parse("a=%zz&b=%")
  assert_equal "\u0000", params["a"]
  assert_equal "%", params["b"]
end

test "parse of an empty string yields an empty Params" do
  params = Cybertrain::Query.parse("")
  assert params.empty?
end

test "split_key splits scalar, nested and list-in-nested forms" do
  assert_equal ["id"], Cybertrain::Query.split_key("id")
  assert_equal ["post", "title"], Cybertrain::Query.split_key("post[title]")
  assert_equal ["post", "tags", ""], Cybertrain::Query.split_key("post[tags][]")
  assert_equal ["b", ""], Cybertrain::Query.split_key("b[]")
end

test "split_key treats a malformed bracket as part of a plain key" do
  assert_equal ["a["], Cybertrain::Query.split_key("a[")
end

test "encode round-trips through parse" do
  encoded = Cybertrain::Query.encode({ "a" => "1", "b" => "x y" })
  assert_equal "a=1&b=x+y", encoded
  params = Cybertrain::Query.parse(encoded)
  assert_equal "1", params["a"]
  assert_equal "x y", params["b"]
end

Cybertrain::Test.run!
