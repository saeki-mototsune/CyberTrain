# The MySQL connection URL, the server's initial handshake, the password
# scrambles of mysql_native_password and caching_sha2_password, and the
# authentication exchange (TLS switch, auth switch, caching_sha2's fast and
# full paths, a server ERR) against a scripted fake server. No sockets.
#
# The handshake packet is one a MySQL 8.0.46 server (script/mysql-dev) sent,
# captured once. The scramble vectors were computed with CRuby's Digest
# before the implementation existed.
require "cybertrain/net/socket"
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/packet"
require "cybertrain/db/mysql/url"
require "cybertrain/db/mysql/handshake"
require "cybertrain/db/mysql/auth"
require "cybertrain/test"

Wire = Cybertrain::DB::MySQL::Wire
Url = Cybertrain::DB::MySQL::Url
Handshake = Cybertrain::DB::MySQL::Handshake
Auth = Cybertrain::DB::MySQL::Auth
PacketIO = Cybertrain::DB::MySQL::PacketIO

# The initial handshake of mysql:8.0 (8.0.46), started by script/mysql-dev:
# protocol 10, connection id 13, capabilities 0xdfffffff, charset 0x35
# (the low byte of utf8mb4_0900_bin, 309), plugin caching_sha2_password.
RECORDED_HEAD = "0a382e302e3436000d000000374278115c157c0b00ffff350200ffdf150000000000000000000074565b260b6a317465195a4b00"
RECORDED_PLUGIN = "63616368696e675f736861325f70617373776f726400"
RECORDED_SCRAMBLE = "374278115c157c0b74565b260b6a317465195a4b"
NATIVE_PLUGIN = "6d7973716c5f6e61746976655f70617373776f726400"
OK_PACKET = "00000002000000"

def hex(s)
  out = String.new
  i = 0
  while i < s.bytesize
    out << (s.getbyte(i) + 256).to_s(16).byteslice(1, 2)
    i += 1
  end
  out
end

def unhex(text)
  s = text.to_s
  out = "0" * (s.bytesize / 2)
  i = 0
  while i < out.bytesize
    out.setbyte(i, s.byteslice(2 * i, 2).to_i(16))
    i += 1
  end
  out
end

# One packet as the server frames it.
def frame(seq, payload)
  out = Wire.int_le(payload.bytesize, 3)
  out << Wire.int_le(seq, 1)
  out << payload
  out
end

# A peer that answers from a script and records what the client sends:
# stream_read hands out the scripted bytes, stream_write appends to a
# separate buffer.
class ScriptStream < Cybertrain::Net::Stream
  def initialize(script)
    @script_in = String.new
    @script_in << script
    @script_pos = 0
    @script_out = String.new
  end

  def stream_read(max, timer)
    left = @script_in.bytesize - @script_pos
    return "" if left <= 0

    n = left < max ? left : max
    out = @script_in.byteslice(@script_pos, n)
    @script_pos += n
    out
  end

  def stream_write(data, timer)
    @script_out << data
    nil
  end

  def stream_label
    "fake:3306"
  end

  def script_sent
    @script_out
  end
end

# The fake TLS switch: records that it ran and hands back a PacketIO over a
# second scripted stream, as the real one hands back one over TLS.
class FakeTls < Cybertrain::DB::MySQL::TlsUpgrade
  def initialize(stream)
    @fake_io = PacketIO.new(stream)
    @fake_calls = 0
  end

  def mysql_tls_upgrade(io)
    @fake_calls += 1
    @fake_io
  end

  def fake_io
    @fake_io
  end

  def fake_calls
    @fake_calls
  end
end

# The packets the client wrote, payloads with their sequence numbers.
def sent_packets(bytes)
  out = []
  pos = 0
  while pos < bytes.bytesize
    size = Wire.read_int_le(bytes, pos, 3)
    out << [bytes.getbyte(pos + 3), bytes.byteslice(pos + 4, size)]
    pos += 4 + size
  end
  out
end

# Reads the handshake from `stream` as a connection does, then
# authenticates; the plain PacketIO.
def connect(stream, url_text, tls)
  io = PacketIO.new(stream)
  hs = Handshake.parse(io.read_packet)
  assert_nil Auth.handshake(io, Url.parse(url_text), hs, tls)
  io
end

def url_error(text)
  assert_raises("ArgumentError") { Url.parse(text) }
