require "cybertrain/http/request"
require "cybertrain/http/client_error"
require "cybertrain/params"
require "cybertrain/config"
require "cybertrain/test"

# Request#loopback? and Request#client_ip (issue #70): which address a
# rate limit counts. HTTP layer only (plus Config's flag), so this program
# runs under CRuby too.

def from(addr, forwarded)
  headers = { "host" => "example.com" }
  headers["x-forwarded-for"] = forwarded unless forwarded.empty?
  Cybertrain::Request.new("POST", "/session", headers, "", addr)
end

test "loopback? is 127.0.0.0/8, ::1 and IPv4-mapped 127.x.x.x" do
  ["127.0.0.1", "127.255.0.9", "127.1.2.3", "::1", "::ffff:127.0.0.1", "::FFFF:127.9.9.9"].each do |addr|
    assert from(addr, "").loopback?, addr
  end
end

test "loopback? is false for every other address" do
  ["", "128.0.0.1", "10.0.0.1", "192.168.1.1", "127.0.0", "127.0.0.256", "127.0.0.1.5", "127..0.1",
   "127.0.0.1x", "1270.0.0.1", "0127.0.0.1", "::2", "::ffff:10.0.0.1", "::fff:127.0.0.1", "localhost",
   "2001:db8::1"].each do |addr|
    refute from(addr, "").loopback?, addr
  end
end

test "without a trusted proxy client_ip is the peer, whatever X-Forwarded-For says" do
  Cybertrain::Request.trusted_proxy = false
  assert_equal "127.0.0.1", from("127.0.0.1", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "").client_ip
end

test "with a trusted proxy a loopback peer's last X-Forwarded-For hop is the client" do
  Cybertrain::Request.trusted_proxy = true
  assert_equal "203.0.113.9", from("127.0.0.1", "203.0.113.9").client_ip
  # Earlier hops are the client's own words: only the proxy's is used.
  assert_equal "203.0.113.9", from("127.0.0.1", "10.9.9.9, 1.2.3.4,203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::1", " 6.6.6.6 ,\t203.0.113.9 \t").client_ip
  assert_equal "2001:db8::7", from("::ffff:127.0.0.1", "2001:db8::7").client_ip
  # No header: the peer.
  assert_equal "127.0.0.1", from("127.0.0.1", "").client_ip
  Cybertrain::Request.trusted_proxy = false
end

test "with a trusted proxy a peer that is not loopback keeps its own address" do
  Cybertrain::Request.trusted_proxy = true
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  assert_equal "", from("", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxy = false
end

test "a last hop that is empty, too long or not printable ASCII falls back to the peer" do
  Cybertrain::Request.trusted_proxy = true
  long = "1" * 46
  just_fits = "1" * 45
  bad = ["203.0.113.9,", "203.0.113.9, ", " ", ",", long, "1.2.3.4 5", "1.2.3.4\x7f", "1.2\x013"]
  bad.each do |value|
    assert_equal "127.0.0.1", from("127.0.0.1", value).client_ip
  end
  assert_equal just_fits, from("127.0.0.1", just_fits).client_ip
  # Bytes that are not valid UTF-8 are scanned, never split or stripped.
  invalid = "1.1.1.1, \xFFA".b
  assert_equal "127.0.0.1", from("127.0.0.1", invalid).client_ip
  earlier_invalid = "\xC3(, 203.0.113.9".b
  assert_equal "203.0.113.9", from("127.0.0.1", earlier_invalid).client_ip
  Cybertrain::Request.trusted_proxy = false
end

test "Request.trusted_proxy is false until set" do
  assert_equal false, Cybertrain::Request.trusted_proxy
  Cybertrain::Request.trusted_proxy = true
  assert_equal true, Cybertrain::Request.trusted_proxy
  Cybertrain::Request.trusted_proxy = false
  assert_equal false, Cybertrain::Request.trusted_proxy
end

test "Config#trusted_proxy comes from CYBERTRAIN_TRUSTED_PROXY (1 or true)" do
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = ""
  refute Cybertrain::Config.new.trusted_proxy
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = "1"
  assert Cybertrain::Config.new.trusted_proxy
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = "true"
  assert Cybertrain::Config.new.trusted_proxy
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = "0"
  refute Cybertrain::Config.new.trusted_proxy
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = "yes"
  refute Cybertrain::Config.new.trusted_proxy
  ENV["CYBERTRAIN_TRUSTED_PROXY"] = ""
end

Cybertrain::Test.run!
