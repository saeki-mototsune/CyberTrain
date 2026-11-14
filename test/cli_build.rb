require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli"

# cybertrain build without spin: the command list and the dist/ assembly
# from a fake build/bin/<name>. CRuby-portable.

# This program, run again as the holder that "a crashed holder's build lock
# is taken at once" kills: with LOCK_CHILD set to an application root, it
# takes that application's build lock and waits to be killed.
LOCK_CHILD = "CYBERTRAIN_TEST_BUILD_LOCK_CHILD"
SELF = File.expand_path($0)
REPO = File.expand_path("..", __dir__)
if ENV[LOCK_CHILD].to_s != ""
  child_lock = Cybertrain::CLI::BuildLock.new(ENV[LOCK_CHILD].to_s)
  child_lock.take
  sleep 60
  child_lock.release
  exit(0)
end

ROOT = Dir.mktmpdir("cybertrain-cli-build")
Dir.chdir(ROOT)

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
  rm_tree(ROOT)
end

def make_app
  File.write("spin.toml", "[package]\nname = \"blog\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../cybertrain\" }\n")
  Dir.mkdir("build")
  Dir.mkdir("build/bin")
  File.write("build/bin/blog", "#!/bin/sh\necho built\n")
  File.chmod(0o755, "build/bin/blog")
  Dir.mkdir("public")
  Dir.mkdir("public/img")
  File.write("public/style.css", "body{}\n")
  File.write("public/img/logo.txt", "logo\n")
  Dir.mkdir("public/assets")
  File.write("public/assets/application-0123456789abcdef.css", "a{}\n")
end

make_app

test "app_name reads [package] name from spin.toml" do
  assert_equal "blog", Cybertrain::CLI::Build.app_name(".")
  assert_equal "", Cybertrain::CLI::Build.app_name("no_such_dir")
end

test "app_name rejects only a name that breaks the build/bin/<name> path" do
  File.write("spin.toml", "[package]\nname = \"x; touch PWNED #\"\n")
  message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.app_name(".") }
  assert_equal "spin.toml [package] name 'x; touch PWNED #' cannot contain whitespace", message
  assert_equal 1, Cybertrain::CLI.run(["build"])
  refute File.exist?("PWNED")
  # Each reason has its own wording (Cybertrain::AppName.problem, the one
  # predicate Application.new applies too).
  {
    "a/b" => "cannot contain '/'",
    # "." and ".." would make build/bin/<name> the directory itself or build/.
    "." => "cannot be '.' or '..'",
    ".." => "cannot be '.' or '..'",
    # A leading "-" would reach `spin build` as an option (quote_arg leaves it
    # bare); a "-" inside the name is fine (my-app below).
    "--release" => "cannot start with '-' (spin would read it as an option)",
    "-x" => "cannot start with '-' (spin would read it as an option)",
    "a b" => "cannot contain whitespace",
    "a\tb" => "cannot contain whitespace"
  }.each do |bad, reason|
    File.write("spin.toml", "[package]\nname = \"#{bad}\"\n")
    message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.app_name(".") }
    assert_equal "spin.toml [package] name '#{bad}' #{reason}", message
  end
  # An empty name is not an error here: run_in_app reports it.
  File.write("spin.toml", "[package]\nname = \"\"\n")
  assert_equal "", Cybertrain::CLI::Build.app_name(".")
  assert_equal "cannot be empty", Cybertrain::AppName.problem("")
  assert_equal "cannot contain whitespace", Cybertrain::AppName.problem("a\nb")
  assert_equal "cannot contain whitespace", Cybertrain::AppName.problem("a\rb")
  assert_equal "", Cybertrain::AppName.problem("my-app")
  assert_equal ["public", "storage", "tmp"], Cybertrain::CLI::Build::DIST_ENTRIES
  # The names assemble() creates in dist/ only matter to the build: app_name
  # (read by migration, db, server and build alike) accepts them, so an
  # existing app named tmp or Public still migrates and serves; the build
  # path (require_dist_name!) refuses them in any letter case (macOS APFS
  # makes "Public" and public one directory entry), and the dot-prefixed
  # scratch names too, with one message naming the reason.
  ["public", "storage", "tmp", "Public", "STORAGE", "Tmp", "TMP", ".hidden", ".public.old", ".blog.tmp"].each do |name|
    File.write("spin.toml", "[package]\nname = \"#{name}\"\n")
    assert_equal name, Cybertrain::CLI::Build.app_name(".")
    # NOTES rule 10: run_in_app's own path returns 1, so the block's value is an Integer.
    assert_equal 0, Cybertrain::CLI.run_in_app { |n| n == name ? 0 : 1 }
    message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.require_dist_name!(name) }
    assert_includes message, "spin.toml [package] name '#{name}' collides with what `cybertrain build` keeps in dist/ (public, storage, tmp)"
  end
  # `cybertrain build` itself refuses, before the toolchain is touched.
  File.write("spin.toml", "[package]\nname = \"tmp\"\n")
  assert_equal 1, Cybertrain::CLI.run(["build"])
  assert_equal "", Cybertrain::CLI::Build.dist_name_problem("tmp2")
  Cybertrain::CLI::Build.require_dist_name!("blog")
  # Only those names and a leading dot: other spellings are other entries.
  ["tmp2", "my_public", "blog", "a.b", "MyApp"].each do |fine|
    File.write("spin.toml", "[package]\nname = \"#{fine}\"\n")
    assert_equal fine, Cybertrain::CLI::Build.app_name(".")
  end
  # Shell safety comes from quote_arg, not from the spelling: a hand-written
  # "my-app" or "MyApp" builds as it did before the check existed.
  File.write("spin.toml", "[package]\nname = \"my-app\"\n")
  assert_equal "my-app", Cybertrain::CLI::Build.app_name(".")
  assert_equal "spin build my-app", Cybertrain::CLI::Build.commands("my-app")[1]
  assert_equal "spin build 'my app'", Cybertrain::CLI::Build.commands("my app")[1]
  File.write("spin.toml", "[package]\nname = \"MyApp\"\n")
  assert_equal "MyApp", Cybertrain::CLI::Build.app_name(".")
  File.write("spin.toml", "[package]\nname = \"blog\"\nversion = \"0.1.0\"\n")
  assert_equal "blog", Cybertrain::CLI::Build.app_name(".")
