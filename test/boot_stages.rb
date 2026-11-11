# Application#boot's three stages and what a failure in each leaves behind
# (docs/design.md D66): a boot that fails after validation releases the
# database pool it connected (and only that one), is not booted, leaves
# the process-shared settings at their defaults, and can be retried; a
# role whose start fails halfway stops what it had started.
#
# Application#boot connects SQLite through FFI, so this runs compiled only
# (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"

PRISTINE = Cybertrain::Runtime.describe

def stage_config(env)
  c = Cybertrain::Config.new
  c.env = env
  c.database_path = ":memory:"
  c.secret_key_base = "boot-stages-secret"
  c.views_root = "tmp/boot_stages/views"
  c.public_root = "tmp/boot_stages/public"
  c.max_page = 77
  c
end

def stage_views(page)
  table = { "" => "" }
  table.delete("")
  table["pages/index.html.erb"] = page
  table
end

def stage_app(config, views)
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" },
                              views: views, config: config)
end

GOOD = "<h1>ok</h1>\n"
BROKEN = "<% if true %>\n<p>never closed</p>\n"

test "stage 2: a database that cannot be opened leaves nothing behind, and the retry boots" do
  Cybertrain::Runtime.reset!
  c = stage_config("test")
  c.database_path = "tmp/boot_stages/no/such/dir/app.sqlite3"
  app = stage_app(c, stage_views(GOOD))
  assert_raises("Cybertrain::DB::Error") { app.boot }
  refute app.booted?
  refute Cybertrain::DB.connected?
  assert_equal PRISTINE, Cybertrain::Runtime.describe

  c.database_path = ":memory:"
  app.boot
  assert app.booted?
  assert Cybertrain::DB.connected?
  assert_equal 77, Cybertrain::Params.max_page
  app.shutdown
  refute Cybertrain::DB.connected?
end

test "stage 3: an embedded template that does not parse closes the pool this boot connected and resets the settings" do
  Cybertrain::Runtime.reset!
  app = stage_app(stage_config("production"), stage_views(BROKEN))
  error = assert_raises("Cybertrain::Template::SyntaxError") { app.boot }
  assert_includes error, "pages/index.html.erb"
  refute app.booted?
  refute Cybertrain::DB.connected?
  assert_equal PRISTINE, Cybertrain::Runtime.describe

  fixed = stage_app(stage_config("production"), stage_views(GOOD))
  fixed.boot
  assert fixed.booted?
  assert_equal 77, Cybertrain::Params.max_page
  fixed.shutdown
end

test "a failed boot never closes a pool the caller connected" do
  Cybertrain::Runtime.reset!
  Cybertrain::DB.connect(":memory:", size: 1)
  mine = Cybertrain::DB.generation
  app = stage_app(stage_config("production"), stage_views(BROKEN))
  assert_raises("Cybertrain::Template::SyntaxError") { app.boot }
  refute app.booted?
  assert Cybertrain::DB.connected?
  assert_equal mine, Cybertrain::DB.generation
  app.shutdown
  assert Cybertrain::DB.connected?
  Cybertrain::DB.disconnect
end

test "a failed boot after a good one leaves the first Application's pool, and defaults for the settings" do
  Cybertrain::Runtime.reset!
  first = stage_app(stage_config("test"), stage_views(GOOD))
  first.boot
  generation = Cybertrain::DB.generation
  second = stage_app(stage_config("production"), stage_views(BROKEN))
  assert_raises("Cybertrain::Template::SyntaxError") { second.boot }
  assert Cybertrain::DB.connected?
  assert_equal generation, Cybertrain::DB.generation
  assert first.booted?
  assert_equal PRISTINE, Cybertrain::Runtime.describe
  first.boot # puts the first Application's settings back
  assert_equal 77, Cybertrain::Params.max_page
  first.shutdown
  refute Cybertrain::DB.connected?
end

# ---- a role's partial start ------------------------------------------------

$stage_events = Array.new(0) { "" }

class StartingFeed < Cybertrain::Background::Service
  def service_name = "starting"
  def service_feed_names = ["alpha"]

  def service_start_only(config, names)
    $stage_events << "alpha started"
    true
  end

  def service_stop
    $stage_events << "alpha stopped"
    nil
  end
end

class FailingFeed < Cybertrain::Background::Service
  def service_name = "failing"
  def service_feed_names = ["beta"]

  def service_start_only(config, names)
    raise "beta cannot start"
  end

  def service_stop
    $stage_events << "beta stopped"
    nil
  end
end

Cybertrain::Background.register(StartingFeed.new)
Cybertrain::Background.register(FailingFeed.new)

test "a feeds role whose second feed raises on start stops the first and frees the role" do
  Cybertrain::Runtime.reset!
  app = stage_app(stage_config("test"), stage_views(GOOD))
  error = assert_raises("RuntimeError") { app.run_feeds([]) }
  assert_equal "beta cannot start", error
  assert_equal ["alpha started", "alpha stopped", "beta stopped"], $stage_events
  assert_equal "", Cybertrain::Runtime.role
  refute Cybertrain::Background.feeds_failed?
  app.shutdown
end

Cybertrain::Test.run!
