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

test "decode_escapes (the loop under decode and Request.split_path) leaves '+' alone when asked" do
  assert_equal "a+b c\u00e9", Cybertrain::Query.decode_escapes("a+b%20c%C3%A9", false)
  assert_equal "+", Cybertrain::Query.decode_escapes("+", false)
  assert_equal "++A+", Cybertrain::Query.decode_escapes("++%41+", false)
  assert_equal "a b c\u00e9", Cybertrain::Query.decode_escapes("a+b%20c%C3%A9", true)
  assert_equal "plain\u00e9", Cybertrain::Query.decode_escapes("plain\u00e9", false)
  assert_equal "", Cybertrain::Query.decode_escapes("", false)
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
  assert_equal "a b", Cybertrain::Query.decode("a+b")
  assert_equal "\u00e9 \u00e9", Cybertrain::Query.decode("\u00e9+%C3%A9")
  assert_equal " A ", Cybertrain::Query.decode("+%41+")
  assert_equal "A B", Cybertrain::Query.decode("%41+%42")
  assert_equal "A  B ", Cybertrain::Query.decode("%41++%42+")
  assert_equal " \u00e9\u3042 ", Cybertrain::Query.decode("+%C3%A9\u3042+")
  assert_equal "plain\u00e9text", Cybertrain::Query.decode("plain\u00e9text")
  assert_equal "plain text", Cybertrain::Query.decode("plain text")
  assert_equal "x%y", Cybertrain::Query.decode("x%25y")
  assert_raises("QueryMalformed") { Cybertrain::Query.decode("%zz") }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode("\u00e9%4") }
end

test "decode_escapes refuses a percent sign that is not followed by two hex digits, whatever its caller checked" do
  # "%+1ab" once walked past the "+" as if "%+1" were an escape: pos landed
  # ahead of the cached "+" offset and a nil byteslice raised FrozenError
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%+1ab", true) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%+1ab", false) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%zz", true) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%4z", false) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("a%4", false) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%", false) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%4", false) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%41%4", true) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%41%zz", true) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("a+b%", true) }
  assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("+%+1ab", true) }
  assert_equal "A", Cybertrain::Query.decode_escapes("%41", true)
  assert_equal "A b%", Cybertrain::Query.decode_escapes("%41+b%25", true)
  assert_equal "+A +", Cybertrain::Query.decode_escapes("%2B%41+%2b", true)
  assert_equal "a\u00e9 b", Cybertrain::Query.decode_escapes("a%C3%A9+b", true)
end

# NOTES rule 52: CRuby's byteindex raises IndexError for an offset inside a
# character of an invalid String; Query validates once and answers
# QueryMalformed (a 400) instead, with one fixed message and never the raw text.
test "an invalid byte sequence is QueryMalformed, not IndexError, raw or percent-encoded" do
  msg = "invalid byte sequence in request parameters"
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=1&\x81b=2") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=x+\x81y") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=%41\x81") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("\x81=1") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=%81") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.parse("%C3=1") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode("x+\x81y") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode("%41\x81") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode("\x81") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode("%81") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode("ok%C3") }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("a\x81", false) }
  assert_equal msg, assert_raises("QueryMalformed") { Cybertrain::Query.decode_escapes("%81", false) }
end

test "decode of valid percent-encoded multibyte text still works, a malformed escape keeps its own message" do
  assert_equal "\u00e9", Cybertrain::Query.decode("%C3%A9")
  assert_equal "caf\u00e9 x", Cybertrain::Query.decode("caf%C3%A9+x")
  msg = assert_raises("QueryMalformed") { Cybertrain::Query.decode("%ZZ") }
  assert_equal "malformed percent-encoding in request parameters", msg
end

test "parse of a 100-pair valid non-ASCII body still works" do
  body = (0...100).map { |i| "k#{i}=%C3%A9\u00e9+#{i}" }.join("&")
  params = Cybertrain::Query.parse(body)
  assert_equal "\u00e9\u00e9 0", params["k0"]
  assert_equal "\u00e9\u00e9 99", params["k99"]
  assert_equal 100, params.to_h.length
end

test "parse_into writes into the caller's Params, later pairs over earlier ones, and parse is parse_into on a fresh one" do
  params = Cybertrain::Params.new
  params.set_value("a", "old")
  params.set_value("keep", "k")
  assert Cybertrain::Query.parse_into(params, "a=1&b[]=2").equal?(params)
  Cybertrain::Query.parse_into(params, "a=3&b[]=4")
  assert_equal "3", params["a"]
  assert_equal "k", params["keep"]
  assert_equal ["2", "4"], params.list("b")
  assert_equal "1", Cybertrain::Query.parse("a=1")["a"]
  assert_equal 0, Cybertrain::Query.parse("").to_h.length
end

test "value_of answers what Params#[] answers after a parse" do
  bodies = [
    "a=1&a=2", "a=1&a[]=2", "a[]=2&a=1", "a=1&a[b]=2", "a=1&&a", "a&a=2&a", "%61=1&a+b=2&a=3",
    "a[b]=1&a=2&a[b][c]=3", "x=1", "", "&&", "a=%C3%A9&b=1", "a=1&a[=2", "a=1&a]=2&a[]x=3", "a==1"
  ]
  bodies.each do |body|
    assert_equal Cybertrain::Query.parse(body)["a"].to_s, Cybertrain::Query.value_of(body, "a")
  end
  assert_equal "\u00e9", Cybertrain::Query.value_of("a=%C3%A9&b=1", "a")
  assert_equal "=1", Cybertrain::Query.value_of("a==1", "a")
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
