require "cybertrain/http/request"
require "cybertrain/http/client_error"
require "cybertrain/params"
require "cybertrain/config"
require "cybertrain/test"

# Request#loopback? and Request#client_ip (issue #70): which address a
# rate limit counts; Request.trusted_proxies, the CIDR list for a proxy that
# is not on loopback (kamal-proxy in its own container, PR #79 review). HTTP layer only (plus Config's flag), so this program
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

test "a peer inside a trusted IPv4 CIDR names the client; one outside does not" do
  Cybertrain::Request.trusted_proxies = ["172.16.0.0/12", "10.0.0.0/8"]
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("172.31.255.255", "6.6.6.6, 203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("10.200.0.1", "203.0.113.9").client_ip
  # IPv4-mapped peers (a dual-stack listener) match the IPv4 entry.
  assert_equal "203.0.113.9", from("::ffff:172.18.0.2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::FFFF:10.0.0.1", "203.0.113.9").client_ip
  # Just outside, another network, and loopback (trusted_proxy is off).
  ["172.15.255.255", "172.32.0.1", "11.0.0.1", "192.168.1.1", "127.0.0.1", "::ffff:172.32.0.1",
   "::1", "2001:db8::1", "", "not an address"].each do |outside|
    assert_equal outside, from(outside, "203.0.113.9").client_ip
  end
  # No header, or a bad last hop: the peer.
  assert_equal "172.18.0.2", from("172.18.0.2", "").client_ip
  assert_equal "172.18.0.2", from("172.18.0.2", "203.0.113.9,").client_ip
  Cybertrain::Request.trusted_proxies = Array.new(0) { "" }
end

test "a single trusted address matches only itself" do
  Cybertrain::Request.trusted_proxies = ["172.18.0.2"]
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "172.18.0.3", from("172.18.0.3", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxies = ["10.0.0.0/0"]
  assert_equal "203.0.113.9", from("198.51.100.1", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxies = Array.new(0) { "" }
end

test "IPv6 trusted networks: compressed, zone ignored on the peer, bounded prefixes" do
  Cybertrain::Request.trusted_proxies = ["fd00::/8", "2001:db8:0:1::/64", "fe80::/10"]
  assert_equal "203.0.113.9", from("fd12:3456::1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("2001:db8:0:1:ffff::2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("fe80::1%eth0", "203.0.113.9").client_ip
  assert_equal "2001:db8:0:2::1", from("2001:db8:0:2::1", "203.0.113.9").client_ip
  assert_equal "fc00::1", from("fc00::1", "203.0.113.9").client_ip
  # An IPv6 network does not take an IPv4 peer that it does not cover.
  assert_equal "172.18.0.2", from("172.18.0.2", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxies = ["::1"]
  assert_equal "203.0.113.9", from("::1", "203.0.113.9").client_ip
  assert_equal "::2", from("::2", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxies = Array.new(0) { "" }
end

test "Request.trusted_proxies is empty until set and refuses a bad entry" do
  assert_equal 0, Cybertrain::Request.trusted_proxies.size
  Cybertrain::Request.trusted_proxies = ["172.16.0.0/12", "fd00::/8"]
  assert_equal ["172.16.0.0/12", "fd00::/8"], Cybertrain::Request.trusted_proxies
  assert_raises("ArgumentError") { Cybertrain::Request.trusted_proxies = ["172.16.0.0/33"] }
  # A refused list leaves the installed one as it was.
  assert_equal ["172.16.0.0/12", "fd00::/8"], Cybertrain::Request.trusted_proxies
  Cybertrain::Request.trusted_proxies = Array.new(0) { "" }
  assert_equal 0, Cybertrain::Request.trusted_proxies.size
end

test "the loopback shorthand and the list add up" do
  Cybertrain::Request.trusted_proxy = true
  Cybertrain::Request.trusted_proxies = ["172.16.0.0/12"]
  assert_equal "203.0.113.9", from("127.0.0.1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  Cybertrain::Request.trusted_proxy = false
  Cybertrain::Request.trusted_proxies = Array.new(0) { "" }
end

test "IpAddress.parse_network bounds prefixes and refuses what is not a network" do
  ["172.16.0.0/12", "10.0.0.0/8", "172.18.0.2", "0.0.0.0/0", "1.2.3.4/32", "::/0", "::1",
   "fd00::/8", "2001:db8::/128", "::ffff:10.0.0.0/104"].each do |accepted|
    assert_equal 17, Cybertrain::IpAddress.parse_network(accepted).size
  end
  ["", "/8", "10.0.0.0/", "10.0.0.0/33", "::/129", "10.0.0.0/8/8", "10.0.0.0/8x", "10.0.0.0/-1",
   "10.0.0.0/0008", "10.0.0", "010.0.0.1", "10.0.0.256", "fe80::1%eth0", "fe80::/10%eth0", "::1::",
   "1:2:3:4:5:6:7:8:9", "gggg::", "localhost", " 10.0.0.1", "10.0.0.1 "].each do |refused|
    assert_equal 0, Cybertrain::IpAddress.parse_network(refused).size
  end
  # An IPv4 entry is stored as its IPv4-mapped network: prefix + 96.
  assert_equal 108, Cybertrain::IpAddress.parse_network("172.16.0.0/12")[0]
  assert_equal 128, Cybertrain::IpAddress.parse_network("fd00::1")[0]
end

test "Config#trusted_proxies comes from CYBERTRAIN_TRUSTED_PROXIES and is checked at boot" do
  ENV["CYBERTRAIN_TRUSTED_PROXIES"] = ""
  assert_equal 0, Cybertrain::Config.new.trusted_proxies.size
  assert_equal "", Cybertrain::Config.new.trusted_proxies_error
  ENV["CYBERTRAIN_TRUSTED_PROXIES"] = "172.16.0.0/12, 10.0.0.0/8,,fd00::/8 "
  listed = Cybertrain::Config.new
  assert_equal ["172.16.0.0/12", "10.0.0.0/8", "fd00::/8"], listed.trusted_proxies
  assert_equal "", listed.trusted_proxies_error
  ENV["CYBERTRAIN_TRUSTED_PROXIES"] = "172.18.0.2"
  assert_equal ["172.18.0.2"], Cybertrain::Config.new.trusted_proxies
  ENV["CYBERTRAIN_TRUSTED_PROXIES"] = "10.0.0.0/8,172.16.0.0/40"
  assert_equal "CYBERTRAIN_TRUSTED_PROXIES / trusted_proxies entry \"172.16.0.0/40\" is not an IP address or CIDR (e.g. 172.16.0.0/12)",
               Cybertrain::Config.new.trusted_proxies_error
  ENV["CYBERTRAIN_TRUSTED_PROXIES"] = ""
  assigned = Cybertrain::Config.new
  assigned.trusted_proxies = ["kamal-proxy"]
  assert_includes assigned.trusted_proxies_error, "\"kamal-proxy\""
end

Cybertrain::Test.run!
