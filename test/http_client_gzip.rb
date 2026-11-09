# Cybertrain::HttpClient with cybertrain/http/gzip_ffi in the program: the
# request says `Accept-Encoding: gzip` and a `Content-Encoding: gzip` body
# is inflated, through GzipFFI.gunzip under max_body when it is kept and
# through the incremental inflater, at most 64 KiB at a time, when it is
# streamed to a block or into a file. The responses come from
# Test::HttpReceiver (`gzip: true` wraps its body in gzip; the compressible
# fixture below was made by CRuby's Zlib.gzip). Ports are never printed.
#
# GzipFFI is Spinel FFI, so this program cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23). The
# client scans headers and chunk sizes byte by byte in a program that links
# zlib, so the NOTES rule 62 check is part of building it:
#   spinel test/http_client_gzip.rb -c -o /tmp/x.c
#   grep -c 'sp_nomethod_msg("getbyte"' /tmp/x.c      -> 0
require "tmpdir"
require "cybertrain/http_client"
require "cybertrain/http/gzip_ffi"
require "cybertrain/test"
require "cybertrain/test/http_receiver"

# What the fixture inflates to: 320,000 bytes.
def big_text
  "0123456789abcdef" * 20_000
end

# Zlib.gzip(big_text, level: 9) under CRuby: 673 bytes on the wire.
def big_gzip
  gz = String.new
  gz << "\x1F\x8B\x08\x00\xCF\x31\xF2\x6A\x02\x03\xED\xC7\xC9\x01\xC0\x10\x00\x00\xB0\x95\x94\xBA\xC6\x41"
  gz << "\xD9\x7F\x84\x0E\xE1\x9B\xFC\x12\x9E\x98\xDE\x5C\x6A\xEB\x63\xAE\x6F\x9F\xE0\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE"
  gz << "\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\xEE\x7E\xF9\x1F\x0A\x3F\xA3\x41\x00\xE2\x04"
  gz << "\x00"
  gz
end

def receiver(max = 1)
  Cybertrain::Test::HttpReceiver.new(max: max)
end

def gzip_client(max_body = 1_048_576, redirects = 0)
  Cybertrain::HttpClient.new(timeout: 2, deadline: 10, max_body: max_body, allow_private: true, redirects: redirects)
end

def gzip_headers(value)
  h = { "" => "" }
  h.delete("")
  h["Content-Encoding"] = value
  h
end

# What a request ended with: "ok <status>" and the body, or the error's
# kind and message. The rescue ladder is in a method that receives the
# block as a Proc (spikes/NOTES.md rule 32), one clause per class (rule 47).
class Outcome
  attr_reader :kind, :text

  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def outcome(&action)
  begin
    res = action.call
    return Outcome.new("ok #{res.status}", res.body)
  rescue Cybertrain::HttpClient::TooLargeError => e
    return Outcome.new("too large", e.message)
  rescue Cybertrain::HttpClient::BadResponseError => e
    return Outcome.new("bad response", e.message)
  rescue Cybertrain::HttpClient::Error => e
    return Outcome.new("other error", e.message)
  end
  Outcome.new("none", "")
end

TMP = Dir.mktmpdir("cybertrain-gzip")

test "the gzip decoder is installed by requiring cybertrain/http/gzip_ffi" do
  assert Cybertrain::HttpClient.gzip_decoder.gzip_ready?
end

test "Accept-Encoding: gzip is sent and a gzip body is inflated under max_body" do
  text = "hello gzip " * 50
  rx = receiver(2)
  rx.respond_with(status: 200, body: text, gzip: true)
  rx.start
  plain = gzip_client(1000).get(rx.url("/feed"))
  rx.respond_with(status: 200, body: text, gzip: true, chunked: true)
  chunked = gzip_client(1000).get(rx.url("/feed"))
  reqs = rx.received_requests(2)
  rx.stop
  assert_equal 2, reqs.size
  assert_equal "gzip", reqs[0].http_header("Accept-Encoding")
  assert_equal "gzip", reqs[1].http_header("Accept-Encoding")
  assert_equal 200, plain.status
  assert_equal text, plain.body
  assert_equal 550, plain.body.bytesize
  # The headers are the ones received: the body was sent gzip-encoded.
  assert_equal "gzip", plain.header("Content-Encoding")
  assert_equal text, chunked.body
  # The compressed fixture: 673 bytes on the wire, 320,000 inflated.
  rx2 = receiver
  rx2.respond_with(status: 200, body: big_gzip, headers: gzip_headers(" X-Gzip "))
  rx2.start
  big = gzip_client(320_000).get(rx2.url("/big"))
  rx2.stop
  assert_equal 320_000, big.body.bytesize
  assert big.body == big_text
end

