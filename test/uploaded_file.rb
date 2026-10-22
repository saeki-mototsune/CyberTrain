require "cybertrain/http/uploaded_file"
require "cybertrain/test"

# Bytes are written as string escapes and made binary with .b; a String is
# never built by appending n.chr (it stays tagged UTF-8 under Spinel).
def png_bytes
  "\x89PNG\r\n\x1a\nIHDR".b
end

def jpeg_bytes
  "\xFF\xD8\xFF\xE0\x00\x10JFIF".b
end

def webp_bytes
  "RIFF\x24\x00\x00\x00WEBPVP8 ".b
end

# Arguments are bound to locals before .new (NOTES rule 58).
def make_file(name, data)
  n = name
  declared = "image/png"
  d = data
  Cybertrain::UploadedFile.new(n, declared, d)
end

test "sniff recognises PNG, JPEG, GIF87a, GIF89a, WebP and PDF" do
  assert_equal "image/png", Cybertrain::UploadedFile.sniff(png_bytes)
  assert_equal "image/jpeg", Cybertrain::UploadedFile.sniff(jpeg_bytes)
  assert_equal "image/gif", Cybertrain::UploadedFile.sniff("GIF87a\x01\x00".b)
  assert_equal "image/gif", Cybertrain::UploadedFile.sniff("GIF89a\x01\x00".b)
  assert_equal "image/webp", Cybertrain::UploadedFile.sniff(webp_bytes)
  assert_equal "application/pdf", Cybertrain::UploadedFile.sniff("%PDF-1.7\n".b)
end