end

test "Url.parse reads every part and decodes the user and password" do
  url = Url.parse("mysql://app%2Dx:p%40ss%3Aw0rd%2F@db.internal:3307/shop?ssl_mode=verify&connect_timeout=7&read_timeout=40&write_timeout=50")
  assert_equal "db.internal", url.host
  assert_equal 3307, url.port
  assert_equal "app-x", url.user
  assert_equal "p@ss:w0rd/", url.password
  assert_equal "shop", url.database
  assert_equal "verify", url.ssl_mode
  assert_equal 7, url.connect_timeout
  assert_equal 40, url.read_timeout
  assert_equal 50, url.write_timeout
  assert_equal "db.internal:3307", url.server_label
end

test "Url.parse defaults" do
  url = Url.parse("mysql://root@db.internal")
  assert_equal "root", url.user
  assert_equal "", url.password
  assert_equal 3306, url.port
  assert_equal "", url.database
  assert_equal "verify", url.ssl_mode
  assert_equal 5, url.connect_timeout
  assert_equal 30, url.read_timeout
  assert_equal 30, url.write_timeout
  assert_equal "", Url.parse("mysql://root:pw@db.internal/").database
end

test "Url.parse takes a bracketed IPv6 host" do
  url = Url.parse("mysql://u:pw@[::1]:3310/app?ssl_mode=disabled")
  assert_equal "::1", url.host
  assert_equal 3310, url.port
  assert_equal "disabled", url.ssl_mode
  assert_equal "[::1]:3310", url.server_label
end

test "a password may hold an unescaped @, / or ?" do
  url = Url.parse("mysql://u:a@b/c?d@10.0.0.5/app?ssl_mode=disabled")
  assert_equal "a@b/c?d", url.password
  assert_equal "10.0.0.5", url.host
  assert_equal "app", url.database
end

test "each malformed URL is an ArgumentError that names the fault" do
  assert_equal "MySQL URL: must start with mysql://", url_error("postgres://u:hunter2@h/db")
  assert_equal "MySQL URL: no user name", url_error("mysql://:hunter2@h/db")
  assert_equal "MySQL URL: no user name", url_error("mysql://h/db")
  assert_equal "MySQL URL: no host", url_error("mysql://u:hunter2@/db")
  assert_equal "MySQL URL: no host", url_error("mysql://u:hunter2@:3306/db")
  assert_equal "MySQL URL: the port must be a number from 1 to 65535", url_error("mysql://u:hunter2@h:99999/db")
  assert_equal "MySQL URL: the port must be a number from 1 to 65535", url_error("mysql://u:hunter2@h:abc/db")
  assert_equal "MySQL URL: the port must be a number from 1 to 65535", url_error("mysql://u:hunter2@h:/db")
  assert_equal "MySQL URL: the port must be a number from 1 to 65535", url_error("mysql://u:hunter2@h:0/db")
  assert_equal "MySQL URL: '[' without ']' in the host", url_error("mysql://u:hunter2@[::1/db")
  assert_equal "MySQL URL: '[x]' is not an IPv6 address", url_error("mysql://u:hunter2@[x]/db")
  assert_equal "MySQL URL: unexpected text after the IPv6 address", url_error("mysql://u:hunter2@[::1]x/db")
  assert_equal "MySQL URL: malformed percent-escape in the user name or password", url_error("mysql://u:hunter2%zz@h/db")
  assert_equal "MySQL URL: malformed percent-escape in the user name or password", url_error("mysql://u:hunter2%2@h/db")
  assert_equal "MySQL URL: the database name cannot contain '/'", url_error("mysql://u:hunter2@h/a/b")
  assert_equal "MySQL URL: unknown ssl_mode 'prefer' (use verify or disabled)", url_error("mysql://u:hunter2@h/db?ssl_mode=prefer")
  assert_equal "MySQL URL: unknown parameter 'foo' (known: ssl_mode, connect_timeout, read_timeout, write_timeout)", url_error("mysql://u:hunter2@h/db?foo=1")
  assert_equal "MySQL URL: malformed parameter 'ssl_mode' (expected name=value)", url_error("mysql://u:hunter2@h/db?ssl_mode")
  assert_equal "MySQL URL: read_timeout must be a whole number of seconds from 1 to 86400", url_error("mysql://u:hunter2@h/db?read_timeout=0")
  assert_equal "MySQL URL: connect_timeout must be a whole number of seconds from 1 to 86400", url_error("mysql://u:hunter2@h/db?connect_timeout=1.5")
  assert_equal "MySQL URL: write_timeout must be a whole number of seconds from 1 to 86400", url_error("mysql://u:hunter2@h/db?write_timeout=99999999999999999999999")