test "a caller's Accept-Encoding is sent as written, not doubled" do
  rx = receiver(2)
  rx.respond_with(status: 200, body: "plain")
  rx.start
  first = gzip_client.get(rx.url("/"), headers: { "Accept-Encoding" => "identity" })
  gzip_client.get(rx.url("/"), headers: { "accept-encoding" => "gzip, deflate" })
  reqs = rx.received_requests(2)
  rx.stop
  assert_equal "plain", first.body
  assert_equal "identity", reqs[0].http_header("Accept-Encoding")
  assert_equal "gzip, deflate", reqs[1].http_header("Accept-Encoding")
end

test "a streamed gzip body yields inflated chunks" do
  rx = receiver(2)
  rx.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx.start
  pieces = Array.new(0) { "" }
  res = gzip_client(100).get(rx.url("/stream")) { |chunk| pieces << chunk }
  # Chunked on the wire: the gzip stream is cut in two frames.
  rx.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"), chunked: true)
  framed = Array.new(0) { "" }
  gzip_client(100).request("GET", rx.url("/stream")) { |chunk| framed << chunk }
  rx.stop
  assert_equal 200, res.status
  assert_equal "", res.body
  # 673 bytes on the wire become five or more pieces of at most 64 KiB.
  assert pieces.size >= 5
  biggest = 0
  pieces.each { |p| biggest = p.bytesize if p.bytesize > biggest }
  assert biggest <= 65_536
  assert pieces.join == big_text
  assert framed.size >= 5
  assert framed.join == big_text
end

test "get_to_file of a gzip body writes the inflated bytes" do
  path = "#{TMP}/inflated.txt"
  rx = receiver(2)
  rx.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx.start
  res = gzip_client(100).get_to_file(rx.url("/file"), path)
  rx.respond_with(status: 200, body: "small file", gzip: true, chunked: true)
  small = gzip_client.get_to_file(rx.url("/file"), path + "2")
  rx.stop
  assert_equal 200, res.status
  assert_equal "", res.body
  assert_equal 320_000, res.bytes_written
  assert_equal 320_000, File.size(path)
  assert File.read(path) == big_text
  refute File.exist?("#{path}.part")
  assert_equal 10, small.bytes_written
  assert_equal "small file", File.read(path + "2")
end

test "an inflated body past max_body raises TooLargeError" do
  rx = receiver
  rx.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx.start
  bomb = outcome { gzip_client(4096).get(rx.url("/bomb")) }
  rx.stop
  assert_equal "too large", bomb.kind
  assert_includes bomb.text, "4096"
  assert_includes bomb.text, "127.0.0.1"
  # Compressed bytes past max_body are refused before they are inflated.
  rx2 = receiver
  rx2.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx2.start
  wire = outcome { gzip_client(100).get(rx2.url("/bomb")) }
  rx2.stop
  assert_equal "too large", wire.kind
end

test "Content-Encoding: br is a BadResponseError" do
  rx = receiver(3)
  rx.respond_with(status: 200, body: "compressed?", headers: gzip_headers("br"))
  rx.start
  br = outcome { gzip_client.get(rx.url("/")) }
  rx.respond_with(status: 200, body: "compressed?", headers: gzip_headers("gzip, br"))
  stacked = outcome { gzip_client.get(rx.url("/")) }
  rx.respond_with(status: 200, body: "plain", headers: gzip_headers(" Identity "))
  identity = outcome { gzip_client.get(rx.url("/")) }
  rx.stop
  assert_equal "bad response", br.kind
  assert_includes br.text, "br"
  assert_equal "bad response", stacked.kind
  assert_equal "ok 200", identity.kind
  assert_equal "plain", identity.text
end

# A streamed GET's outcome: the pieces' total size in `text` when it ends.
def streamed_outcome(client, url)
  outcome do
    total = Array.new(0) { 0 }
    res = client.get(url) { |chunk| total << chunk.bytesize }
    Cybertrain::HttpClient::Response.new(res.status, res.headers, total.sum.to_s)
  end
end

test "corrupt or truncated gzip is a BadResponseError, buffered and streamed" do
  gz = big_gzip
  truncated = gz.byteslice(0, gz.bytesize - 8)
  cut_early = gz.byteslice(0, 300)
  rx = receiver(6)
  rx.start
  rx.respond_with(status: 200, body: truncated, headers: gzip_headers("gzip"))
  kept_truncated = outcome { gzip_client.get(rx.url("/")) }
  rx.respond_with(status: 200, body: "not gzip at all", headers: gzip_headers("gzip"))
  kept_garbage = outcome { gzip_client.get(rx.url("/")) }
  rx.respond_with(status: 200, body: truncated, headers: gzip_headers("gzip"))
  streamed_truncated = streamed_outcome(gzip_client, rx.url("/"))
  rx.respond_with(status: 200, body: cut_early, headers: gzip_headers("gzip"), chunked: true)
  streamed_cut = streamed_outcome(gzip_client, rx.url("/"))
  rx.respond_with(status: 200, body: "not gzip at all", headers: gzip_headers("gzip"))
  streamed_garbage = streamed_outcome(gzip_client, rx.url("/"))
  path = "#{TMP}/cut.txt"
  rx.respond_with(status: 200, body: truncated, headers: gzip_headers("gzip"))
  to_file = outcome { gzip_client.get_to_file(rx.url("/"), path) }
  rx.stop
  assert_equal "bad response", kept_truncated.kind
  assert_includes kept_truncated.text, "gzip"
  assert_equal "bad response", kept_garbage.kind
  assert_equal "bad response", streamed_truncated.kind
  assert_includes streamed_truncated.text, "gzip"
  assert_equal "bad response", streamed_cut.kind
  assert_equal "bad response", streamed_garbage.kind
  assert_equal "bad response", to_file.kind
  refute File.exist?(path)
  refute File.exist?("#{path}.part")
