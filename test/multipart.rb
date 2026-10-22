require "digest"
require "cybertrain/test"
require "cybertrain/http/multipart"

# Cybertrain::Multipart against browser-shaped and hostile bodies. File data
# is binary, so it is compared by bytesize and SHA-256 (and getbyte), never
# with == on the raw value (spikes/NOTES.md rules 27, 60). Every piece of a
# body is appended with .b to a binary buffer: a UTF-8 literal with
# non-ASCII text next to binary bytes would raise under CRuby otherwise.

BOUNDARY = "----WebKitFormBoundaryAbC123xyz"
CRLF = "\r\n"

# Every byte value 0..255, once, as escapes (no n.chr, which would stay
# tagged UTF-8 under Spinel).
ALL_BYTES = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5A\x5B\x5C\x5D\x5E\x5F\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6A\x6B\x6C\x6D\x6E\x6F\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7A\x7B\x7C\x7D\x7E\x7F\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9D\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFB\xFC\xFD\xFE\xFF"

def all_bytes
  ALL_BYTES.b
end

def png_with_nul_and_ff
  out = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xFF\xFF\x00\x00".b
  out << all_bytes
  out << "\x00\x00\x00\x00IEND\xAEB`\x82".b
  out
end

def sha(data)
  Digest::SHA256.hexdigest(data)
end

def content_type(boundary)
  "multipart/form-data; boundary=#{boundary}"
end

# One part: the delimiter line, the header lines, a blank line, the data.
# `headers` is every header line after the delimiter, joined with CRLF.
def raw_part(boundary, headers, data)
  out = "".b
  out << "--".b
  out << boundary.b
  out << "\r\n".b
  out << headers.b
  out << "\r\n\r\n".b
  out << data.b
  out << "\r\n".b
  out
end

def text_part(boundary, name, value)
  raw_part(boundary, "Content-Disposition: form-data; name=\"#{name}\"", value)
end

def file_part(boundary, name, filename, type, data)
  raw_part(boundary, "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\nContent-Type: #{type}", data)
end

def closing(boundary)
  "--#{boundary}--\r\n".b
end

def parse_body(body)
  Cybertrain::Multipart.parse(body, content_type(BOUNDARY))
end

# A body with one text part whose Content-Disposition line is `disposition`.
def with_disposition(disposition, data)
  body = raw_part(BOUNDARY, "Content-Disposition: #{disposition}", data)
  body << closing(BOUNDARY)
  body
end

def with_headers(headers)
  body = raw_part(BOUNDARY, headers, "v")
  body << closing(BOUNDARY)
  body
end

def reset_limits
  Cybertrain::Multipart.configure(5_242_880, 128)
end

def assert_file(form, i, name, filename, declared, data)
  assert_equal name, form.file_name_at(i)
  up = form.file_at(i)
  assert_equal filename, up.original_filename
  assert_equal declared, up.declared_content_type
  assert_equal data.bytesize, up.byte_size
  assert_equal sha(data), up.sha256_hex
  assert_equal data.bytesize, up.body_bytes.bytesize
end

# ---------------------------------------------------------------- a browser

def browser_body
  png = png_with_nul_and_ff
  body = "".b
  body << text_part(BOUNDARY, "authenticity_token", "tok-123_abc")
  body << text_part(BOUNDARY, "_method", "patch")
  body << text_part(BOUNDARY, "post[title]", "Hello 日本語")
  body << text_part(BOUNDARY, "post[body]", "line one\r\nline two\r\n\r\nline four")
  body << text_part(BOUNDARY, "post[tags][]", "a")
  body << text_part(BOUNDARY, "post[tags][]", "b")
  body << text_part(BOUNDARY, "empty", "")
  body << file_part(BOUNDARY, "post[cover]", "cover.png", "image/png", png)
  body << file_part(BOUNDARY, "post[avatar]", "", "application/octet-stream", "")
  body << text_part(BOUNDARY, "commit", "Update Post")
  body << closing(BOUNDARY)
  body
end

