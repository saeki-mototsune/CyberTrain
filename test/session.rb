require "cybertrain/test"
require "cybertrain/session"
require "cybertrain/crypto"
require "cybertrain/encryptor"
require "cybertrain/cookie_jar"
require "cybertrain/middleware/session_store"
require "cybertrain/http/request"
require "cybertrain/http/cookies"
require "cybertrain/context"
require "uri"
require "base64"
require "json"

# The session cookie is AES-256-GCM under a key derived from the secret
# (Crypto.derive_key(secret, "cybertrain session")); cybertrain/session.rb
# requires cybertrain/encryptor and so Spinel's openssl package, which needs
# libssl: the snapshot comes from the compiled binary (spikes/NOTES.md rule
# 23). Sealed values are random (a fresh nonce each), so nothing printed
# depends on them.
SECRET = "s3cr3t"
KEY = Cybertrain::Crypto.derive_key(SECRET, "cybertrain session")

# A downstream middleware that writes into the session SessionStore already
# loaded, standing in for a real controller action.
class SessionWriter < Cybertrain::Middleware
  def call(ctx)
    ctx.session["user"] = "alice"
    nil
  end
end

# A downstream middleware that only reads, proving an unchanged session
# leaves the response cookie-free.
class SessionReader < Cybertrain::Middleware
  attr_reader :seen

  def call(ctx)
    @seen = ctx.session["user"]
    nil
  end
end

# Writes more than a cookie can hold.
class SessionHoarder < Cybertrain::Middleware
  def call(ctx)
    ctx.session["blob"] = "x" * 5000
    nil
  end
end

test "the session cookie is encrypted and round-trips" do
  key = Cybertrain::Crypto.derive_key("s" * 64, "cybertrain session")
  s = Cybertrain::Session.new; s[:user_id] = 5
  value = Cybertrain::Session.dump(s, key)
  refute value.include?("user_id")
  refute Base64.urlsafe_decode64(value + "=" * ((4 - value.size % 4) % 4)).include?("user_id")
  assert_equal "5", Cybertrain::Session.load(value, key)[:user_id]
end

test "derive_key: 32 raw bytes, one per label and secret" do
  a = Cybertrain::Crypto.derive_key(SECRET, "cybertrain session")
  assert_equal 32, a.bytesize
  assert_equal a, Cybertrain::Crypto.derive_key(SECRET, "cybertrain session")
  refute a == Cybertrain::Crypto.derive_key(SECRET, "cybertrain signed cookie")
  refute a == Cybertrain::Crypto.derive_key(SECRET, "cybertrain encrypted cookie")
  refute a == Cybertrain::Crypto.derive_key("other", "cybertrain session")
  assert_equal Cybertrain::Crypto.hmac_hex(SECRET, "cybertrain key\0cybertrain session"), Cybertrain::Crypto.hex(a)
  refute Cybertrain::Crypto.hmac_hex(SECRET, "cybertrain session") == Cybertrain::Crypto.hex(a)
end

test "round trip dump/load" do
  session = Cybertrain::Session.new
  session["user_id"] = "42"
  session["role"] = "admin"

  cookie_value = Cybertrain::Session.dump(session, KEY)
  loaded = Cybertrain::Session.load(cookie_value, KEY)

  assert_equal "42", loaded["user_id"]
  assert_equal "admin", loaded["role"]
  assert_equal({ "user_id" => "42", "role" => "admin" }, loaded.to_h)
end

test "two dumps of one session differ (a fresh nonce each)" do
  session = Cybertrain::Session.new({ "user_id" => "42" })
  refute Cybertrain::Session.dump(session, KEY) == Cybertrain::Session.dump(session, KEY)
end

