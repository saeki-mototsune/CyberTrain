# Request#decoded_body with the real inflater, Cybertrain::GzipFFI: the
# system zlib streamed under a ceiling, so a body that is small on the wire
# and huge inflated is refused when the ceiling is reached. The inflater is
# Spinel FFI, so this program cannot run under CRuby: its snapshot comes from
# the compiled binary (spikes/NOTES.md rule 23). The gzip inputs are made by
# Spinel's own zlib package (Zlib.gzip), which is independent of the system
# zlib the inflater uses.
require "zlib"
require "cybertrain/http/request"
require "cybertrain/http/gzip_ffi"
require "cybertrain/http/client_error"
require "cybertrain/test"

Cybertrain::GzipFFI.install!

def gzip_request(body, encoding = "gzip")
  Cybertrain::Request.new("POST", "/api", { "content-encoding" => encoding }, body)
end

# The bare class name of what decoded_body raises, "" when nothing does
# (Class#name has no namespace under Spinel, NOTES rule 46).
def decode_error(req, limit)
  req.decoded_body(limit)
  ""
rescue Cybertrain::QueryInvalid => e
  Cybertrain::ClientError.bare_name(e.class.name.to_s)
end

test "a gzip body is inflated once and the same String is returned every time" do
  text = "{\"items\":[" + (["{\"n\":1}"] * 500).join(",") + "]}"
  req = gzip_request(Zlib.gzip(text))
  first = req.decoded_body
  assert_equal text, first
  assert first.equal?(req.decoded_body)
  assert_equal Zlib.gzip(text).bytesize, req.body.bytesize
end

test "x-gzip is gzip too" do
  assert_equal "hello", gzip_request(Zlib.gzip("hello"), "x-gzip").decoded_body
end

test "embedded NUL bytes survive the inflate" do
  raw = "a\x00b\x00\x00c"
  out = gzip_request(Zlib.gzip(raw)).decoded_body
  assert_equal 6, out.bytesize
  assert_equal [97, 0, 98, 0, 0, 99], out.bytes
end

test "the inflated body is tagged UTF-8 like a plain one, so the two compare alike" do
  json = "{\"name\":\"caf\u00e9\"}"
  inflated = gzip_request(Zlib.gzip(json)).decoded_body
  plain = Cybertrain::Request.new("POST", "/api", {}, json).decoded_body
  assert_equal plain.encoding.to_s, inflated.encoding.to_s
  assert_equal plain, inflated
  assert_equal json.bytesize, inflated.bytesize
end

test "an empty gzip member inflates to an empty body" do
  assert_equal "", gzip_request(Zlib.gzip("")).decoded_body
end

test "a multi-member gzip file is inflated whole" do
  two = Zlib.gzip("first,") + Zlib.gzip("second")
  assert_equal "first,second", gzip_request(two).decoded_body
end

test "bytes after the last member that are not a member make the body undecodable" do
  garbage = Zlib.gzip("hello") + "trailing junk"
  assert_equal "BodyUndecodable", decode_error(gzip_request(garbage), 1000)
end

test "a body that is not gzip, or too short to be, is undecodable before anything is read" do
  assert_equal "BodyUndecodable", decode_error(gzip_request("not gzip at all, but long enough to try"), 1000)
  assert_equal "BodyUndecodable", decode_error(gzip_request("short"), 1000)
  assert_equal "BodyUndecodable", decode_error(gzip_request("x" * 18), 1000)
end

test "a corrupt member (a flipped byte in the deflate data) is undecodable" do
  gz = Zlib.gzip("a" * 2000)
  bad = gz.dup
  bad.setbyte(gz.bytesize / 2, (gz.getbyte(gz.bytesize / 2) + 1) % 256)
  assert_equal "BodyUndecodable", decode_error(gzip_request(bad), 10_000)
end

test "a truncated member is undecodable" do
  gz = Zlib.gzip("a" * 2000)
  cut = gz.byteslice(0, gz.bytesize - 12).to_s + "\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_equal "BodyUndecodable", decode_error(gzip_request(cut), 10_000)
end

test "a body one byte over the limit is refused, one at the limit passes" do
  big = "a" * 10_000
  gz = Zlib.gzip(big)
  assert_equal "BodyTooLarge", decode_error(gzip_request(gz), 9_999)
  assert_equal "", decode_error(gzip_request(gz), 10_000)
end

test "a trailer that lies small changes nothing: the inflater measures the output" do
  gz = Zlib.gzip("a" * 10_000)
  lying = gz.byteslice(0, gz.bytesize - 4).to_s + "\x01\x00\x00\x00"
  assert_equal "BodyTooLarge", decode_error(gzip_request(lying), 9_999)
end

test "a zip bomb is refused at the ceiling: 20 MB of zeros, small on the wire, against a 1 MiB limit" do
  bomb = Zlib.gzip("\x00" * 20_000_000)
  assert bomb.bytesize < 1_048_576
  lying = bomb.byteslice(0, bomb.bytesize - 4).to_s + "\x01\x00\x00\x00"
  assert_equal "BodyTooLarge", decode_error(gzip_request(lying), 1_048_576)
  assert_equal "BodyTooLarge", decode_error(gzip_request(bomb), 1_048_576)
end

test "a decode error is not cached: every call raises again, and a later larger limit succeeds" do
  req = gzip_request(Zlib.gzip("a" * 100))
  assert_equal "BodyTooLarge", decode_error(req, 99)
  assert_equal "BodyTooLarge", decode_error(req, 99)
  assert_equal "", decode_error(req, 100)
end

test "a cached body is checked against a smaller limit asked for later" do
  req = gzip_request(Zlib.gzip("a" * 100))
  assert_equal 100, req.decoded_body(100).bytesize
  assert_equal "BodyTooLarge", decode_error(req, 50)
end

test "GzipFFI.gunzip refuses a limit it cannot represent" do
  assert_raises("ArgumentError") { Cybertrain::GzipFFI.gunzip(Zlib.gzip("x"), Cybertrain::GzipFFI::MAX_LIMIT + 1) }
  assert_raises("ArgumentError") { Cybertrain::GzipFFI.gunzip(Zlib.gzip("x"), -1) }
end

Cybertrain::Test.run!