test "a browser-shaped body: text fields, nested names, a PNG file, an unselected file input dropped" do
  form = parse_body(browser_body)
  assert_equal 8, form.text_count
  assert_equal "authenticity_token", form.text_name_at(0)
  assert_equal "tok-123_abc", form.text_value_at(0)
  assert_equal "post[title]", form.text_name_at(2)
  assert_equal "Hello 日本語", form.text_value_at(2)
  assert_equal "line one\r\nline two\r\n\r\nline four", form.text_value_at(3)
  assert_equal "post[tags][]", form.text_name_at(4)
  assert_equal "a", form.text_value_at(4)
  assert_equal "b", form.text_value_at(5)
  assert_equal "", form.text_value_at(6)
  assert_equal "commit", form.text_name_at(7)
  # The empty file input (filename="" and no bytes) is dropped; the PNG stays.
  assert_equal 1, form.file_count
  assert_file(form, 0, "post[cover]", "cover.png", "image/png", png_with_nul_and_ff)
  up = form.file_at(0)
  assert_equal "image/png", up.detected_content_type
  assert up.image?
  bytes = up.body_bytes
  assert_equal 0x89, bytes.getbyte(0).to_i
  assert_equal 0, bytes.getbyte(8).to_i
  assert_equal 0xFF, bytes.getbyte(16).to_i
  assert_equal 0, bytes.getbyte(20).to_i
  assert_equal 1, bytes.getbyte(21).to_i
  puts "browser body: #{form.text_count} texts, #{form.file_count} file, #{up.byte_size} bytes, sha256 #{up.sha256_hex[0, 16]}"
end

test "text_value is the last top-level match and is empty when absent" do
  form = parse_body(browser_body)
  assert_equal "tok-123_abc", form.text_value("authenticity_token")
  assert_equal "patch", form.text_value("_method")
  assert_equal "Update Post", form.text_value("commit")
  assert_equal "", form.text_value("missing")
  assert_equal "", form.text_value("title")
  assert_equal "", form.text_value("post")
  body = "".b
  body << text_part(BOUNDARY, "_method", "delete")
  body << text_part(BOUNDARY, "_method", "patch")
  body << closing(BOUNDARY)
  assert_equal "patch", parse_body(body).text_value("_method")
end

test "a body with no parts is an empty form" do
  form = parse_body(closing(BOUNDARY))
  assert_equal 0, form.text_count
  assert_equal 0, form.file_count
  form = parse_body("--#{BOUNDARY}--".b)
  assert_equal 0, form.text_count
end

test "a file keeps its bytes whatever they are: all 256 values, NUL runs, a trailing CRLF" do
  data = "".b
  data << all_bytes
  data << ("\x00".b * 300)
  data << all_bytes
  data << "\r\n".b
  body = file_part(BOUNDARY, "f", "all.bin", "application/octet-stream", data)
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 1, form.file_count
  assert_file(form, 0, "f", "all.bin", "application/octet-stream", data)
  assert_equal 256 * 2 + 300 + 2, form.file_at(0).byte_size
  assert_equal "application/octet-stream", form.file_at(0).detected_content_type
end

test "an empty file with a name is kept; an empty name with data is kept too" do
  body = file_part(BOUNDARY, "a", "empty.txt", "text/plain", "")
  body << file_part(BOUNDARY, "b", "", "application/octet-stream", "xyz")
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 2, form.file_count
  assert form.file_at(0).empty?
  assert_equal "empty.txt", form.file_at(0).original_filename
  assert_equal "upload", form.file_at(1).original_filename
  assert_equal 3, form.file_at(1).byte_size
end

# ------------------------------------------------------------- look-alikes

test "boundary look-alikes inside file data do not end the part" do
  tricky = "".b
  tricky << "--#{BOUNDARY}X".b
  tricky << "\r\n--#{BOUNDARY}X more".b
  tricky << "\r\n--#{BOUNDARY}-x".b
  tricky << "\r\n--#{BOUNDARY} tail".b
  tricky << "\r\n--#{BOUNDARY}\t \t x".b
  tricky << "\r\n--#{BOUNDARY[0, 10]}".b
  tricky << "--#{BOUNDARY}".b
  tricky << "\r\n\r\n--".b
  tricky << "\r".b
  body = text_part(BOUNDARY, "before", "1")
  body << file_part(BOUNDARY, "f", "tricky.bin", "application/octet-stream", tricky)
  body << text_part(BOUNDARY, "after", "2")
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 2, form.text_count
  assert_equal "1", form.text_value("before")
  assert_equal "2", form.text_value("after")
  assert_equal 1, form.file_count
  assert_file(form, 0, "f", "tricky.bin", "application/octet-stream", tricky)
end