test "foreign and damaged session cookies load empty" do
  session = Cybertrain::Session.new({ "user_id" => "42" })
  value = Cybertrain::Session.dump(session, KEY)
  # One flipped character: in the nonce, in the middle and in the tag (the
  # one before the last: the last may carry only padding bits).
  [1, value.size / 2, value.size - 2].each do |at|
    flipped = value[0, at] + (value[at] == "A" ? "B" : "A") + value[at + 1, value.size - at - 1]
    assert_equal [], Cybertrain::Session.load(flipped, KEY).keys
  end
  # Truncated to 20 bytes, and one byte short.
  assert_equal [], Cybertrain::Session.load(value[0, 20], KEY).keys
  assert_equal [], Cybertrain::Session.load(value[0, value.size - 1], KEY).keys
  # A 0.4 signed cookie: "<b64 JSON>--<64 hex HMAC>" under the raw secret.
  payload = Base64.urlsafe_encode64(JSON.generate({ "user_id" => "42" }), padding: false)
  old = "#{payload}--#{Cybertrain::Crypto.hmac_hex(SECRET, payload)}"
  assert_equal [], Cybertrain::Session.load(old, KEY).keys
  # A value from cookies.encrypted[:x], copied into the session's cookie.
  res = Cybertrain::Response.new
  jar = Cybertrain::CookieJar.new(Cybertrain::Cookies.parse(""), res,
                                  signed_key: Cybertrain::Crypto.derive_key(SECRET, "cybertrain signed cookie"),
                                  encrypted_key: Cybertrain::Crypto.derive_key(SECRET, "cybertrain encrypted cookie"))
  jar.encrypted[:x] = JSON.generate({ "user_id" => "42" })
  copied = Cybertrain::Cookies.parse(res.cookies[0])["x"].to_s
  assert_equal JSON.generate({ "user_id" => "42" }), jar.encrypted[:x]
  assert_equal [], Cybertrain::Session.load(copied, KEY).keys
  # The same plaintext sealed with the session's additional data but under
  # the encrypted-cookie key: another key, so it fails too.
  other = Cybertrain::Encryptor.new(Cybertrain::Crypto.derive_key(SECRET, "cybertrain encrypted cookie"))
  moved = Base64.urlsafe_encode64(other.seal_bytes(JSON.generate({ "user_id" => "42" }), "session"), padding: false)
  assert_equal [], Cybertrain::Session.load(moved, KEY).keys
  # Sealed under the session key but with another purpose's additional data.
  mine = Cybertrain::Encryptor.new(KEY)
  wrong_aad = Base64.urlsafe_encode64(mine.seal_bytes(JSON.generate({ "user_id" => "42" }), "cookie:x"), padding: false)
  assert_equal [], Cybertrain::Session.load(wrong_aad, KEY).keys
  # A 5000-byte value (refused before decrypting), an authentic one over
  # 4096 bytes, and the right value under another secret.
  assert_equal [], Cybertrain::Session.load("A" * 5000, KEY).keys
  big_value = Cybertrain::Session.dump(Cybertrain::Session.new({ "blob" => "y" * 3100 }), KEY)
  assert big_value.bytesize > 4096
  assert_equal [], Cybertrain::Session.load(big_value, KEY).keys
  assert_equal [], Cybertrain::Session.load(value, Cybertrain::Crypto.derive_key("another", "cybertrain session")).keys
end

test "garbage loads empty" do
  assert Cybertrain::Session.load("not-a-valid-cookie-value", KEY).to_h.empty?
  assert Cybertrain::Session.load("", KEY).to_h.empty?
  assert Cybertrain::Session.load("--", KEY).to_h.empty?
  assert Cybertrain::Session.load("x" * 90, KEY).to_h.empty?
  assert Cybertrain::Session.load("%%%%", KEY).to_h.empty?
  assert Cybertrain::Session.load("caf\u00e9 \u65e5\u672c", KEY).to_h.empty?
end

test "an authentic payload that is not a JSON object loads empty" do
  enc = Cybertrain::Encryptor.new(KEY)
  ["not json!!", "[1,2]", "\"text\"", "", "{\"a\":"].each do |text|
    value = Base64.urlsafe_encode64(enc.seal_bytes(text, "session"), padding: false)
    assert Cybertrain::Session.load(value, KEY).to_h.empty?
  end