end

test "no URL error message holds the password" do
  bad = [
    "postgres://u:hunter2@h/db", "mysql://:hunter2@h/db", "mysql://u:hunter2@/db",
    "mysql://u:hunter2@h:99999/db", "mysql://u:hunter2@[::1/db", "mysql://u:hunter2%zz@h/db",
    "mysql://u:hunter2@h/a/b", "mysql://u:hunter2@h/db?ssl_mode=prefer", "mysql://u:hunter2@h/db?foo=1",
    "mysql://u:hunter2@h/db?read_timeout=0", "mysql://u:hunter2@8.8.8.8/db?ssl_mode=disabled",
    "mysql://u:hunter2@db.example.com/db?ssl_mode=disabled", "mysql://u:hunter2@[2001:db8::1]/db?ssl_mode=disabled",
    "mysql://u:hunter2", "mysql://u:hunter2@", "u:hunter2@h"
  ]
  bad.each do |text|
    message = url_error(text)
    assert_equal false, message.include?("hunter2")
    assert_equal true, message.start_with?("MySQL URL: ")
  end
end

test "ssl_mode=disabled is accepted for local and private addresses" do
  ["10.0.0.5", "127.0.0.1", "127.4.5.6", "localhost", "172.16.0.1", "172.31.255.255", "192.168.1.2", "[::1]", "[fd00::1]", "[fc12:3456::7]"].each do |host|
    url = Url.parse("mysql://u:pw@#{host}/app?ssl_mode=disabled")
    assert_equal "disabled", url.ssl_mode
  end
end

test "ssl_mode=disabled is refused for any other host" do
  assert_equal "MySQL URL: ssl_mode=disabled is allowed only for localhost, a loopback address, an RFC 1918 address or fc00::/7, not 8.8.8.8: " \
               "without TLS the session crosses the network in plain text (host names are not looked up)",
               url_error("mysql://u:hunter2@8.8.8.8/db?ssl_mode=disabled")
  ["11.0.0.1", "172.32.0.1", "172.15.0.1", "192.169.0.1", "db.example.com", "localhost.example.com", "[2001:db8::1]", "[fe80::1]", "[::ffff:8.8.8.8]"].each do |host|
    message = url_error("mysql://u:pw@#{host}/app?ssl_mode=disabled")
    assert_equal true, message.include?("ssl_mode=disabled is allowed only")
  end
  # verify is the default and goes anywhere.
  assert_equal "verify", Url.parse("mysql://u:pw@8.8.8.8/app").ssl_mode
end