test "a text value may hold NUL, CRLF and multibyte text" do
  value = "a\x00b\r\n\x00\u65e5\u672c".b.force_encoding("UTF-8")
  body = text_part(BOUNDARY, "t", value)
  body << closing(BOUNDARY)
  got = parse_body(body).text_value("t")
  assert_equal value.bytesize, got.bytesize
  assert_equal sha(value.b), sha(got.b)
  assert got.valid_encoding?
end

test "a text value that holds look-alikes keeps them" do
  value = "x\r\n--#{BOUNDARY}Y\r\n--#{BOUNDARY}-z"
  body = text_part(BOUNDARY, "t", value)
  body << closing(BOUNDARY)
  assert_equal value, parse_body(body).text_value("t")
end

test "a long run of look-alikes is scanned in linear time" do
  chunk = "\r\n--#{BOUNDARY}X".b
  data = "".b
  i = 0
  while i < 20_000
    data << chunk
    i += 1
  end
  body = file_part(BOUNDARY, "f", "dense.bin", "application/octet-stream", data)
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_file(form, 0, "f", "dense.bin", "application/octet-stream", data)
  puts "dense look-alikes: #{form.file_at(0).byte_size} bytes"
end

test "128 parts of mixed binary data keep every byte" do
  body = "".b
  digests = Array.new(0) { "" }
  i = 0
  while i < 128
    data = "".b
    data << all_bytes.byteslice(i, 256 - i)
    data << "\x00\r\n--".b
    data << all_bytes.byteslice(0, i)
    digests << sha(data)
    body << file_part(BOUNDARY, "f#{i}", "p#{i}.bin", "application/octet-stream", data)
    i += 1
  end
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 128, form.file_count
  i = 0
  while i < 128
    assert_equal "f#{i}", form.file_name_at(i)
    assert_equal digests[i], form.file_at(i).sha256_hex
    assert_equal 256 + 5, form.file_at(i).byte_size
    i += 1
  end
end

test "a 4 MiB file part parses and round-trips" do
  data = "".b
  unit = all_bytes
  i = 0
  while i < 16_384
    data << unit
    i += 1
  end
  body = file_part(BOUNDARY, "big", "big.bin", "application/octet-stream", data)
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 4_194_304, form.file_at(0).byte_size
  assert_equal sha(data), form.file_at(0).sha256_hex
end

test "a 9 MiB body of 110 big parts, dense in NUL runs and look-alikes, keeps every digest" do
  unit = "".b
  unit << all_bytes
  unit << ("\x00".b * 64)
  unit << "\r\n--#{BOUNDARY}X\r\n--#{BOUNDARY}-\r\n--#{BOUNDARY} x".b
  digests = Array.new(0) { "" }
  body = "".b
  i = 0
  while i < 110
    data = "".b
    j = 0
    while j < 200
      data << unit
      j += 1
    end
    data << i.to_s.b
    digests << sha(data)
    body << file_part(BOUNDARY, "f#{i}", "big#{i}.bin", "application/octet-stream", data)
    i += 1
  end
  body << closing(BOUNDARY)
  assert body.bytesize > 9_000_000
  form = parse_body(body)
  assert_equal 110, form.file_count
  i = 0
  while i < 110
    assert_equal digests[i], form.file_at(i).sha256_hex
    i += 1
  end
  puts "big body: #{form.file_count} files, #{body.bytesize} bytes"
end

# ------------------------------------------------- preamble, epilogue, padding

test "a preamble and an epilogue are ignored" do
  body = "This is a multipart message.\r\nIgnore this part.\r\n".b
  body << text_part(BOUNDARY, "a", "1")
  body << "--#{BOUNDARY}--\r\nepilogue text\r\n--#{BOUNDARY}\r\nmore".b
  form = parse_body(body)
  assert_equal 1, form.text_count
  assert_equal "1", form.text_value("a")
end

test "the first delimiter may start at offset 0 or after a CRLF" do
  body = text_part(BOUNDARY, "a", "1")
  body << closing(BOUNDARY)
  assert_equal "1", parse_body(body).text_value("a")
  shifted = "\r\n".b
  shifted << body
  assert_equal "1", parse_body(shifted).text_value("a")
end

