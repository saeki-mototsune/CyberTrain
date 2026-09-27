require "cybertrain/test"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/middleware/session_store"
require "cybertrain/router"

# Task 7 review, issue 3 (compile fragility): several program shapes the
# framework itself produces failed to compile under Spinel before this fix
# (CsrfProtection.token_for took a bare `session` parameter that widened to
# an untyped poly value across call sites -- see Session#csrf_token!).
# Documented here is which of those shapes now compile.
#
# COMPILES (covered below and by test/csrf_chain.rb):
#   - Requiring cybertrain/middleware/csrf_protection without ever calling
#     `CsrfProtection.new` anywhere in the program (was: fails at
#     csrf_protection.rb's `super` call).
#   - Application#stack's `CsrfProtection (if csrf)` -- a conditional
#     instantiation where the `false` branch is the one actually taken at
#     run time, so `CsrfProtection.new` is never *executed*, only present
#     as a reachable call site in the source.
#   - `CsrfProtection.token_for(ctx.session)` called from inside a Router
#     block, i.e. from a route handler (the shape the form helpers in
#     cybertrain/template/helpers.rb use) -- see test/csrf_chain.rb.
#   - The real production stack, SessionStore -> CsrfProtection -> Router,
#     built and called end to end -- see test/csrf_chain.rb.
#
# STILL DOES NOT COMPILE (a genuine Spinel whole-program type-inference gap,
# not something fixable from cybertrain code -- tracked, not worked around):
#   - `require "cybertrain/middleware/session_store"` in a program where
#     `SessionStore#call` is never reachable (SessionStore is never
#     instantiated, or is instantiated but its `#call` chain is never
#     invoked). The dead method body still gets type-checked with no
#     concrete Session usage to pin its types, and that miscompiles code in
#     cybertrain/params.rb that has nothing to do with sessions. Requiring
#     session_store.rb is safe exactly when the program also builds AND
#     calls a real SessionStore chain, which is always true of a real app
#     (Application#stack always instantiates and calls SessionStore) and of
#     every test here.
class Page < Cybertrain::Middleware
  def call(ctx)
    ctx.response.body = "page"
    nil
  end
end

# Mirrors Application#stack: `CsrfProtection (if csrf)`.
def build_stack(router, csrf)
  csrf ? Cybertrain::CsrfProtection.new(router) : router
end

test "CsrfProtection required but never instantiated still compiles and runs" do
  router = Cybertrain::Router.new
  router.get("/") { |ctx| ctx.response.body = "hi" }

  req = Cybertrain::Request.new("GET", "/", {}, "")
  ctx = Cybertrain::Context.new(req)
  router.call(ctx)

  assert_equal "hi", ctx.response.body
end

test "a stack built with csrf: false never touches CsrfProtection at run time" do
  router = Cybertrain::Router.new
  router.post("/") { |ctx| ctx.response.body = "posted" }

  stack = build_stack(router, false)
  app = Cybertrain::SessionStore.new(stack, secret: "s3cr3t")
  req = Cybertrain::Request.new("POST", "/", {}, "")
  ctx = Cybertrain::Context.new(req)
  app.call(ctx)

  assert_equal "posted", ctx.response.body
end

test "a stack built with csrf: true still enforces the token" do
  router = Cybertrain::Router.new
  router.post("/") { |ctx| ctx.response.body = "posted" }

  stack = build_stack(router, true)
  app = Cybertrain::SessionStore.new(stack, secret: "s3cr3t")
  req = Cybertrain::Request.new("POST", "/", {}, "")
  ctx = Cybertrain::Context.new(req)
  app.call(ctx)

  assert_equal 403, ctx.response.status
end

Cybertrain::Test.run!
