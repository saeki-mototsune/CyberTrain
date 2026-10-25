# The built-in health check (Config#health_path, Cybertrain::HealthCheck,
# issue #76) through a booted Application and Cybertrain::Test::Client:
# 200 ok with no-store and no cookie, before a public/ file of the same
# name and before a login before_action; 503 "database unavailable" when
# the pool is closed or gone; 503 "worker stale" when the running
# Scheduler's last tick is old; off when health_path is "". Every
# middleware the program requires is exercised (spikes/NOTES.md rule 36).
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

ROOT = "tmp/health_test"

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

remove_tree(ROOT)
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT)
Dir.mkdir("#{ROOT}/public")
# A static file at the health path's name: the check answers first.
File.write("#{ROOT}/public/up", "static file\n")
at_exit { remove_tree(ROOT) }

ENV.delete("CYBERTRAIN_HEALTH_PATH")
ENV["CYBERTRAIN_ENV"] = "test"

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# What the login filter saw, read back by the tests (a constant: NOTES
# rule 64).
TRAIL = Array.new(0) { "" }

class ApplicationController < Cybertrain::Controller
  # The filter generated authentication puts here: everything redirects to
  # the sign-in page.
  before_action { |c| c.require_login }

  def require_login
    TRAIL << request.path
    redirect_to "/login"
  end
end

class PagesController < ApplicationController
  def index
    render plain: "home"
  end
end

def build_config(health_path)
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.public_root = "#{ROOT}/public"
  c.secret_key_base = "health-test-secret"
  c.log_level = :info
  c.health_path = health_path
  c
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/", "root") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }
# A route on the health path too: the check answers before the router.
ROUTER.get("/up", "up") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }

def build_app(config)
  Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args) { "/" }, config: config)
end

APP = build_app(build_config("/up"))
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

def stack_names(app)
  names = Array.new(0) { "" }
  node = app.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  names
end

def trail_text
  TRAIL.join(",")
end

test "the check sits inside RequestLogger and before Static" do
  assert_equal ["Cybertrain::RequestLogger", "Cybertrain::HealthCheck", "Cybertrain::Static", "Cybertrain::MethodOverride",
                "Cybertrain::SessionStore", "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(APP)
end

test "GET /up answers 200 ok, text/plain, no-store, without a cookie or the login filter" do
  res = CLIENT.get("/up")
  assert_equal 200, res.status
  assert_equal "ok", res.body
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type").to_s
  assert_equal "no-store", res.header("Cache-Control").to_s
  assert res.cookies.empty?
  assert_equal "", trail_text
end

test "the login filter does run for every other page" do
  res = CLIENT.get("/")
  assert_equal 302, res.status
  assert_equal "/login", res.header("Location").to_s
  assert_equal "/", trail_text
end

test "HEAD /up answers too; a query string does not matter; other paths and methods pass" do
  assert_equal 200, CLIENT.request("HEAD", "/up").status
  assert_equal "ok", CLIENT.get("/up?probe=1").body
  assert_equal 404, CLIENT.get("/up/more").status
  assert_equal 404, CLIENT.get("/upx").status
  assert_equal 403, CLIENT.post("/up").status
end

def lines_in(text)
  n = 0
  at = text.index("\n")
  until at.nil?
    n += 1
    at = text.index("\n", at + 1)
  end
  n
end

test "each poll is the normal two request log lines" do
  before = LOG.string.size
  CLIENT.get("/up")
  logged = LOG.string
  poll = logged[before, logged.size - before].to_s
  assert_includes poll, "Started GET \"/up\" for"
  assert_includes poll, "Completed 200 in"
  assert_equal 2, lines_in(poll)
end

test "503 database unavailable once the pool is closed or gone" do
  Cybertrain::DB.pool.close_all
  closed = CLIENT.get("/up")
  Cybertrain::DB.disconnect
  gone = CLIENT.get("/up")
  Cybertrain::DB.connect(":memory:", size: 1)
  back = CLIENT.get("/up")
  assert_equal 503, closed.status
  assert_equal "database unavailable", closed.body
  assert_equal "no-store", closed.header("Cache-Control").to_s
  assert_equal 503, gone.status
  assert_equal "database unavailable", gone.body
  assert_equal 200, back.status
end

test "health_path \"\" turns the check off: the rest of the stack answers /up" do
  off = build_app(build_config(""))
  assert_equal ["Cybertrain::RequestLogger", "Cybertrain::Static", "Cybertrain::MethodOverride",
                "Cybertrain::SessionStore", "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(off)
  res = Cybertrain::Test::Client.new(off).get("/up")
  assert_equal 200, res.status
  assert_equal "static file\n", res.body
end

test "another path, from CYBERTRAIN_HEALTH_PATH; an empty variable turns it off" do
  ENV["CYBERTRAIN_HEALTH_PATH"] = "/healthz"
  moved = Cybertrain::Config.new
  ENV["CYBERTRAIN_HEALTH_PATH"] = ""
  disabled = Cybertrain::Config.new
  ENV.delete("CYBERTRAIN_HEALTH_PATH")
  assert_equal "/healthz", moved.health_path
  assert_equal "", disabled.health_path
  assert_equal "/up", Cybertrain::Config.new.health_path
  assert_equal 300, moved.health_worker_stale
end

test "boot refuses a path without a leading slash and a stale limit below 1" do
  c = build_config("up")
  assert_includes c.health_error, "health_path must start with"
  c.health_path = ""
  assert_equal "", c.health_error
  c.health_path = "/up"
  assert_equal "", c.health_error
  c.health_worker_stale = 0
  assert_includes c.health_error, "health_worker_stale must be at least 1"
end

test "not stale while the scheduler is not running, whatever its last tick" do
  Cybertrain::Scheduler.run_due(1000)
  refute Cybertrain::Scheduler.running?
  assert_equal "ok", CLIENT.get("/up").body
end

# Last: the scheduler thread keeps running until the program exits (it
# sleeps a scheduler_interval of an hour between ticks).
test "503 worker stale when the running scheduler's last tick is older than health_worker_stale" do
  Cybertrain::Scheduler.every(3600, "health test task") { TRAIL << "task" }
  c = build_config("/up")
  c.scheduler_interval = 3600
  assert Cybertrain::Scheduler.start!(c)
  sleep 0.2 # the thread's first tick
  assert_equal "ok", CLIENT.get("/up").body
  now = Time.now.to_i
  Cybertrain::Scheduler.run_due(now - 301)
  stale = CLIENT.get("/up")
  assert_equal 503, stale.status
  assert_equal "worker stale", stale.body
  Cybertrain::Scheduler.run_due(now - 299)
  assert_equal "ok", CLIENT.get("/up").body
  Cybertrain::Scheduler.stop!
  Cybertrain::Scheduler.run_due(now - 1000)
  assert_equal "ok", CLIENT.get("/up").body
end

Cybertrain::Test.run!
