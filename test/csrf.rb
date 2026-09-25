require "cybertrain/test"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/http/request"
require "cybertrain/context"
require "cybertrain/session"

FORM_TYPE = "application/x-www-form-urlencoded"

# A terminal middleware that records whether it was reached, standing in for
# the router at the end of a real chain.
class RecordingApp < Cybertrain::Middleware
  attr_reader :called

  def initialize
    super(nil)
    @called = false
  end

  def call(ctx)
    @called = true
    ctx.response.body = "inner"
    nil
  end
end

# A GET/HEAD/OPTIONS request, or any other method with an empty body and no
# form params. ctx.params is deliberately left as the empty Params.new that
# Context#initialize gives it: in the real stack (MethodOverride ->
# SessionStore -> CsrfProtection -> Router) the Router is the ONLY thing that
# ever fills ctx.params, and it runs after CsrfProtection, so CsrfProtection
# must never rely on ctx.params being populated.
def build_ctx(method)
  req = Cybertrain::Request.new(method, "/posts", {}, "")
  ctx = Cybertrain::Context.new(req)
  ctx.session = Cybertrain::Session.new
  ctx
end

# A POST whose authenticity token (if any) rides in the urlencoded body, the
# way a real HTML form submits it -- not pre-filled into ctx.params.
def build_form_post(body)
  req = Cybertrain::Request.new("POST", "/posts", { "content-type" => FORM_TYPE }, body)
  ctx = Cybertrain::Context.new(req)
  ctx.session = Cybertrain::Session.new
  ctx
end

test "a GET always passes, even without a token" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  ctx = build_ctx("GET")

  csrf.call(ctx)

  assert inner.called
  refute ctx.response.performed?
end

test "a POST without a token is rejected" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  ctx = build_ctx("POST")
  Cybertrain::CsrfProtection.token_for(ctx.session)

  csrf.call(ctx)

  refute inner.called
  assert_equal 403, ctx.response.status
  assert_equal "Invalid authenticity token", ctx.response.body
  assert ctx.response.performed?
end

# Regression for the BLOCKER: CsrfProtection sits before the Router in the
# stack, so the token must be read straight out of the form body (the way
# MethodOverride reads `_method`), never out of ctx.params.
test "a POST with the right token in the urlencoded body passes" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  session = Cybertrain::Session.new
  token = Cybertrain::CsrfProtection.token_for(session)
  ctx = build_form_post("#{Cybertrain::CsrfProtection::PARAM}=#{token}")
  ctx.session = session

  csrf.call(ctx)

  assert inner.called
  refute ctx.response.performed?
end

test "a POST with the right token in the query string passes" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  session = Cybertrain::Session.new
  token = Cybertrain::CsrfProtection.token_for(session)
  req = Cybertrain::Request.new("POST", "/posts?#{Cybertrain::CsrfProtection::PARAM}=#{token}", {}, "")
  ctx = Cybertrain::Context.new(req)
  ctx.session = session

  csrf.call(ctx)

  assert inner.called
  refute ctx.response.performed?
end

test "a POST with the right token via the header passes" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  req = Cybertrain::Request.new("POST", "/posts", {}, "")
  ctx = Cybertrain::Context.new(req)
  ctx.session = Cybertrain::Session.new
  token = Cybertrain::CsrfProtection.token_for(ctx.session)
  req.headers[Cybertrain::CsrfProtection::HEADER] = token

  csrf.call(ctx)

  assert inner.called
  refute ctx.response.performed?
end

test "a POST with the wrong token in the body is rejected" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  session = Cybertrain::Session.new
  Cybertrain::CsrfProtection.token_for(session)
  ctx = build_form_post("#{Cybertrain::CsrfProtection::PARAM}=wrong-token")
  ctx.session = session

  csrf.call(ctx)

  refute inner.called
  assert_equal 403, ctx.response.status
end

# An empty session token (not yet minted, or explicitly cleared) must never
# be satisfied by an equally empty provided token.
test "an empty session token is treated as missing" do
  inner = RecordingApp.new
  csrf = Cybertrain::CsrfProtection.new(inner)
  ctx = build_form_post("")
  ctx.session[Cybertrain::CsrfProtection::TOKEN_KEY] = ""

  csrf.call(ctx)

  refute inner.called
  assert_equal 403, ctx.response.status
end

test "token_for mints a token once and reuses it" do
  session = Cybertrain::Session.new
  t1 = Cybertrain::CsrfProtection.token_for(session)
  t2 = Cybertrain::CsrfProtection.token_for(session)
  assert_equal t1, t2
  refute t1.empty?
end

test "token_for marks the session changed and stores the token under TOKEN_KEY" do
  session = Cybertrain::Session.new
  refute session.changed?
  token = Cybertrain::CsrfProtection.token_for(session)
  assert session.changed?
  assert_equal token, session[Cybertrain::CsrfProtection::TOKEN_KEY]
end

Cybertrain::Test.run!
