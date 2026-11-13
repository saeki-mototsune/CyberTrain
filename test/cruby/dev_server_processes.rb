require "cybertrain/test"
require "cybertrain/cli/dev_server/machine"
require "cybertrain/cli/dev_server/processes"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "fileutils"

# The supervisor's runner (cybertrain/cli/dev_server/processes.rb, and the
# file watch of cybertrain/cli/dev_server/watch.rb) with real processes: tiny
# Ruby scripts in a temporary directory stand in for the CRuby child, the
# compiled binary, gen and spin. Bounds are cut to fractions of a second and
# every port is 0, so nothing here depends on a free port number. Every
# process a test starts is gone when it ends. CRuby only.

DevServer = Cybertrain::CLI::DevServer
Processes = DevServer::Processes
Machine = DevServer::Machine
REPO = File.expand_path("../..", __dir__)

# The commands a test gives the runner: script paths by role.
class StandIn < Processes
  attr_accessor :scripts

  def child_command(kind) = [RbConfig.ruby, @scripts.fetch(kind), "4000"]
  def gen_command = [RbConfig.ruby, @scripts.fetch(:gen)]

  def build_command(incremental)
    args = [RbConfig.ruby, @scripts.fetch(:spin), "build", "app"]
    incremental ? args + ["--", "--incremental"] : args
  end
end

# Records the events the runner delivers, in place of the Machine.
class Recorder
  attr_reader :events

  def initialize = @events = []
  def on_child_ready(kind, generation) = @events << [:ready, kind, generation]
  def on_child_exit(kind, generation, info) = @events << [:exit, kind, generation, info]
  def on_build_done(generation, ok, output) = @events << [:build, generation, ok, output]
  def on_change(paths) = @events << [:change, paths]
end

# A temporary application directory with the given scripts written into
# bin/stand-ins/; yields the runner, its listener and the directory. Every
# process the runner still owns is stopped at the end.
def with_runner(scripts, watch_interval: 0.05)
  Dir.mktmpdir("dev-server-processes") do |root|
    root = File.realpath(root)
    Dir.mkdir(File.join(root, "bin"))
    Dir.mkdir(File.join(root, "bin", "stand-ins"))
    paths = {}
    scripts.each do |role, source|
      path = File.join(root, "bin", "stand-ins", "#{role}.rb")
      File.write(path, source)
      paths[role] = path
    end
    listener = TCPServer.new("127.0.0.1", 0)
    runner = StandIn.new(root: root, name: "app", port: listener.addr[1], load_path: [REPO, root],
                         listener: listener, out: StringIO.new, err: StringIO.new)
    runner.scripts = paths
    runner.ready_timeout = 5
    runner.stop_grace = 2
    runner.watch_interval = watch_interval
    begin
      yield runner, listener, root
    ensure
      runner.cancel_build
      runner.stop_child
      runner.close
      listener.close
    end
  end
end

# Polls (the driver's tick without the machine's on_tick) until the block is
# true or seconds have passed; returns the block's last answer.
def poll_until(runner, machine, seconds = 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    runner.wait_for_activity(0.02)
    runner.poll(machine)
    done = yield
    return done if done || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end

def poll_for(runner, machine, seconds)
  poll_until(runner, machine, seconds) { false }
end

def wait_for_file(path, seconds = 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  File.exist?(path)
end

# Gone: no such process, or a zombie nobody has reaped yet.
def gone?(pid)
  Process.kill(0, pid)
  stat = IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], &:read).strip
  stat.empty? || stat.start_with?("Z")
rescue Errno::ESRCH
  true
end

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

READY = <<~RUBY
  File.write(ENV.fetch("CYBERTRAIN_DEV_READY_FILE"), ENV.fetch("CYBERTRAIN_DEV_GENERATION"))
  sleep 30
RUBY

# --- children -----------------------------------------------------------------

