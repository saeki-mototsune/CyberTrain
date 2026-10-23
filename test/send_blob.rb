require "digest"
require "stringio"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"

# Controller#send_blob through a real controller action, a Router and
# Test::Client: the headers an untrusted upload is served with, and the body
# bytes arriving intact. cybertrain/controller pulls in the SQLite FFI
# bindings, so take the snapshot from the compiled binary
# (script/regen-snapshot), not from CRuby (spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

# Every byte value once, then a PNG signature in front: NUL, CR, LF and the
# bytes above 0x7F are what would break a text-minded response writer.
def all_bytes
  out = +"\x89PNG\r\n\x1a\n".b
  i = 0
  while i < 256
    out << i.chr.b
    i += 1
  end
  out
end

BLOB = all_bytes

# The body of a serialized response: everything after the blank line.
def body_of(raw)
  cut = raw.index("\r\n\r\n")
  raw.byteslice(cut + 4, raw.bytesize - cut - 4)
end

def head_of(raw)
  cut = raw.index("\r\n\r\n")
  raw.byteslice(0, cut)
end

class FilesController < Cybertrain::Controller
  def png
    send_blob(BLOB, filename: "photo.png", content_type: "image/png")
  end

  def svg
    send_blob("<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'></svg>", filename: "logo.svg", content_type: "image/svg+xml")
  end

  def html
    send_blob("<script>alert(1)</script>", filename: "page.html", content_type: "text/html")
  end

  def claimed
    send_blob(BLOB, filename: "x.png", content_type: "image/png; charset=utf-8")
  end

  # A tampered stored name: quotes, CRLF header injection, a path, non-ASCII.
  def hostile
    send_blob(BLOB, filename: "..\\evil/a\"b\r\nSet-Cookie: x=1\r\n\r\ncafé‮.png", content_type: "image/png")
  end

  def accented
    send_blob(BLOB, filename: "café 日本.png", content_type: "image/png")
  end

  def empty_name
    send_blob("", filename: "", content_type: "application/pdf")
  end
end

router = Cybertrain::Router.new
router.get("/png", "png") { |ctx| FilesController.new(ctx).process(:png) { |c| c.png } }
router.get("/svg", "svg") { |ctx| FilesController.new(ctx).process(:svg) { |c| c.svg } }
router.get("/html", "html") { |ctx| FilesController.new(ctx).process(:html) { |c| c.html } }
router.get("/claimed", "claimed") { |ctx| FilesController.new(ctx).process(:claimed) { |c| c.claimed } }
router.get("/hostile", "hostile") { |ctx| FilesController.new(ctx).process(:hostile) { |c| c.hostile } }
router.get("/accented", "accented") { |ctx| FilesController.new(ctx).process(:accented) { |c| c.accented } }
router.get("/empty", "empty") { |ctx| FilesController.new(ctx).process(:empty_name) { |c| c.empty_name } }

CLIENT = Cybertrain::Test::Client.new(router)

def show_headers(res)
  puts "status #{res.status}"
  puts "type #{res.header("Content-Type")}"
  puts "disposition #{res.header("Content-Disposition")}"
  puts "nosniff #{res.header("X-Content-Type-Options")}"
  puts "csp #{res.header("Content-Security-Policy")}"
  puts "cache #{res.header("Cache-Control")}"
end

test "a PNG is served inline with the lock-down headers" do
  res = CLIENT.get("/png")
  show_headers(res)
  assert_equal 200, res.status
  assert_equal "image/png", res.header("Content-Type")
  assert_equal "inline; filename=\"photo.png\"; filename*=UTF-8''photo.png", res.header("Content-Disposition")
  assert_equal "nosniff", res.header("X-Content-Type-Options")
  assert_equal "default-src 'none'; sandbox", res.header("Content-Security-Policy")
  assert_equal "private, max-age=3600", res.header("Cache-Control")
  assert res.performed?
end

test "an SVG is forced to an attachment of unknown type" do
  res = CLIENT.get("/svg")
  show_headers(res)
  assert_equal "application/octet-stream", res.header("Content-Type")
  assert_equal "attachment; filename=\"logo.svg\"; filename*=UTF-8''logo.svg", res.header("Content-Disposition")
  assert_equal "nosniff", res.header("X-Content-Type-Options")
  assert_equal "default-src 'none'; sandbox", res.header("Content-Security-Policy")
