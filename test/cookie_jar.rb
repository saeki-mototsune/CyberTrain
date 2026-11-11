require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/middleware/session_store"
require "cybertrain/cookie_jar"
require "cybertrain/test/client"
require "base64"

# Controller#cookies (spec section 5, C-7): plain, permanent, signed and
# encrypted cookies through SessionStore, a controller and Test::Client, as
# a browser would carry them from one request to the next. cybertrain/
# controller links SQLite through FFI and the jar's encrypted view needs
# libssl, so this program cannot run under CRuby: its snapshot comes from
# the compiled binary (spikes/NOTES.md rule 23). Encrypted values are
# random (a fresh nonce each), so nothing printed depends on them.
SECRET = "cookie-jar-secret"

class CookiesController < Cybertrain::Controller
  def write_plain
    cookies[:theme] = "dark"
    render plain: "theme=#{cookies[:theme]}"
  end

  def read_plain
    value = cookies[:theme]
    render plain: value.nil? ? "(none)" : value
  end

  def write_expiring
    cookies[:theme] = { value: "x", expires: Time.utc(2030, 1, 1), httponly: false }
    render plain: "ok"
  end

  def write_options
    cookies[:pref] = { value: "a b", max_age: 60, path: "/admin", secure: true, same_site: "Strict" }
    render plain: "ok"
  end

  def write_permanent
    cookies.permanent[:p] = "1"
    render plain: "ok"
  end

  def remove
    old = cookies.delete(:theme)
    render plain: old.nil? ? "(none)" : old
  end

  def write_signed
    cookies.signed[:uid] = "7"
    render plain: "ok"
  end

  def read_signed
    value = cookies.signed[:uid]
    render plain: value.nil? ? "(none)" : value
  end

  def write_encrypted
    cookies.encrypted[:card] = "4242"
    render plain: "ok"
  end

  def read_encrypted
    value = cookies.encrypted[:card]
    render plain: value.nil? ? "(none)" : value
  end

  # The encrypted value of :card, copied as it is into :other.
  def copy_encrypted
    raw = cookies[:card]
    cookies[:other] = raw.nil? ? "" : raw
    render plain: "ok"
  end

  def read_other
    value = cookies.encrypted[:other]
    render plain: value.nil? ? "(none)" : value
  end

  # The signed value of :uid, copied as it is into :other.
  def copy_signed
    raw = cookies[:uid]
    cookies[:other] = raw.nil? ? "" : raw
    render plain: "ok"
  end

  def read_other_signed
    value = cookies.signed[:other]
    render plain: value.nil? ? "(none)" : value
  end

  def bad_name
    cookies["x; Domain=evil.example"] = "v"
    render plain: "ok"
  end

  def bad_delete
    cookies.delete("a=b")
    render plain: "ok"
  end

  # "big=" and 4092 bytes is 4096: written. `?extra=1` is one byte over.
  def big_plain
    cookies[:big] = ("x" * 4092) + params[:extra].to_s
    render plain: "ok"
  end

  # `n` e-acutes: two bytes each, six ("%C3%A9") as sent.
  def big_multibyte
    cookies[:big] = "\u00e9" * params[:n].to_i
    render plain: "ok"
  end

  def big_encrypted
    cookies.encrypted[:big] = "x" * 3100
    render plain: "ok"
  end

  def write_twice
    cookies[:theme] = "a"
    cookies[:theme] = "b"
    render plain: "ok"
  end

  def write_permanent_views
    cookies.permanent.signed[:ps] = "s"
    cookies.permanent.encrypted[:pe] = "e"
    render plain: "ok"
  end

  def read_permanent_views
    render plain: "#{cookies.signed[:ps]} #{cookies.encrypted[:pe]}"
  end

  def remove_views
    cookies.signed.delete(:uid)
    cookies.encrypted.delete(:card, path: "/")
    cookies.permanent.delete(:p)
    render plain: "ok"
  end
end