end

test "command strings quote every interpolated value" do
  assert_equal "'x; touch PWNED #'", Cybertrain::CLI::Build.quote_arg("x; touch PWNED #")
  assert_equal "'it'\\''s'", Cybertrain::CLI::Build.quote_arg("it's")
  assert_equal "spin build 'x; touch PWNED #'", Cybertrain::CLI::Build.commands("x; touch PWNED #")[1]
  assert_equal "spin run 'x; touch PWNED #'", Cybertrain::CLI::Build.server_commands("x; touch PWNED #", "")[1]
  assert_equal "spin run blog -- '1; id'", Cybertrain::CLI::Build.server_commands("blog", "1; id")[1]
end

test "an empty application name never reaches the commands from the CLI" do
  # run_in_app is the one place that refuses it (before yielding), so the
  # command builders do not repeat the check: a direct caller gets a quoted "".
  File.write("spin.toml", "[package]\nname = \"\"\n")
  yielded = false
  assert_equal 1, Cybertrain::CLI.run_in_app { |_n| yielded = true; 0 }
  refute yielded
  assert_equal "spin build ''", Cybertrain::CLI::Build.commands("")[1]
  assert_equal "spin run ''", Cybertrain::CLI::Build.server_commands("", "")[1]
  File.write("spin.toml", "[package]\nname = \"blog\"\n")
end

# gen and db are tools that run for milliseconds: they are built in spin's
# debug mode (-O0), the application in release mode.
test "gen and db are built in spin's debug mode" do
  assert_equal "SPIN_DEBUG=1 spin", Cybertrain::Shell::TOOL_SPIN
end

test "build embeds the views, builds, then restores the empty table" do
  assert_equal ["SPIN_DEBUG=1 spin run gen -- --embed-views", "spin build blog", "SPIN_DEBUG=1 spin run gen"], Cybertrain::CLI::Build.commands("blog")
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- migrate", "SPIN_DEBUG=1 spin run gen"], Cybertrain::CLI::Build.migration_commands
  assert_equal "'a'\\''b'", Cybertrain::Shell.quote("a'b")
end