test "the recorded handshake parses" do
  hs = Handshake.parse(unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  assert_equal "8.0.46", hs.server_version
  assert_equal 13, hs.connection_id
  assert_equal 20, hs.scramble.bytesize
  assert_equal RECORDED_SCRAMBLE, hex(hs.scramble)
  assert_equal 0xdfffffff, hs.capabilities
  assert_equal "caching_sha2_password", hs.auth_plugin
end

test "a handshake whose plugin name lacks its NUL still parses" do
  tail = RECORDED_PLUGIN.byteslice(0, RECORDED_PLUGIN.bytesize - 2)
  hs = Handshake.parse(unhex(RECORDED_HEAD + tail))
  assert_equal "caching_sha2_password", hs.auth_plugin
end

test "an ERR in place of the handshake is a DB::Error with the server's message" do
  err = "ff1004" + hex("Too many connections")
  message = assert_raises("Cybertrain::DB::Error") { Handshake.parse(unhex(err)) }
  assert_equal "MySQL error 1040: Too many connections", message
end

test "an old protocol or a cut packet is a DB::Error" do
  message = assert_raises("Cybertrain::DB::Error") { Handshake.parse(unhex("09" + RECORDED_HEAD.byteslice(2, 40))) }
  assert_equal "MySQL: handshake protocol 9 is not supported (MySQL 8.0 or newer is needed)", message
  assert_raises("Cybertrain::DB::Error") { Handshake.parse(unhex(RECORDED_HEAD.byteslice(0, 40))) }
  assert_raises("Cybertrain::DB::Error") { Handshake.parse("") }
end

test "native_password and caching_sha2 match the CRuby Digest vectors" do
  assert_equal "f5cac3f3b3df2133feb57db682c71e6ed433a988", hex(Auth.native_password("secret", "0123456789abcdefghij"))
  assert_equal "7e4adda2f2d5ef09b4147518becb0cee2939376203650a8c2bb2815959364bd0", hex(Auth.caching_sha2("secret", "0123456789abcdefghij"))
  assert_equal "17cffea90a4f33cb0f1084bbc982cd50eb66b80b", hex(Auth.native_password("secret", unhex(RECORDED_SCRAMBLE)))
end

test "an empty password scrambles to the empty string" do
  assert_equal "", Auth.native_password("", "0123456789abcdefghij")
  assert_equal "", Auth.caching_sha2("", "0123456789abcdefghij")
end

test "mysql_native_password: the response and the OK" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + NATIVE_PLUGIN))
  server << frame(2, unhex(OK_PACKET))
  stream = ScriptStream.new(server)
  tls = FakeTls.new(ScriptStream.new(""))
  io = connect(stream, "mysql://root@127.0.0.1?ssl_mode=disabled", tls)
  assert_equal 0, tls.fake_calls
  sent = sent_packets(stream.script_sent)
  assert_equal 1, sent.size
  assert_equal 1, sent[0][0]
  # No database: CONNECT_WITH_DB is off; empty password: a 0 length.
  assert_equal "02a22f0100000001ff0000000000000000000000000000000000000000000000726f6f7400006d7973716c5f6e61746976655f70617373776f726400", hex(sent[0][1])
  # The connection goes on over the plain PacketIO: at sequence 3.
  io.write_packet("x")
  assert_equal 3, sent_packets(stream.script_sent)[1][0]
end

test "caching_sha2_password: the fast path (0x01 0x03) then OK" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  server << frame(2, unhex("0103"))
  server << frame(3, unhex(OK_PACKET))
  stream = ScriptStream.new(server)
  connect(stream, "mysql://cybertrain:secret@10.0.0.5/cybertrain_test?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  sent = sent_packets(stream.script_sent)
  assert_equal 1, sent.size
  assert_equal "0aa22f0100000001ff00000000000000000000000000000000000000000000006379626572747261696e002059b05b2c483d7910da61c651e426e8c4b7cabe64ad4105854c26d4bf817f66aa6379626572747261696e5f746573740063616368696e675f736861325f70617373776f726400", hex(sent[0][1])
end

test "caching_sha2_password: full authentication without TLS is refused" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  server << frame(2, unhex("0104"))
  stream = ScriptStream.new(server)
  message = assert_raises("Cybertrain::DB::Error") do
    connect(stream, "mysql://cybertrain:secret@10.0.0.5/cybertrain_test?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "caching_sha2_password full authentication needs TLS (ssl_mode=verify)", message
  # Nothing but the scramble went out: never the password.
  assert_equal 1, sent_packets(stream.script_sent).size
  assert_equal false, stream.script_sent.include?("secret")
end

test "ssl_mode=verify: SSL Request, the switch, then the response and full authentication over TLS" do
  plain = ScriptStream.new(frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN)))
  over_tls = String.new
  over_tls << frame(3, unhex("0104"))
  over_tls << frame(5, unhex(OK_PACKET))
  secure = ScriptStream.new(over_tls)
  tls = FakeTls.new(secure)
  connect(plain, "mysql://cybertrain:secret@db.internal/cybertrain_test", tls)
  assert_equal 1, tls.fake_calls
  before = sent_packets(plain.script_sent)
  assert_equal 1, before.size
  assert_equal 1, before[0][0]
  assert_equal "0aaa2f0100000001ff0000000000000000000000000000000000000000000000", hex(before[0][1])
  after = sent_packets(secure.script_sent)
  assert_equal 2, after.size
  assert_equal 2, after[0][0]
  assert_equal "0aaa2f0100000001ff00000000000000000000000000000000000000000000006379626572747261696e002059b05b2c483d7910da61c651e426e8c4b7cabe64ad4105854c26d4bf817f66aa6379626572747261696e5f746573740063616368696e675f736861325f70617373776f726400", hex(after[0][1])
  assert_equal 4, after[1][0]
  assert_equal "73656372657400", hex(after[1][1])
  # The connection goes on over TLS, the sequence carried on: 6.
  tls.fake_io.write_packet("x")
  assert_equal 6, sent_packets(secure.script_sent)[2][0]
  assert_equal 1, sent_packets(plain.script_sent).size
  assert_equal false, plain.script_sent.include?("secret")