end

test "dump writes no base64 padding, so serialize has nothing to encode at any length" do
  value = ""
  while value.size < 6
    dumped = Cybertrain::Session.dump(Cybertrain::Session.new({ "v" => value }), KEY)
    assert Cybertrain::Query.plain?(dumped)
    assert_equal value, Cybertrain::Session.load(dumped, KEY)["v"]
    value += "x"
  end
end

test "a cookie written with base64 padding still loads" do
  enc = Cybertrain::Encryptor.new(KEY)
  padded_seen = 0
  value = ""
  while value.size < 3
    cookie = Base64.urlsafe_encode64(enc.seal_bytes(JSON.generate({ "v" => value }), "session"))
    padded_seen += 1 unless cookie.index("=").nil?
    assert_equal value, Cybertrain::Session.load(cookie, KEY)["v"]
    value += "x"
  end
  assert_equal 2, padded_seen
end

test "changed? starts false" do
  session = Cybertrain::Session.new
  refute session.changed?
end

test "changed? true after a new write" do
  session = Cybertrain::Session.new
  session["a"] = "1"
  assert session.changed?
end

test "changed? false when the same value is written again" do
  session = Cybertrain::Session.load(Cybertrain::Session.dump(Cybertrain::Session.new, KEY), KEY)
  session["a"] = "1"
  loaded = Cybertrain::Session.load(Cybertrain::Session.dump(session, KEY), KEY)
  refute loaded.changed?
  loaded["a"] = "1"
  refute loaded.changed?
  loaded["a"] = "2"
  assert loaded.changed?
end

test "changed? after delete" do
  session = Cybertrain::Session.new
  refute session.changed?
  session.delete("missing")
  refute session.changed?
  session["a"] = "1"
  session.delete("a")
  assert session.changed?
end

test "key?, keys and clear" do
  session = Cybertrain::Session.new
  session["a"] = "1"
  session["b"] = "2"
  assert session.key?("a")
  assert session.key?(:b)
  refute session.key?("c")
  assert_equal ["a", "b"], session.keys
  session.clear
  assert session.to_h.empty?
  assert session.changed?
end

test "SessionStore's Set-Cookie loads back to the value the chain wrote" do
  store = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET)
  req = Cybertrain::Request.new("GET", "/", {}, "")
  ctx = Cybertrain::Context.new(req)

  store.call(ctx)

  assert_equal 1, ctx.response.cookies.length
  set_cookie = ctx.response.cookies[0]
  assert_includes set_cookie, "HttpOnly"
  assert_includes set_cookie, "SameSite=Lax"
  assert_includes set_cookie, "Path=/"
  assert_includes set_cookie, "Max-Age=1209600"

  cookie_value = Cybertrain::Cookies.parse(set_cookie)["_cybertrain_session"]
  loaded = Cybertrain::Session.load(cookie_value, KEY)
  assert_equal({ "user" => "alice" }, loaded.to_h)
end

test "a request carrying that cookie sees the value" do
  writer_store = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET)
  req1 = Cybertrain::Request.new("GET", "/", {}, "")
  ctx1 = Cybertrain::Context.new(req1)
  writer_store.call(ctx1)

  # The exact value the first request's own Set-Cookie produced, not a
  # freshly dumped cookie -- proves the header the middleware actually wrote
  # is the one a follow-up request round-trips through.
  cookie_header = Cybertrain::Cookies.parse(ctx1.response.cookies[0])
  header_value = "_cybertrain_session=#{URI.encode_www_form_component(cookie_header["_cybertrain_session"])}"

  reader = SessionReader.new
  reader_store = Cybertrain::SessionStore.new(reader, secret: SECRET)
  req2 = Cybertrain::Request.new("GET", "/", { "cookie" => header_value }, "")
  ctx2 = Cybertrain::Context.new(req2)

  reader_store.call(ctx2)

  assert_equal "alice", reader.seen