test "db commands generate first, and again after migrate and rollback" do
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- migrate", "SPIN_DEBUG=1 spin run gen"], Cybertrain::CLI::Build.db_commands(["migrate"])
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- rollback 2", "SPIN_DEBUG=1 spin run gen"], Cybertrain::CLI::Build.db_commands(["rollback", "2"])
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- status"], Cybertrain::CLI::Build.db_commands(["status"])
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- schema:dump"], Cybertrain::CLI::Build.db_commands(["schema:dump"])
  assert_equal ["SPIN_DEBUG=1 spin run gen", "SPIN_DEBUG=1 spin run db -- 'a b' ''"], Cybertrain::CLI::Build.db_commands(["a b", ""])
  assert_equal "migrate", Cybertrain::CLI::Build.quote_arg("migrate")
  assert_equal "'x;y'", Cybertrain::CLI::Build.quote_arg("x;y")
end

test "db without a command prints its usage" do
  assert_equal 1, Cybertrain::CLI.run(["db"])
end

test "server generates first and passes an optional port" do
  assert_equal ["SPIN_DEBUG=1 spin run gen", "spin run blog"], Cybertrain::CLI::Build.server_commands("blog", "")
  assert_equal ["SPIN_DEBUG=1 spin run gen", "spin run blog -- 4000"], Cybertrain::CLI::Build.server_commands("blog", "4000")
  assert Cybertrain::CLI::Build.port?("4000")
  assert Cybertrain::CLI::Build.port?("65535")
  refute Cybertrain::CLI::Build.port?("65536")
  refute Cybertrain::CLI::Build.port?("")
  refute Cybertrain::CLI::Build.port?("80a")
  refute Cybertrain::CLI::Build.port?("-1")
  refute Cybertrain::CLI::Build.port?("000080000")
  refute Cybertrain::CLI::Build.port?("0")
end

test "server rejects a PORT that is not a number" do
  assert_equal 1, Cybertrain::CLI.run(["server", "abc"])
  assert_equal 1, Cybertrain::CLI.run(["server", "0"])
end

test "server rejects anything after PORT" do
  assert_equal 1, Cybertrain::CLI.run(["server", "4000", "extra"])
end

# exe/cybertrain sends `server ... --spinel` here (today's compiled loop);
# the flag is taken out wherever it stands, so PORT is checked as before.
test "server --spinel is today's loop: the flag is dropped, PORT and extra words are checked" do
  assert_equal 1, Cybertrain::CLI.run(["server", "--spinel", "abc"])
  assert_equal 1, Cybertrain::CLI.run(["server", "4000", "--spinel", "extra"])
  assert_equal 1, Cybertrain::CLI.run(["server", "--spinel", "4000", "extra"])
  assert_includes Cybertrain::CLI::USAGE, "cybertrain server [PORT] [--spinel]"
end

# The checks of the test below, in a method so that the test block holds
# only the begin/ensure that restores the directory and the environment
# (NOTES rule 32: the fewer yielding calls inside a block with its own
# ensure, the better).
def spinel_port_checks(fake)
  [["server", "--spinel", "4000"], ["server", "4000", "--spinel"]].each do |argv|
    File.delete("#{fake}/calls") if File.exist?("#{fake}/calls")
    assert_equal 0, Cybertrain::CLI.run(argv)
    assert_equal "run gen\nbuild blog -- --incremental\nrun blog -- 4000\n", File.read("#{fake}/calls")
  end
  nil
end

# Wherever the flag stands, PORT reaches the compiled loop's commands. A fake
# pinned Spinel (CYBERTRAIN_SPINEL_HOME) satisfies the toolchain check, and
# its spin records each command instead of running it.
test "server --spinel passes PORT to the compiled loop, before or after the flag" do
  fake = "#{ROOT}/spinel_fake"
  app = "#{ROOT}/spinel_app"
  Dir.mkdir(fake)
  Dir.mkdir(app)
  File.write("#{fake}/spinel", "#!/bin/sh\necho \"spinel #{Cybertrain::SPINEL_TAG} (abc123def) [cc 13.3.0]\"\n")
  File.write("#{fake}/spin", "#!/bin/sh\necho \"$*\" >> #{fake}/calls\n")
  File.chmod(0o755, "#{fake}/spinel")
  File.chmod(0o755, "#{fake}/spin")
  File.write("#{app}/spin.toml", "[package]\nname = \"blog\"\nversion = \"0.1.0\"\n")
  saved_home = ENV["CYBERTRAIN_SPINEL_HOME"].to_s
  saved_path = ENV["PATH"].to_s
  saved_dir = Dir.pwd
  ENV["CYBERTRAIN_SPINEL_HOME"] = fake
  Dir.chdir(app)
  begin
    spinel_port_checks(fake)
  ensure
    # Restored even when an assertion fails: the rest of the file runs in
    # the original directory, with the original toolchain.
    Dir.chdir(saved_dir)
    ENV["CYBERTRAIN_SPINEL_HOME"] = saved_home
    ENV["PATH"] = saved_path
  end
  # Not the begin/ensure's value (see test/db_transaction.rb).
  nil