test "a preamble of exactly 1024 bytes is accepted, 1025 is not" do
  body = text_part(BOUNDARY, "a", "1")
  body << closing(BOUNDARY)
  ok = ("p".b * 1024) + "\r\n".b
  ok << body
  assert_equal "1", parse_body(ok).text_value("a")
  big = ("p".b * 1025) + "\r\n".b
  big << body
  message = assert_raises("MultipartMalformed") { parse_body(big) }
  assert_equal "multipart body does not start with the boundary", message
end

test "text glued to the first delimiter is malformed" do
  # Glued to the delimiter, it is not a preamble line, and nothing else
  # closes the body.
  glued = "xx--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1".b
  assert_raises("MultipartMalformed") { parse_body(glued) }
  assert_raises("MultipartMalformed") { parse_body("".b) }
  assert_raises("MultipartMalformed") { parse_body("just some text".b) }
end

test "transport padding after delimiters is accepted up to 16 bytes" do
  body = "--#{BOUNDARY} \t \r\n".b
  body << "Content-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n".b
  body << "--#{BOUNDARY}\t\t\r\n".b
  body << "Content-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n".b
  body << "--#{BOUNDARY}--  \r\n".b
  form = parse_body(body)
  assert_equal "1", form.text_value("a")
  assert_equal "2", form.text_value("b")
  padded16 = "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--#{BOUNDARY}#{" " * 16}\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--#{BOUNDARY}--\r\n".b
  form = parse_body(padded16)
  assert_equal "1", form.text_value("a")
  assert_equal "2", form.text_value("b")
  # Past 16 bytes it is no delimiter at all, so it is part of the value.
  padded17 = "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--#{BOUNDARY}#{" " * 17}\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--#{BOUNDARY}--\r\n".b
  form = parse_body(padded17)
  assert_equal 1, form.text_count
  assert_equal 0, form.text_value("b").bytesize
  assert_equal "1\r\n--#{BOUNDARY}#{" " * 17}\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2", form.text_value("a")
end

test "a delimiter followed by junk is no delimiter" do
  body = "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--#{BOUNDARY}!\r\n".b
  assert_raises("MultipartMalformed") { parse_body(body) }
  assert_raises("MultipartMalformed") { parse_body("--#{BOUNDARY}X\r\n".b) }
end

# ----------------------------------------------------------------- boundary

test "boundary_from reads a token and a quoted-string" do
  assert_equal "abc123", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=abc123")
  assert_equal "----WebKitFormBoundaryAbC", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=----WebKitFormBoundaryAbC")
  assert_equal "abc", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"abc\"")
  assert_equal "a b:c", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"a b:c\"")
  assert_equal "a\"b\\c", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"a\\\"b\\\\c\"")
  assert_equal "a;b", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"a;b\"")
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data;boundary=xyz")
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data;  boundary = xyz ")
end

test "boundary_from matches the parameter name without regard to case, among others" do
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data; BOUNDARY=xyz")
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data; Boundary=xyz")
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data; charset=utf-8; boundary=xyz; x=y")
  assert_equal "xyz", Cybertrain::Multipart.boundary_from("multipart/form-data; foo=\"a;boundary=nope\"; boundary=xyz")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; xboundary=xyz")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary2=xyz")
end

test "boundary_from is empty when missing or invalid" do
  assert_equal "", Cybertrain::Multipart.boundary_from("")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data;")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"\"")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"unterminated")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=a; boundary=b")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=a\r\nb")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"a\nb\"")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"a\x00b\"")
end

test "boundary_from allows 200 bytes and refuses 201" do
  assert_equal 200, Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=#{"b" * 200}").bytesize
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=#{"b" * 201}")
  assert_equal 200, Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"#{"b" * 200}\"").bytesize
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"#{"b" * 201}\"")
end

test "boundary_from refuses non-ASCII bytes" do
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=caf\u00e9")
  assert_equal "", Cybertrain::Multipart.boundary_from("multipart/form-data; boundary=\"\u65e5\u672c\"")
end

test "parse without a usable boundary raises MultipartMalformed" do
  body = text_part(BOUNDARY, "a", "1")
  message = assert_raises("MultipartMalformed") { Cybertrain::Multipart.parse(body, "multipart/form-data") }
  assert_equal "missing or invalid multipart boundary", message
  assert_raises("MultipartMalformed") { Cybertrain::Multipart.parse(body, "") }
  assert_raises("MultipartMalformed") { Cybertrain::Multipart.parse(body, "multipart/form-data; boundary=#{"b" * 201}") }
  assert_raises("MultipartMalformed") { Cybertrain::Multipart.parse(body, "multipart/form-data; boundary=caf\u00e9") }