end

class FlashWriter < Cybertrain::Middleware
  def call(ctx)
    ctx.flash[:notice] = "created"
    nil
  end
end

class FlashReader < Cybertrain::Middleware
  attr_reader :seen

  def call(ctx)
    value = ctx.flash[:notice]
    @seen = value.nil? ? "" : value
    nil
  end
end

def cookie_header_from(response, name = "_cybertrain_session")
  raw = Cybertrain::Cookies.parse(response.cookies[0])[name]
  "#{name}=#{URI.encode_www_form_component(raw)}"
end

test "flash round-trips through SessionStore: request 1 sets, request 2 sees, request 3 is empty" do
  store1 = Cybertrain::SessionStore.new(FlashWriter.new, secret: SECRET)
  req1 = Cybertrain::Request.new("GET", "/", {}, "")
  ctx1 = Cybertrain::Context.new(req1)
  store1.call(ctx1)
  assert_equal 1, ctx1.response.cookies.length
  cookie1 = cookie_header_from(ctx1.response)

  reader2 = FlashReader.new
  store2 = Cybertrain::SessionStore.new(reader2, secret: SECRET)
  req2 = Cybertrain::Request.new("GET", "/", { "cookie" => cookie1 }, "")
  ctx2 = Cybertrain::Context.new(req2)
  store2.call(ctx2)
  assert_equal "created", reader2.seen
  assert_equal 1, ctx2.response.cookies.length
  cookie2 = cookie_header_from(ctx2.response)

  reader3 = FlashReader.new
  store3 = Cybertrain::SessionStore.new(reader3, secret: SECRET)
  req3 = Cybertrain::Request.new("GET", "/", { "cookie" => cookie2 }, "")
  ctx3 = Cybertrain::Context.new(req3)
  store3.call(ctx3)
  assert_equal "", reader3.seen
end

test "the session cookie is Secure only when SessionStore is built with secure: true" do
  plain = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET)
  plain_ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  plain.call(plain_ctx)
  refute plain_ctx.response.cookies[0].include?("Secure")

  secure = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET, secure: true)
  secure_ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  secure.call(secure_ctx)
  assert secure_ctx.response.cookies[0].end_with?("; Secure")
end

test "SessionStore passes same_site and partitioned to its Set-Cookie" do
  store = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET, same_site: "None", partitioned: true)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  store.call(ctx)
  assert ctx.response.cookies[0].end_with?("; SameSite=None; Max-Age=1209600; Secure; Partitioned")
end

test "an unchanged session sets no cookie" do
  store = Cybertrain::SessionStore.new(SessionReader.new, secret: SECRET)
  req = Cybertrain::Request.new("GET", "/", {}, "")
  ctx = Cybertrain::Context.new(req)

  store.call(ctx)

  assert ctx.response.cookies.empty?
end

test "a session larger than a cookie is refused at write" do
  store = Cybertrain::SessionStore.new(SessionHoarder.new, secret: SECRET)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  message = assert_raises("CookieOverflow") { store.call(ctx) }
  # {"blob":"x"*5000} is 5011 bytes; sealed, 5039; in Base64, 6719; with
  # "_cybertrain_session=", 6739.
  assert_equal "session cookie is 6739 bytes, over the 4096 a browser keeps (store less in the session)", message
  assert ctx.response.cookies.empty?
end

test "SessionStore gives the context a cookie jar over the request's cookies" do
  store = Cybertrain::SessionStore.new(SessionReader.new, secret: SECRET)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", { "cookie" => "theme=dark" }, ""))
  store.call(ctx)
  assert_equal "dark", ctx.cookie_jar[:theme]
  assert_nil ctx.cookie_jar["missing"]
end

# ---- absolute lifetime (SessionStore absolute_max_age) ---------------------

LIFE_START = 1_000_000
WEEK = 604_800

