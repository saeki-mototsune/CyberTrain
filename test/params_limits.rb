require "cybertrain/http/query"
require "cybertrain/http/client_error"
require "cybertrain/params"
require "cybertrain/test"

# Request-parameter DoS limits: bracket nesting depth, pairs per parse, and
# eviction cost. Assertions are on results, never on time.

test "a key nested 10000 levels deep raises QueryTooDeep instead of overflowing the stack" do
  key = "a" + ("[x]" * 10000)
  assert_raises("QueryTooDeep") { Cybertrain::Query.split_key(key) }
  assert_raises("QueryTooDeep") { Cybertrain::Query.parse(key + "=1") }
end

test "QueryTooDeep and QueryTooMany are StandardErrors (assert_raises rescues only those)" do
  msg = assert_raises("QueryTooDeep") { Cybertrain::Query.split_key("a" + ("[x]" * 33)) }
  assert_equal "parameter nesting too deep (limit 32)", msg
  msg2 = assert_raises("QueryTooMany") { Cybertrain::Query.parse((0..4096).map { |i| "k#{i}=1" }.join("&")) }
  assert_equal "too many parameters (limit 4096)", msg2
end

test "nesting exactly MAX_DEPTH deep parses, one more raises" do
  assert_equal 32, Cybertrain::Query::MAX_DEPTH
  ok = "a" + ("[x]" * 32)
  assert_equal 33, Cybertrain::Query.split_key(ok).length
  params = Cybertrain::Query.parse(ok + "=v")
  assert params.key?("a")
  assert_raises("QueryTooDeep") { Cybertrain::Query.split_key("a" + ("[x]" * 33)) }
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

test "a key with MAX_DEPTH pairs and a malformed tail is one plain key; one more pair is QueryTooDeep" do
  # split_key refuses a key at the (MAX_DEPTH + 1)th well-formed pair without
  # reading the rest (bounded work, however long the tail), so the malformed
  # tail only turns the key into a plain one while the pairs so far fit.
  key = "a" + "[x]" * 32 + "[oops"
  assert_equal [key], Cybertrain::Query.split_key(key)
  params = Cybertrain::Query.parse("#{key}=1")
  assert_equal "1", params[key]
  deeper = "a" + "[x]" * 33 + "[oops"
  assert_raises("QueryTooDeep") { Cybertrain::Query.split_key(deeper) }
  assert_raises("QueryTooDeep") { Cybertrain::Query.parse("#{deeper}=1") }
end

test "a non-ASCII key with 100000 bracket pairs is refused as QueryTooDeep" do
  # Character offsets into a non-ASCII String are O(n); the bounded first
  # pass keeps this to MAX_DEPTH + 1 pairs. Asserted on the result only.
  key = "k\u00e9" + "[]" * 100000
  assert_raises("QueryTooDeep") { Cybertrain::Query.split_key(key) }
  assert_raises("QueryTooDeep") { Cybertrain::Query.parse("#{key}=1") }
end

test "a key of a few bracket pairs behind one non-ASCII character splits by byte offsets, multibyte parts intact" do
  assert_equal ["\u00e9", "\u3042", "b"], Cybertrain::Query.split_key("\u00e9[\u3042][b]")
  assert_equal ["k\u00e9", "", "\u3042x"], Cybertrain::Query.split_key("k\u00e9[][\u3042x]")
  assert_equal ["\u3042[b"], Cybertrain::Query.split_key("\u3042[b")
  assert_equal ["\u3042[b]\u00e9"], Cybertrain::Query.split_key("\u3042[b]\u00e9")
  params = Cybertrain::Query.parse("\u00e9[\u3042][b]=1&%C3%A9x%5B%E3%81%82%5D=2")
  assert_equal "1", params.nested("\u00e9").nested("\u3042")["b"]
  assert_equal "2", params.nested("\u00e9x")["\u3042"]
end

test "a non-ASCII key with MAX_DEPTH pairs of 300000 bytes parses without rescanning (9.6 MB, O(key), not O(MAX_DEPTH x key))" do
  # Character offsets (key[pos], key.index("]", pos)) take an O(pos) scan on a
  # UTF-8 String with one multibyte character: 0.47 s per parse on CRuby for
  # this key, three times per request. Byte offsets make it one pass.
  # Asserted on the result only.
  key = "\u00e9" + ("[" + ("a" * 300_000) + "]") * 32
  parts = Cybertrain::Query.split_key(key)
  assert_equal 33, parts.length
  assert_equal "\u00e9", parts[0]
  assert_equal 300_000, parts[1].length
  assert_equal 300_000, parts[32].length
  assert_raises("QueryTooDeep") { Cybertrain::Query.split_key(key + "[a]") }
  params = Cybertrain::Query.parse(key + "=v")
  assert params.key?("\u00e9")
end

test "a large non-ASCII value and a large non-ASCII key decode without a quadratic library call" do
  # URI.decode_www_form_component is quadratic on a non-ASCII String under
  # Spinel (8.5 s for e-acute + 200 000 bytes, NOTES rule 49); Query.decode
  # gives it only the ASCII runs of escapes. Asserted on the result only.
  value = "\u00e9" + ("v" * 300_000)
  params = Cybertrain::Query.parse("k=" + value)
  assert_equal 300_001, params["k"].length
  assert_equal "\u00e9", params["k"][0, 1]
  big_key = "\u00e9" + ("k" * 300_000)
  params = Cybertrain::Query.parse(big_key + "=" + value + "%C3%A9")
  assert_equal 300_002, params[big_key].length
  assert_equal "\u00e9", params[big_key][300_001, 1]
  assert_equal 300_002, Cybertrain::Query.decode(value + "%C3%A9").length