test "a child that writes its ready file is reported ready once" do
  with_runner({ cruby: READY }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_child(:cruby, 3)
    poll_until(runner, rec) { !rec.events.empty? }
    poll_for(runner, rec, 0.2)
    assert_equal [[:ready, :cruby, 3]], rec.events
  end
end

test "a child that dies at boot is reported with its failure file and exit status" do
  script = <<~RUBY
    File.write(ENV.fetch("CYBERTRAIN_DEV_FAILURE_FILE"), "error: port 3000 is in use")
    $stderr.puts "not this: the failure file comes first"
    exit 1
  RUBY
  with_runner({ binary: script }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_child(:binary, 2)
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal [[:exit, :binary, 2, "error: port 3000 is in use\nexit status 1"]], rec.events
  end
end

test "without a failure file the exit carries the STDERR tail, which was copied as it came" do
  script = <<~RUBY
    45.times { |i| $stderr.puts "line \#{i}" }
    exit 2
  RUBY
  with_runner({ cruby: script }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_child(:cruby, 1)
    poll_until(runner, rec) { !rec.events.empty? }
    tail = (5..44).map { |i| "line #{i}" }
    assert_equal [[:exit, :cruby, 1, (tail + ["exit status 2"]).join("\n")]], rec.events
    assert_includes runner.err.string, "line 0\n"
    assert_includes runner.err.string, "line 44\n"
  end
end

test "a child killed by a signal is reported with the signal" do
  with_runner({ cruby: "Process.kill(:KILL, Process.pid)\nsleep 5\n" }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_child(:cruby, 1)
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal [[:exit, :cruby, 1, "signal 9 (KILL)"]], rec.events
  end
end

test "a child that does not become ready in time is stopped and reported" do
  with_runner({ cruby: "sleep 30\n" }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.ready_timeout = 0.3
    runner.start_child(:cruby, 4)
    pid = runner.child_pid
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal [[:exit, :cruby, 4, "did not become ready in 0.3 s"]], rec.events
    assert gone?(pid), "the child is gone"
    assert_nil runner.child_pid
  end
end

test "stop_child sends TERM, then KILL after the grace" do
  script = <<~RUBY
    trap(:TERM) { }
    File.write(ENV.fetch("CYBERTRAIN_DEV_READY_FILE"), ENV.fetch("CYBERTRAIN_DEV_GENERATION"))
    sleep 30 while true
  RUBY
  with_runner({ cruby: script }) do |runner, _listener, root|
    runner.stop_grace = 0.3
    runner.start_child(:cruby, 1)
    pid = runner.child_pid
    assert wait_for_file(File.join(root, "tmp", "cybertrain-dev", "ready")), "the child trapped TERM"
    # Bounded: a stop_child that never sends KILL fails here instead of
    # waiting out the stand-in, which never ends by itself.
    stopper = Thread.new { runner.stop_child }
    took = elapsed { stopper.join(3) }
    unless stopper.join(0)
      Process.kill(:KILL, pid)
      stopper.join
      flunk "stop_child did not return within 3 s of TERM (no KILL after the grace)"
    end
    assert took < 1.0, "stop_child took #{took} s"
    assert gone?(pid), "the child is gone"
    refute File.exist?(File.join(root, "tmp", "cybertrain-dev", "child.pid")), "child.pid is removed"
  end
end

test "a child the runner stopped itself is never reported, nor its replacement's predecessor" do
  with_runner({ cruby: READY }) do |runner, _listener, root|
    rec = Recorder.new
    runner.start_child(:cruby, 1)
    assert wait_for_file(File.join(root, "tmp", "cybertrain-dev", "ready"))
    runner.stop_child
    poll_for(runner, rec, 0.2)
    assert_equal [], rec.events
    # The same kind and generation again (the machine does this after a dead
    # binary): only the live process counts.
    runner.start_child(:cruby, 1)
    pid = runner.child_pid
    poll_until(runner, rec) { !rec.events.empty? }
    Process.kill(:KILL, pid)
    poll_until(runner, rec) { rec.events.size > 1 }
    assert_equal [[:ready, :cruby, 1], [:exit, :cruby, 1, "signal 9 (KILL)"]], rec.events
  end
end

test "the child inherits the listener and its environment" do
  script = <<~RUBY
    keys = %w[CYBERTRAIN_DEV_LISTEN_FD CYBERTRAIN_DEV_READY_FILE CYBERTRAIN_DEV_STATE_FILE
              CYBERTRAIN_DEV_FAILURE_FILE CYBERTRAIN_DEV_GENERATION CYBERTRAIN_ENV]
    File.write(File.join(Dir.pwd, "env.txt"), keys.map { |k| "\#{k}=\#{ENV[k]}" }.join("\\n"))
    #{READY}
  RUBY
  with_runner({ cruby: script }) do |runner, listener, root|
    rec = Recorder.new
    runner.start_child(:cruby, 6)
    poll_until(runner, rec) { !rec.events.empty? }
    dev = File.join(root, "tmp", "cybertrain-dev")
    env = File.read(File.join(root, "env.txt")).lines.map(&:chomp)
    assert_equal ["CYBERTRAIN_DEV_LISTEN_FD=#{listener.fileno}", "CYBERTRAIN_DEV_READY_FILE=#{dev}/ready",
                  "CYBERTRAIN_DEV_STATE_FILE=#{dev}/state", "CYBERTRAIN_DEV_FAILURE_FILE=#{dev}/failure",
                  "CYBERTRAIN_DEV_GENERATION=6", "CYBERTRAIN_ENV=#{ENV["CYBERTRAIN_ENV"] || "development"}"], env
    assert_equal runner.child_pid.to_s, File.read(File.join(dev, "child.pid"))
  end
end

test "a child command that cannot be started is reported as the child's exit on the next poll" do
  with_runner({}) do |runner, _listener, root|
    missing = File.join(root, "build", "bin", "app")
    runner.define_singleton_method(:child_command) { |_kind| [missing, "4000"] }
    rec = Recorder.new
    runner.start_child(:binary, 3)
    assert_nil runner.child_pid
    runner.poll(rec)
    assert_equal 1, rec.events.size
    assert_equal [:exit, :binary, 3], rec.events[0][0, 3]
    assert rec.events[0][3].start_with?("could not start #{missing}: "), rec.events[0][3]
    poll_for(runner, rec, 0.1)
    assert_equal 1, rec.events.size
  end
end

# --- holding ------------------------------------------------------------------

def request(port)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
  sock
end

test "while holding the supervisor answers 503; after release_hold a child answers" do
  child = <<~RUBY
    require "socket"
    server = TCPServer.for_fd(Integer(ENV.fetch("CYBERTRAIN_DEV_LISTEN_FD")))
    #{READY.lines.first}
    loop do
      client = server.accept
      client.readpartial(4096)
      client.write("HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok")
      client.close
    end
  RUBY
  with_runner({ cruby: child }) do |runner, listener, _root|
    rec = Recorder.new
    port = listener.addr[1]
    runner.hold("gen failed", "<script>boom</script>")
    first = request(port)
    answer = +""
    poll_until(runner, rec) do
      chunk = first.read_nonblock(65_536, exception: false)
      answer << chunk if chunk.is_a?(String)
      chunk.nil?
    end
    assert answer.start_with?("HTTP/1.1 503 Service Unavailable\r\n"), answer[0, 40]
    assert_includes answer, "&lt;script&gt;boom&lt;/script&gt;"
    assert_includes answer, "Waiting for: a saved change"
    first.close

    runner.release_hold
    second = request(port)
    poll_for(runner, rec, 0.3)
    assert IO.select([second], nil, nil, 0.1).nil?, "nobody answers between the hold and the child"
    runner.start_child(:cruby, 1)
    assert IO.select([second], nil, nil, 5), "the child answers the waiting connection"
    assert second.read.start_with?("HTTP/1.1 200 OK")
    second.close
  end
end

# --- the build ----------------------------------------------------------------

SPIN = <<~RUBY
  File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
  if ARGV.include?("--incremental")
    puts "spinel: unknown option '--incremental'"
    exit 1
  end
  puts "built"
RUBY

test "a toolchain that refuses --incremental is built again without it, and from then on" do
  with_runner({ spin: SPIN }) do |runner, _listener, root|
    rec = Recorder.new
    runner.start_build(4)
    poll_until(runner, rec) { !rec.events.empty? }
    poll_for(runner, rec, 0.2)
    assert_equal [[:build, 4, true, "built\n"]], rec.events
    assert_equal "built\n", File.read(File.join(root, "tmp", "rebuild.log"))
    runner.start_build(5)
    poll_until(runner, rec) { rec.events.size > 1 }
    assert_equal [:build, 5, true, "built\n"], rec.events[1]
    assert_equal ["build app -- --incremental", "build app", "build app"], File.read(File.join(root, "spin-calls.txt")).lines.map(&:chomp)
  end
end

test "a failed build reports its log" do
  with_runner({ spin: "puts 'app.rb:1: error'\nexit 1\n" }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_build(2)
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal [[:build, 2, false, "app.rb:1: error\n"]], rec.events
  end
end

test "cancel_build kills the build's whole process group" do
  spin = <<~RUBY
    grandchild = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 30")
    File.write(File.join(Dir.pwd, "pids.txt"), "\#{Process.pid} \#{grandchild}")
    sleep 30
  RUBY
  with_runner({ spin: spin }) do |runner, _listener, root|
    rec = Recorder.new
    runner.start_build(1)
    assert wait_for_file(File.join(root, "pids.txt"))
    sleep 0.05 while File.read(File.join(root, "pids.txt")).split.size < 2
    pids = File.read(File.join(root, "pids.txt")).split.map(&:to_i)
    runner.cancel_build
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.02 until pids.all? { |pid| gone?(pid) } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert pids.all? { |pid| gone?(pid) }, "the build and its grandchild are gone"
    poll_for(runner, rec, 0.2)
    assert_equal [], rec.events
  end
end

test "build.pid names the build's group while it runs: gone at its end, its cancel and close" do
  with_runner({ spin: "sleep 0.3 if ARGV.include?('slow')\nputs 'built'\n" }) do |runner, _listener, root|
    path = File.join(root, "tmp", "cybertrain-dev", "build.pid")
    rec = Recorder.new
    runner.define_singleton_method(:build_command) do |_incremental|
      [RbConfig.ruby, @scripts.fetch(:spin), "slow"]
    end
    runner.start_build(1)
    assert_equal runner.build_pid.to_s, File.read(path)
    assert_equal runner.build_pid, Process.getpgid(runner.build_pid)
    poll_until(runner, rec) { !rec.events.empty? }
    refute File.exist?(path), "removed when the build ends"
    runner.start_build(2)
    assert File.exist?(path)
    runner.cancel_build
    refute File.exist?(path), "removed when the build is cancelled"
    runner.start_build(3)
    runner.close
    refute File.exist?(path), "removed at close"
  end
end

# --- gen, the state file, the lock --------------------------------------------

test "log loses its line, without raising, once the terminal is gone" do
  with_runner({}) do |runner, listener, root|
    reader, writer = IO.pipe
    reader.close
    gone = Processes.new(root: root, name: "app", port: listener.addr[1], load_path: [],
                         listener: listener, out: writer, err: StringIO.new)
    assert_nil gone.log("=> spinel: ready")
    writer.close
    assert_nil gone.log("=> spinel: ready")
  end
end

test "run_gen answers gen's status and its output" do
  with_runner({ gen: "puts 'wrote gen/app.rb'\n$stderr.puts 'warning'\nexit 1\n" }) do |runner, _listener, _root|
    ok, output = runner.run_gen
    refute ok
    assert_includes output, "wrote gen/app.rb"
    assert_includes output, "warning"
  end
end

test "write_state renames a whole file into place" do
  with_runner({}) do |runner, _listener, root|
    path = File.join(root, "tmp", "cybertrain-dev", "state")
    runner.write_state(7, "cruby", "failed", "out\ntext")
    snapshot = Cybertrain::Dev::StateFile.parse(File.read(path))
    assert_equal [7, "cruby", "failed", "out\ntext"], [snapshot.generation, snapshot.serving, snapshot.build, snapshot.output]
    before = File.stat(path).ino
    held = File.open(path)
    runner.write_state(8, "spinel", "ready", "")
    assert_equal "generation 7", held.gets.chomp
    held.close
    refute before == File.stat(path).ino, "a new file was renamed over the old one"
    assert_equal 8, Cybertrain::Dev::StateFile.parse(File.read(path)).generation
    assert_equal ["state"], Dir.children(File.dirname(path)).sort
  end
end

test "build_locked? follows the rebuilder's rule for a stale lock" do
  with_runner({}) do |runner, _listener, root|
    FileUtils.mkdir_p(File.join(root, "tmp"))
    lock = File.join(root, "tmp", "cybertrain-build.lock")
    refute runner.build_locked?
    File.write(lock, Process.pid.to_s)
    assert runner.build_locked?, "a live PID holds the lock"
    File.write(lock, "")
    assert runner.build_locked?, "a lock without a PID counts"
    dead = Process.spawn(RbConfig.ruby, "-e", "exit")
    Process.wait(dead)
    File.write(lock, dead.to_s)
    refute runner.build_locked?, "a dead PID does not count"
    refute File.exist?(lock), "and its lock is removed"
    File.write(lock, Process.pid.to_s)
    old = Time.now - Processes::STALE_LOCK_AGE - 1
    File.utime(old, old, lock)
    refute runner.build_locked?, "a lock older than the stale age does not count"
  end
end

# --- the machine and the runner together --------------------------------------

STATE_CHILD = <<~RUBY
  trap(:TERM) do
    File.write(File.join(Dir.pwd, "term-\#{Process.pid}"), "")
    sleep 0.5
    exit 0
  end
  #{READY}
RUBY

BINARY_CHILD = <<~RUBY
  File.write(File.join(Dir.pwd, "binary-spawned"), "")
  #{READY}
RUBY

def drive(runner, machine, seconds)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    runner.wait_for_activity(0.02)
    runner.poll(machine)
    machine.on_tick
    break if yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end

def save(path, text)
  File.write(path, text)
  later = Time.now + 2
  File.utime(later, later, path)
end

test "a build that succeeds hands the port to the binary" do
  scripts = { gen: "", cruby: STATE_CHILD, binary: BINARY_CHILD, spin: "puts 'built'\n" }
  with_runner(scripts) do |runner, _listener, root|
    machine = Machine.new(runner)
    runner.watch
    machine.start
    runner.start_watching
    drive(runner, machine, 5) { File.exist?(File.join(root, "binary-spawned")) && machine.serving == :spinel }
    assert_equal :spinel, machine.serving
    assert File.exist?(File.join(root, "binary-spawned")), "the binary was started"
  end
end

# R14: the save lands while the CRuby child drains, before the watcher's next
# poll (its interval is a minute here), so only the fresh snapshot that
# change_pending? takes can see it.
# The build waits for the child's ready file, which the child writes after its
# TERM trap is in place: a handover before that would kill it outright.
AFTER_READY_SPIN = <<~RUBY
  sleep 0.01 until File.exist?("tmp/cybertrain-dev/ready")
  puts "built"
RUBY

test "a save made while the child is slow to stop keeps the binary from starting" do
  scripts = { gen: "", cruby: STATE_CHILD, binary: BINARY_CHILD, spin: AFTER_READY_SPIN }
  with_runner(scripts, watch_interval: 60) do |runner, _listener, root|
    Dir.mkdir(File.join(root, "app"))
    model = File.join(root, "app", "article.rb")
    File.write(model, "class Article\nend\n")
    machine = Machine.new(runner)
    runner.watch
    machine.start
    runner.start_watching
    child = runner.child_pid
    saver = Thread.new do
      termed = wait_for_file(File.join(root, "term-#{child}"))
      save(model, "class Article\n  # saved\nend\n")
      termed
    end
    drive(runner, machine, 5) { machine.serving != :cruby }
    assert saver.value, "the save was made while the child was stopping"
    refute File.exist?(File.join(root, "binary-spawned")), "the binary was never spawned"
    assert_equal :none, machine.serving
    assert runner.change_pending?, "the change is still pending for the watcher's next poll"
  end
end

# After the machine's stop the runner owns nothing: the child and the whole
# build are gone, and nothing is reported for either.
test "after the machine's stop nothing runs and nothing is reported" do
  spin = <<~RUBY
    File.write(File.join(Dir.pwd, "build-pid"), Process.pid.to_s)
    sleep 30
  RUBY
  scripts = { gen: "", cruby: READY, binary: READY, spin: spin }
  with_runner(scripts) do |runner, _listener, root|
    machine = Machine.new(runner)
    machine.start
    child = runner.child_pid
    build = runner.build_pid
    drive(runner, machine, 5) { File.exist?(File.join(root, "tmp", "cybertrain-dev", "ready")) }
    assert wait_for_file(File.join(root, "build-pid")), "the build started"
    machine.stop
    assert_nil runner.child_pid
    assert_nil runner.build_pid
    assert gone?(child), "the child is gone"
    assert gone?(build), "the build is gone"
    rec = Recorder.new
    poll_for(runner, rec, 0.3)
    assert_equal [], rec.events
  end
end

test "a change runs one round; the files gen rewrites are not a change of their own" do
  gen = <<~RUBY
    Dir.mkdir("gen") unless Dir.exist?("gen")
    File.write("gen/app.rb", "# \#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}\\n")
    File.open("gen-runs.txt", "a") { |f| f.puts "gen" }
  RUBY
  scripts = { gen: gen, cruby: READY, binary: READY, spin: "sleep 30\n" }
  with_runner(scripts) do |runner, _listener, root|
    Dir.mkdir(File.join(root, "app"))
    model = File.join(root, "app", "article.rb")
    File.write(model, "class Article\nend\n")
    machine = Machine.new(runner)
    runner.watch
    machine.start
    runner.start_watching
    save(model, "class Article\n  # saved\nend\n")
    drive(runner, machine, 5) { machine.generation == 2 }
    drive(runner, machine, 0.5) { false }
    assert_equal 2, machine.generation
    assert_equal ["Changed app/article.rb"], runner.out.string.lines.map(&:chomp).grep(/\AChanged/)
    assert_equal 2, File.read(File.join(root, "gen-runs.txt")).lines.size
  end
end

Cybertrain::Test.run!