end

test "a quoted boundary and an odd one parse" do
  odd = "a b'()+_,-./:=?"
  body = text_part(odd, "a", "1")
  body << closing(odd)
  form = Cybertrain::Multipart.parse(body, "multipart/form-data; boundary=\"#{odd}\"")
  assert_equal "1", form.text_value("a")
  quoted = Cybertrain::Multipart.parse(body, "MULTIPART/FORM-DATA; Boundary=\"#{odd}\"; charset=utf-8")
  assert_equal "1", quoted.text_value("a")
end

# ----------------------------------------------------- Content-Disposition

test "disposition parameters: case, spaces, tokens, escapes, filename wins over filename*" do
  form = parse_body(with_disposition("FORM-DATA; NAME=\"a\"", "1"))
  assert_equal "1", form.text_value("a")
  form = parse_body(with_disposition("form-data;name=a", "2"))
  assert_equal "2", form.text_value("a")
  form = parse_body(with_disposition("form-data ;  name = \"a\"  ;", "3"))
  assert_equal "3", form.text_value("a")
  form = parse_body(with_disposition("form-data; name=\"a\\\"b\\\\c\"", "4"))
  assert_equal "4", form.text_value("a\"b\\c")
  form = parse_body(with_disposition("form-data; name=\"a;b\"; filename=\"x;y.png\"; filename*=UTF-8''z.png", "bytes"))
  assert_equal 1, form.file_count
  assert_equal "a;b", form.file_name_at(0)
  assert_equal "x;y.png", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"a\"; filename*=UTF-8''z.png", "t"))
  assert_equal 0, form.file_count  # filename* alone is not a filename
  assert_equal "t", form.text_value("a")
end

test "filenames are sanitized: paths, quotes, controls and an invalid UTF-8 name" do
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"..\\\\..\\\\evil.png\"", "x"))
  assert_equal "evil.png", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"C:\\fakepath\\photo.png\"", "x"))
  assert_equal "photo.png", form.file_at(0).original_filename  # old IE sends backslashes unescaped
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"../../etc/passwd\"", "x"))
  assert_equal "passwd", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"a\\\"b<c>.png\"", "x"))
  assert_equal "abc.png", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"\u65e5\u672c\u8a9e.png\"", "x"))
  assert_equal "\u65e5\u672c\u8a9e.png", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"bad\xFF\xFE.png\"", "x"))
  assert_equal "upload", form.file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"..\"", "x"))
  assert_equal "upload", form.file_at(0).original_filename
end

test "the part Content-Type is sanitized and never trusted" do
  form = parse_body(file_part(BOUNDARY, "f", "a.png", "Image/PNG; charset=binary", "x") + closing(BOUNDARY))
  assert_equal "image/png", form.file_at(0).declared_content_type
  assert_equal "application/octet-stream", form.file_at(0).detected_content_type
  form = parse_body(file_part(BOUNDARY, "f", "a.png", "text/html\"><script>", "x") + closing(BOUNDARY))
  assert_equal "", form.file_at(0).declared_content_type
  body = raw_part(BOUNDARY, "Content-Disposition: form-data; name=\"f\"; filename=\"a.png\"", "x")
  body << closing(BOUNDARY)
  assert_equal "", parse_body(body).file_at(0).declared_content_type
  form = parse_body(file_part(BOUNDARY, "f", "a.png", "image/png", png_with_nul_and_ff) + closing(BOUNDARY))
  assert form.file_at(0).image?
  form = parse_body(file_part(BOUNDARY, "f", "a.png", "image/png", "<html><script>alert(1)</script>") + closing(BOUNDARY))
  assert_equal "image/png", form.file_at(0).declared_content_type
  refute form.file_at(0).image?, "HTML sent as image/png is not an image"
end

test "other part headers are ignored and header names are case-insensitive" do
  headers = "content-disposition: form-data; name=\"a\"\r\nX-Anything: whatever\r\nContent-Transfer-Encoding: base64\r\nCONTENT-TYPE: text/plain"
  body = raw_part(BOUNDARY, headers, "aGk=")
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal "aGk=", form.text_value("a")
end

test "UTF-8 in a field name is kept" do
  body = text_part(BOUNDARY, "\u540d\u524d", "\u5024")
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal "\u540d\u524d", form.text_name_at(0)
  assert_equal "\u5024", form.text_value("\u540d\u524d")
