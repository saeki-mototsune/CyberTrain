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
# bin/stand-ins/ (a directory made in inside when given); yields the runner, its listener and the directory. Every
# process the runner still owns is stopped at the end.
def with_runner(scripts, watch_interval: 0.05, load_path: [REPO], inside: nil, stopping: nil)
  Dir.mktmpdir("dev-server-processes", inside) do |root|
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
    options = { root: root, name: "app", port: listener.addr[1], load_path: load_path + [root],
                listener: listener, out: StringIO.new, err: StringIO.new }
    options[:stopping] = stopping unless stopping.nil?
    runner = StandIn.new(**options)
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

# Waits until the block is true or seconds have passed; its last answer.
def wait_for(seconds = 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    done = yield
    return done if done || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.02
  end
end

# The filesystem's clock now, the one a file's time comes from (the
# kernel's coarse clock can lag the wall clock by a tick): a marker file's
# modification time.
def fs_now(root)
  marker = File.join(root, "clock-marker")
  File.write(marker, "")
  File.mtime(marker)
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
    require "socket"
    keys = %w[CYBERTRAIN_DEV_LISTEN_FD CYBERTRAIN_DEV_READY_FILE CYBERTRAIN_DEV_STATE_FILE
              CYBERTRAIN_DEV_FAILURE_FILE CYBERTRAIN_DEV_GENERATION CYBERTRAIN_ENV]
    File.write(File.join(Dir.pwd, "env.txt"), keys.map { |k| "\#{k}=\#{ENV[k]}" }.join("\\n"))
    server = TCPServer.for_fd(Integer(ENV.fetch("CYBERTRAIN_DEV_LISTEN_FD")))
    #{READY.lines.first}
    client = server.accept
    client.write("accepted by \#{Process.pid}")
    client.close
    sleep 30
  RUBY
  with_runner({ cruby: script }) do |runner, listener, root|
    rec = Recorder.new
    runner.start_child(:cruby, 6)
    poll_until(runner, rec) { !rec.events.empty? }
    # The descriptor is open in the child and is the listener: it accepts.
    client = TCPSocket.new("127.0.0.1", listener.addr[1])
    assert IO.select([client], nil, nil, 5), "the child answers"
    assert_equal "accepted by #{runner.child_pid}", client.read
    client.close
    dev = File.join(root, "tmp", "cybertrain-dev")
    env = File.read(File.join(root, "env.txt")).lines.map(&:chomp)
    assert_equal ["CYBERTRAIN_DEV_LISTEN_FD=#{listener.fileno}", "CYBERTRAIN_DEV_READY_FILE=#{dev}/ready",
                  "CYBERTRAIN_DEV_STATE_FILE=#{dev}/state", "CYBERTRAIN_DEV_FAILURE_FILE=#{dev}/failure",
                  "CYBERTRAIN_DEV_GENERATION=6", "CYBERTRAIN_ENV=#{ENV["CYBERTRAIN_ENV"] || "development"}"], env
    assert_equal runner.child_pid.to_s, File.read(File.join(dev, "child.pid"))
  end
end

# A descriptor the supervisor inherited without close-on-exec (the lock of
# playground/playground-server, fd 9) does not reach its children or its
# build: after a supervisor killed outright, a leftover would hold it. The
# listener still does.
def descriptor_open_script(name, fd)
  <<~RUBY
    def open?(fd)
      IO.for_fd(fd, autoclose: false)
      true
    rescue Errno::EBADF
      false
    end
    listen = ENV["CYBERTRAIN_DEV_LISTEN_FD"].to_s
    File.write(File.join(Dir.pwd, "#{name}.tmp"), "inherited=\#{open?(#{fd})} listener=\#{listen.empty? ? "none" : open?(Integer(listen))}")
    File.rename(File.join(Dir.pwd, "#{name}.tmp"), File.join(Dir.pwd, "#{name}"))
    sleep 30 if "#{name}" == "child-fds"
  RUBY
end

test "the child and the build get the listener but no other descriptor the supervisor inherited" do
  Dir.mktmpdir("dev-server-fds") do |dir|
    inherited = File.open(File.join(dir, "lock"), "w")
    inherited.close_on_exec = false
    fd = inherited.fileno
    begin
      scripts = { cruby: descriptor_open_script("child-fds", fd), spin: descriptor_open_script("build-fds", fd) }
      with_runner(scripts) do |runner, _listener, root|
        runner.start_child(:cruby, 1)
        runner.start_build(1)
        assert wait_for_file(File.join(root, "child-fds")), "the child ran"
        assert wait_for_file(File.join(root, "build-fds")), "the build ran"
        assert_equal "inherited=false listener=true", File.read(File.join(root, "child-fds"))
        assert_equal "inherited=false listener=none", File.read(File.join(root, "build-fds"))
      end
    ensure
      inherited.close
    end
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

test "a child that cannot be recorded in child.pid is stopped, then reported" do
  with_runner({ cruby: READY }) do |runner, _listener, _root|
    spawned = []
    runner.define_singleton_method(:write_file) do |path, text|
      if path.end_with?("child.pid")
        spawned << text.to_i
        raise Errno::ENOSPC, path
      end
      super(path, text)
    end
    rec = Recorder.new
    runner.start_child(:cruby, 2)
    assert_nil runner.child_pid
    assert_equal 1, spawned.size
    assert gone?(spawned[0]), "the spawned child is stopped"
    runner.poll(rec)
    assert_equal [:exit, :cruby, 2], rec.events[0][0, 3]
    assert_includes rec.events[0][3], "No space left on device"
  end
end

test "the STDERR tail keeps the last characters of each line; the copy is whole" do
  script = <<~RUBY
    $stderr.write("a" * 10_000 + "\\n" + "y" * 1_000_000 + "zzz")
    exit 3
  RUBY
  with_runner({ cruby: script }) do |runner, _listener, _root|
    rec = Recorder.new
    runner.start_child(:cruby, 1)
    poll_until(runner, rec) { !rec.events.empty? }
    lines = rec.events[0][3].split("\n")
    assert_equal ["a" * Processes::TAIL_LINE_CHARS, "y" * (Processes::TAIL_LINE_CHARS - 3) + "zzz", "exit status 3"], lines
    assert_equal 10_000 + 1 + 1_000_000 + 3, runner.err.string.size
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

# A page larger than the socket's buffers goes out as the client takes it:
# the sockets still being written are IO.select's write set, so the driver
# wakes as soon as one can take more, not once per tick (here a tick of a
# second, which would make the page take many seconds).
test "a held page larger than the socket's buffers wakes the driver as the client reads it" do
  with_runner({}) do |runner, listener, _root|
    rec = Recorder.new
    runner.hold("t", "x" * 400_000)
    listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)
    client = Socket.new(:INET, :STREAM)
    client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
    client.connect(Socket.sockaddr_in(listener.addr[1], "127.0.0.1"))
    client.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    took = nil
    reader = Thread.new do
      text = client.read
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      text
    end
    # The last wait sleeps its whole second: the page is out by then.
    while reader.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 3
      runner.wait_for_activity(1.0)
      runner.poll(rec)
    end
    client.close_write if reader.alive?
    page = reader.value
    assert page.start_with?("HTTP/1.1 503"), page[0, 40]
    assert page.bytesize > 400_000, "the whole page arrived (#{page.bytesize} bytes)"
    assert took < 1.0, "the page took #{took} s"
  ensure
    client&.close
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