def build_router
  router = Cybertrain::Router.new
  router.add("GET", "/write_plain", "") { |ctx| CookiesController.new(ctx).process(:write_plain) { |c| c.write_plain } }
  router.add("GET", "/read_plain", "") { |ctx| CookiesController.new(ctx).process(:read_plain) { |c| c.read_plain } }
  router.add("GET", "/write_expiring", "") { |ctx| CookiesController.new(ctx).process(:write_expiring) { |c| c.write_expiring } }
  router.add("GET", "/write_options", "") { |ctx| CookiesController.new(ctx).process(:write_options) { |c| c.write_options } }
  router.add("GET", "/write_permanent", "") { |ctx| CookiesController.new(ctx).process(:write_permanent) { |c| c.write_permanent } }
  router.add("GET", "/remove", "") { |ctx| CookiesController.new(ctx).process(:remove) { |c| c.remove } }
  router.add("GET", "/write_signed", "") { |ctx| CookiesController.new(ctx).process(:write_signed) { |c| c.write_signed } }
  router.add("GET", "/read_signed", "") { |ctx| CookiesController.new(ctx).process(:read_signed) { |c| c.read_signed } }
  router.add("GET", "/write_encrypted", "") { |ctx| CookiesController.new(ctx).process(:write_encrypted) { |c| c.write_encrypted } }
  router.add("GET", "/read_encrypted", "") { |ctx| CookiesController.new(ctx).process(:read_encrypted) { |c| c.read_encrypted } }
  router.add("GET", "/copy_encrypted", "") { |ctx| CookiesController.new(ctx).process(:copy_encrypted) { |c| c.copy_encrypted } }
  router.add("GET", "/read_other", "") { |ctx| CookiesController.new(ctx).process(:read_other) { |c| c.read_other } }
  router.add("GET", "/copy_signed", "") { |ctx| CookiesController.new(ctx).process(:copy_signed) { |c| c.copy_signed } }
  router.add("GET", "/read_other_signed", "") { |ctx| CookiesController.new(ctx).process(:read_other_signed) { |c| c.read_other_signed } }
  router.add("GET", "/bad_name", "") { |ctx| CookiesController.new(ctx).process(:bad_name) { |c| c.bad_name } }
  router.add("GET", "/big_plain", "") { |ctx| CookiesController.new(ctx).process(:big_plain) { |c| c.big_plain } }
  router.add("GET", "/big_multibyte", "") { |ctx| CookiesController.new(ctx).process(:big_multibyte) { |c| c.big_multibyte } }
  router.add("GET", "/big_encrypted", "") { |ctx| CookiesController.new(ctx).process(:big_encrypted) { |c| c.big_encrypted } }
  router.add("GET", "/bad_delete", "") { |ctx| CookiesController.new(ctx).process(:bad_delete) { |c| c.bad_delete } }
  router.add("GET", "/write_twice", "") { |ctx| CookiesController.new(ctx).process(:write_twice) { |c| c.write_twice } }
  router.add("GET", "/write_permanent_views", "") { |ctx| CookiesController.new(ctx).process(:write_permanent_views) { |c| c.write_permanent_views } }
  router.add("GET", "/read_permanent_views", "") { |ctx| CookiesController.new(ctx).process(:read_permanent_views) { |c| c.read_permanent_views } }
  router.add("GET", "/remove_views", "") { |ctx| CookiesController.new(ctx).process(:remove_views) { |c| c.remove_views } }
  router
end

APP = Cybertrain::SessionStore.new(build_router, secret: SECRET)
SECURE_APP = Cybertrain::SessionStore.new(build_router, secret: SECRET, secure: true)
# No SessionStore: the jar is built over the request's Cookie header.
BARE_APP = build_router

# The response's Set-Cookie values for `name`.
def set_cookies_for(response, name)
  out = []
  response.cookies.each { |c| out << c if c.start_with?("#{name}=") }
  out
end

