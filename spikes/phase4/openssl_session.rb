# Phase 4a spike, item 4 (spec section 12): the whole framework with
# Spinel's openssl package always linked (what Task 12 makes `require
# "cybertrain"` do), a session round trip through Application#call and
# Response#to_http (written by one request, read by the next from the
# Set-Cookie the first sent), and the C output searched for the
# NoMethodError switches rule 62 describes. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4/; SQLite and libssl
# through FFI, so compiled only):
#   spinel $(spin flags) openssl_session.rb -o /tmp/openssl_session && /tmp/openssl_session
#   spinel $(spin flags) openssl_session.rb -c -o /tmp/s.c
#   grep -c 'sp_raise_nomethod(sp_nomethod_msg("getbyte"' /tmp/s.c
#   grep -c 'sp_raise_nomethod(sp_nomethod_msg("each_byte"' /tmp/s.c
# Output (68 s to compile; the two greps over the 140,167-line C, which
# has 543 `sp_raise_nomethod(sp_nomethod_msg(` switches for other names,
# print 0 and 0):
#   first: HTTP/1.1 200 OK / wrote alice
#   cookie name: _cybertrain_session
#   second: HTTP/1.1 200 OK / read alice
#   without the cookie: read (none)
#   tampered cookie: read (none)
#   encryptor: true café
#   names: format=:json expect={"title" => "Hi"} printer="x"
#   names: format=:html expect={"title" => ""} printer="x"
#   Mailer.expect: nil
#   Printer.format: 42
#   hmac: 5031fe3d989c6d15
#
# The program also defines `format` answering a Symbol (Request#format,
# reopened here as Task 2 will write it) beside Console::Printer.format's
# String, and `expect` answering a Hash (Params#expect, as Task 4 will)
# beside Mailer.expect's nil: both pairs build and answer correctly. In
# the C, `params.expect(...)` and `request.format` (boxed receivers in an
# action) dispatch over the class receivers too (a switch that would raise
# ArgumentError for Mailer / Printer), never reached.
require "cybertrain"
require "cybertrain/encryptor"
require "cybertrain/application"
require "cybertrain/mailer"
require "cybertrain/console/printer"

# Two names the plan gives new homes (controller ruling 5): `format`
# answering a String (Console::Printer.format, today) beside a Symbol
# (Request#format, Task 2), and `expect` answering nil (Mailer.expect,
# today) beside a Hash (Params#expect, Task 4).
module Cybertrain
  class Request
    def format
      p = path.to_s
      return :json if p.end_with?(".json")

      :html
    end
  end

  class Params
    def expect(key)
      out = { "" => "" }
      out.delete("")
      child = nested(key)
      out["title"] = child[:title].to_s
      out
    end
  end
end

class FakeReply
  def reply_code = 250
  def reply_summary = "250 ok"
end

class FakeSession
  def session_label = "smtp"
end

class SessionsController < Cybertrain::Controller
  def write
    session["user"] = params[:name].to_s
    render plain: "wrote #{session["user"]}"
  end

  def read
    user = session["user"]
    render plain: "read #{user.nil? ? "(none)" : user}"
  end

  def names
    expected = params.expect(:article)
    render plain: "format=#{request.format.inspect} expect=#{expected.inspect} printer=#{Cybertrain::Console::Printer.format("x")}"
  end
end

module Gen
  module Routes
    def self.build(router)
      router.add("GET", "/write/:name", "") { |ctx| SessionsController.new(ctx).process(:write) { |c| c.write } }
      router.add("GET", "/read", "") { |ctx| SessionsController.new(ctx).process(:read) { |c| c.read } }
      router.add("GET", "/names.json", "") { |ctx| SessionsController.new(ctx).process(:names) { |c| c.names } }
      router.add("GET", "/names", "") { |ctx| SessionsController.new(ctx).process(:names) { |c| c.names } }
      router
    end

    def self.url_resolver
      ->(name, args) { "/#{name}" }
    end
  end
end

def spike_config
  c = Cybertrain::Config.new
  c.log_level = :none
  c.static_files = false
  c.csrf = false
  c.secret_key_base = "phase4-spike-secret-key-base"
  c
end

# One request through the whole stack; answers the response's wire form.
def round_trip(app, path, cookie)
  headers = { "host" => "localhost" }
  headers["cookie"] = cookie unless cookie.empty?
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", path, headers, ""))
  app.call(ctx)
  ctx.response.to_http
end

# "name=value" of the first Set-Cookie line of a wire response.
def first_cookie(http)
  http.each_line do |l|
    next unless l.downcase.start_with?("set-cookie: ")

    return l[12, l.length].to_s.split(";")[0].to_s
  end
  ""
end

def body_of(http)
  http.split("\r\n\r\n", 2)[1].to_s
end

app = Cybertrain::Application.new(router: Gen::Routes.build(Cybertrain::Router.new), url_resolver: Gen::Routes.url_resolver, config: spike_config)
first = round_trip(app, "/write/alice", "")
puts "first: #{first.lines[0].strip} / #{body_of(first)}"
cookie = first_cookie(first)
puts "cookie name: #{cookie.split("=")[0]}"
second = round_trip(app, "/read", cookie)
puts "second: #{second.lines[0].strip} / #{body_of(second)}"
third = round_trip(app, "/read", "")
puts "without the cookie: #{body_of(third)}"
tampered = "#{cookie}x"
puts "tampered cookie: #{body_of(round_trip(app, "/read", tampered))}"

enc = Cybertrain::Encryptor.new(Cybertrain::Encryptor.from_hex("00" * 32))
payload = enc.encrypt("café")
puts "encryptor: #{payload.start_with?("1:")} #{enc.decrypt(payload)}"
puts "names: #{body_of(round_trip(app, "/names.json?article[title]=Hi", ""))}"
puts "names: #{body_of(round_trip(app, "/names", ""))}"
puts "Mailer.expect: #{Cybertrain::Mailer.expect(FakeSession.new, FakeReply.new, 250, "MAIL").inspect}"
puts "Printer.format: #{Cybertrain::Console::Printer.format(42)}"
puts "hmac: #{OpenSSL::HMAC.hexdigest("SHA256", "key", "data")[0, 16]}"