# Restarts the lifetime, as generated authentication does at sign-in.
class LifetimeRestarter < Cybertrain::Middleware
  def call(ctx)
    ctx.session.restart_lifetime!
    ctx.session["user"] = "bob"
    nil
  end
end

# Changes the session without touching its lifetime.
class LifetimeToucher < Cybertrain::Middleware
  def call(ctx)
    ctx.session["visits"] = "2"
    nil
  end
end

# A Cookie header carrying a session with these entries, sealed under KEY.
def lifetime_cookie(entries)
  value = Cybertrain::Session.dump(Cybertrain::Session.new(entries), KEY)
  "_cybertrain_session=#{URI.encode_www_form_component(value)}"
end

# The session the response's Set-Cookie holds.
def lifetime_written(ctx)
  raw = Cybertrain::Cookies.parse(ctx.response.cookies[0])["_cybertrain_session"]
  Cybertrain::Session.load(raw, KEY)
end

def lifetime_ctx(cookie)
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", { "cookie" => cookie }, ""))
end

test "Session#issued_at reads the recorded start, 0 for none or garbage" do
  assert_equal 0, Cybertrain::Session.new.issued_at
  assert_equal 42, Cybertrain::Session.new({ "_issued_at" => "42" }).issued_at
  assert_equal 0, Cybertrain::Session.new({ "_issued_at" => "" }).issued_at
  assert_equal 0, Cybertrain::Session.new({ "_issued_at" => "12x" }).issued_at
  assert_equal 0, Cybertrain::Session.new({ "_issued_at" => "-5" }).issued_at
  assert_equal 0, Cybertrain::Session.new({ "_issued_at" => "1" * 19 }).issued_at
end

test "absolute_max_age stamps the first write and caps the cookie's Max-Age" do
  stamping = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET, absolute_max_age: WEEK)
  stamping.fixed_now = LIFE_START
  stamp_ctx = lifetime_ctx("")
  stamping.call(stamp_ctx)
  assert_includes stamp_ctx.response.cookies[0], "Max-Age=604800"
  written = lifetime_written(stamp_ctx)
  assert_equal "alice", written["user"]
  assert_equal LIFE_START, written.issued_at
end

test "a cookie past the absolute lifetime loads empty however recently it was used" do
  aging = lifetime_cookie({ "user" => "alice", "_issued_at" => LIFE_START.to_s })
  inside = SessionReader.new
  inside_store = Cybertrain::SessionStore.new(inside, secret: SECRET, absolute_max_age: WEEK)
  inside_store.fixed_now = LIFE_START + WEEK - 1
  inside_ctx = lifetime_ctx(aging)
  inside_store.call(inside_ctx)
  assert_equal "alice", inside.seen
  assert inside_ctx.response.cookies.empty?

  past = SessionReader.new
  past_store = Cybertrain::SessionStore.new(past, secret: SECRET, absolute_max_age: WEEK)
  past_store.fixed_now = LIFE_START + WEEK
  past_store.call(lifetime_ctx(aging))
  assert_nil past.seen

  # A write six days in keeps the start and sends what is left (one day).
  late = Cybertrain::SessionStore.new(LifetimeToucher.new, secret: SECRET, absolute_max_age: WEEK)
  late.fixed_now = LIFE_START + 6 * 86_400
  late_ctx = lifetime_ctx(aging)
  late.call(late_ctx)
  assert_includes late_ctx.response.cookies[0], "Max-Age=86400"
  assert_equal LIFE_START, lifetime_written(late_ctx).issued_at
end