test "plain, permanent, signed and encrypted cookies" do
  client = Cybertrain::Test::Client.new(APP)

  res = client.get("/write_plain")
  assert_equal "theme=dark", res.body
  assert_equal ["theme=dark; Path=/; HttpOnly; SameSite=Lax"], set_cookies_for(res, "theme")
  assert_equal "dark", client.get("/read_plain").body

  res = client.get("/write_expiring")
  assert_equal ["theme=x; Path=/; SameSite=Lax; Expires=Tue, 01 Jan 2030 00:00:00 GMT"], set_cookies_for(res, "theme")

  res = client.get("/write_permanent")
  assert_equal ["p=1; Path=/; HttpOnly; SameSite=Lax; Max-Age=631139040"], set_cookies_for(res, "p")

  res = client.get("/remove")
  assert_equal "x", res.body
  assert_equal ["theme=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"], set_cookies_for(res, "theme")
  assert_equal "(none)", client.get("/read_plain").body

  res = client.get("/write_signed")
  signed = set_cookies_for(res, "uid")[0].to_s
  value = signed.split(";")[0].to_s[4, signed.size].to_s
  assert_equal "7", client.get("/read_signed").body
  sep = value.size - 66
  assert_equal "--", value[sep, 2]
  assert_equal "7", Base64.urlsafe_decode64(value[0, sep].to_s + "=" * ((4 - sep % 4) % 4))
  tampered = value[0, value.size - 1] + (value[value.size - 1] == "0" ? "1" : "0")
  client.cookies["uid"] = tampered
  assert_equal "(none)", client.get("/read_signed").body
  # A signed value moved to another payload: its own HMAC no longer fits.
  client.cookies["uid"] = "OA--" + value[sep + 2, 64].to_s
  assert_equal "(none)", client.get("/read_signed").body
  client.cookies["uid"] = "garbage"
  assert_equal "(none)", client.get("/read_signed").body

  res = client.get("/write_encrypted")
  card = set_cookies_for(res, "card")[0].to_s
  refute card.include?("4242")
  assert card.end_with?("; Path=/; HttpOnly; SameSite=Lax")
  assert_equal "4242", client.get("/read_encrypted").body

  # An encrypted value copied to another cookie name reads nil.
  client.get("/copy_encrypted")
  assert_equal client.cookies["card"], client.cookies["other"]
  assert_equal "(none)", client.get("/read_other").body
  # A signed value copied to another cookie name reads nil (the name is in the HMAC).
  client.get("/write_signed")
  assert_equal "7", client.get("/read_signed").body
  client.get("/copy_signed")
  assert_equal client.cookies["uid"], client.cookies["other"]
  assert_equal "(none)", client.get("/read_other_signed").body
  # A damaged one reads nil too.
  raw = client.cookies["card"].to_s
  client.cookies["card"] = raw[0, 10] + (raw[10] == "A" ? "B" : "A") + raw[11, raw.size - 11].to_s
  assert_equal "(none)", client.get("/read_encrypted").body
  client.cookies["card"] = "x"
  assert_equal "(none)", client.get("/read_encrypted").body

  # Two writes of one name leave one Set-Cookie.
  res = client.get("/write_twice")
  assert_equal ["theme=b; Path=/; HttpOnly; SameSite=Lax"], set_cookies_for(res, "theme")
end

test "options: max_age, path, secure and same_site; values are percent-encoded" do
  client = Cybertrain::Test::Client.new(APP)
  res = client.get("/write_options")
  assert_equal ["pref=a+b; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=60; Secure"], set_cookies_for(res, "pref")
end

test "permanent.signed and permanent.encrypted last 20 years and read back" do
  client = Cybertrain::Test::Client.new(APP)
  res = client.get("/write_permanent_views")
  assert set_cookies_for(res, "ps")[0].to_s.end_with?("; Max-Age=631139040")
  assert set_cookies_for(res, "pe")[0].to_s.end_with?("; Max-Age=631139040")
  assert_equal "s e", client.get("/read_permanent_views").body
end

test "the views delete too" do
  client = Cybertrain::Test::Client.new(APP)
  client.get("/write_signed")
  client.get("/write_encrypted")
  client.get("/write_permanent")
  res = client.get("/remove_views")
  assert_equal ["uid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"], set_cookies_for(res, "uid")
  assert_equal ["card=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"], set_cookies_for(res, "card")
  assert_equal ["p=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"], set_cookies_for(res, "p")
  assert_equal "(none)", client.get("/read_signed").body
  assert_equal "(none)", client.get("/read_encrypted").body
end