end

# Stands in for the three spin commands: records each one with whether the
# build lock (holding this process's PID) was held while it ran, and fails
# the one named `failing`. With `writes`, a gen step writes that file (a path
# under root), as gen does when a route or the schema changed.
class FakeRunner < Cybertrain::CLI::Build::Runner
  attr_reader :log

  def initialize(failing, writes = "")
    @failing = failing
    @writes = writes
    @log = Array.new(0) { "" }
  end

  def run_step(root, command)
    path = "#{root}/tmp/cybertrain-build.lock"
    lock = "unlocked"
    if File.exist?(path)
      lock = File.read(path) == Process.pid.to_s ? "locked" : "locked by #{File.read(path).inspect}"
    end
    @log << "#{command} (#{lock})"
    File.write("#{root}/#{@writes}", "# written by gen\n") if @writes != "" && command.include?(" run gen")
    command != @failing
  end
end

# The name check lives in CLI.build_app alone (Build.run assumes a validated
# name), ahead of Toolchain.ensure!: a refused name returns 1 before any
# toolchain is fetched, any step runs or the lock is taken.
test "cybertrain build refuses a name that collides with dist/ before the toolchain, any step or the lock" do
  ["tmp", "Public", ".hidden"].each do |name|
    File.write("spin.toml", "[package]\nname = \"#{name}\"\n")
    assert_equal 1, Cybertrain::CLI.run(["build"])
    refute File.exist?("tmp/cybertrain-build.lock")
    refute File.exist?("dist")
  end
  File.write("spin.toml", "[package]\nname = \"blog\"\n")
end

test "build runs the three steps under tmp/cybertrain-build.lock, then assembles dist/" do
  runner = FakeRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen -- --embed-views (locked)", "spin build blog (locked)", "SPIN_DEBUG=1 spin run gen (locked)"], runner.log
  refute File.exist?("tmp/cybertrain-build.lock")
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.directory?("dist/public")
  rm_tree("dist")
end

test "a failed spin build still restores gen/views.rb, skips assemble and exits 1" do
  runner = FakeRunner.new("spin build blog")
  assert_equal 1, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen -- --embed-views (locked)", "spin build blog (locked)", "SPIN_DEBUG=1 spin run gen (locked)"], runner.log
  refute File.exist?("dist")
  refute File.exist?("tmp/cybertrain-build.lock")
end

test "a failed restore exits 1, warns about gen/views.rb and releases the lock" do
  runner = FakeRunner.new("SPIN_DEBUG=1 spin run gen")
  assert_equal 1, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal 3, runner.log.size
  refute File.exist?("dist")
  refute File.exist?("tmp/cybertrain-build.lock")
end

# The build lock is the kernel's flock on the file (CLI::BuildLock), which
# also records the holder's PID. A BuildLock taken on behalf of PID 1 stands
# for another process holding the lock: flock is per open file description,
# so a second open in this process conflicts as another process's would.
# 2147483647 is a PID that has gone.
LOCK = "tmp/cybertrain-build.lock"
OTHER_LIVE_PID = "1"
DEAD_PID = "2147483647"

def clear_lock
  Dir.mkdir("tmp") unless File.directory?("tmp")
  File.delete(LOCK) if File.exist?(LOCK)
end

def other_holder
  Cybertrain::CLI::BuildLock.new(".", OTHER_LIVE_PID.to_i)
end

# Another taker that wins between this one's open and its lock.
class RacingLock < Cybertrain::CLI::BuildLock
  attr_reader :other

  def initialize(root)
    super(root)
    @other = Cybertrain::CLI::BuildLock.new(root, OTHER_LIVE_PID.to_i)
  end

  def before_lock
    @other.take unless @other.holding?
    nil
  end
