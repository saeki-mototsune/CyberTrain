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

test "parse of a malformed percent-escape raises QueryMalformed on every runtime" do
  assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=%zz") }
  assert_raises("QueryMalformed") { Cybertrain::Query.parse("b=%") }
  assert_raises("QueryMalformed") { Cybertrain::Query.parse("c=%4") }
  assert_raises("QueryMalformed") { Cybertrain::Query.parse("%zz=1") }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode("50%off") }
end

test "decode handles runs of escapes, '+', and non-ASCII text between them" do
  # Query.decode hands the library decoder only the ASCII runs of %XX escapes
  # (NOTES rule 49); these pin the chunk boundaries.
  assert_equal "a b c\u00e9", Cybertrain::Query.decode("a%20b+c%C3%A9")
  assert_equal "A", Cybertrain::Query.decode("%41")
  assert_equal "aA", Cybertrain::Query.decode("a%41")
  assert_equal "\u00e9A", Cybertrain::Query.decode("%C3%A9%41")
  assert_equal "aAbBc", Cybertrain::Query.decode("a%41b%42c")
  assert_equal "\u00e9 \u00e9", Cybertrain::Query.decode("\u00e9+%C3%A9")
  assert_equal "\u00e9\u00e9\u3042x\u00e9", Cybertrain::Query.decode("\u00e9%C3%A9%E3%81%82x\u00e9")
  assert_equal " ", Cybertrain::Query.decode("+")
  assert_equal "  ", Cybertrain::Query.decode("++")
  assert_equal "plain\u00e9text", Cybertrain::Query.decode("plain\u00e9text")
  assert_equal "plain text", Cybertrain::Query.decode("plain text")
  assert_equal "x%y", Cybertrain::Query.decode("x%25y")
  assert_raises("QueryMalformed") { Cybertrain::Query.decode("%zz") }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode("\u00e9%4") }
end

test "valid_escapes? wants two hex digits after every percent sign" do
  assert Cybertrain::Query.valid_escapes?("")
  assert Cybertrain::Query.valid_escapes?("plain text")
  assert Cybertrain::Query.valid_escapes?("%41%4a%4A%e6%9d%be")
  assert Cybertrain::Query.valid_escapes?("\u677e%41")
  assert !Cybertrain::Query.valid_escapes?("%")
  assert !Cybertrain::Query.valid_escapes?("%4")
  assert !Cybertrain::Query.valid_escapes?("%zz")
  assert !Cybertrain::Query.valid_escapes?("%41%")
  assert !Cybertrain::Query.valid_escapes?("\u677e%g1")
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
