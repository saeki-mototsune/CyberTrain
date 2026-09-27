require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/middleware/session_store"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/router"

# End-to-end regression for the Task 7 review's two BLOCKERs: driving the
# real production stack order (SessionStore -> CsrfProtection -> Router,
# per docs/superpowers/plans/2026-09-24-cybertrain-mvp.md line 850) through
# Cybertrain::Test::Client the way a real form POST arrives, with the token
# minted through a route handler block (the shape the form helpers in
# cybertrain/template/helpers.rb mint it from: Helpers#csrf_token ->
# Session#csrf_token!, which token_for delegates to) rather than a
# hand-built Context.
#
# This also stands in as the "does the shape the framework actually
# produces compile" check the review asked for: a conditionally-included
# CsrfProtection (`csrf ? CsrfProtection.new(router) : router`, matching
# Application#stack's `CsrfProtection (if csrf)`) is exercised via
# test/csrf_conditional.rb.
SECRET = "chain-secret"

router = Cybertrain::Router.new
router.get("/token") { |ctx| ctx.response.body = Cybertrain::CsrfProtection.token_for(ctx.session) }
router.post("/comments") { |ctx| ctx.response.body = "created" }

stack = Cybertrain::CsrfProtection.new(router)
app = Cybertrain::SessionStore.new(stack, secret: SECRET)

test "mint on GET, round-trip the cookie, POST with the body token passes" do
  client = Cybertrain::Test::Client.new(app)

  minted = client.get("/token")
  token = minted.body
  refute token.empty?
  assert_equal 1, minted.cookies.length

  created = client.post("/comments", { "authenticity_token" => token })
  assert_response created, :ok
  assert_equal "created", created.body
end

test "POST without the body token is rejected even with a valid session cookie" do
  client = Cybertrain::Test::Client.new(app)
  client.get("/token")

  rejected = client.post("/comments", {})
  assert_response rejected, :forbidden
end

test "POST with the token via the header passes without a body param" do
  client = Cybertrain::Test::Client.new(app)
  token = client.get("/token").body

  rejected = client.request("POST", "/comments", "", { "x-csrf-token" => token })
  assert_response rejected, :ok
  assert_equal "created", rejected.body
end

Cybertrain::Test.run!