end

# A taker that opens the file just before its holder releases it (and
# unlinks it), then locks what it opened.
class LateOpenLock < Cybertrain::CLI::BuildLock
  def initialize(root, holder)
    super(root)
    @holder = holder
  end

  def before_lock
    @holder.release
    nil
  end
end

# A holder paused before deleting its file, long enough for the lock to be
# old and another taker to try for it.
class OvertakenLock < Cybertrain::CLI::BuildLock
  attr_reader :overtaken

  def initialize(root)
    super(root)
    @overtaken = false
  end

  def before_release_delete
    return nil if @overtaken

    old = Time.now - 31 * 60
    File.utime(old, old, lock_path) if File.exist?(lock_path)
    other = Cybertrain::CLI::BuildLock.new(".", OTHER_LIVE_PID.to_i)
    @overtaken = other.take
    other.release
    nil
  end
end

# A disk that is full once the lock has been opened.
class FullDiskLock < Cybertrain::CLI::BuildLock
  def write_owner(f)
    raise IOError, "No space left on device"
  end
end

# A full disk whose close fails too: CRuby retries the failed flush on
# close and raises again, after releasing the descriptor.
class FullDiskCloseLock < FullDiskLock
  def close_file(f)
    f.close
    raise IOError, "close failed too"
  end
end

# A build during which another process deletes the lock file and takes a
# new one (as a reader still on the old PID-and-age rule might delete it).
class TakeoverRunner < FakeRunner
  attr_reader :other

  def initialize(failing)
    super(failing)
    @other = Cybertrain::CLI::BuildLock.new(".", OTHER_LIVE_PID.to_i)
  end

  def run_step(root, command)
    ok = super
    if command == "spin build blog"
      File.delete("#{root}/tmp/cybertrain-build.lock")
      @other.take
    end
    ok
  end
end

# A build whose lock file ages past the old 30-minute rule during each
# step; records whether a step ever started with the lock not held.
class AgingRunner < FakeRunner
  attr_reader :free_seen

  def initialize(failing)
    super(failing)
    @free_seen = false
  end

  def run_step(root, command)
    path = "#{root}/tmp/cybertrain-build.lock"
    @free_seen = true unless Cybertrain::CLI::BuildLock.new(root).held?
    ok = super
    old = Time.now - 31 * 60
    File.utime(old, old, path) if File.exist?(path)
    ok
  end
end

def open_descriptors
  File.directory?("/dev/fd") ? Dir.children("/dev/fd").size : 0
end

test "Build.lock_path names the lock BuildLock takes" do
  assert_equal "/apps/blog/tmp/cybertrain-build.lock", Cybertrain::CLI::Build.lock_path("/apps/blog")
  assert_equal Cybertrain::CLI::BuildLock.new("/apps/blog").lock_path, Cybertrain::CLI::Build.lock_path("/apps/blog")
end

test "the build lock is created holding this process's PID when it is free" do
  clear_lock
  lock = Cybertrain::CLI::BuildLock.new(".")
  refute lock.held?
  assert lock.take
  assert lock.held?
  assert Cybertrain::CLI::BuildLock.new(".").held?
  assert_equal Process.pid.to_s, File.read(LOCK)
  lock.release
  refute File.exist?(LOCK)
  refute Cybertrain::CLI::BuildLock.new(".").held?
end

test "taking and releasing the build lock leaves no descriptor open" do
  clear_lock
  warm = Cybertrain::CLI::BuildLock.new(".")
  assert warm.take
  warm.release
  before = open_descriptors
  3.times do
    lock = Cybertrain::CLI::BuildLock.new(".")
    assert lock.take
    lock.release
  end
  assert_equal before, open_descriptors
end

test "a held build lock is refused, and cybertrain build stops before any step" do
  clear_lock
  other = other_holder
  assert other.take
  refute Cybertrain::CLI::BuildLock.new(".").take
  assert_equal OTHER_LIVE_PID, File.read(LOCK)
  runner = FakeRunner.new("")
  assert_equal 1, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal 0, runner.log.size
  assert_equal OTHER_LIVE_PID, File.read(LOCK)
  refute File.exist?("dist")
  other.release
  refute File.exist?(LOCK)
end