end

# ------------------------------------------------------------------- limits

test "too many parts raises MultipartTooManyParts, counting a dropped file input too" do
  Cybertrain::Multipart.configure(5_242_880, 3)
  body = text_part(BOUNDARY, "a", "1")
  body << text_part(BOUNDARY, "b", "2")
  body << file_part(BOUNDARY, "c", "", "application/octet-stream", "")
  ok = body + closing(BOUNDARY)
  form = parse_body(ok)
  assert_equal 2, form.text_count
  assert_equal 0, form.file_count
  body << text_part(BOUNDARY, "d", "4")
  body << closing(BOUNDARY)
  message = assert_raises("MultipartTooManyParts") { parse_body(body) }
  assert_equal "too many multipart parts (limit 3)", message
  reset_limits
end

test "the part count is checked before the part is cut, so a flood of tiny parts stops early" do
  Cybertrain::Multipart.configure(5_242_880, 128)
  body = "".b
  i = 0
  while i < 129
    body << text_part(BOUNDARY, "k#{i}", "v")
    i += 1
  end
  body << closing(BOUNDARY)
  message = assert_raises("MultipartTooManyParts") { parse_body(body) }
  assert_equal "too many multipart parts (limit 128)", message
  reset_limits
end

test "a part header block of 8192 bytes passes and 8193 raises MultipartHeaderTooLarge" do
  base = "Content-Disposition: form-data; name=\"a\"\r\nX-Pad: "
  ok = base + ("p" * (8192 - base.bytesize))
  assert_equal 8192, ok.bytesize
  form = parse_body(with_headers(ok))
  assert_equal "v", form.text_value("a")
  big = base + ("p" * (8193 - base.bytesize))
  message = assert_raises("MultipartHeaderTooLarge") { parse_body(with_headers(big)) }
  assert_equal "multipart part headers too large (limit 8192 bytes)", message
end

test "a file over max_upload_bytes raises MultipartPartTooLarge, exactly the limit passes" do
  Cybertrain::Multipart.configure(10, 128)
  ok = file_part(BOUNDARY, "f", "a.bin", "application/octet-stream", "0123456789") + closing(BOUNDARY)
  assert_equal 10, parse_body(ok).file_at(0).byte_size
  big = file_part(BOUNDARY, "f", "a.bin", "application/octet-stream", "0123456789A") + closing(BOUNDARY)
  message = assert_raises("MultipartPartTooLarge") { parse_body(big) }
  assert_equal "uploaded file too large (limit 10 bytes)", message
  # Text fields are not held to the file limit.
  text = text_part(BOUNDARY, "t", "0123456789ABCDEF") + closing(BOUNDARY)
  assert_equal "0123456789ABCDEF", parse_body(text).text_value("t")
  reset_limits
  assert_equal 5_242_880, Cybertrain::Multipart.max_upload_bytes
  assert_equal 128, Cybertrain::Multipart.max_parts
end

test "the text values together are held to 1 MiB" do
  half = "t" * 524_288
  body = text_part(BOUNDARY, "a", half)
  body << text_part(BOUNDARY, "b", half)
  body << closing(BOUNDARY)
  form = parse_body(body)
  assert_equal 524_288, form.text_value("a").bytesize
  assert_equal 524_288, form.text_value("b").bytesize
  body = text_part(BOUNDARY, "a", half)
  body << text_part(BOUNDARY, "b", half)
  body << text_part(BOUNDARY, "c", "x")
  body << closing(BOUNDARY)
  message = assert_raises("MultipartPartTooLarge") { parse_body(body) }
  assert_equal "multipart text fields too large (limit 1048576 bytes)", message
  one = text_part(BOUNDARY, "a", "t" * 1_048_577) + closing(BOUNDARY)
  assert_raises("MultipartPartTooLarge") { parse_body(one) }
end

test "a name of 1024 bytes passes and 1025 raises MultipartMalformed" do
  form = parse_body(text_part(BOUNDARY, "n" * 1024, "v") + closing(BOUNDARY))
  assert_equal 1024, form.text_name_at(0).bytesize
  message = assert_raises("MultipartMalformed") { parse_body(text_part(BOUNDARY, "n" * 1025, "v") + closing(BOUNDARY)) }
  assert_equal "multipart part name too long (limit 1024 bytes)", message
end

