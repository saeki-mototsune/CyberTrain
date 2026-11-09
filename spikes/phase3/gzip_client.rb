# Phase 3 spike, check 4 (spec section 14): the HTTP client with the TLS
# layer (Spinel's openssl package) and GzipFFI linked into one program,
# checked in the generated C for the boxed getbyte / each_byte dispatch of
# NOTES rule 62, then run: a gzip body served chunked by the test receiver,
# read through the client's byte-by-byte header and chunk scan, inflated
# with GzipFFI.gunzip. A record, not a test. GzipFFI is FFI and the TLS
# layer needs libssl, so this program runs compiled only.
#
# Commands (Spinel 2026.11.04.7026, from spikes/phase3/):
#   spinel $(spin flags) gzip_client.rb -c -o /tmp/gzip_client.c
#   grep -c 'sp_raise_nomethod(sp_nomethod_msg("getbyte"' /tmp/gzip_client.c
#   grep -c 'sp_raise_nomethod(sp_nomethod_msg("each_byte"' /tmp/gzip_client.c
#   spinel $(spin flags) gzip_client.rb -o /tmp/gzip_client && /tmp/gzip_client
# Output:
#   0   (getbyte grep)
#   0   (each_byte grep)
#   chunked=false: status 200, content-encoding gzip, 34 bytes -> "hello gzip hello gzip hello gzip ", request sent accept-encoding gzip
#   chunked=true: status 200, content-encoding gzip, 34 bytes -> "hello gzip hello gzip hello gzip ", request sent accept-encoding gzip
#   garbage: Cybertrain::BodyUndecodable: request body is not valid gzip data
#   over the limit: Cybertrain::BodyTooLarge: request body inflates to more than 10 bytes
require "cybertrain/http_client"
require "cybertrain/net/tls"
require "cybertrain/http/gzip_ffi"
require "cybertrain/test/http_receiver"

Cybertrain::GzipFFI.install!

# Zlib.gzip("hello gzip " * 3) under CRuby.
GZ = "\x1F\x8B\x08\x00\x7D\xB0\xF1\x6A\x00\x03\xCB\x48\xCD\xC9\xC9\x57\x48\xAF\xCA\x2C\x50\xC8\xC0\xCA\x04\x00\x22\xC1\x1F\x0A\x21\x00\x00\x00"

def served(chunked)
  rx = Cybertrain::Test::HttpReceiver.new(headers: { "Content-Encoding" => "gzip" }, body: GZ, chunked: chunked)
  rx.start
  client = Cybertrain::HttpClient.new(timeout: 2, deadline: 5, allow_private: true)
  res = client.get(rx.url("/feed"), headers: { "Accept-Encoding" => "gzip" })
  req = rx.received_request
  rx.stop
  sent = req.nil? ? "(none)" : req.http_header("accept-encoding")
  inflated = Cybertrain::GzipFFI.gunzip(res.body, 1_048_576)
  puts "chunked=#{chunked}: status #{res.status}, content-encoding #{res.header("Content-Encoding")}, " \
       "#{res.body.bytesize} bytes -> #{inflated.inspect}, request sent accept-encoding #{sent}"
end

served(false)
served(true)

begin
  Cybertrain::GzipFFI.gunzip("not gzip", 100)
rescue Cybertrain::BodyUndecodable => e
  puts "garbage: #{e.class.name}: #{e.message}"
end
begin
  Cybertrain::GzipFFI.gunzip(GZ, 10)
rescue Cybertrain::BodyTooLarge => e
  puts "over the limit: #{e.class.name}: #{e.message}"
end
