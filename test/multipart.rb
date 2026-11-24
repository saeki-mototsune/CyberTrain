require "digest"
require "cybertrain/test"
require "cybertrain/http/multipart"
require "cybertrain/params"

# Multipart.fill into cybertrain's Params, read back with its strong
# parameters (`require`). The parser's own cases, browser-shaped and
# hostile bodies, are spinel-http's (its test/multipart.rb). File data is
# binary, so it is compared by bytesize and SHA-256, never with == on the
# raw value (spikes/NOTES.md rules 27, 60). Every piece of a body is
# appended with .b to a binary buffer: a UTF-8 literal with non-ASCII text
# next to binary bytes would raise under CRuby otherwise.

BOUNDARY = "----WebKitFormBoundaryAbC123xyz"

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

Cybertrain::Test.run!