test "a lock file nobody holds is taken at once, whatever PID or age it records" do
  [DEAD_PID, OTHER_LIVE_PID, ""].each do |left|
    clear_lock
    File.write(LOCK, left)
    old = Time.now - 31 * 60
    File.utime(old, old, LOCK)
    refute Cybertrain::CLI::BuildLock.new(".").held?
    assert_equal left, File.read(LOCK)
    lock = Cybertrain::CLI::BuildLock.new(".")
    assert lock.take
    assert_equal Process.pid.to_s, File.read(LOCK)
    lock.release
    refute File.exist?(LOCK)
  end
end

test "two takers racing for the build lock leave exactly one holder" do
  clear_lock
  File.write(LOCK, DEAD_PID)
  # the other locks the file after this one opened it
  racer = RacingLock.new(".")
  refute racer.take
  assert racer.other.holding?
  assert_equal OTHER_LIVE_PID, File.read(LOCK)
  racer.other.release
  # two takers in this process: the second finds the first's lock
  first = Cybertrain::CLI::BuildLock.new(".")
  second = Cybertrain::CLI::BuildLock.new(".")
  assert first.take
  refute second.take
  assert_equal Process.pid.to_s, File.read(LOCK)
  first.release
  refute File.exist?(LOCK)
end

test "a taker that opened the file before its holder released it ends up on the path's file" do
  clear_lock
  holder = other_holder
  assert holder.take
  late = LateOpenLock.new(".", holder)
  assert late.take
  # the lock it holds is the one at the path: no third taker gets in
  assert File.exist?(LOCK)
  assert_equal Process.pid.to_s, File.read(LOCK)
  third = other_holder
  refute third.take
  late.release
  refute File.exist?(LOCK)
end

test "a crashed holder's build lock is taken at once" do
  clear_lock
  ENV[LOCK_CHILD] = File.expand_path(".")
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", REPO, SELF)
  else
    pid = Process.spawn(SELF)
  end
  ENV.delete(LOCK_CHILD)
  waited = 0
  while waited < 200 && !(File.exist?(LOCK) && File.read(LOCK) == pid.to_s)
    sleep 0.05
    waited += 1
  end
  assert_equal pid.to_s, File.read(LOCK)
  lock = Cybertrain::CLI::BuildLock.new(".")
  assert Cybertrain::CLI::BuildLock.new(".").held?
  refute lock.take
  Process.kill(9, pid)
  Process.wait(pid)
  # the file still names the dead child; the kernel dropped its lock
  assert_equal pid.to_s, File.read(LOCK)
  refute Cybertrain::CLI::BuildLock.new(".").held?
  assert lock.take
  assert_equal Process.pid.to_s, File.read(LOCK)
  lock.release
  refute File.exist?(LOCK)
end

test "a holder releasing an old build lock never lets another taker in before it is done" do
  clear_lock
  lock = OvertakenLock.new(".")
  assert lock.take
  lock.release
  refute lock.overtaken
  refute File.exist?(LOCK)
end

test "releasing the build lock leaves a lock another taker holds at the path" do
  clear_lock
  lock = Cybertrain::CLI::BuildLock.new(".")
  assert lock.take
  File.delete(LOCK)
  other = other_holder
  assert other.take
  lock.release
  assert_equal OTHER_LIVE_PID, File.read(LOCK)
  assert other.held?
  other.release
  clear_lock
  runner = TakeoverRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal OTHER_LIVE_PID, File.read(LOCK)
  runner.other.release
  rm_tree("dist")
  clear_lock
end

test "a build lock whose PID cannot be written is closed and removed, and the error goes on" do
  clear_lock
  # a first take and release, so that anything the runtime opens once for
  # them is open before the count
  warm = Cybertrain::CLI::BuildLock.new(".")
  assert warm.take
  warm.release
  before = open_descriptors
  assert_raises("IOError") { FullDiskLock.new(".").take }
  refute File.exist?(LOCK)
  assert_equal before, open_descriptors
  lock = Cybertrain::CLI::BuildLock.new(".")
  assert lock.take
  lock.release
end

test "a build lock whose close fails as well still raises the write's error" do
  clear_lock
  warm = Cybertrain::CLI::BuildLock.new(".")
  assert warm.take
  warm.release
  before = open_descriptors
  message = ""
  begin
    FullDiskCloseLock.new(".").take
  rescue IOError => e
    message = e.message
  end
  assert_equal "No space left on device", message
  refute File.exist?(LOCK)
  assert_equal before, open_descriptors
  lock = Cybertrain::CLI::BuildLock.new(".")
  assert lock.take
  lock.release