end

test "a gzip response with no body bytes is an empty body, kept and streamed" do
  rx = receiver(2)
  rx.respond_with(status: 200, body: "", headers: gzip_headers("gzip"))
  rx.start
  kept = outcome { gzip_client.get(rx.url("/")) }
  streamed = streamed_outcome(gzip_client, rx.url("/"))
  rx.stop
  assert_equal "ok 200", kept.kind
  assert_equal "", kept.text
  assert_equal "ok 200", streamed.kind
  assert_equal "0", streamed.text
end

class StreamStop < StandardError
end

# How a streamed gzip GET whose block raises on the first piece ended. The
# rescue is in a method of its own (rule 32).
def stopped_stream(client, url)
  client.get(url) do |chunk|
    raise StreamStop, "stopped at #{chunk.bytesize} bytes" if chunk.bytesize > 0
    nil
  end
  Outcome.new("none", "")
rescue StreamStop => e
  Outcome.new(e.class.name.to_s, e.message)
rescue Cybertrain::HttpClient::Error => e
  Outcome.new("client error", e.message)
end

test "an exception raised in the streamed block passes through the gzip sink unchanged" do
  rx = receiver
  rx.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx.start
  stopped = stopped_stream(gzip_client, rx.url("/stream"))
  rx.stop
  assert_includes stopped.kind, "StreamStop"
  assert_equal "stopped at 65536 bytes", stopped.text
  # The client is usable afterwards (the decoder was closed by read_body's
  # ensure, the stream by exchange's).
  rx2 = receiver
  rx2.respond_with(status: 200, body: big_gzip, headers: gzip_headers("gzip"))
  rx2.start
  after = gzip_client.get(rx2.url("/"))
  rx2.stop
  assert after.body == big_text
end

test "HttpClient.gzip= replaces the gzip support" do
  installed = Cybertrain::HttpClient.gzip_decoder
  Cybertrain::HttpClient.gzip = Cybertrain::GzipDecoder.new
  rx = receiver
  rx.respond_with(status: 200, body: "hello", gzip: true)
  rx.start
  refused = outcome { gzip_client.get(rx.url("/")) }
  req = rx.received_request
  rx.stop
  Cybertrain::HttpClient.gzip = installed
  assert_equal "bad response", refused.kind
  assert_includes refused.text, "gzip_ffi"
  assert_equal "", req.http_header("Accept-Encoding")
  assert Cybertrain::HttpClient.gzip_decoder.gzip_ready?
end

test "a multi-member gzip body inflates to every member, buffered and streamed" do
  two = String.new
  two << Cybertrain::Test::HttpReceiver.rx_gzip("first,")
  two << Cybertrain::Test::HttpReceiver.rx_gzip("second")
  rx = receiver(2)
  rx.respond_with(status: 200, body: two, headers: gzip_headers("gzip"))
  rx.start
  kept = gzip_client.get(rx.url("/"))
  rx.respond_with(status: 200, body: two, headers: gzip_headers("gzip"), chunked: true)
  pieces = Array.new(0) { "" }
  gzip_client.get(rx.url("/")) { |chunk| pieces << chunk }
  rx.stop
  assert_equal "first,second", kept.body
  assert_equal "first,second", pieces.join
end

test "HEAD, 204 and a redirect's body are not inflated" do
  rx = receiver(2)
  rx.respond_with(status: 200, body: "not gzip at all", headers: gzip_headers("gzip"))
  rx.start
  head = outcome { gzip_client.request("HEAD", rx.url("/")) }
  rx.respond_with(status: 204, headers: gzip_headers("gzip"))
  empty = outcome { gzip_client.get(rx.url("/")) }
  rx.stop
  assert_equal "ok 200", head.kind
  assert_equal "", head.text
  assert_equal "ok 204", empty.kind
  landing = receiver
  landing.respond_with(status: 200, body: "landed", gzip: true)
  landing.start
  hop = receiver
  hop.respond_with(status: 302, body: "not gzip at all", headers: gzip_headers("gzip"), redirect_to: landing.url("/end"))
  hop.start
  res = outcome { gzip_client(1_048_576, 1).get(hop.url("/start")) }
  hop.stop
  landing.stop
  assert_equal "ok 200", res.kind
  assert_equal "landed", res.text
end

test "cleanup" do
  Dir.children(TMP).each { |child| File.delete("#{TMP}/#{child}") }
  Dir.rmdir(TMP)
end

Cybertrain::Test.run!