test "a raw filename of 1024 bytes passes and 1025 raises MultipartMalformed" do
  form = parse_body(file_part(BOUNDARY, "f", "n" * 1024, "image/png", "x") + closing(BOUNDARY))
  assert_equal 255, form.file_at(0).original_filename.bytesize  # cut to the 255-byte display limit
  message = assert_raises("MultipartMalformed") { parse_body(file_part(BOUNDARY, "f", "n" * 1025, "image/png", "x") + closing(BOUNDARY)) }
  assert_equal "multipart filename too long (limit 1024 bytes)", message
end

# ---------------------------------------------------------------- malformed

test "a part with no blank line after its headers is malformed" do
  body = "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n".b
  body << "--#{BOUNDARY}--\r\n".b
  message = assert_raises("MultipartMalformed") { parse_body(body) }
  assert_equal "multipart part has no end of headers", message
  assert_raises("MultipartMalformed") { parse_body("--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"".b) }
end

test "a body that stops before its closing delimiter is malformed" do
  whole = text_part(BOUNDARY, "a", "1")
  message = assert_raises("MultipartMalformed") { parse_body(whole) }
  assert_equal "unterminated multipart part", message
  cut = text_part(BOUNDARY, "a", "1")
  cut << "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nstill going".b
  assert_raises("MultipartMalformed") { parse_body(cut) }
  # A closing delimiter without the CRLF before it is data, not a delimiter.
  glued = "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1--#{BOUNDARY}--\r\n".b
  assert_raises("MultipartMalformed") { parse_body(glued) }
end

test "a duplicate Content-Disposition or Content-Type is malformed" do
  headers = "Content-Disposition: form-data; name=\"a\"\r\nContent-Disposition: form-data; name=\"b\""
  message = assert_raises("MultipartMalformed") { parse_body(with_headers(headers)) }
  assert_equal "duplicate Content-Disposition in multipart part", message
  headers = "Content-Disposition: form-data; name=\"a\"\r\ncontent-disposition: form-data; name=\"b\""
  assert_raises("MultipartMalformed") { parse_body(with_headers(headers)) }
  headers = "Content-Disposition: form-data; name=\"a\"\r\nContent-Type: text/plain\r\nContent-Type: text/html"
  message = assert_raises("MultipartMalformed") { parse_body(with_headers(headers)) }
  assert_equal "duplicate Content-Type in multipart part", message
end

test "a part that is not form-data, or has no usable name, is malformed" do
  message = assert_raises("MultipartMalformed") { parse_body(with_disposition("attachment; name=\"a\"", "1")) }
  assert_equal "multipart part is not form-data", message
  assert_raises("MultipartMalformed") { parse_body(with_disposition("file; name=\"a\"", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Type: text/plain")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; filename=\"a.png\"", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"\"", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"a\"; name=\"b\"", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"a\"; filename=\"x\"; filename=\"y\"", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"a", "1")) }
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"a\"; filename=\"b", "1")) }
end

test "a field name that is not valid UTF-8 is malformed" do
  message = assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"a\xFFb\"", "1")) }
  assert_equal "multipart part name is not valid UTF-8", message
  assert_raises("MultipartMalformed") { parse_body(with_disposition("form-data; name=\"\xC3\"", "1")) }
end

test "a text value that is not valid UTF-8 raises QueryMalformed" do
  message = assert_raises("QueryMalformed") { parse_body(with_disposition("form-data; name=\"a\"", "ok \xFF\xFE bad")) }
  assert_equal "invalid byte sequence in request parameters", message
  assert_raises("QueryMalformed") { parse_body(with_disposition("form-data; name=\"a\"", "\xC3")) }
  # The same bytes in a FILE are just bytes.
  body = file_part(BOUNDARY, "f", "a.bin", "application/octet-stream", "ok \xFF\xFE bad")
  body << closing(BOUNDARY)
  assert_equal 9, parse_body(body).file_at(0).byte_size
end

test "malformed header lines are refused" do
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nNoColonHere")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\n: empty-name")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nX Bad: space in name")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nX-Bad : space before colon")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\n folded continuation")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\n\tfolded: continuation")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nX-Lf: bare\nlf")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nX-Cr: bare\rcr")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\"\r\nX-Nul: a\x00b")) }
  assert_raises("MultipartMalformed") { parse_body(with_headers("Content-Disposition: form-data; name=\"a\x00b\"")) }
end