test "a cookie without a start gets one; restart_lifetime! starts the count again" do
  legacy = SessionReader.new
  legacy_store = Cybertrain::SessionStore.new(legacy, secret: SECRET, absolute_max_age: WEEK)
  legacy_store.fixed_now = LIFE_START
  legacy_ctx = lifetime_ctx(lifetime_cookie({ "user" => "alice" }))
  legacy_store.call(legacy_ctx)
  assert_equal "alice", legacy.seen
  assert_equal 1, legacy_ctx.response.cookies.length
  assert_equal LIFE_START, lifetime_written(legacy_ctx).issued_at

  restarting = Cybertrain::SessionStore.new(LifetimeRestarter.new, secret: SECRET, absolute_max_age: WEEK)
  restarting.fixed_now = LIFE_START + 5 * 86_400
  restart_ctx = lifetime_ctx(lifetime_cookie({ "user" => "alice", "_issued_at" => LIFE_START.to_s }))
  restarting.call(restart_ctx)
  restarted = lifetime_written(restart_ctx)
  assert_equal "bob", restarted["user"]
  assert_equal LIFE_START + 5 * 86_400, restarted.issued_at
  assert_includes restart_ctx.response.cookies[0], "Max-Age=604800"
end

test "absolute_max_age 0 (SessionStore's default) leaves the start alone" do
  ancient = SessionReader.new
  ancient_store = Cybertrain::SessionStore.new(ancient, secret: SECRET)
  ancient_ctx = lifetime_ctx(lifetime_cookie({ "user" => "alice", "_issued_at" => "1" }))
  ancient_store.call(ancient_ctx)
  assert_equal "alice", ancient.seen
  assert ancient_ctx.response.cookies.empty?
end

# ---- per-session lifetime and browser-session cookies (stamp_lifetime!) ----

DAY = 86_400
MONTH = 2_592_000 # 30 days, Config#auth_remember_for's default

# Signs in with "remember me" checked, in the order the generated
# start_new_session_for uses: restart_lifetime! first, then stamp_lifetime!.
class LifetimeRememberer < Cybertrain::Middleware
  def call(ctx)
    ctx.session.restart_lifetime!
    ctx.session.stamp_lifetime!(MONTH, true)
    ctx.session["user"] = "carol"
    nil
  end
end

# Signs in with "remember me" unchecked: a browser-session cookie, bounded
# by a week.
class LifetimeBrowser < Cybertrain::Middleware
  def call(ctx)
    ctx.session.restart_lifetime!
    ctx.session.stamp_lifetime!(WEEK, false)
    ctx.session["user"] = "dave"
    nil
  end
end

# The wrong order: the restart erases the stamp just written.
class LifetimeStampThenRestart < Cybertrain::Middleware
  def call(ctx)
    ctx.session.stamp_lifetime!(MONTH, true)
    ctx.session.restart_lifetime!
    ctx.session["user"] = "erin"
    nil
  end
end

# Stamps a lifetime without restarting it: the stamp counts from the start
# the cookie already records.
class LifetimeLateStamper < Cybertrain::Middleware
  def call(ctx)
    ctx.session.stamp_lifetime!(WEEK, true)
    nil
  end
end

# What a SessionReader sees for `cookie` under a store at `now`.
def lifetime_seen(cookie, now, absolute_max_age)
  reader = SessionReader.new
  store = Cybertrain::SessionStore.new(reader, secret: SECRET, absolute_max_age: absolute_max_age)
  store.fixed_now = now
  store.call(lifetime_ctx(cookie))
  reader.seen
end

# A session's entries as "k=v" pairs in key order, joined with ",".
def lifetime_pairs(session)
  keys = session.keys.sort
  out = []
  i = 0
  while i < keys.size
    out << "#{keys[i]}=#{session[keys[i]]}"
    i += 1
  end
  out.join(",")
end