end

test "a large non-ASCII value full of '+' decodes to spaces without a library gsub over the whole text" do
  # "+" is handled in the byte loop (Query.decode_escapes), not by a gsub
  # over the text that nothing has measured on non-ASCII input under Spinel.
  # Asserted on the result only.
  value = "\u00e9" + ("+" * 300_000) + "%C3%A9" + ("a+" * 1000)
  decoded = Cybertrain::Query.decode(value)
  assert_equal 300_000 + 1 + 1 + 2000, decoded.length
  assert_equal 300_000 + 1000, decoded.count(" ")
  assert_equal "\u00e9", decoded[0, 1]
  assert_equal "\u00e9", decoded[300_001, 1]
  params = Cybertrain::Query.parse("k=" + value)
  assert_equal decoded, params["k"]
end

test "Query.decode (shared by Query and Cookies) decodes clean escapes" do
  # The malformed case is in test/query.rb.
  assert_equal "a b", Cybertrain::Query.decode("a+b")
  assert_equal "A B", Cybertrain::Query.decode("%41%20B")
  assert_equal "", Cybertrain::Query.decode("")
end

test "MAX_PAIRS pairs parse, one more raises QueryTooMany" do
  assert_equal 4096, Cybertrain::Query::MAX_PAIRS
  ok = (0...4096).map { |i| "k#{i}=1" }.join("&")
  assert_equal 4096, Cybertrain::Query.parse(ok).keys.length
  too_many = ok + "&extra=1"
  assert_raises("QueryTooMany") { Cybertrain::Query.parse(too_many) }
end

test "empty segments count towards MAX_PAIRS but are still skipped" do
  assert_equal ["a", "b"], Cybertrain::Query.parse("a=1&&b=2").keys
  assert_equal ["a"], Cybertrain::Query.parse("&&a=1&&").keys
  assert_equal "2", Cybertrain::Query.parse("a=1&&b=2")["b"]
  # exactly MAX_PAIRS segments, almost all empty: fine; one more: QueryTooMany
  ok = ("&" * 4095) + "a=1"
  assert_equal ["a"], Cybertrain::Query.parse(ok).keys
  assert_equal [], Cybertrain::Query.parse("&" * 4096).keys
  assert_raises("QueryTooMany") { Cybertrain::Query.parse(ok + "&b=1") }
  assert_raises("QueryTooMany") { Cybertrain::Query.parse("&" * 4097) }
end

test "a body of one non-ASCII character and many '&' is refused as QueryTooMany, not scanned quadratically" do
  # Empty segments used to be skipped uncounted, so this never reached
  # QueryTooMany and each character-offset index/slice was O(pos): 11 s for
  # 200 000 on CRuby. Asserted on the result only.
  assert_raises("QueryTooMany") { Cybertrain::Query.parse("\u00e9" + ("&" * 4097)) }
  assert_raises("QueryTooMany") { Cybertrain::Query.parse("\u00e9" + ("&" * 200000)) }
  assert_equal ["k\u00e9"], Cybertrain::Query.parse("k\u00e9=1&&").keys
end

test "4000 segments after a non-ASCII character parse by byte offsets (O(body), not O(MAX_PAIRS x body))" do
  # Character offsets into a non-ASCII String are O(pos), so 4000 segments of
  # 600 bytes took seconds on CRuby (18 s at 10 MB) until Query.parse cut by
  # bytes. Built with a loop and << so it is the same on both runtimes;
  # asserted on the result only.
  body = +"k\u00e9=first"
  i = 1
  while i < 4000
    body << "&k" << i.to_s << "=" << ("v" * 600)
    i += 1
  end
  params = Cybertrain::Query.parse(body)
  assert_equal 4000, params.keys.length
  assert_equal "first", params["k\u00e9"]
  assert_equal 600, params["k3999"].length
  assert_equal "v", params["k1"][0, 1]
end

test "multibyte keys and values survive the byte-offset cut, whatever the segment boundaries" do
  params = Cybertrain::Query.parse("\u00e9=\u00e9\u00e9&&%C3%A9x=%E3%81%82&\u3042=1&")
  assert_equal ["\u00e9", "\u00e9x", "\u3042"], params.keys
  assert_equal "\u00e9\u00e9", params["\u00e9"]
  assert_equal "\u3042", params["\u00e9x"]
  assert_equal "1", params["\u3042"]
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

test "QueryMalformed (an undecodable percent-escape) is a client fault: 400, not 500" do
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryMalformed.new("malformed percent-encoding"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryTooMany.new("too many"))
  assert_equal 500, Cybertrain::ClientError.status_for(ArgumentError.new("the app's own"))
end

# Which rescue clause a malformed escape lands in, as a plain method with one
# begin/rescue and no block (NOTES rule 32; rule 47: clauses, not is_a?). It
# used to be the decoder's ArgumentError under CRuby; it is QueryInvalid now
# on both runtimes (README "Differences from Rails").
def malformed_rescued_by(text)
  Cybertrain::Query.parse(text)
  "none"
rescue ArgumentError
  "ArgumentError"
rescue Cybertrain::QueryInvalid
  "QueryInvalid"
end

test "a malformed escape is rescued as QueryInvalid, not ArgumentError (upgrade note)" do
  assert_equal "QueryInvalid", malformed_rescued_by("a=%zz")
  assert_equal "QueryInvalid", malformed_rescued_by("a%=1")
  assert_equal "none", malformed_rescued_by("a=%41")
end

Cybertrain::Test.run!