test "a header-injection attempt in a filename stays a display name" do
  headers = "Content-Disposition: form-data; name=\"f\"; filename=\"a.png\""
  body = raw_part(BOUNDARY, headers, "x")
  body << closing(BOUNDARY)
  assert_equal "a.png", parse_body(body).file_at(0).original_filename
  form = parse_body(with_disposition("form-data; name=\"f\"; filename=\"x.png%0d%0aSet-Cookie: a=b\"", "1"))
  name = form.file_at(0).original_filename
  assert_equal false, name.include?("\r")
  assert_equal false, name.include?("\n")
end

# --------------------------------------------------------------------- fill

test "fill: texts by set_path, files by set_upload_path" do
  form = parse_body(browser_body)
  params = Cybertrain::Params.new
  Cybertrain::Multipart.fill(params, form)
  assert_equal "patch", params["_method"]
  assert_equal "tok-123_abc", params["authenticity_token"]
  post = params.require(:post)
  assert_equal "Hello 日本語", post[:title]
  assert_equal "line one\r\nline two\r\n\r\nline four", post[:body]
  assert_equal ["a", "b"], post.list(:tags)
  assert_equal "", params["empty"]
  assert post.upload?(:cover)
  up = post.upload(:cover)
  assert_equal "cover.png", up.original_filename
  assert_equal sha(png_with_nul_and_ff), up.sha256_hex
  refute post.upload?(:avatar), "the unselected file input is not in the params"
  assert_nil post.upload(:avatar)
  puts "filled: post[cover] = #{up.original_filename}, #{up.byte_size} bytes, sha256 #{up.sha256_hex[0, 16]}"
end

test "fill: a file named name[] is refused, a plain file name is fine" do
  body = file_part(BOUNDARY, "docs[]", "a.txt", "text/plain", "x")
  body << closing(BOUNDARY)
  message = assert_raises("MultipartMalformed") { Cybertrain::Multipart.fill(Cybertrain::Params.new, parse_body(body)) }
  assert_equal "multiple files per field are not supported", message
  body = file_part(BOUNDARY, "doc", "a.txt", "text/plain", "x")
  body << closing(BOUNDARY)
  params = Cybertrain::Params.new
  Cybertrain::Multipart.fill(params, parse_body(body))
  assert params.upload?(:doc)
end

test "fill: names are not percent-decoded, and nesting is limited like a query string" do
  body = text_part(BOUNDARY, "a%5Bb%5D", "1")
  body << closing(BOUNDARY)
  params = Cybertrain::Params.new
  Cybertrain::Multipart.fill(params, parse_body(body))
  assert_equal "1", params["a%5Bb%5D"]
  deep = "a" + ("[b]" * 33)
  body = text_part(BOUNDARY, deep, "1") + closing(BOUNDARY)
  assert_raises("QueryTooDeep") { Cybertrain::Multipart.fill(Cybertrain::Params.new, parse_body(body)) }
  fine = "a" + ("[b]" * 32)
  body = text_part(BOUNDARY, fine, "1") + closing(BOUNDARY)
  Cybertrain::Multipart.fill(Cybertrain::Params.new, parse_body(body))
end

test "fill: more fields than Query::MAX_PAIRS raises QueryTooMany" do
  form = Cybertrain::MultipartForm.new
  i = 0
  while i < 4097
    form.add_text("k#{i}", "v")
    i += 1
  end
  message = assert_raises("QueryTooMany") { Cybertrain::Multipart.fill(Cybertrain::Params.new, form) }
  assert_equal "too many parameters (limit 4096)", message
  small = Cybertrain::MultipartForm.new
  i = 0
  while i < 4096
    small.add_text("k#{i}", "v")
    i += 1
  end
  params = Cybertrain::Params.new
  Cybertrain::Multipart.fill(params, small)
  assert_equal "v", params["k4095"]
end

test "MultipartForm keeps parts in order, one list per kind" do
  form = Cybertrain::MultipartForm.new
  form.add_text("a", "1")
  form.add_file("f", Cybertrain::UploadedFile.blank)
  form.add_text("b", "2")
  assert_equal 2, form.text_count
  assert_equal 1, form.file_count
  assert_equal "b", form.text_name_at(1)
  assert_equal "2", form.text_value_at(1)
  assert_equal "f", form.file_name_at(0)
  assert form.file_at(0).empty?
end

Cybertrain::Test.run!