# Records its arguments, as SPIN does, and builds.
RECORDING_SPIN = <<~RUBY
  File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
  puts "built"
RUBY

# build/bin/app, written after every Ruby file of the application (the
# stand-ins included), whose times go back a minute.
def write_fresh_binary(root)
  past = Time.now - 60
  Dir.glob(File.join(root, "**", "*.rb")).each { |path| File.utime(past, past, path) }
  FileUtils.mkdir_p(File.join(root, "build", "bin"))
  File.write(File.join(root, "build", "bin", "app"), "binary")
end

def spin_calls(root)
  File.read(File.join(root, "spin-calls.txt")).lines.map(&:chomp)
end

# spin's own up-to-date check is skipped when it is given spinel flags:
# `spin build NAME -- --incremental` recompiles a binary that is up to date.
# The runner's first build, given a binary newer than every Ruby file
# (Build.binary_stale?, the rule of the compiled loop), gets the plain
# command, which spin answers "up to date". Every test of the command passes
# no -I directory but the application's, so that only the files it writes
# decide (none of the repository's, whatever their times).
test "a binary newer than every Ruby file is built with the plain command, so that spin can find it up to date" do
  with_runner({ spin: RECORDING_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal [[:build, 1, true, "built\n"]], rec.events
    assert_equal ["build app"], spin_calls(root)
  end
end

test "a missing binary, or one older than a Ruby file, is built incrementally" do
  with_runner({ spin: RECORDING_SPIN }, load_path: []) do |runner, _listener, root|
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal [[:build, 1, true, "built\n"]], rec.events
    assert_equal ["build app -- --incremental"], spin_calls(root)
  end
  with_runner({ spin: RECORDING_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    File.write(File.join(root, "app.rb"), "# saved after the build\n")
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal ["build app -- --incremental"], spin_calls(root)
  end
end

# R24: only the runner's first build may be plain. A later build follows a
# change round, and a save that landed in the last instant of the build
# before it (after spinel had read the sources, before the binary was
# written) leaves a binary newer than the saved file: by the files' times it
# is up to date, and a plain build would hand the port to it without the
# save.
test "every build after the runner's first is incremental, a fresh binary included" do
  with_runner({ spin: RECORDING_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { rec.events.size == 1 }
    write_fresh_binary(root)
    runner.start_build(2)
    poll_until(runner, rec) { rec.events.size == 2 }
    assert_equal [[:build, 1, true, "built\n"], [:build, 2, true, "built\n"]], rec.events
    assert_equal ["build app", "build app -- --incremental"], spin_calls(root)
  end
end

# A first build that was cancelled (a save during it) counts as the first:
# the one after it is incremental whatever the files' times.
test "a build after a cancelled first build is incremental" do
  spin = <<~RUBY
    first = !File.exist?("spin-calls.txt")
    File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
    sleep 30 if first
    puts "built"
  RUBY
  with_runner({ spin: spin }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    rec = Recorder.new
    runner.start_build(1)
    assert wait_for_file(File.join(root, "spin-calls.txt"))
    runner.cancel_build
    write_fresh_binary(root)
    runner.start_build(2)
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal [[:build, 2, true, "built\n"]], rec.events
    assert_equal ["build app", "build app -- --incremental"], spin_calls(root)
  end
end

# I-1 with the machine: the first build is plain (the binary is fresh), and a
# save lands while it runs, after the sources were read and before the
# binary is written. The handover sees the change and gives way to its
# round; that round's build must recompile, although the binary is newer
# than the saved file. The stand-in spin makes the save itself, so that the
# watcher (a minute between polls) cannot see it before the build ends;
# then the watcher is woken for its next poll (Watch#delivered wakes its
# thread; with nothing taken it marks nothing done), which hands the change
# to the machine as it would after its interval.
LATE_SAVE_SPIN = <<~RUBY
  first = !File.exist?("spin-calls.txt")
  File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
  if first
    File.write("app/article.rb", "class Article\n  # saved during the build\nend\n")
    sleep 0.05
    File.write("build/bin/app", "binary built from the sources before the save")
  end
  puts "built"
RUBY

test "a save in the last instant of a plain build is compiled by the next build, not found up to date" do
  scripts = { gen: "", cruby: READY, binary: BINARY_CHILD, spin: LATE_SAVE_SPIN }
  with_runner(scripts, watch_interval: 60, load_path: []) do |runner, _listener, root|
    Dir.mkdir(File.join(root, "app"))
    model = File.join(root, "app", "article.rb")
    File.write(model, "class Article\nend\n")
    write_fresh_binary(root)
    machine = Machine.new(runner)
    runner.watch
    machine.start
    runner.start_watching
    drive(runner, machine, 5) { machine.serving != :cruby }
    assert_equal :none, machine.serving
    refute File.exist?(File.join(root, "binary-spawned")), "the binary without the save never took the port"
    # R25: the build left the binary at its launch, before the save.
    assert File.mtime(File.join(root, "build", "bin", "app")) < File.mtime(model), "the binary is older than the save"
    runner.watch.delivered
    drive(runner, machine, 5) { machine.serving == :spinel }
    assert_equal :spinel, machine.serving
    assert_equal ["build app", "build app -- --incremental"], spin_calls(root)
  end
end

# A toolchain that refuses --incremental leaves only the plain command, and
# spin's own check, which reads the files' times, decides. The binary is
# left at the launch of the build that wrote it (R25), so that the save made
# during that build is newer and spin compiles it.
LATE_SAVE_OLD_SPIN = <<~RUBY
  first = !File.exist?("spin-calls.txt")
  File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
  if ARGV.include?("--incremental")
    puts "spinel: unknown option '--incremental'"
    exit 1
  end
  if first
    File.write("app/article.rb", "class Article\n  # saved during the build\nend\n")
    sleep 0.05
    File.write("build/bin/app", "binary built from the sources before the save")
  end
  puts "built"
RUBY

test "without --incremental, a save in the last instant of a build leaves the binary older than the save" do
  scripts = { gen: "", cruby: READY, binary: BINARY_CHILD, spin: LATE_SAVE_OLD_SPIN }
  with_runner(scripts, watch_interval: 60, load_path: []) do |runner, _listener, root|
    Dir.mkdir(File.join(root, "app"))
    model = File.join(root, "app", "article.rb")
    File.write(model, "class Article\nend\n")
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    machine = Machine.new(runner)
    runner.watch
    machine.start
    runner.start_watching
    drive(runner, machine, 5) { machine.serving != :cruby }
    assert_equal :none, machine.serving
    assert File.mtime(binary) < File.mtime(model), "spin finds the binary older than the save"
    runner.watch.delivered
    drive(runner, machine, 5) { machine.serving == :spinel }
    assert_equal :spinel, machine.serving
    assert_equal ["build app", "build app -- --incremental", "build app"], spin_calls(root)
    assert File.mtime(binary) < File.mtime(model), "spin still finds the binary older than the save"
  end
end

# R25: a build of the session that ends ok leaves build/bin/NAME at the
# time read just before it was launched. The stand-in spin writes the binary
# after a delay; a save is made during the delay. The compiler read the
# sources at some moment after the launch, so the save is newer than the
# binary, which may lack it; a later session's first build then sees the
# binary stale and builds incrementally.
DELAYED_SPIN = <<~RUBY
  File.open(File.join(Dir.pwd, "spin-calls.txt"), "a") { |f| f.puts ARGV.join(" ") }
  sleep 0.2
  # "up to date": spin's own check found nothing to do.
  File.write("build/bin/app", "binary") unless File.exist?("up-to-date")
  puts "built"
  exit(File.exist?("fail") ? 1 : 0)
RUBY

# A second session's runner on the same application (the same listener
# will do: no child is started).
def next_session(runner, listener, root)
  other = StandIn.new(root: root, name: "app", port: listener.addr[1], load_path: [root],
                      listener: listener, out: StringIO.new, err: StringIO.new)
  other.scripts = runner.scripts
  yield other
ensure
  other&.cancel_build
  other&.close
end

test "a build that ends ok leaves the binary at its launch, older than a save made during it; the next session builds incrementally" do
  with_runner({ spin: DELAYED_SPIN }, load_path: []) do |runner, listener, root|
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    model = File.join(root, "article.rb")
    rec = Recorder.new
    before = fs_now(root)
    runner.start_build(1)
    after = fs_now(root)
    launch = File.mtime(File.join(root, "tmp", "cybertrain-dev", "build.pid"))
    sleep 0.05
    File.write(model, "# saved during the build\n")
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal [[:build, 1, true, "built\n"]], rec.events
    stamped = File.mtime(binary)
    assert stamped >= before && stamped <= after, "the binary is at the launch (#{stamped.to_f} not in #{before.to_f}..#{after.to_f})"
    assert stamped == launch, "the launch is build.pid's time (#{stamped.to_r} is not #{launch.to_r})"
    assert stamped < File.mtime(model), "the binary is older than the save"
    assert_equal ["build app"], spin_calls(root)
    next_session(runner, listener, root) do |other|
      other.start_build(1)
      poll_until(other, rec) { rec.events.size == 2 }
      assert_equal [:build, 1, true, "built\n"], rec.events[1]
    end
    assert_equal ["build app", "build app -- --incremental"], spin_calls(root)
  end
end

test "after a build of a session that ends ok, an untouched application's next session gets the plain command" do
  with_runner({ spin: DELAYED_SPIN }, load_path: []) do |runner, listener, root|
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    rec = Recorder.new
    before = fs_now(root)
    runner.start_build(1)
    after = fs_now(root)
    poll_until(runner, rec) { rec.events.size == 1 }
    stamped = File.mtime(binary)
    assert stamped >= before && stamped <= after, "the binary is at the launch (#{stamped.to_f} not in #{before.to_f}..#{after.to_f})"
    File.write(File.join(root, "up-to-date"), "")
    next_session(runner, listener, root) do |other|
      other.start_build(1)
      poll_until(other, rec) { rec.events.size == 2 }
    end
    assert_equal ["build app", "build app"], spin_calls(root)
    assert File.mtime(binary) == stamped, "the second session's build kept the binary's time"
  end
end

# The rule only ever moves the binary's time back: a build that left the
# binary alone (spin's "up to date") keeps its time exactly, which an
# up-to-date start (e2e step 16, the playground's image) depends on.
test "a build that ends ok without writing the binary keeps the binary's time exactly" do
  with_runner({ spin: DELAYED_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    earlier = Time.at(Time.now.to_i - 30, 123_456_789, :nsec)
    File.utime(earlier, earlier, binary)
    File.write(File.join(root, "up-to-date"), "")
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal [[:build, 1, true, "built\n"]], rec.events
    assert_equal ["build app"], spin_calls(root)
    assert File.mtime(binary) == earlier, "the binary's time moved: #{File.mtime(binary).to_r} is not #{earlier.to_r}"
  end
end

# A build that wrote the binary and then failed (a later step, a signal)
# is stamped too: the binary may lack a save made while it ran.
test "a failed build that wrote the binary leaves it at its launch too" do
  with_runner({ spin: DELAYED_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    File.write(File.join(root, "fail"), "")
    binary = File.join(root, "build", "bin", "app")
    rec = Recorder.new
    before = fs_now(root)
    runner.start_build(1)
    after = fs_now(root)
    poll_until(runner, rec) { rec.events.size == 1 }
    assert_equal [[:build, 1, false, "built\n"]], rec.events
    stamped = File.mtime(binary)
    assert stamped >= before && stamped <= after, "the binary is at the launch (#{stamped.to_f} not in #{before.to_f}..#{after.to_f})"
  end
end

# A cancelled build may have written the binary before its cancel (a save
# is what cancels it): the binary goes back to that build's launch too.
test "a cancelled build that wrote the binary leaves it at its launch" do
  spin = <<~RUBY
    File.write("build/bin/app", "binary")
    File.write("written", "")
    sleep 30
  RUBY
  with_runner({ spin: spin }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    before = fs_now(root)
    runner.start_build(1)
    after = fs_now(root)
    assert wait_for_file(File.join(root, "written"))
    assert File.mtime(binary) > after, "spin wrote the binary after the launch"
    runner.cancel_build
    stamped = File.mtime(binary)
    assert stamped >= before && stamped <= after, "the binary is at the launch (#{stamped.to_f} not in #{before.to_f}..#{after.to_f})"
  end
end

test "a binary whose time cannot be set does not fail the build; one line says so" do
  with_runner({ spin: DELAYED_SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    binary = File.join(root, "build", "bin", "app")
    rec = Recorder.new
    original = File.singleton_class.instance_method(:utime)
    File.singleton_class.send(:define_method, :utime) { |*_args| raise Errno::EPERM, binary }
    begin
      runner.start_build(1)
      poll_until(runner, rec) { rec.events.size == 1 }
    ensure
      File.singleton_class.send(:define_method, :utime, original)
    end
    assert_equal [[:build, 1, true, "built\n"]], rec.events
    lines = runner.out.string.lines.grep(/build\/bin\/app/)
    assert lines.size == 1, runner.out.string
    assert lines[0].start_with?("=> could not set the time of build/bin/app to its build's start: Operation not permitted"), lines[0]
  end
end

# spin rebuilds after a change to a Ruby file of a path dependency (the
# framework, among the -I directories), whichever file it is.
test "a Ruby file of another -I directory newer than the binary makes the build incremental" do
  Dir.mktmpdir("dev-server-framework") do |framework|
    FileUtils.mkdir_p(File.join(framework, "cybertrain"))
    base = File.join(framework, "cybertrain", "base.rb")
    File.write(base, "# the framework\n")
    past = Time.now - 120
    File.utime(past, past, base)
    with_runner({ spin: RECORDING_SPIN }, load_path: [framework]) do |runner, _listener, root|
      write_fresh_binary(root)
      rec = Recorder.new
      runner.start_build(1)
      poll_until(runner, rec) { rec.events.size == 1 }
      assert_equal ["build app"], spin_calls(root)
    end
    with_runner({ spin: RECORDING_SPIN }, load_path: [framework]) do |runner, _listener, root|
      write_fresh_binary(root)
      File.write(base, "# edited after the build\n")
      rec = Recorder.new
      runner.start_build(1)
      poll_until(runner, rec) { rec.events.size == 1 }
      assert_equal ["build app -- --incremental"], spin_calls(root)
    end
  end
end

# An application inside its framework's checkout (examples/blog in the
# repository): the framework's walk passes over the application's tree,
# which binary_stale? reads with its own build/ and tmp/ skipped. A Ruby
# file the application keeps under tmp/ or build/ is not a source.
test "the framework's walk passes over an application inside it, its build/ and tmp/ included" do
  Dir.mktmpdir("dev-server-framework") do |framework|
    framework = File.realpath(framework)
    FileUtils.mkdir_p(File.join(framework, "cybertrain"))
    base = File.join(framework, "cybertrain", "base.rb")
    File.write(base, "# the framework\n")
    past = Time.now - 120
    File.utime(past, past, base)
    with_runner({ spin: RECORDING_SPIN }, load_path: [framework], inside: framework) do |runner, _listener, root|
      write_fresh_binary(root)
      FileUtils.mkdir_p(File.join(root, "tmp", "cache"))
      later = Time.now + 60
      ["tmp/cache/compiled.rb", "build/generated.rb"].each do |path|
        File.write(File.join(root, path), "# written after the binary\n")
        File.utime(later, later, File.join(root, path))
      end
      rec = Recorder.new
      runner.start_build(1)
      poll_until(runner, rec) { rec.events.size == 1 }
      assert_equal ["build app"], spin_calls(root)
    end
  end
end

test "a toolchain that refuses --incremental still builds a fresh binary with the plain command, and a stale one without the flag" do
  with_runner({ spin: SPIN }, load_path: []) do |runner, _listener, root|
    write_fresh_binary(root)
    rec = Recorder.new
    runner.start_build(1)
    poll_until(runner, rec) { rec.events.size == 1 }
    File.write(File.join(root, "app.rb"), "# saved after the build\n")
    runner.start_build(2)
    poll_until(runner, rec) { rec.events.size == 2 }
    runner.start_build(3)
    poll_until(runner, rec) { rec.events.size == 3 }
    assert_equal [[:build, 1, true, "built\n"], [:build, 2, true, "built\n"], [:build, 3, true, "built\n"]], rec.events
    assert_equal ["build app", "build app -- --incremental", "build app", "build app"], spin_calls(root)
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

test "a spin that cannot be started is a failed build with the reason" do
  with_runner({}) do |runner, _listener, root|
    missing = File.join(root, "no-such-dir", "spin")
    runner.define_singleton_method(:build_command) { |_incremental| [missing, "build", "app"] }
    rec = Recorder.new
    runner.start_build(5)
    assert_nil runner.build_pid
    poll_until(runner, rec) { !rec.events.empty? }
    assert_equal 1, rec.events.size
    assert_equal [:build, 5, false], rec.events[0][0, 3]
    assert rec.events[0][3].start_with?("could not start #{missing}: No such file or directory"), rec.events[0][3]
    assert_equal rec.events[0][3], File.read(File.join(root, "tmp", "rebuild.log"))
    poll_for(runner, rec, 0.1)
    assert_equal 1, rec.events.size
  end
end

# spin removes its compiler's stderr file when the step it waits for fails;
# KILL to the whole group gave it no chance. The stand-in waits for its
# compiler (a grandchild), then cleans up, as spin does. The cancel comes
# once the stand-in compiler is up: a Ruby still booting can let a TERM go
# by unanswered for longer than BUILD_CLEANUP, which a C compiler never does.
test "cancel_build lets the build's leader clean up after its children are stopped" do
  spin = <<~RUBY
    compiler = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "File.write('compiler-up', ''); sleep 30")
    File.write(File.join(Dir.pwd, "pids.txt"), "\#{Process.pid} \#{compiler}")
    Process.wait(compiler)
    File.write(File.join(Dir.pwd, "cleaned"), "")
    exit 1
  RUBY
  with_runner({ spin: spin }) do |runner, _listener, root|
    runner.start_build(1)
    assert wait_for_file(File.join(root, "pids.txt"))
    assert wait_for { File.read(File.join(root, "pids.txt")).split.size == 2 }, "the build wrote both PIDs"
    pids = File.read(File.join(root, "pids.txt")).split.map(&:to_i)
    assert wait_for_file(File.join(root, "compiler-up"))
    took = elapsed { runner.cancel_build }
    assert File.exist?(File.join(root, "cleaned")), "the leader cleaned up"
    assert took < DevServer::BUILD_CLEANUP, "cancel_build took #{took} s"
    assert pids.all? { |pid| gone?(pid) }, "the build and its grandchild are gone"
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
    assert wait_for { File.read(File.join(root, "pids.txt")).split.size == 2 }, "the build wrote both PIDs"
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
    build = runner.build_pid
    runner.close
    assert File.exist?(path), "kept at close while the build runs"
    # A build that has ended unseen: close reaps it and removes the file.
    assert wait_for { gone?(build) }, "the build ended"
    runner.close
    refute File.exist?(path), "removed at close"
  end
end

# A stop that raised half-way (here the signal, after the runner had let go
# of the process) may leave the child or the build running: close keeps
# their PID files then, so that the next `cybertrain server` can still find
# and stop them; once they are gone the files go.
test "close keeps child.pid and build.pid while the process they name still runs" do
  with_runner({ cruby: READY, spin: "sleep 30\n" }) do |runner, _listener, root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    runner.start_child(:cruby, 1)
    runner.start_build(1)
    child = runner.child_pid
    build = runner.build_pid
    runner.define_singleton_method(:signal) { |_pid, _name| raise Errno::EIO }
    assert_raises("Errno::EIO") { runner.stop_child }
    original = DevServer.method(:stop_group)
    DevServer.define_singleton_method(:stop_group) { |_pgid, _grace| raise Errno::EIO }
    begin
      assert_raises("Errno::EIO") { runner.cancel_build }
    ensure
      DevServer.define_singleton_method(:stop_group, original)
    end
    assert_nil runner.child_pid
    assert_nil runner.build_pid
    runner.close
    assert_equal ["build.pid", "child.pid"], Dir.children(dev).sort
    assert_includes runner.out.string, "pid #{child}"
    assert_includes runner.out.string, "pid #{build}"
    [child, -build].each { |pid| Process.kill(:KILL, pid) }
    [child, build].each { |pid| Process.wait(pid) }
    runner.close
    assert_equal [], Dir.children(dev)
  end
end

# The group's id stays pinned by its leader, a zombie, until the final KILL
# has been sent: the leader is reaped only after it.
test "cancel_build reaps the build's leader only after the group's KILL" do
  with_runner({ spin: "trap(:TERM) { exit 1 }\nsleep 30\n" }) do |runner, _listener, root|
    runner.start_build(1)
    build = runner.build_pid
    assert wait_for_file(File.join(root, "tmp", "cybertrain-dev", "build.pid"))
    sleep 0.2 # the stand-in's trap is set
    seen = nil
    original = DevServer.method(:stop_group)
    DevServer.define_singleton_method(:stop_group) do |pgid, grace, &ended|
      original.call(pgid, grace, &ended)
      # Still there (a zombie) once stop_group is done: not reaped in it.
      seen = DevServer.alive?(pgid)
    end
    begin
      runner.cancel_build
    ensure
      DevServer.define_singleton_method(:stop_group, original)
    end
    assert_equal true, seen
    assert gone?(build)
  end
end

# Without /proc, and with a ps that answers nothing (busybox's rejects -p),
# nobody can tell whether the build's leader has ended: it is not taken for
# ended, so it still gets the cleanup wait and the group's TERM before the
# KILL, as with a ps that answers.
test "without /proc and a ps that fails, cancel_build still sends TERM before KILL" do
  spin = <<~RUBY
    trap(:TERM) { File.write(File.join(Dir.pwd, "got-term"), ""); exit 1 }
    File.write(File.join(Dir.pwd, "trapped"), "")
    sleep 30
  RUBY
  with_runner({ spin: spin }) do |runner, _listener, root|
    bin = File.join(root, "failing-ps")
    Dir.mkdir(bin)
    File.write(File.join(bin, "ps"), "#!/bin/sh\necho 'ps: unrecognized option: p' >&2\nexit 1\n")
    File.chmod(0o755, File.join(bin, "ps"))
    runner.start_build(1)
    build = runner.build_pid
    assert wait_for_file(File.join(root, "trapped"))
    saved = ENV["PATH"]
    original = DevServer.method(:proc_state)
    took = nil
    begin
      ENV["PATH"] = "#{bin}:#{saved}"
      DevServer.define_singleton_method(:proc_state) { |_pid| nil }
      refute DevServer.ended?(build), "a running leader is not taken for ended"
      took = elapsed { runner.cancel_build }
    ensure
      ENV["PATH"] = saved
      DevServer.define_singleton_method(:proc_state, original)
    end
    assert File.exist?(File.join(root, "got-term")), "the leader got TERM before the KILL"
    assert took >= DevServer::BUILD_CLEANUP, "the cleanup wait was kept (#{took} s)"
    assert took < Processes::CANCEL_GRACE + 0.5, "cancel_build took #{took} s"
    assert gone?(build)
  end
end

# Where /proc is absent (macOS) the zombie is found by ps; the wait for it
# is bounded either way.
test "ended? reads /proc: a running process is not ended, a zombie is, a reaped one is" do
  pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
  refute DevServer.ended?(pid)
  Process.kill(:KILL, pid)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  sleep 0.01 until DevServer.ended?(pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  assert DevServer.ended?(pid)
  assert_equal File.directory?("/proc/self") ? "Z" : nil, DevServer.proc_state(pid)
  Process.wait(pid)
  assert DevServer.ended?(pid)
ensure
  begin
    Process.kill(:KILL, pid)
    Process.wait(pid)
  rescue SystemCallError
    nil
  end
end

# A /proc/PID/stat read through File.read gives what answer gives.
def with_stat_read(answer)
  original = File.singleton_class.instance_method(:read)
  File.singleton_class.send(:define_method, :read) do |path, *rest, **options|
    path.to_s.match?(%r{/[0-9]+/stat\z}) ? answer.call : original.bind(self).call(path, *rest, **options)
  end
  yield
ensure
  File.singleton_class.send(:remove_method, :read)
end

# Only "no such process" means gone. /proc mounted with hidepid, or a
# container's restricted /proc, answers EACCES or EPERM for a process that
# runs: proc_state does not know then, and ended? asks ps. A /proc of the
# test's own (proc_state's second argument), so that the same assertions
# run where there is no /proc.
test "proc_state answers ended only for a process that is gone; other errors and odd text are unknown" do
  Dir.mktmpdir("dev-server-proc") do |proc_dir|
    Dir.mkdir(File.join(proc_dir, "self"))
    Dir.mkdir(File.join(proc_dir, "42"))
    stat = File.join(proc_dir, "42", "stat")
    File.write(stat, "42 (a (b) c) S 1 42")
    assert_equal "S", DevServer.proc_state(42, proc_dir)
    File.write(stat, "42 no parenthesis S 1")
    assert_nil DevServer.proc_state(42, proc_dir)
    File.write(stat, "42 (ruby) ")
    assert_nil DevServer.proc_state(42, proc_dir)
    assert_equal "X", DevServer.proc_state(43, proc_dir)
    with_stat_read(-> { raise Errno::ESRCH }) { assert_equal "X", DevServer.proc_state(42, proc_dir) }
    [Errno::EACCES, Errno::EPERM, Errno::EIO].each do |error|
      with_stat_read(-> { raise error }) { assert_nil DevServer.proc_state(42, proc_dir) }
    end
    Dir.rmdir(File.join(proc_dir, "self"))
    assert_nil DevServer.proc_state(42, proc_dir)
  end
  pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
  begin
    with_stat_read(-> { raise Errno::EACCES }) do
      refute DevServer.ended?(pid), "a running process whose stat cannot be read is not ended"
    end
  ensure
    Process.kill(:KILL, pid)
    Process.wait(pid)
  end
end

# --- gen, the state file, the lock --------------------------------------------

test "close removes the files' leftover .tmp copies too" do
  with_runner({}) do |runner, _listener, root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    FileUtils.mkdir_p(dev)
    files = Processes::FILES.flat_map { |file| [file, "#{file}.tmp"] }
    files.each { |file| File.write(File.join(dev, file), "1") }
    Dir.mkdir(File.join(dev, "ffi"))
    runner.close
    assert_equal ["ffi"], Dir.children(dev)
  end
end

# A poll that raises would end the watch's thread, and every later save
# would go unnoticed: it is logged once, and the watch goes on.
test "the file watch survives a poll that raises, says so once, and notices later saves" do
  Dir.mktmpdir("dev-server-watch") do |root|
    Dir.mkdir(File.join(root, "app"))
    model = File.join(root, "app", "article.rb")
    File.write(model, "class Article\nend\n")
    lines = Queue.new
    watch = DevServer::Watch.new(root, 0.02) { |line| lines << line }
    failing = true
    original = watch.method(:snapshot)
    watch.define_singleton_method(:snapshot) do
      raise Errno::EACCES, "app" if failing

      original.call
    end
    watch.start_watching
    begin
      sleep 0.2
      assert_equal 1, lines.size
      assert_equal "=> the file watch failed (Errno::EACCES: Permission denied - app); trying again", lines.pop
      refute watch.pending?, "no fresh look: what the watcher has seen decides"
      failing = false
      sleep 0.1
      assert_equal "=> the file watch works again", lines.pop
      save(model, "class Article\n  # saved\nend\n")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      paths = nil
      paths = watch.take until paths || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_equal ["app/article.rb"], paths
      watch.delivered
    ensure
      watch.close
    end
  end
end

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

# A gen that hangs: it starts a grandchild in its process group, writes
# both PIDs to "gen-pids", and sleeps; with the file "stubborn" both ignore
# TERM.
SLOW_GEN = <<~RUBY
  stubborn = File.exist?("stubborn")
  trap(:TERM) {} if stubborn
  grandchild = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "trap(:TERM) {} if \#{stubborn}; loop { sleep 1 }")
  File.write("gen-pids.tmp", "\#{Process.pid} \#{grandchild}")
  File.rename("gen-pids.tmp", "gen-pids")
  $stdout.puts "gen: working"
  $stdout.flush
  loop { sleep 1 }
RUBY

# R32: a stop asked while gen runs (the driver's flag, the stopping
# predicate) reaches gen: its whole group gets TERM, then KILL after the
# stop grace, and run_gen answers [false, "stopped"] without the "gen
# failed" message. Within the grace (0.3 s here) and a margin.
test "a stop asked while gen runs stops gen's process group within the grace" do
  [false, true].each do |stubborn|
    stop = false
    with_runner({ gen: SLOW_GEN }, stopping: -> { stop }) do |runner, _listener, root|
      runner.stop_grace = 0.3
      File.write(File.join(root, "stubborn"), "") if stubborn
      pids = []
      watcher = Thread.new do
        wait_for_file(File.join(root, "gen-pids"))
        pids = File.read(File.join(root, "gen-pids")).split.map(&:to_i)
        stop = true
      end
      result = nil
      took = elapsed { result = runner.run_gen }
      watcher.join
      assert_equal [false, "stopped"], result
      assert_equal 2, pids.size
      assert took < 2.0, "run_gen returned in #{took} s"
      assert took >= 0.3, "a gen that ignores TERM gets the grace (#{took} s)" if stubborn
      pids.each { |pid| assert gone?(pid), "pid #{pid} of gen is still running (stubborn: #{stubborn})" }
      assert runner.err.string.index("gen failed").nil?, "no gen failed message for a stop"
    ensure
      pids&.each do |pid|
        Process.kill(:KILL, pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end

# Without a stop, a gen that finishes is read whole, and what it left
# running in its process group does not outlive it.
test "run_gen reads gen's output as it comes and stops what gen left in its group" do
  gen = <<~RUBY
    grandchild = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "loop { sleep 1 }")
    File.write("left.tmp", grandchild.to_s)
    File.rename("left.tmp", "left")
    $stdout.write("x" * 200_000)
    $stderr.puts "\nwarning: done"
    exit 0
  RUBY
  with_runner({ gen: gen }) do |runner, _listener, root|
    ok, output = runner.run_gen
    assert ok
    assert_equal 200_000, output.count("x")
    assert_includes output, "warning: done"
    left = File.read(File.join(root, "left")).to_i
    assert wait_for(2) { gone?(left) }, "gen's leftover #{left} is still running"
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