end

test "an HTML blob is forced to an attachment of unknown type" do
  res = CLIENT.get("/html")
  show_headers(res)
  assert_equal "application/octet-stream", res.header("Content-Type")
  assert_equal "attachment; filename=\"page.html\"; filename*=UTF-8''page.html", res.header("Content-Disposition")
  assert_equal "<script>alert(1)</script>", res.body
end

test "a type with parameters is not on the inline list" do
  res = CLIENT.get("/claimed")
  show_headers(res)
  assert_equal "application/octet-stream", res.header("Content-Type")
  assert res.header("Content-Disposition").start_with?("attachment;")
end

test "a hostile stored filename makes a safe ASCII header" do
  res = CLIENT.get("/hostile")
  disposition = res.header("Content-Disposition")
  puts "disposition #{disposition}"
  assert disposition.ascii_only?
  refute disposition.include?("\r")
  refute disposition.include?("\n")
  assert_nil res.header("Set-Cookie")
  assert_equal 0, res.cookies.length
  assert_equal 0, res.to_http.scan("\r\nSet-Cookie:").length
  head = head_of(res.to_http)
  assert head.ascii_only?
  # the status line, the five headers send_blob sets, the X-Frame-Options
  # default and Content-Length: nothing injected
  puts "header lines #{head.split("\r\n").length}"
end

test "a non-ASCII filename gets an ASCII fallback and a percent-encoded name" do
  res = CLIENT.get("/accented")
  puts "disposition #{res.header("Content-Disposition")}"
  assert res.header("Content-Disposition").ascii_only?
  assert_includes res.header("Content-Disposition"), "filename*=UTF-8''caf%C3%A9%20%E6%97%A5%E6%9C%AC.png"
end

test "an empty filename falls back to upload" do
  res = CLIENT.get("/empty")
  puts "disposition #{res.header("Content-Disposition")}"
  assert_equal "application/octet-stream", res.header("Content-Type")
  assert_includes res.header("Content-Disposition"), "filename=\"upload\""
  assert_equal "", res.body
end

test "binary body bytes survive to_http intact" do
  res = CLIENT.get("/png")
  assert_equal 264, BLOB.bytesize
  assert_equal 264, res.body.bytesize
  want = Digest::SHA256.hexdigest(BLOB)
  puts "blob sha256 #{want}"
  raw = res.to_http
  tail = body_of(raw)
  puts "wire body bytes #{tail.bytesize}"
  puts "wire body sha256 #{Digest::SHA256.hexdigest(tail)}"
  assert_equal 264, tail.bytesize
  assert_equal want, Digest::SHA256.hexdigest(tail)
  assert_includes head_of(raw), "Content-Length: 264"
  assert head_of(raw).ascii_only?
  assert_equal want, Digest::SHA256.hexdigest(res.body)
end

test "HEAD answers the same headers and Content-Length without the body" do
  res = CLIENT.request("HEAD", "/png")
  assert_equal 200, res.status
  assert_equal "image/png", res.header("Content-Type")
  raw = res.to_http(true)
  puts "head only bytes after blank line #{body_of(raw).bytesize}"
  assert_equal 0, body_of(raw).bytesize
  assert_includes raw, "Content-Length: 264\r\n"
  assert_includes raw, "X-Content-Type-Options: nosniff\r\n"
  assert_includes raw, "Content-Disposition: inline; filename=\"photo.png\""
end

test "send_blob sends exactly one nosniff next to the global defaults" do
  ["/png", "/svg", "/html", "/empty"].each do |path|
    raw = CLIENT.get(path).to_http
    assert_equal 1, raw.scan(/^x-content-type-options:/i).length
    assert_equal 1, raw.scan(/^x-frame-options:/i).length
    assert_includes raw, "X-Content-Type-Options: nosniff\r\n"
    assert_includes raw, "X-Frame-Options: SAMEORIGIN\r\n"
    # send_blob adds the CSP on top of the defaults
    assert_includes raw, "Content-Security-Policy: default-src 'none'; sandbox\r\n"
  end
  puts "nosniff lines #{CLIENT.get("/png").to_http.scan(/^x-content-type-options:/i).length}"
end

Cybertrain::Test.run!