test "lifetime_limit and browser_session? read the stamp; stamp_lifetime! writes it" do
  plain = Cybertrain::Session.new
  assert_equal 0, plain.lifetime_limit
  refute plain.browser_session?
  assert_equal 0, Cybertrain::Session.new({ "_lifetime" => "x1" }).lifetime_limit
  refute Cybertrain::Session.new({ "_browser" => "0" }).browser_session?

  remembered = Cybertrain::Session.new
  assert_nil remembered.stamp_lifetime!(MONTH, true)
  assert remembered.changed?
  assert_equal MONTH, remembered.lifetime_limit
  refute remembered.browser_session?
  assert_equal "_lifetime=2592000", lifetime_pairs(remembered)

  browser = Cybertrain::Session.new
  browser.stamp_lifetime!(WEEK, false)
  assert_equal WEEK, browser.lifetime_limit
  assert browser.browser_session?
  assert_equal "_browser=1,_lifetime=604800", lifetime_pairs(browser)

  # A later persistent stamp drops the browser flag; 0 seconds drops the
  # lifetime (SessionStore's absolute_max_age applies again).
  browser.stamp_lifetime!(0, true)
  assert_equal 0, browser.lifetime_limit
  refute browser.browser_session?
  assert_equal "", lifetime_pairs(browser)
end

test "a stamped lifetime replaces the absolute limit" do
  # absolute_max_age is a week; the stamp says 30 days.
  stamping = Cybertrain::SessionStore.new(LifetimeRememberer.new, secret: SECRET, absolute_max_age: WEEK)
  stamping.fixed_now = LIFE_START
  stamp_ctx = lifetime_ctx("")
  stamping.call(stamp_ctx)
  written = lifetime_written(stamp_ctx)
  assert_equal LIFE_START, written.issued_at
  assert_equal MONTH, written.lifetime_limit
  cookie = cookie_header_from(stamp_ctx.response)

  assert_equal "carol", lifetime_seen(cookie, LIFE_START + 15 * DAY, WEEK)
  assert_equal "carol", lifetime_seen(cookie, LIFE_START + MONTH - 1, WEEK)
  assert_nil lifetime_seen(cookie, LIFE_START + MONTH, WEEK)
  assert_nil lifetime_seen(cookie, LIFE_START + 31 * DAY, WEEK)
  # The stamp also holds with absolute_max_age off.
  assert_equal "carol", lifetime_seen(cookie, LIFE_START + 15 * DAY, 0)
  assert_nil lifetime_seen(cookie, LIFE_START + 31 * DAY, 0)
end

test "an unstamped session keeps session_absolute_max_age" do
  aging = lifetime_cookie({ "user" => "alice", "_issued_at" => LIFE_START.to_s })
  assert_equal "alice", lifetime_seen(aging, LIFE_START + WEEK - 1, WEEK)
  assert_nil lifetime_seen(aging, LIFE_START + WEEK, WEEK)

  # The write keeps today's clamp: max_age (two weeks) under a 30-day
  # absolute limit.
  store = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET, absolute_max_age: MONTH)
  store.fixed_now = LIFE_START
  ctx = lifetime_ctx("")
  store.call(ctx)
  assert_includes ctx.response.cookies[0], "; Max-Age=1209600"
  written = lifetime_written(ctx)
  assert_equal 0, written.lifetime_limit
  assert_equal LIFE_START, written.issued_at
end

test "a browser session cookie has no Max-Age" do
  # absolute_max_age 0: the stamp alone gets _issued_at written.
  store = Cybertrain::SessionStore.new(LifetimeBrowser.new, secret: SECRET, absolute_max_age: 0)
  store.fixed_now = LIFE_START
  ctx = lifetime_ctx("")
  store.call(ctx)
  set_cookie = ctx.response.cookies[0]
  refute set_cookie.include?("Max-Age")
  refute set_cookie.include?("Expires")
  assert set_cookie.end_with?("; Path=/; HttpOnly; SameSite=Lax")
  written = lifetime_written(ctx)
  assert_equal "dave", written["user"]
  assert written.browser_session?
  assert_equal WEEK, written.lifetime_limit
  assert_equal LIFE_START, written.issued_at

  # A later write keeps it a browser-session cookie, and the week still ends it.
  cookie = cookie_header_from(ctx.response)
  later = Cybertrain::SessionStore.new(LifetimeToucher.new, secret: SECRET, absolute_max_age: 0)
  later.fixed_now = LIFE_START + 3 * DAY
  later_ctx = lifetime_ctx(cookie)
  later.call(later_ctx)
  refute later_ctx.response.cookies[0].include?("Max-Age")
  refute later_ctx.response.cookies[0].include?("Expires")
  assert_equal "2", lifetime_written(later_ctx)["visits"]
  assert_equal "dave", lifetime_seen(cookie, LIFE_START + WEEK - 1, 0)
  assert_nil lifetime_seen(cookie, LIFE_START + WEEK, 0)