end

test "a long cybertrain build keeps its lock held however old the file gets" do
  clear_lock
  runner = AgingRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal 3, runner.log.size
  refute runner.free_seen
  refute File.exist?(LOCK)
  rm_tree("dist")
end

test "assemble copies the binary and public/ into dist/ and keeps storage/ and tmp/" do
  Dir.mkdir("dist")
  Dir.mkdir("dist/storage")
  File.write("dist/storage/production.sqlite3", "keep me")
  Dir.mkdir("dist/public")
  File.write("dist/public/stale.css", "old")
  # Leftovers of an interrupted earlier run.
  File.write("dist/.blog.tmp", "stale binary")
  Dir.mkdir("dist/.public.tmp")
  File.write("dist/.public.tmp/old.css", "stale")
  Dir.mkdir("dist/.public.old")
  File.write("dist/.public.old/older.css", "stale")
  written = Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal ["dist/blog", "dist/public/", "dist/storage/", "dist/tmp/"], written
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.executable?("dist/blog")
  assert_equal "body{}\n", File.read("dist/public/style.css")
  assert_equal "logo\n", File.read("dist/public/img/logo.txt")
  assert_equal "a{}\n", File.read("dist/public/assets/application-0123456789abcdef.css")
  refute File.exist?("dist/public/stale.css")
  refute File.exist?("dist/public/old.css")
  assert_equal "keep me", File.read("dist/storage/production.sqlite3")
  assert File.directory?("dist/tmp")
  refute File.exist?("dist/.blog.tmp")
  refute File.exist?("dist/.public.tmp")
  refute File.exist?("dist/.public.old")
  assert_equal "", Dir.children("dist").select { |child| child.start_with?(".") }.join(",")
end

test "assemble removes a symlink in dist/public without following it" do
  Dir.mkdir("outside")
  File.write("outside/keep.txt", "keep")
  File.symlink("#{ROOT}/outside", "dist/public/linked")
  Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal "keep", File.read("outside/keep.txt")
  refute File.exist?("dist/public/linked")
  assert_equal "", Dir.children("dist").select { |child| child.start_with?(".") }.join(",")
end

test "assemble fails clearly when the binary is missing" do
  File.delete("build/bin/blog")
  message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.assemble(".", "blog") }
  assert_equal "build/bin/blog is missing: `spin build blog` did not produce it", message
end

test "the incremental build command quotes the name" do
  assert_equal "spin build blog -- --incremental", Cybertrain::CLI::Build.incremental_command("blog")
  assert_equal "spin build 'it'\\''s' -- --incremental", Cybertrain::CLI::Build.incremental_command("it's")
end

# A tree of its own, with modification times set by File.utime: a binary at
# T, every file at T - 100 unless a case moves one to T + 100. app/linked is
# a symlink to a directory outside the tree.
STALE_APP = "#{ROOT}/stale_app"
STALE_OUTSIDE = "#{ROOT}/stale_outside"
STALE_T = 1_700_000_000

def stale_touch(path, offset)
  time = Time.at(STALE_T + offset)
  File.utime(time, time, "#{STALE_APP}/#{path}")
  nil
end

# The test's rm_tree follows symlinks: the link goes first.
def stale_cleanup
  File.delete("#{STALE_APP}/app/linked") if File.symlink?("#{STALE_APP}/app/linked")
  rm_tree(STALE_APP) if File.exist?(STALE_APP)
  rm_tree(STALE_OUTSIDE) if File.exist?(STALE_OUTSIDE)
  nil
end

def stale_app
  stale_cleanup
  Dir.mkdir(STALE_OUTSIDE)
  File.write("#{STALE_OUTSIDE}/linked.rb", "# linked\n")
  ["", "/app", "/app/models", "/app/build", "/build", "/build/bin", "/tmp", "/dist", "/storage", "/public", "/.git", "/.bundle",
   "/node_modules", "/config", "/gen"].each { |d| Dir.mkdir("#{STALE_APP}#{d}") }
  ["app/models/post.rb", "config/routes.rb", "app/build/nested.rb", "build/scratch.rb", "tmp/scratch.rb", "dist/scratch.rb",
   "storage/scratch.rb", "public/scratch.rb", ".git/scratch.rb", ".bundle/scratch.rb", "node_modules/scratch.rb",
   "app/models/notes.txt"].each do |path|
    File.write("#{STALE_APP}/#{path}", "# #{path}\n")
    stale_touch(path, -100)
  end
  File.symlink(STALE_OUTSIDE, "#{STALE_APP}/app/linked")
  stale_touch("app/linked/linked.rb", -100)
  File.write("#{STALE_APP}/build/bin/blog", "binary")
  stale_touch("build/bin/blog", 0)
  nil