end

test "ssl_mode=verify against a server without TLS is refused before any credential" do
  # Capabilities 0xdffff7ff: the recorded ones less CLIENT_SSL (0x800).
  head = "0a382e302e3436000d000000374278115c157c0b00fff7350200ffdf150000000000000000000074565b260b6a317465195a4b00"
  plain = ScriptStream.new(frame(0, unhex(head + RECORDED_PLUGIN)))
  message = assert_raises("Cybertrain::DB::Error") do
    connect(plain, "mysql://cybertrain:secret@db.internal/cybertrain_test", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "db.internal:3306: the MySQL server does not offer TLS, which ssl_mode=verify needs", message
  assert_equal "", plain.script_sent
end

test "an auth switch (0xFE) to mysql_native_password is answered with its scramble" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  switch = unhex("fe" + NATIVE_PLUGIN)
  switch << "abcdefghijklmnopqrst"
  switch << unhex("00")
  server << frame(2, switch)
  server << frame(4, unhex(OK_PACKET))
  stream = ScriptStream.new(server)
  connect(stream, "mysql://cybertrain:secret@10.0.0.5/cybertrain_test?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  sent = sent_packets(stream.script_sent)
  assert_equal 2, sent.size
  assert_equal 3, sent[1][0]
  assert_equal "8817c50fa779daef010ee7577825b0847df9842e", hex(sent[1][1])
end

test "an auth switch to an unknown plugin, or a second switch, is a DB::Error" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  server << frame(2, unhex("fe" + hex("sha256_password") + "00" + hex("abcdefghijklmnopqrst") + "00"))
  message = assert_raises("Cybertrain::DB::Error") do
    connect(ScriptStream.new(server), "mysql://u:secret@10.0.0.5/db?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "10.0.0.5:3306: MySQL asked for the authentication plugin 'sha256_password', which is not supported (mysql_native_password, caching_sha2_password)", message
  twice = String.new
  twice << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  twice << frame(2, unhex("fe" + NATIVE_PLUGIN + hex("abcdefghijklmnopqrst") + "00"))
  twice << frame(4, unhex("fe" + NATIVE_PLUGIN + hex("abcdefghijklmnopqrst") + "00"))
  message = assert_raises("Cybertrain::DB::Error") do
    connect(ScriptStream.new(twice), "mysql://u:secret@10.0.0.5/db?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "10.0.0.5:3306: MySQL switched the authentication plugin twice", message
end

test "an ERR during authentication is a DB::Error with the server's message and no password" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  server << frame(2, unhex("ff1504233238303030" + hex("Access denied for user 'cybertrain'@'10.0.0.1' (using password: YES)")))
  message = assert_raises("Cybertrain::DB::Error") do
    connect(ScriptStream.new(server), "mysql://cybertrain:secret@10.0.0.5/cybertrain_test?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "10.0.0.5:3306: MySQL error 1045 (28000): Access denied for user 'cybertrain'@'10.0.0.1' (using password: YES)", message
  assert_equal false, message.include?("secret")
end

test "an unexpected packet during authentication is a DB::Error" do
  server = String.new
  server << frame(0, unhex(RECORDED_HEAD + RECORDED_PLUGIN))
  server << frame(2, unhex("0109"))
  message = assert_raises("Cybertrain::DB::Error") do
    connect(ScriptStream.new(server), "mysql://u:secret@10.0.0.5/db?ssl_mode=disabled", FakeTls.new(ScriptStream.new("")))
  end
  assert_equal "10.0.0.5:3306: unexpected MySQL packet 0x01 0x09 during authentication", message
end

test "the TlsUpgrade base refuses" do
  message = assert_raises("Cybertrain::DB::Error") do
    Cybertrain::DB::MySQL::TlsUpgrade.new.mysql_tls_upgrade(PacketIO.new(ScriptStream.new("")))
  end
  assert_equal "MySQL: no TLS upgrade was given for ssl_mode=verify", message
end

Cybertrain::Test.run!