test "sniff never reports SVG, HTML, XML or script" do
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("<!DOCTYPE html><html></html>".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("<?xml version=\"1.0\"?><svg/>".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("<script>alert(1)</script>".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("GIF90a".b)
end

test "sniff on short and empty input is the unknown type" do
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("\x89PNG".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("\xFF\xD8".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("GIF89".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("RIFF\x00\x00\x00\x00WEB".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("%PDF".b)
end

test "sniff needs both the RIFF and the WEBP tag" do
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("RIFF\x24\x00\x00\x00WAVEfmt ".b)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("RIFX\x24\x00\x00\x00WEBPVP8 ".b)
end

test "sniff reads bytes across NUL and 0xFF" do
  data = "\x89PNG\r\n\x1a\n\x00\x00\xFF\xFF".b
  assert_equal "image/png", Cybertrain::UploadedFile.sniff(data)
  assert_equal "application/octet-stream", Cybertrain::UploadedFile.sniff("\x00\x89PNG\r\n\x1a\n".b)
end

test "inline_safe? is an exact match on the four raster types" do
  assert Cybertrain::UploadedFile.inline_safe?("image/png")
  assert Cybertrain::UploadedFile.inline_safe?("image/jpeg")
  assert Cybertrain::UploadedFile.inline_safe?("image/gif")
  assert Cybertrain::UploadedFile.inline_safe?("image/webp")
  refute Cybertrain::UploadedFile.inline_safe?("image/svg+xml")
  refute Cybertrain::UploadedFile.inline_safe?("text/html")
  refute Cybertrain::UploadedFile.inline_safe?("application/pdf")
  refute Cybertrain::UploadedFile.inline_safe?("IMAGE/PNG")
  refute Cybertrain::UploadedFile.inline_safe?("image/png; charset=x")
  refute Cybertrain::UploadedFile.inline_safe?("")
end

test "sanitize_filename keeps an ordinary name" do
  assert_equal "photo.png", Cybertrain::UploadedFile.sanitize_filename("photo.png")
  assert_equal "my photo (1).png", Cybertrain::UploadedFile.sanitize_filename("my photo (1).png")
  assert_equal "caf\u00e9.png", Cybertrain::UploadedFile.sanitize_filename("caf\u00e9.png")
  assert_equal "\u5199\u771f.jpg", Cybertrain::UploadedFile.sanitize_filename("\u5199\u771f.jpg")
end

test "sanitize_filename drops a path, however it is spelled" do
  assert_equal "evil.png", Cybertrain::UploadedFile.sanitize_filename("../../evil.png")
  assert_equal "evil.png", Cybertrain::UploadedFile.sanitize_filename("..\\..\\evil.png")
  assert_equal "passwd", Cybertrain::UploadedFile.sanitize_filename("/etc/passwd")
  assert_equal "x.png", Cybertrain::UploadedFile.sanitize_filename("C:\\Users\\me\\x.png")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("dir/")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("..")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename(".")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("../..")
end

test "sanitize_filename drops control bytes, DEL and header or shell metacharacters" do
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\x00b.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\r\nb.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\tb\x7F.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\"b.png")
  # The "/" of a closing tag is a separator, so only the tail is left.
  assert_equal "b.png", Cybertrain::UploadedFile.sanitize_filename("<b>x</b>.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("<a>b.png")
  assert_equal "abcdef.png", Cybertrain::UploadedFile.sanitize_filename("a:b*c?d|e>f.png")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("\x00\x01\x02")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("\"<>:*?|")
end

test "sanitize_filename drops bidi controls and zero-width characters" do
  assert_equal "exe.png", Cybertrain::UploadedFile.sanitize_filename("e\u202Ex\u202Ce.png")
  assert_equal "abc.png", Cybertrain::UploadedFile.sanitize_filename("a\u200Bb\u200Fc.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\u2066\u2069b.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("\uFEFFa\uFEFFb.png")
  assert_equal "ab.png", Cybertrain::UploadedFile.sanitize_filename("a\u202Ab\u202D.png")
  # Neighbours of the dropped ranges are kept.
  assert_equal "a\u200Ab.png", Cybertrain::UploadedFile.sanitize_filename("a\u200Ab.png")
  assert_equal "a\u2065b.png", Cybertrain::UploadedFile.sanitize_filename("a\u2065b.png")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("\u200B\u200E\uFEFF")
end

test "sanitize_filename strips leading and trailing dots and spaces" do
  assert_equal "a.png", Cybertrain::UploadedFile.sanitize_filename("  a.png  ")
  assert_equal "htaccess", Cybertrain::UploadedFile.sanitize_filename("...htaccess")
  assert_equal "png", Cybertrain::UploadedFile.sanitize_filename(".png")
  assert_equal "a.png", Cybertrain::UploadedFile.sanitize_filename("a.png. . .")
  assert_equal "a b", Cybertrain::UploadedFile.sanitize_filename(" a b ")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("   ")
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("")
end

test "sanitize_filename cuts to 255 bytes on a character boundary" do
  long = "a" * 300
  assert_equal 255, Cybertrain::UploadedFile.sanitize_filename(long).bytesize
  # 2-byte characters: 254 bytes hold 127 of them, a 255th byte would split one.
  two = "\u00e9" * 200
  cut = Cybertrain::UploadedFile.sanitize_filename(two)
  assert_equal 254, cut.bytesize
  assert cut.valid_encoding?
  # 3-byte characters: 85 of them are 255 bytes exactly.
  three = "\u5199" * 100
  cut3 = Cybertrain::UploadedFile.sanitize_filename(three)
  assert_equal 255, cut3.bytesize
  assert cut3.valid_encoding?
  # 4-byte characters: 63 are 252 bytes, the 64th would end at 256.
  four = "\u{1F600}" * 100
  cut4 = Cybertrain::UploadedFile.sanitize_filename(four)
  assert_equal 252, cut4.bytesize
  assert cut4.valid_encoding?
  # A cut that lands on trailing dots is stripped again.
  dots = ("a" * 254) + "." + "b"
  assert_equal 254, Cybertrain::UploadedFile.sanitize_filename(dots).bytesize
end

test "sanitize_filename turns invalid UTF-8 into the fallback" do
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("a\xFFb.png".b)
  assert_equal "upload", Cybertrain::UploadedFile.sanitize_filename("\xC3".b)
  assert_equal "caf\u00e9.png", Cybertrain::UploadedFile.sanitize_filename("caf\u00e9.png".b)
end

test "sanitize_filename does not modify its argument" do
  name = "../x.png"
  out = Cybertrain::UploadedFile.sanitize_filename(name)
  assert_equal "x.png", out
  assert_equal "../x.png", name
  assert out.valid_encoding?
end

test "sanitize_type keeps a plain media type, lowercased, without parameters" do
  assert_equal "image/png", Cybertrain::UploadedFile.sanitize_type("image/png")
  assert_equal "image/png", Cybertrain::UploadedFile.sanitize_type("IMAGE/PNG")
  assert_equal "text/html", Cybertrain::UploadedFile.sanitize_type("text/html; charset=utf-8")
  assert_equal "text/html", Cybertrain::UploadedFile.sanitize_type("  Text/HTML  ;x=1")
  assert_equal "image/svg+xml", Cybertrain::UploadedFile.sanitize_type("image/svg+xml")
  assert_equal "application/vnd.api+json", Cybertrain::UploadedFile.sanitize_type("application/vnd.api+json")
  assert_equal "a/b", Cybertrain::UploadedFile.sanitize_type("a/b")
end

test "sanitize_type rejects anything that is not type/subtype" do
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("/png")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("/")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("a/b/c")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image /png")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/pn g")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/png\r\nX: y")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/p\x00ng")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/\"png\"")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("image/p\xC3\xA9")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("*/*")
  assert_equal "", Cybertrain::UploadedFile.sanitize_type("; charset=x")
end

test "sanitize_type allows 127 bytes and refuses 128" do
  ok = "a/" + ("b" * 125)
  assert_equal 127, ok.bytesize
  assert_equal ok, Cybertrain::UploadedFile.sanitize_type(ok)
  assert_equal "", Cybertrain::UploadedFile.sanitize_type(ok + "b")
end

test "content_disposition for a plain name" do
  assert_equal "attachment; filename=\"photo.png\"; filename*=UTF-8''photo.png",
    Cybertrain::UploadedFile.content_disposition("attachment", "photo.png")
  assert_equal "inline; filename=\"photo.png\"; filename*=UTF-8''photo.png",
    Cybertrain::UploadedFile.content_disposition("inline", "photo.png")
end

test "content_disposition treats an unknown disposition as attachment" do
  assert_equal "attachment; filename=\"a.png\"; filename*=UTF-8''a.png",
    Cybertrain::UploadedFile.content_disposition("INLINE", "a.png")
  assert_equal "attachment; filename=\"a.png\"; filename*=UTF-8''a.png",
    Cybertrain::UploadedFile.content_disposition("form-data", "a.png")
  assert_equal "attachment; filename=\"a.png\"; filename*=UTF-8''a.png",
    Cybertrain::UploadedFile.content_disposition("", "a.png")
end

test "content_disposition percent-encodes non-ASCII per RFC 5987 and falls back to underscores" do
  out = Cybertrain::UploadedFile.content_disposition("attachment", "caf\u00e9.png")
  assert_equal "attachment; filename=\"caf__.png\"; filename*=UTF-8''caf%C3%A9.png", out
  jp = Cybertrain::UploadedFile.content_disposition("inline", "\u5199\u771f.jpg")
  assert_equal "inline; filename=\"______.jpg\"; filename*=UTF-8''%E5%86%99%E7%9C%9F.jpg", jp
end

test "content_disposition keeps CR, LF, quotes and backslashes out of the header" do
  out = Cybertrain::UploadedFile.content_disposition("attachment", "a\"b\\c\r\nd;e.png")
  assert_equal "attachment; filename=\"a_b_c__d_e.png\"; filename*=UTF-8''a%22b%5Cc%0D%0Ad%3Be.png", out
  refute out.include?("\r")
  refute out.include?("\n")
  assert_equal 2, out.count("\"")
end

test "content_disposition encodes everything outside the RFC 5987 attr-chars" do
  out = Cybertrain::UploadedFile.content_disposition("attachment", "a b%c'd(e)f*g,h.png")
  assert_equal "attachment; filename=\"a b_c_d_e_f_g_h.png\"; filename*=UTF-8''a%20b%25c%27d%28e%29f%2Ag%2Ch.png", out
  # Single quotes: "#$&" would interpolate the $& variable in a double-quoted String.
  attr_chars = '!#$&+.^_`|~-az09'
  keep = Cybertrain::UploadedFile.content_disposition("attachment", attr_chars)
  assert_equal "attachment; filename=\"_____._____-az09\"; filename*=UTF-8''" + attr_chars, keep
end

test "content_disposition output is always ASCII, even for hostile bytes" do
  hostile = "\xFF\xFE\x00\x80 weird \u202E\u{1F600}.png"
  out = Cybertrain::UploadedFile.content_disposition("attachment", hostile)
  ascii = true
  i = 0
  while i < out.bytesize
    b = out.getbyte(i)
    ascii = false if b < 0x20 || b > 0x7E
    i += 1
  end
  assert ascii
  assert_includes out, "%FF%FE%00%80"
  assert_includes out, "%E2%80%AE"
  assert_includes out, "%F0%9F%98%80"
end

test "content_disposition of an empty name" do
  assert_equal "attachment; filename=\"\"; filename*=UTF-8''",
    Cybertrain::UploadedFile.content_disposition("attachment", "")
end

test "an UploadedFile reports its name, types, size and kind" do
  f = make_file("pic.png", png_bytes)
  assert_equal "pic.png", f.original_filename
  assert_equal "image/png", f.declared_content_type
  assert_equal png_bytes.bytesize, f.byte_size
  assert_equal "image/png", f.detected_content_type
  assert f.image?
  refute f.empty?
  assert_equal png_bytes.bytesize, f.body_bytes.bytesize
  assert_equal png_bytes.b.getbyte(0), f.body_bytes.getbyte(0)
end

test "the declared type is never trusted: HTML named png is not an image" do
  html = "<html><script>alert(1)</script></html>".b
  f = make_file("x.png", html)
  assert_equal "image/png", f.declared_content_type
  assert_equal "application/octet-stream", f.detected_content_type
  refute f.image?
end

test "SVG is not an image" do
  svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".b
  f = make_file("x.svg", svg)
  assert_equal "application/octet-stream", f.detected_content_type
  refute f.image?
end

test "a PDF is detected but is not inline-safe" do
  f = make_file("doc.pdf", "%PDF-1.4\n".b)
  assert_equal "application/pdf", f.detected_content_type
  refute f.image?
end

test "detected_content_type is stable across calls" do
  f = make_file("pic.jpg", jpeg_bytes)
  assert_equal "image/jpeg", f.detected_content_type
  assert_equal "image/jpeg", f.detected_content_type
end

test "blank is an empty file with no name or type" do
  b = Cybertrain::UploadedFile.blank
  assert b.empty?
  assert_equal 0, b.byte_size
  assert_equal "", b.original_filename
  assert_equal "", b.declared_content_type
  assert_equal "application/octet-stream", b.detected_content_type
  refute b.image?
end

test "empty? is true for a zero-byte file with a name" do
  f = make_file("empty.png", "".b)
  assert f.empty?
  assert_equal 0, f.byte_size
  assert_equal "empty.png", f.original_filename
  refute f.image?
end

test "sha256_hex is the SHA-256 of the bytes, including NUL and 0xFF" do
  assert_equal "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", make_file("e", "".b).sha256_hex
  assert_equal "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", make_file("a", "abc".b).sha256_hex
  data = "\x00\xFF\x00".b
  f = make_file("b", data)
  assert_equal 64, f.sha256_hex.bytesize
  assert_equal Digest::SHA256.hexdigest(data), f.sha256_hex
  assert_equal f.sha256_hex, f.sha256_hex
  refute make_file("c", "\x00".b).sha256_hex == make_file("d", "\x00\x00".b).sha256_hex
end

test "inspect and to_s show the name and size, never the bytes" do
  secret = "TOP-SECRET-PAYLOAD-BYTES"
  f = make_file("pic.png", (png_bytes + secret.b))
  expected = "#<Cybertrain::UploadedFile \"pic.png\" #{png_bytes.bytesize + secret.bytesize} bytes>"
  assert_equal expected, f.inspect
  assert_equal expected, f.to_s
  refute f.inspect.include?("SECRET")
  refute f.inspect.include?("PNG")
  assert_equal "#<Cybertrain::UploadedFile \"\" 0 bytes>", Cybertrain::UploadedFile.blank.inspect
end

# The snapshot records the actual values, so a runtime that disagrees with
# CRuby shows up as a diff and not only as an assertion.
test "representative results are recorded in the snapshot" do
  puts "name: " + Cybertrain::UploadedFile.sanitize_filename("..\\..\\a\u202Eb\"c\r\n.png")
  puts "name: " + Cybertrain::UploadedFile.sanitize_filename("\u00e9" * 200).bytesize.to_s
  puts "type: " + Cybertrain::UploadedFile.sanitize_type(" Image/PNG ; q=1")
  puts "disp: " + Cybertrain::UploadedFile.content_disposition("inline", "caf\u00e9 \"1\".png")
  puts "file: " + make_file("p.png", png_bytes).inspect
  puts "sha:  " + make_file("p.png", png_bytes).sha256_hex
  puts "kind: " + make_file("p.png", webp_bytes).detected_content_type
end

Cybertrain::Test.run!