end

test "binary_stale? is true without a binary or with a Ruby file as new as it outside build/, dist/, tmp/, storage/, public/, node_modules/ and dot directories" do
  stale_app
  refute Cybertrain::CLI::Build.binary_stale?(STALE_APP, "blog")
  assert Cybertrain::CLI::Build.binary_stale?(STALE_APP, "other")
  # Not Ruby, not followed (a symlinked directory), or skipped at the top level.
  ["app/models/notes.txt", "app/linked/linked.rb", "build/scratch.rb", "tmp/scratch.rb", "dist/scratch.rb",
   "storage/scratch.rb", "public/scratch.rb", ".git/scratch.rb", ".bundle/scratch.rb", "node_modules/scratch.rb"].each do |path|
    stale_touch(path, 100)
    refute Cybertrain::CLI::Build.binary_stale?(STALE_APP, "blog"), path
    stale_touch(path, -100)
  end
  # app/build is not the top-level build/.
  ["app/models/post.rb", "config/routes.rb", "app/build/nested.rb"].each do |path|
    stale_touch(path, 100)
    assert Cybertrain::CLI::Build.binary_stale?(STALE_APP, "blog"), path
    stale_touch(path, -100)
  end
  # The same instant as the binary (a filesystem that keeps whole seconds):
  # stale, the mistake that costs one build rather than a stale server.
  stale_touch("app/models/post.rb", 0)
  assert Cybertrain::CLI::Build.binary_stale?(STALE_APP, "blog")
  stale_touch("app/models/post.rb", -100)
  File.delete("#{STALE_APP}/build/bin/blog")
  assert Cybertrain::CLI::Build.binary_stale?(STALE_APP, "blog")
  stale_cleanup
end

test "server builds incrementally only when the binary is stale, then runs it" do
  stale_app
  runner = FakeRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen (unlocked)", "spin run blog (unlocked)"], runner.log
  stale_touch("app/models/post.rb", 100)
  runner = FakeRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "4000", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen (unlocked)", "spin build blog -- --incremental (unlocked)", "spin run blog -- 4000 (unlocked)"], runner.log
  stale_cleanup
end

# The check comes after the gen step: what gen writes is what makes the
# binary stale when a route or the schema changed.
test "server builds incrementally when the gen step wrote a Ruby file" do
  stale_app
  runner = FakeRunner.new("", "gen/routes.rb")
  assert_equal 0, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen (unlocked)", "spin build blog -- --incremental (unlocked)", "spin run blog (unlocked)"], runner.log
  stale_cleanup
end

test "server stops at a failing gen or incremental build" do
  stale_app
  stale_touch("app/models/post.rb", 100)
  runner = FakeRunner.new("SPIN_DEBUG=1 spin run gen")
  assert_equal 1, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen (unlocked)"], runner.log
  runner = FakeRunner.new("spin build blog -- --incremental")
  assert_equal 1, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "", runner)
  assert_equal ["SPIN_DEBUG=1 spin run gen (unlocked)", "spin build blog -- --incremental (unlocked)"], runner.log
  runner = FakeRunner.new("spin run blog")
  assert_equal 1, Cybertrain::CLI::Build.run_server(STALE_APP, "blog", "", runner)
  assert_equal 3, runner.log.size
  stale_cleanup
end

test "the CLI needs spin.toml for migration, db, server and build" do
  Dir.mkdir("elsewhere")
  Dir.chdir("elsewhere")
  assert_equal 1, Cybertrain::CLI.run(["migration"])
  assert_equal 1, Cybertrain::CLI.run(["db", "status"])
  assert_equal 1, Cybertrain::CLI.run(["server"])
  assert_equal 1, Cybertrain::CLI.run(["build"])
  Dir.chdir("..")
end

Cybertrain::Test.run!