test "Secure by default where the session cookie is (Config#session_secure)" do
  client = Cybertrain::Test::Client.new(SECURE_APP)
  res = client.get("/write_plain")
  assert_equal ["theme=dark; Path=/; HttpOnly; SameSite=Lax; Secure"], set_cookies_for(res, "theme")
  res = client.get("/write_expiring")
  assert_equal ["theme=x; Path=/; SameSite=Lax; Expires=Tue, 01 Jan 2030 00:00:00 GMT; Secure"], set_cookies_for(res, "theme")
end

test "without SessionStore: plain cookies work, signed and encrypted refuse" do
  client = Cybertrain::Test::Client.new(BARE_APP)
  res = client.get("/write_plain")
  assert_equal ["theme=dark; Path=/; HttpOnly; SameSite=Lax"], set_cookies_for(res, "theme")
  assert_equal "dark", client.get("/read_plain").body
  message = assert_raises("ArgumentError") { client.get("/write_signed") }
  assert_equal "cookies.signed and cookies.encrypted need SessionStore in the stack (it holds the keys derived from secret_key_base)", message
end

test "the jar refuses a cookie name that is not a token, on write and on delete" do
  client = Cybertrain::Test::Client.new(APP)
  assert_raises("ArgumentError") { client.get("/bad_name") }
  assert_raises("ArgumentError") { client.get("/bad_delete") }
end

test "without SessionStore the jar defaults Secure from Cybertrain.config.session_secure" do
  saved = Cybertrain.config.session_secure
  begin
    Cybertrain.config.session_secure = true
    res = Cybertrain::Test::Client.new(BARE_APP).get("/write_plain")
    assert_equal ["theme=dark; Path=/; HttpOnly; SameSite=Lax; Secure"], set_cookies_for(res, "theme")
  ensure
    # restored even when the request or the assertion raises
    Cybertrain.config.session_secure = saved
  end
end

test "a cookie over 4096 bytes raises CookieOverflow instead of being dropped by the browser" do
  client = Cybertrain::Test::Client.new(APP)
  res = client.get("/big_plain")
  assert_equal 200, res.status
  assert_equal 1, set_cookies_for(res, "big").size
  msg = assert_raises("CookieOverflow") { Cybertrain::Test::Client.new(APP).get("/big_plain?extra=1") }
  assert_equal "cookie big is 4097 bytes, over the 4096 a browser keeps", msg
  # the size counted is the percent-encoded value's: 1500 e-acutes are 3000
  # bytes, but 9000 as sent; 682 are 4092 as sent, and 683 one over
  msg = assert_raises("CookieOverflow") { Cybertrain::Test::Client.new(APP).get("/big_multibyte?n=1500") }
  assert_equal "cookie big is 9004 bytes, over the 4096 a browser keeps", msg
  res = Cybertrain::Test::Client.new(APP).get("/big_multibyte?n=682")
  assert_equal 200, res.status
  assert_equal 1, set_cookies_for(res, "big").size
  msg = assert_raises("CookieOverflow") { Cybertrain::Test::Client.new(APP).get("/big_multibyte?n=683") }
  assert_equal "cookie big is 4102 bytes, over the 4096 a browser keeps", msg
  # the size counted is the sealed value's: 3100 bytes seal and encode past 4096
  msg = assert_raises("CookieOverflow") { Cybertrain::Test::Client.new(APP).get("/big_encrypted") }
  assert_includes msg, "cookie big is 4"
end

test "Cookies.serialize writes Expires for a Time" do
  set_cookie = Cybertrain::Cookies.serialize("a", "b", expires: Time.utc(1994, 11, 6, 8, 49, 37))
  assert_equal "a=b; Path=/; HttpOnly; SameSite=Lax; Expires=Sun, 06 Nov 1994 08:49:37 GMT", set_cookie
end

test "Response#replace_cookie keeps one Set-Cookie per name" do
  res = Cybertrain::Response.new
  res.add_cookie("a=1; Path=/")
  res.add_cookie("ab=2; Path=/")
  assert_nil res.replace_cookie("a", "a=3; Path=/")
  assert_equal ["ab=2; Path=/", "a=3; Path=/"], res.cookies
end

Cybertrain::Test.run!
