# Cybertrain::Runtime and the Application lifecycle (docs/design.md D64):
# the process-shared settings a boot installs depend on that boot's config
# alone (whatever booted before), Runtime.reset! puts every one of them
# back, a second boot of the same Application changes nothing, and
# #shutdown closes only the database pool its own boot connected.
#
# Application#boot connects SQLite through FFI, so this runs compiled only
# (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"

# What the modules hold before any boot: taken before anything below runs.
PRISTINE = Cybertrain::Runtime.describe

def runtime_config(tag)
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.secret_key_base = "runtime-#{tag}-secret"
  c.views_root = "tmp/runtime_test/#{tag}/views"
  c.public_root = "tmp/runtime_test/#{tag}/public"
  c
end

# Every setting Runtime.apply writes, changed from its default.
def config_a
  c = runtime_config("a")
  c.layout = "layouts/a"
  c.max_upload_bytes = 1000
  c.max_multipart_parts = 7
  c.upload_root = "tmp/runtime_test/a/uploads"
  c.max_page = 50
  c.trusted_proxy = true
  c.trusted_proxies = ["10.0.0.0/8"]
  c.filter_parameters = ["pin"]
  c.permissions_policy = "camera=()"
  c.log_level = :warn
  c
end

# A config that leaves them all at their defaults.
def config_b
  runtime_config("b")
end

def app_for(config)
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" }, config: config)
end

test "before any boot the settings are the modules' own defaults" do
  assert_equal 0, Cybertrain::Runtime.applied
  assert_equal "", Cybertrain::Runtime.role
  assert_equal "views=none layout=layouts/application assets_raise=true assets_kept=0 " \
               "max_upload_bytes=5242880 max_parts=128 upload_root=storage/uploads max_page=10000 " \
               "trusted_proxy=false trusted_proxies= " \
               "filter_parameters=password,password_confirmation,token,secret,secret_key_base,session_key,api_key,authorization " \
               "permissions_policy=camera=(), microphone=(), geolocation=() log_level=info", PRISTINE
end

test "a boot installs every setting of its config" do
  app = app_for(config_a)
  refute app.booted?
  app.boot
  assert app.booted?
  assert_equal 1, Cybertrain::Runtime.applied
  assert_equal "views=configured layout=layouts/a assets_raise=true assets_kept=0 " \
               "max_upload_bytes=1000 max_parts=7 upload_root=tmp/runtime_test/a/uploads max_page=50 " \
               "trusted_proxy=true trusted_proxies=10.0.0.0/8 filter_parameters=pin " \
               "permissions_policy=camera=() log_level=warn", Cybertrain::Runtime.describe
  app.shutdown
end

test "Runtime.reset! restores every default" do
  app_for(config_a).boot.shutdown
  refute PRISTINE == Cybertrain::Runtime.describe
  Cybertrain::Runtime.reset!
  assert_equal PRISTINE, Cybertrain::Runtime.describe
end

test "the settings after a boot do not depend on what booted before" do
  Cybertrain::Runtime.reset!
  app_for(config_b).boot.shutdown
  b_alone = Cybertrain::Runtime.describe
  Cybertrain::Runtime.reset!
  app_for(config_a).boot.shutdown
  a_alone = Cybertrain::Runtime.describe
  refute a_alone == b_alone

  app_for(config_b).boot.shutdown
  assert_equal b_alone, Cybertrain::Runtime.describe
  app_for(config_a).boot.shutdown
  assert_equal a_alone, Cybertrain::Runtime.describe
  Cybertrain::Runtime.reset!
end

test "booting the same Application twice keeps its connection and its settings" do
  Cybertrain::Runtime.reset!
  app = app_for(config_a)
  app.boot
  generation = Cybertrain::DB.generation
  once = Cybertrain::Runtime.describe
  applied = Cybertrain::Runtime.applied
  app.boot
  assert app.booted?
  assert_equal generation, Cybertrain::DB.generation
  assert_equal once, Cybertrain::Runtime.describe
  assert_equal applied + 1, Cybertrain::Runtime.applied
  app.shutdown
  refute Cybertrain::DB.connected?
end

test "shutdown closes the pool its boot connected, and boot works again afterwards" do
  app = app_for(config_b)
  app.boot
  assert Cybertrain::DB.connected?
  first = Cybertrain::DB.generation
  app.shutdown
  refute app.booted?
  refute Cybertrain::DB.connected?
  app.shutdown # a second shutdown is a no-op
  app.boot
  assert app.booted?
  assert_equal first + 1, Cybertrain::DB.generation
  app.shutdown
end

test "shutdown leaves a pool the caller connected, and one connected since" do
  Cybertrain::DB.connect(":memory:", size: 1)
  mine = Cybertrain::DB.generation
  app = app_for(config_b)
  app.boot
  assert_equal mine, Cybertrain::DB.generation
  app.shutdown
  assert Cybertrain::DB.connected?
  Cybertrain::DB.disconnect

  app.boot
  Cybertrain::DB.connect(":memory:", size: 1) # replaces the boot's pool
  later = Cybertrain::DB.generation
  app.shutdown
  assert Cybertrain::DB.connected?
  assert_equal later, Cybertrain::DB.generation
  Cybertrain::DB.disconnect
end

test "a second Application takes the settings over; the pool stays the first's" do
  Cybertrain::Runtime.reset!
  first = app_for(config_a)
  second = app_for(config_b)
  first.boot
  generation = Cybertrain::DB.generation
  second.boot
  assert_equal generation, Cybertrain::DB.generation
  assert_equal "layouts/application", Cybertrain::Views.layout_name
  second.shutdown
  assert Cybertrain::DB.connected?
  first.shutdown
  refute Cybertrain::DB.connected?
  Cybertrain::Runtime.reset!
end

test "a role refused because another runs changes nothing shared" do
  Cybertrain::Runtime.reset!
  app = app_for(config_a)
  assert_equal "", Cybertrain::Runtime.enter_role("feeds")
  Cybertrain::Application.request_stop_roles
  applied = Cybertrain::Runtime.applied
  assert_equal 1, app.run_worker([])
  assert_equal 1, app.run_feeds([])
  refute app.booted?
  assert_equal applied, Cybertrain::Runtime.applied
  assert Cybertrain::Roles.stop_requested?
  assert_equal "feeds", Cybertrain::Runtime.role
  Cybertrain::Runtime.leave_role
  Cybertrain::Roles.reset_stop
end

test "shutdown ends the server's lifecycle too: the next one is built anew" do
  Cybertrain::Runtime.reset!
  c = config_b
  c.port = 8080
  app = app_for(c)
  app.boot
  first = app.server
  assert first.equal?(app.server)
  assert_equal 8080, first.port
  app.shutdown
  c.port = 8081
  app.boot
  second = app.server
  refute second.equal?(first)
  assert_equal 8081, second.port
  app.shutdown
end

test "one role runs at a time" do
  assert_equal "", Cybertrain::Runtime.enter_role("worker")
  assert_equal "worker", Cybertrain::Runtime.role
  assert_equal "the worker role is already running in this process (one Application runs one role at a time)",
               Cybertrain::Runtime.enter_role("feeds")
  Cybertrain::Runtime.leave_role
  assert_equal "", Cybertrain::Runtime.enter_role("feeds")
  Cybertrain::Runtime.leave_role
  assert_equal "", Cybertrain::Runtime.role
end

Cybertrain::Test.run!
