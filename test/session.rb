require "cybertrain/test"
require "cybertrain/session"
require "cybertrain/crypto"
require "cybertrain/middleware/session_store"
require "cybertrain/http/request"
require "cybertrain/http/cookies"
require "cybertrain/context"
require "uri"

SECRET = "s3cr3t"

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

test "round trip dump/load" do
  session = Cybertrain::Session.new
  session["user_id"] = "42"
  session["role"] = "admin"

  cookie_value = Cybertrain::Session.dump(session, SECRET)
  loaded = Cybertrain::Session.load(cookie_value, SECRET)

  assert_equal "42", loaded["user_id"]
  assert_equal "admin", loaded["role"]
  assert_equal({ "user_id" => "42", "role" => "admin" }, loaded.to_h)
end

test "tampered signature loads empty" do
  session = Cybertrain::Session.new
  session["user_id"] = "42"
  cookie_value = Cybertrain::Session.dump(session, SECRET)
  tampered = cookie_value[0, cookie_value.length - 1] + "0"

  loaded = Cybertrain::Session.load(tampered, SECRET)
  assert loaded.to_h.empty?
end

test "wrong secret loads empty" do
  session = Cybertrain::Session.new
  session["user_id"] = "42"
  cookie_value = Cybertrain::Session.dump(session, SECRET)

  loaded = Cybertrain::Session.load(cookie_value, "different secret")
  assert loaded.to_h.empty?
end

test "garbage loads empty" do
  assert Cybertrain::Session.load("not-a-valid-cookie-value", SECRET).to_h.empty?
  assert Cybertrain::Session.load("", SECRET).to_h.empty?
  assert Cybertrain::Session.load("--", SECRET).to_h.empty?
  long_garbage = "x" * 90
  assert Cybertrain::Session.load(long_garbage, SECRET).to_h.empty?
end

test "tampered payload with recomputed signature over garbage JSON loads empty" do
  payload = "not valid base64 json!!"
  forged = "#{payload}--#{Cybertrain::Crypto.hmac_hex(SECRET, payload)}"
  assert Cybertrain::Session.load(forged, SECRET).to_h.empty?
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
  session = Cybertrain::Session.load(Cybertrain::Session.dump(Cybertrain::Session.new, SECRET), SECRET)
  session["a"] = "1"
  loaded = Cybertrain::Session.load(Cybertrain::Session.dump(session, SECRET), SECRET)
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
  loaded = Cybertrain::Session.load(cookie_value, SECRET)
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

Cybertrain::Test.run!
