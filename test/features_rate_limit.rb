require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/rate_limit"
require "cybertrain/test"
require "cybertrain/test/client"

# The core and cybertrain/rate_limit alone (the optional-subsystems design,
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md, section
# 3), which loads the cache: it compiles without jobs, streams, feeds or
# the mailer; the cache and rate limiting are the registered features; a
# limited action refuses past its limit, counted in the cache (the
# default store) and in memory. Runs from a fresh temp directory. It links
# SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-features-rate-limit")
Dir.chdir(TMP)
Dir.mkdir("public")

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

class PagesController < Cybertrain::Controller
  rate_limit to: 2, within: 60, only: [:shared]
  rate_limit to: 1, within: 60, only: [:local], store: :memory, name: "local"

  def shared
    render plain: "shared"
  end

  def local
    render plain: "local"
  end
end

def build_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.public_root = "public"
  c.secret_key_base = "features-rate-limit-secret"
  c.log_level = :info
  c
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/shared", "shared") { |ctx| PagesController.new(ctx).process(:shared) { |c| c.shared } }
ROUTER.get("/local", "local") { |ctx| PagesController.new(ctx).process(:local) { |c| c.local } }

APP = Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" }, config: build_config)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

test "the cache and rate limiting are the registered features" do
  assert_equal "cache,rate_limit", Cybertrain::Features.feature_names.join(",")
end

test "the cache store lets two requests through, then answers 429" do
  assert_equal 200, CLIENT.get("/shared").status
  assert_equal 200, CLIENT.get("/shared").status
  res = CLIENT.get("/shared")
  assert_equal 429, res.status
  assert_equal "Too Many Requests", res.body
  refute res.header("Retry-After").nil?
end

test "the memory store lets one request through, then answers 429" do
  assert_equal 200, CLIENT.get("/local").status
  assert_equal 429, CLIENT.get("/local").status
end

Cybertrain::Test.run!