end

test "a remembered cookie's Max-Age is the remaining lifetime" do
  # absolute_max_age 0 and the default two-week max_age: neither caps the stamp.
  store = Cybertrain::SessionStore.new(LifetimeRememberer.new, secret: SECRET, absolute_max_age: 0)
  store.fixed_now = LIFE_START
  ctx = lifetime_ctx("")
  store.call(ctx)
  assert_includes ctx.response.cookies[0], "; Max-Age=2592000"
  assert_equal LIFE_START, lifetime_written(ctx).issued_at

  later = Cybertrain::SessionStore.new(LifetimeToucher.new, secret: SECRET, absolute_max_age: 0)
  later.fixed_now = LIFE_START + 15 * DAY
  later_ctx = lifetime_ctx(cookie_header_from(ctx.response))
  later.call(later_ctx)
  assert_includes later_ctx.response.cookies[0], "; Max-Age=1296000"
  rewritten = lifetime_written(later_ctx)
  assert_equal LIFE_START, rewritten.issued_at
  assert_equal MONTH, rewritten.lifetime_limit
  assert_equal "carol", rewritten["user"]

  # A stamp shorter than the session's age, without a restart, counts from
  # the recorded start: the session is already over, so Max-Age=0 expires it.
  old = lifetime_cookie({ "user" => "alice", "_issued_at" => LIFE_START.to_s })
  late = Cybertrain::SessionStore.new(LifetimeLateStamper.new, secret: SECRET, absolute_max_age: 0)
  late.fixed_now = LIFE_START + 10 * DAY
  late_ctx = lifetime_ctx(old)
  late.call(late_ctx)
  assert late_ctx.response.cookies[0].end_with?("; SameSite=Lax; Max-Age=0")
end

test "restart_lifetime! clears the stamp" do
  stamped = Cybertrain::Session.new({ "user" => "alice", "_issued_at" => "42", "_lifetime" => "2592000",
                                      "_browser" => "1" })
  assert_nil stamped.restart_lifetime!
  assert stamped.changed?
  assert_equal 0, stamped.issued_at
  assert_equal 0, stamped.lifetime_limit
  refute stamped.browser_session?
  assert_equal "user=alice", lifetime_pairs(stamped)

  # Stamping first and restarting after loses the stamp: the cookie is an
  # unstamped one, under max_age and absolute_max_age.
  wrong = Cybertrain::SessionStore.new(LifetimeStampThenRestart.new, secret: SECRET, absolute_max_age: WEEK)
  wrong.fixed_now = LIFE_START
  wrong_ctx = lifetime_ctx("")
  wrong.call(wrong_ctx)
  assert_includes wrong_ctx.response.cookies[0], "; Max-Age=604800"
  assert_equal 0, lifetime_written(wrong_ctx).lifetime_limit

  # A restart on a remembered cookie returns it to the default limits.
  remembered = lifetime_cookie({ "user" => "carol", "_issued_at" => LIFE_START.to_s, "_lifetime" => MONTH.to_s })
  restarting = Cybertrain::SessionStore.new(LifetimeRestarter.new, secret: SECRET, absolute_max_age: WEEK)
  restarting.fixed_now = LIFE_START + 10 * DAY
  restart_ctx = lifetime_ctx(remembered)
  restarting.call(restart_ctx)
  assert_includes restart_ctx.response.cookies[0], "; Max-Age=604800"
  restarted = lifetime_written(restart_ctx)
  assert_equal 0, restarted.lifetime_limit
  assert_equal LIFE_START + 10 * DAY, restarted.issued_at
end

Cybertrain::Test.run!
