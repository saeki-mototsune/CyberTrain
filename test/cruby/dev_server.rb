require "cybertrain/test"
require "cybertrain/cli/dev_server"
require "cybertrain/http/server"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "fileutils"
require "timeout"

# `cybertrain server` under CRuby (cybertrain/cli/dev_server.rb): reading
# `spin flags`, the refusals at startup (a port in use, an application that
# does not load, a second supervisor, the leftovers of a killed one), and
# the driver loop with stand-in children. The driver runs in a process of
# its own, in a process group of its own, so that a test can send it (and
# its children) the signals a terminal sends. Ports are 0 or taken from a
# socket bound to 0. Every process a test starts is gone when it ends.
# CRuby only.

DevServer = Cybertrain::CLI::DevServer
REPO = File.expand_path("../..", __dir__)
RUBY_VERSION_ON_PATH = IO.popen(["ruby", "-e", "print RUBY_VERSION"], &:read)

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def wait_until(seconds = 5)
  deadline = now + seconds
  loop do
    done = yield
    return done if done || now > deadline

    sleep 0.02
  end
end

# Gone: no such process, or a zombie nobody has reaped yet.
def gone?(pid)
  Process.kill(0, pid)
  stat = IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], &:read).strip
  stat.empty? || stat.start_with?("Z")
rescue Errno::ESRCH
  true
end

def port_free?(port)
  TCPServer.new("127.0.0.1", port).close
  true
rescue Errno::EADDRINUSE
  false
end

# --- the load path ------------------------------------------------------------

test "load_path takes the -I directories of spin flags, in order" do
  assert_equal ["/a", "/b"], DevServer.load_path("--strict-require -I /a -I /b\n")
  assert_equal ["/a"], DevServer.load_path("-I/a")
  assert_equal [], DevServer.load_path("--strict-require\n")
end

# What spin 2026.11.04 printed in an application "sp ace/blog x" depending
# on a framework checkout "fw copy" (both under the scratch directory):
# directories are printed as they are, unquoted, so a directory runs to the
# next flag.
test "load_path keeps directories whose names have spaces, as spin prints them" do
  flags = "--strict-require -I /tmp/scratchpad/fw copy -I /tmp/scratchpad/sp ace/blog x\n"
  assert_equal ["/tmp/scratchpad/fw copy", "/tmp/scratchpad/sp ace/blog x"], DevServer.load_path(flags)
end

# --- startup ------------------------------------------------------------------

# A stand-in application: spin.toml, and a bin/app.rb that answers
# dev-address with the port in the file "port" (0 without it) and otherwise
# records that it was started.
def with_app
  Dir.mktmpdir("dev-server-startup") do |root|
    root = File.realpath(root)
    File.write(File.join(root, "spin.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n")
    Dir.mkdir(File.join(root, "bin"))
    File.write(File.join(root, "bin", "app.rb"), <<~RUBY)
      if ARGV[0] == "dev-address"
        port = File.exist?("port") ? File.read("port").strip : "0"
        puts "127.0.0.1 \#{port}"
      else
        File.write(File.join(Dir.pwd, "child-started"), "")
        sleep 30
      end
    RUBY
    yield root
  end
end

# DevServer.run in this process, with the toolchain and spin flags stood in
# for; returns the exit code and what it printed.
def run_server(root, argv = ["server"])
  out = StringIO.new
  saved = $stdout
  $stdout = out
  originals = %i[ensure_toolchain spin_flags].to_h { |name| [name, DevServer.method(name)] }
  DevServer.define_singleton_method(:ensure_toolchain) { true }
  DevServer.define_singleton_method(:spin_flags) { |_dir| "--strict-require -I #{REPO} -I #{root}\n" }
  # A regression that goes on to serve would block here: it fails instead.
  code = Timeout.timeout(20) { Dir.chdir(root) { DevServer.run(argv) } }
  [code, out.string]
ensure
  $stdout = saved
  originals&.each { |name, method| DevServer.define_singleton_method(name, method) }
end

# --- the framework's dev files ------------------------------------------------

# The installed gem, simulated: a directory with exactly the files
# cybertrain.gemspec lists, and a stand-in framework with the four dev files
# (copied from the checkout) and a cybertrain/preview.rb that does nothing.
# The probe runs `cybertrain server` from those alone (no RubyGems, no
# RUBYLIB, the checkout nowhere on the load path), with the toolchain check
# and `spin flags` stood in for, and prints where each cybertrain file came
# from, before the run, when spin flags is asked, and after it.
DEV_FILES = %w[supervision state_file watcher watched].freeze

PROBE = <<~'RUBY'
  gem_dir, framework = ARGV
  require "cybertrain/cli/dev_server"
  dev_server = Cybertrain::CLI::DevServer
  show = lambda do |label|
    $LOADED_FEATURES.grep(%r{/cybertrain/}).sort.each do |path|
      puts "#{label} #{path.sub(gem_dir, "GEM").sub(framework, "FRAMEWORK")}"
    end
  end
  show.call("required")
  dev_server.define_singleton_method(:ensure_toolchain) { true }
  dev_server.define_singleton_method(:spin_flags) do |root|
    show.call("flags")
    "--strict-require -I #{framework} -I #{root}\n"
  end
  Cybertrain::CLI.define_singleton_method(:run) do |argv|
    puts "compiled loop #{argv.join(" ")}"
    7
  end
  code = dev_server.run(["server", *ARGV[2..]])
  show.call("ran")
  puts "exit #{code}"
RUBY

def with_installed_gem
  Dir.mktmpdir("dev-server-gem") do |dir|
    dir = File.realpath(dir)
    gem_dir = File.join(dir, "gem")
    Gem::Specification.load(File.join(REPO, "cybertrain.gemspec")).files.each do |file|
      FileUtils.mkdir_p(File.dirname(File.join(gem_dir, file)))
      FileUtils.cp(File.join(REPO, file), File.join(gem_dir, file))
    end
    framework = File.join(dir, "framework")
    FileUtils.mkdir_p(File.join(framework, "cybertrain", "dev"))
    DEV_FILES.each do |file|
      FileUtils.cp(File.join(REPO, "cybertrain", "dev", "#{file}.rb"), File.join(framework, "cybertrain", "dev"))
    end
    File.write(File.join(framework, "cybertrain", "preview.rb"), "")
    File.write(File.join(dir, "probe.rb"), PROBE)
    yield dir, gem_dir, framework
  end
end

# Runs the probe in root; returns its output (stdout and stderr together).
# extra_env adds to (or overrides) the probe's environment.
def probe(dir, gem_dir, framework, root, *args, extra_env: {})
  env = { "RUBYLIB" => nil, "RUBYOPT" => nil }.merge(extra_env)
  command = [RbConfig.ruby, "--disable-gems", "-E", "UTF-8", "-I", gem_dir, File.join(dir, "probe.rb"), gem_dir, framework, *args]
  Open3.popen2e(env, *command, chdir: root, pgroup: true) do |stdin, out, waiter|
    stdin.close
    # A regression that goes on to serve would never end: it fails instead.
    unless waiter.join(20)
      Process.kill(:KILL, -waiter.pid)
      waiter.join
      return "probe did not end within 20 s:\n#{out.read}"
    end
    out.read
  end
end

test "the gem's files alone load the supervisor; the dev files come from the application's framework, after spin flags" do
  taken = TCPServer.new("127.0.0.1", 0)
  with_installed_gem do |dir, gem_dir, framework|
    with_app do |root|
      File.write(File.join(root, "port"), taken.addr[1].to_s)
      out = probe(dir, gem_dir, framework, root)
      refute out.include?("LoadError"), out
      # Stopped at the port, which this test holds: past the loading.
      assert_includes out, "error: port #{taken.addr[1]} on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}"
      assert_includes out, "exit 1"
      lines = out.lines.map(&:chomp)
      required = lines.grep(/\Arequired /)
      refute required.empty?, out
      # Only the gem's files at require.
      assert_equal [], required.reject { |line| line.start_with?("required GEM/") }
      # No dev file before spin flags names the framework.
      assert_equal [], lines.grep(%r{\Aflags .*/cybertrain/dev/})
      ran = lines.grep(/\Aran /)
      DEV_FILES.each do |file|
        assert_includes ran, "ran FRAMEWORK/cybertrain/dev/#{file}.rb"
      end
      assert_equal [], ran.grep(%r{cybertrain/dev/}).reject { |line| line.start_with?("ran FRAMEWORK/") }
      # The supervisor's own files stay the gem's.
      assert_equal [], ran.grep(%r{cybertrain/cli/}).reject { |line| line.start_with?("ran GEM/") }
    end
  end
ensure
  taken&.close
end

# The probe's output without its where-loaded lines.
def said(out)
  out.lines.map(&:chomp).grep_v(/\A(required|flags|ran) /)
end

# A framework whose cybertrain/preview.rb is there but whose supervision
# contract is not (a release between the two).
test "a framework without cybertrain/dev/supervision.rb runs the compiled loop, after one line" do
  with_installed_gem do |dir, gem_dir, framework|
    FileUtils.rm(File.join(framework, "cybertrain", "dev", "supervision.rb"))
    with_app do |root|
      out = probe(dir, gem_dir, framework, root, "4000")
      assert_equal ["preview unavailable: this application's cybertrain (#{framework}) has no cybertrain/dev/supervision.rb; " \
                    "running the compiled loop",
                    "compiled loop server 4000 --spinel", "exit 7"], said(out)
      refute File.exist?(File.join(root, "tmp", "cybertrain-dev")), "the supervisor wrote nothing"
      refute File.exist?(File.join(root, "child-started")), "no child was started"
    end
  end
end

# An application pinned to a release older than the preview: neither file.
# preview.rb is checked first, so that release gets that line alone.
test "a framework without cybertrain/preview.rb runs the compiled loop, after one line" do
  with_installed_gem do |dir, gem_dir, framework|
    FileUtils.rm(File.join(framework, "cybertrain", "preview.rb"))
    with_app do |root|
      out = probe(dir, gem_dir, framework, root, "4000")
      line = "preview unavailable: this application's cybertrain (#{framework}) has no cybertrain/preview.rb; running the compiled loop"
      assert_equal [line, "compiled loop server 4000 --spinel", "exit 7"], said(out)
      FileUtils.rm(File.join(framework, "cybertrain", "dev", "supervision.rb"))
      out = probe(dir, gem_dir, framework, root)
      assert_equal [line, "compiled loop server --spinel", "exit 7"], said(out)
      refute File.exist?(File.join(root, "tmp", "cybertrain-dev")), "the supervisor wrote nothing"
      refute File.exist?(File.join(root, "child-started")), "no child was started"
    end
  end
end

# A `ruby` first on PATH (the children's) that cannot load fiddle: the real
# one, with a directory ahead of its own whose fiddle.rb raises the
# LoadError a Ruby built without libffi gives. Yields the PATH to use.
def without_fiddle
  Dir.mktmpdir("dev-server-nofiddle") do |dir|
    real = IO.popen(["sh", "-c", "command -v ruby"], &:read).strip
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "fiddle.rb"), "raise LoadError, 'cannot load such file -- fiddle'\n")
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "ruby"), "#!/bin/sh\nexec '#{real}' -I'#{File.join(dir, "lib")}' \"$@\"\n")
    File.chmod(0o755, File.join(dir, "bin", "ruby"))
    yield "#{File.join(dir, "bin")}:#{ENV.fetch("PATH")}"
  end
end

test "a ruby on PATH that cannot load fiddle runs the compiled loop, after one line; the framework is checked first" do
  with_installed_gem do |dir, gem_dir, framework|
    with_app do |root|
      without_fiddle do |path|
        out = probe(dir, gem_dir, framework, root, "4000", extra_env: { "PATH" => path })
        assert_equal ["preview unavailable: Ruby cannot load fiddle (cybertrain doctor has the details); running the compiled loop",
                      "compiled loop server 4000 --spinel", "exit 7"], said(out)
        refute File.exist?(File.join(root, "tmp", "cybertrain-dev")), "the supervisor wrote nothing"
        refute File.exist?(File.join(root, "child-started")), "no child was started"
        FileUtils.rm(File.join(framework, "cybertrain", "preview.rb"))
        out = probe(dir, gem_dir, framework, root, extra_env: { "PATH" => path })
        assert_equal ["preview unavailable: this application's cybertrain (#{framework}) has no cybertrain/preview.rb; running the compiled loop",
                      "compiled loop server --spinel", "exit 7"], said(out)
      end
    end
  end
end

# The supervisor's own Ruby loads fiddle (the probe above runs it); only
# the children's is judged.
test "child_ruby asks the ruby on PATH for its version and whether it loads fiddle, in one run" do
  without_fiddle do |path|
    saved = ENV["PATH"]
    ENV["PATH"] = path
    begin
      assert_equal [RUBY_VERSION_ON_PATH, false], DevServer.child_ruby
    ensure
      ENV["PATH"] = saved
    end
  end
  assert_equal [RUBY_VERSION_ON_PATH, true], DevServer.child_ruby
end

test "a port that is in use is refused with today's wording, before any child" do
  taken = TCPServer.new("127.0.0.1", 0)
  port = taken.addr[1]
  with_app do |root|
    File.write(File.join(root, "port"), port.to_s)
    code, out = run_server(root)
    assert_equal 1, code
    assert_includes out, "error: port #{port} on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}"
    refute File.exist?(File.join(root, "child-started")), "no child was started"
    refute File.exist?(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid")), "no supervisor.pid is left"
  end
ensure
  taken&.close
end

test "a port argument overrides the application's port" do
  taken = TCPServer.new("127.0.0.1", 0)
  port = taken.addr[1]
  with_app do |root|
    code, out = run_server(root, ["server", port.to_s])
    assert_equal 1, code
    assert_includes out, "error: port #{port} on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}"
  end
ensure
  taken&.close
end

test "a PORT that is not a number, or a word after it, is refused" do
  with_app do |root|
    code, out = run_server(root, ["server", "abc"])
    assert_equal 1, code
    assert_includes out, "error: PORT must be a number"
    code, out = run_server(root, ["server", "4000", "extra"])
    assert_equal 1, code
    assert_includes out, "error: unexpected argument 'extra'"
  end
end

test "an application that does not load under CRuby is refused, naming --spinel" do
  with_app do |root|
    File.write(File.join(root, "bin", "app.rb"), "raise SyntaxError, 'unexpected end'\n")
    code, out = run_server(root)
    assert_equal 1, code
    assert_includes out, "error: "
    assert_includes out, "unexpected end"
    assert_includes out, "cybertrain server --spinel"
  end
end

test "a second supervisor for the same application is refused" do
  # The port is held too, so that a supervisor that went past the check
  # stops at the port instead of serving.
  taken = TCPServer.new("127.0.0.1", 0)
  with_app do |root|
    File.write(File.join(root, "port"), taken.addr[1].to_s)
    Dir.mkdir(File.join(root, "fake"))
    File.write(File.join(root, "fake", "cybertrain"), "sleep 30\n")
    other = Process.spawn(RbConfig.ruby, File.join(root, "fake", "cybertrain"), "server")
    begin
      FileUtils.mkdir_p(File.join(root, "tmp", "cybertrain-dev"))
      File.write(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid"), other.to_s)
      code, out = run_server(root)
      assert_equal 1, code
      assert_includes out, "error: a cybertrain server is already running here (pid #{other})"
      refute File.exist?(File.join(root, "child-started")), "no child was started"
      assert_equal other.to_s, File.read(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid"))
    ensure
      Process.kill(:KILL, other)
      Process.wait(other)
    end
  end
ensure
  taken&.close
end

test "a supervisor.pid naming a process that is not a cybertrain server is not a refusal" do
  taken = TCPServer.new("127.0.0.1", 0)
  with_app do |root|
    File.write(File.join(root, "port"), taken.addr[1].to_s)
    stranger = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    begin
      FileUtils.mkdir_p(File.join(root, "tmp", "cybertrain-dev"))
      File.write(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid"), stranger.to_s)
      code, out = run_server(root)
      # Past the check: it stops at the port, which this test holds.
      assert_equal 1, code
      assert_includes out, Cybertrain::PortInUse::IN_USE
      refute gone?(stranger), "the stranger is left alone"
    ensure
      Process.kill(:KILL, stranger)
      Process.wait(stranger)
    end
  end
ensure
  taken&.close
end

test "a leftover child of this application is stopped; another process is left alone" do
  with_app do |root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    FileUtils.mkdir_p(dev)
    leftover = Process.spawn(RbConfig.ruby, File.join(root, "bin", "app.rb"), "4000", chdir: root)
    stranger = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    begin
      assert wait_until { File.exist?(File.join(root, "child-started")) }
      File.write(File.join(dev, "child.pid"), stranger.to_s)
      DevServer.stop_leftover_child(root, "app", StringIO.new)
      refute gone?(stranger), "a process that is not this application's child is left alone"
      File.write(File.join(dev, "child.pid"), leftover.to_s)
      log = StringIO.new
      DevServer.stop_leftover_child(root, "app", log)
      assert gone?(leftover), "the leftover child is stopped"
      assert_includes log.string, "pid #{leftover}"
      refute File.exist?(File.join(dev, "child.pid"))
    ensure
      [leftover, stranger].each do |pid|
        Process.kill(:KILL, pid)
      rescue Errno::ESRCH
        nil
      end
      [leftover, stranger].each { |pid| Process.wait(pid) }
    end
  end
end

# P14 by whole arguments: a process is this application's child only when it
# runs this application's bin/app.rb (a relative path resolved against the
# process's directory) or is its build/bin/app. Each case is a live process
# named by child.pid; startup stops it or leaves it alone.
test "only this application's bin/app.rb or build/bin/app is taken for a leftover child" do
  with_app do |root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    FileUtils.mkdir_p(dev)
    FileUtils.mkdir_p(File.join(root, "build", "bin"))
    sleeper = "trap(:TERM) { exit 0 }\nsleep 30\n"
    File.write(File.join(root, "sleeper.rb"), sleeper)
    ["build/bin/app", "build/bin/appx"].each do |path|
      File.write(File.join(root, path), "#!#{RbConfig.ruby}\n#{sleeper}")
      File.chmod(0o755, File.join(root, path))
    end
    Dir.mktmpdir("dev-server-other") do |other|
      other = File.realpath(other)
      FileUtils.mkdir_p(File.join(other, "bin"))
      File.write(File.join(other, "bin", "app.rb"), sleeper)
      cases = [
        # [command, directory, stopped?]
        [[RbConfig.ruby, "-E", "UTF-8", "-I", root, "-r", "socket", "bin/app.rb", "4000"], root, true],
        [[RbConfig.ruby, File.join(root, "bin", "app.rb"), "4000"], other, true],
        [["build/bin/app", "4000"], root, true],
        [[File.join(root, "build", "bin", "app"), "4000"], other, true],
        # An editor-like process naming the file, another file, another
        # application's bin/app.rb, a binary whose name starts the same.
        [[RbConfig.ruby, "sleeper.rb", "bin/app.rb"], root, false],
        [[RbConfig.ruby, "-e", "sleep 30", "bin/app.rb"], root, false],
        [[RbConfig.ruby, "bin/app.rb", "4000"], other, false],
        [["build/bin/appx", "4000"], root, false]
      ]
      cases.each do |command, dir, stopped|
        pid = Process.spawn(*command, chdir: dir, out: File::NULL)
        begin
          # Until the exec: a forked process shows this test's command line.
          mine = DevServer.command_line(Process.pid)
          wait_until { DevServer.command_line(pid) != mine }
          File.write(File.join(dev, "child.pid"), pid.to_s)
          DevServer.stop_leftover_child(root, "app", StringIO.new)
          if stopped
            assert gone?(pid), "stopped: #{command.join(" ")} in #{dir}"
          else
            refute gone?(pid), "left alone: #{command.join(" ")} in #{dir}"
          end
        ensure
          begin
            Process.kill(:KILL, pid)
          rescue Errno::ESRCH
            nil
          end
          Process.wait(pid)
        end
      end
    end
  end
end

test "only this application's `spin build NAME` is taken for a leftover build" do
  with_app do |root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    FileUtils.mkdir_p(dev)
    Dir.mktmpdir("dev-server-other") do |other|
      other = File.realpath(other)
      spin = File.join(other, "spin")
      File.write(spin, "#!#{RbConfig.ruby}\nsleep 30\n")
      File.chmod(0o755, spin)
      cases = [
        [[spin, "build", "app", "--", "--incremental"], root, true],
        [[spin, "build", "app"], root, true],
        [[spin, "build", "app"], other, false],
        [[spin, "build", "apps"], root, false],
        [[spin, "run", "app"], root, false],
        [[RbConfig.ruby, "-e", "sleep 30", "spin", "build", "app"], root, false]
      ]
      cases.each do |command, dir, stopped|
        pid = Process.spawn(*command, chdir: dir, pgroup: true)
        begin
          mine = DevServer.command_line(Process.pid)
          wait_until { DevServer.command_line(pid) != mine }
          File.write(File.join(dev, "build.pid"), pid.to_s)
          log = StringIO.new
          DevServer.stop_leftover_build(root, "app", log)
          if stopped
            assert gone?(pid), "stopped: #{command.join(" ")} in #{dir}"
            assert_includes log.string, "(pid #{pid})"
          else
            refute gone?(pid), "left alone: #{command.join(" ")} in #{dir}"
          end
          refute File.exist?(File.join(dev, "build.pid"))
        ensure
          begin
            Process.kill(:KILL, pid)
          rescue Errno::ESRCH
            nil
          end
          Process.wait(pid)
        end
      end
    end
  end
end

test "program finds a ruby interpreter's script after its options" do
  assert_equal ["bin/app.rb", ["4000"]],
               DevServer.program(["/usr/bin/ruby", "-E", "UTF-8", "-I/a", "-I", "/b c", "-r", "cybertrain/preview", "bin/app.rb", "4000"])
  assert_equal ["build/bin/app", ["4000"]], DevServer.program(["build/bin/app", "4000"])
  assert_equal ["x.rb", []], DevServer.program(["ruby3.3", "-w", "--", "x.rb"])
  assert_equal [nil, []], DevServer.program(["ruby", "-e", "sleep", "bin/app.rb"])
  assert_equal [nil, []], DevServer.program(["ruby", "-W0"])
  assert_equal [nil, []], DevServer.program([])
end

# Where a process's directory cannot be read (no /proc), a relative path
# counts only when written as the supervisor spawns it.
test "without the process's directory a relative path must be the one the supervisor spawns" do
  original = DevServer.method(:process_cwd)
  DevServer.define_singleton_method(:process_cwd) { |_pid| nil }
  assert DevServer.names?(1, "bin/app.rb", "/srv/app", "bin/app.rb")
  refute DevServer.names?(1, "./bin/app.rb", "/srv/app", "bin/app.rb")
  refute DevServer.names?(1, "bin/appx.rb", "/srv/app", "bin/app.rb")
  assert DevServer.names?(1, "/srv/app/bin/../bin/app.rb", "/srv/app", "bin/app.rb")
  refute DevServer.names?(1, "/srv/other/bin/app.rb", "/srv/app", "bin/app.rb")
ensure
  DevServer.define_singleton_method(:process_cwd, original)
end

# `ps` cuts its output at $COLUMNS (or the terminal's width) unless told not
# to; the leftover's bin/app.rb comes after every -I directory.
test "a leftover child is recognised with COLUMNS=40 exported, through ps as well" do
  with_app do |root|
    dev = File.join(root, "tmp", "cybertrain-dev")
    FileUtils.mkdir_p(dev)
    dirs = (1..4).map { |i| File.join(root, "a-long-load-path-directory-#{i}") }
    command = [RbConfig.ruby, "-E", "UTF-8", *dirs.map { |dir| "-I#{dir}" }, "bin/app.rb", "4000"]
    saved = ENV["COLUMNS"]
    ENV["COLUMNS"] = "40"
    leftover = Process.spawn(*command, chdir: root)
    begin
      assert wait_until { File.exist?(File.join(root, "child-started")) }
      assert_equal command, DevServer.command_line(leftover)
      assert_equal command, DevServer.ps_command_line(leftover)
      File.write(File.join(dev, "child.pid"), leftover.to_s)
      DevServer.stop_leftover_child(root, "app", StringIO.new)
      assert gone?(leftover), "the leftover child is stopped"
    ensure
      ENV["COLUMNS"] = saved
      begin
        Process.kill(:KILL, leftover)
      rescue Errno::ESRCH
        nil
      end
      Process.wait(leftover)
    end
  end
end

test "a second supervisor is recognised with COLUMNS=40 exported" do
  taken = TCPServer.new("127.0.0.1", 0)
  with_app do |root|
    File.write(File.join(root, "port"), taken.addr[1].to_s)
    fake = File.join(root, "a-long-directory-name-that-pushes-the-command-past-forty-columns", "cybertrain")
    FileUtils.mkdir_p(File.dirname(fake))
    File.write(fake, "sleep 30\n")
    saved = ENV["COLUMNS"]
    ENV["COLUMNS"] = "40"
    other = Process.spawn(RbConfig.ruby, fake, "server")
    begin
      FileUtils.mkdir_p(File.join(root, "tmp", "cybertrain-dev"))
      File.write(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid"), other.to_s)
      wait_until { DevServer.command_line(other).include?("server") }
      code, out = run_server(root)
      assert_equal 1, code
      assert_includes out, "error: a cybertrain server is already running here (pid #{other})"
    ensure
      ENV["COLUMNS"] = saved
      Process.kill(:KILL, other)
      Process.wait(other)
    end
  end
ensure
  taken&.close
end

# --- the driver ---------------------------------------------------------------

# The child stand-in: dev-address answers with the port in the file "port"
# (0 without it); with "leftover" it is a child a killed supervisor left,
# listening on a port of its own; otherwise it serves its kind's name on the
# inherited listener once ready. TERM ends it; INT, by default, too.
CHILD = <<~'RUBY'
  require "socket"
  kind = File.basename($PROGRAM_NAME) == "app.rb" ? "cruby" : "spinel"
  if ARGV[0] == "dev-address"
    port = File.exist?("port") ? File.read("port").strip : "0"
    puts "127.0.0.1 #{port}"
    exit 0
  end
  if ARGV[0] == "leftover"
    server = TCPServer.new("127.0.0.1", 0)
    File.write("port.tmp", server.addr[1].to_s)
    File.rename("port.tmp", "port")
    sleep 60
  end
  trap(:TERM) { exit 0 }
  server = TCPServer.for_fd(Integer(ENV.fetch("CYBERTRAIN_DEV_LISTEN_FD")))
  File.write(ENV.fetch("CYBERTRAIN_DEV_READY_FILE"), ENV.fetch("CYBERTRAIN_DEV_GENERATION"))
  loop do
    client = server.accept
    client.readpartial(4096)
    client.write("HTTP/1.1 200 OK\r\nContent-Length: #{kind.size}\r\nConnection: close\r\n\r\n#{kind}")
    client.close
  end
RUBY

# The spin stand-in on PATH: `spin flags` names the checkout and the
# application; `spin build` writes build/bin/app (the child stand-in, as
# the binary) after a moment, or never finishes when the file "slow-build"
# exists: it then starts a grandchild (a compiler, in the build's process
# group) and writes both PIDs to "build-pids".
SPIN = <<~RUBY
  #!#{RbConfig.ruby}
  root = Dir.pwd
  case ARGV[0]
  when "flags"
    puts "--strict-require -I #{REPO} -I \#{root}"
  when "build"
    if File.exist?("slow-build")
      grandchild = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 60")
      File.write("build-pids.tmp", "\#{Process.pid} \#{grandchild}")
      File.rename("build-pids.tmp", "build-pids")
      sleep 60
    end
    # Not before the driver has seen the CRuby child ready: a binary that
    # came first would take the port from a child never reported ready.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until (File.read("log").include?("=> preview: CRuby (") rescue false) ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    require "fileutils"
    FileUtils.mkdir_p("build/bin")
    File.write("build/bin/app.tmp", "#!#{RbConfig.ruby}\\n" + File.read("bin/app.rb"))
    File.chmod(0o755, "build/bin/app.tmp")
    File.rename("build/bin/app.tmp", "build/bin/app")
    puts "built"
  else
    exit 1
  end
RUBY

# The supervisor's own entry, as exe/cybertrain calls it, with the
# toolchain check stood in for; every exit the runner reports to the
# machine is printed, so a test sees a death the driver should not report.
HARNESS = <<~RUBY
  require "cybertrain/cli/dev_server"
  Cybertrain::CLI::DevServer.define_singleton_method(:ensure_toolchain) { true }
  Cybertrain::CLI::DevServer::Machine.prepend(Module.new do
    def on_child_exit(kind, generation, info)
      puts "EVENT on_child_exit \#{kind} \#{generation}"
      $stdout.flush
      super
    end
  end)
  exit Cybertrain::CLI::DevServer.run(ARGV)
RUBY

# A stand-in application for the driver; yields its directory and a
# function that starts the supervisor (its own process group; its output
# in the file "log"), then makes sure nothing that names the directory is
# left running.
def with_driver_app
  Dir.mktmpdir("dev-server-driver") do |root|
    root = File.realpath(root)
    File.write(File.join(root, "spin.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n")
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.mkdir_p(File.join(root, "fakebin"))
    File.write(File.join(root, "bin", "app.rb"), CHILD)
    File.write(File.join(root, "bin", "gen.rb"), "exit 0\n")
    File.write(File.join(root, "fakebin", "spin"), SPIN)
    File.chmod(0o755, File.join(root, "fakebin", "spin"))
    File.write(File.join(root, "harness.rb"), HARNESS)
    pids = []
    start = lambda do |*args|
      env = { "PATH" => "#{File.join(root, "fakebin")}:#{ENV.fetch("PATH")}" }
      pid = Process.spawn(env, RbConfig.ruby, "-E", "UTF-8", "-I", REPO, File.join(root, "harness.rb"), "server", *args,
                          chdir: root, in: File::NULL, [:out, :err] => [File.join(root, "log"), "w"], pgroup: true)
      pids << pid
      pid
    end
    begin
      yield root, start
    ensure
      pids.each do |pid|
        Process.kill(:KILL, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      pids.each do |pid|
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
      stray = IO.popen(["pgrep", "-f", root], &:read).split.map(&:to_i)
      stray.each do |pid|
        Process.kill(:KILL, pid)
      rescue Errno::ESRCH
        nil
      end
      # Not over a failure already on its way: that one says more.
      assert_equal [], stray if $!.nil?
    end
  end
end

def log_of(root)
  File.read(File.join(root, "log"))
rescue Errno::ENOENT
  ""
end

def listening_port(root)
  log_of(root)[%r{\* Listening on http://127\.0\.0\.1:(\d+)}, 1]&.to_i
end

def get(port)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
  sock.read.split("\r\n\r\n", 2)[1]
ensure
  sock&.close
end

# The supervisor's exit status, within seconds, or nil (then it is killed).
def exit_status(pid, seconds = 5)
  Timeout.timeout(seconds) { Process.wait2(pid)[1] }
rescue Timeout::Error
  nil
end

def dev_files(root)
  Dir.children(File.join(root, "tmp", "cybertrain-dev")).sort
rescue Errno::ENOENT
  []
end

test "the driver starts the CRuby child, hands the port to the binary, and stops on TERM" do
  with_driver_app do |root, start|
    pid = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    port = listening_port(root)
    assert port, "the banner names the port"
    out = log_of(root)
    assert_includes out, "=> Booting cybertrain #{Cybertrain::VERSION}"
    assert_includes out, "=> preview: CRuby #{IO.popen(["ruby", "-e", "print RUBY_VERSION"], &:read)}"
    assert_equal 1, out.scan("=> Booting").size
    assert_equal pid.to_s, File.read(File.join(root, "tmp", "cybertrain-dev", "supervisor.pid"))
    assert wait_until(10) { log_of(root).include?("=> spinel: ready") }, "the binary took the port:\n#{log_of(root)}"
    assert_equal "spinel", get(port)
    Process.kill(:TERM, pid)
    status = exit_status(pid)
    assert status, "the supervisor stopped within 5 s"
    assert_equal 0, status.exitstatus
    assert_equal [], dev_files(root) - ["ffi"]
    assert port_free?(port), "the port is free"
    refute_event(root)
  end
end

def refute_event(root)
  refute log_of(root).include?("EVENT on_child_exit"), "no child's exit was reported:\n#{log_of(root)}"
end

# A closed terminal sends HUP to its process group: the same stop as TERM
# (exit 0), with its cleanup, not death by the default action.
test "HUP stops it like TERM: exit 0, the files removed, the port free" do
  with_driver_app do |root, start|
    File.write(File.join(root, "slow-build"), "")
    pid = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    port = listening_port(root)
    Process.kill(:HUP, pid)
    status = exit_status(pid)
    assert status, "the supervisor stopped within 5 s"
    assert_equal 0, status.exitstatus
    assert_equal [], dev_files(root) - ["ffi"]
    assert port_free?(port), "the port is free"
    refute_event(root)
  end
end

test "INT to the whole process group ends it with 130; the children's deaths are not reported" do
  with_driver_app do |root, start|
    File.write(File.join(root, "slow-build"), "")
    pid = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    port = listening_port(root)
    assert_equal "cruby", get(port)
    # A terminal's Ctrl-C: the supervisor and its children (the build has a
    # group of its own) all get INT; the child dies of it at once.
    Process.kill(:INT, -pid)
    status = exit_status(pid)
    assert status, "the supervisor stopped within 5 s"
    assert_equal 130, status.exitstatus
    assert_equal [], dev_files(root) - ["ffi"]
    assert port_free?(port), "the port is free"
    refute_event(root)
  end
end

# The PIDs the slow stand-in build wrote: its own and its grandchild's.
def build_pids(root)
  assert wait_until(10) { File.exist?(File.join(root, "build-pids")) }, "the build started:\n#{log_of(root)}"
  File.read(File.join(root, "build-pids")).split.map(&:to_i)
end

# The grandchild's command line does not name the directory, so the sweep
# at with_driver_app's end would not see it: it is checked here.
def assert_gone_within(pids, seconds = 2)
  wait_until(seconds) { pids.all? { |pid| gone?(pid) } }
  assert pids.all? { |pid| gone?(pid) }, "gone: #{pids.reject { |pid| gone?(pid) }.inspect} of #{pids.inspect}"
ensure
  pids.each do |pid|
    Process.kill(:KILL, pid)
  rescue Errno::ESRCH
    nil
  end
end

test "TERM while the build runs: the build's group is stopped too" do
  with_driver_app do |root, start|
    File.write(File.join(root, "slow-build"), "")
    pid = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    build = build_pids(root)
    Process.kill(:TERM, pid)
    status = exit_status(pid)
    assert status, "the supervisor stopped within 5 s"
    assert_equal 0, status.exitstatus
    assert_equal [], dev_files(root) - ["ffi"]
    refute_event(root)
    assert_gone_within(build)
  end
end

# R21: a supervisor killed outright leaves its build running in a group of
# its own; the next one finds it in build.pid and stops the whole group
# before it starts a build of its own.
test "a build left by a killed supervisor is stopped, grandchild included" do
  with_driver_app do |root, start|
    File.write(File.join(root, "slow-build"), "")
    first = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    build = build_pids(root)
    assert_equal build[0].to_s, File.read(File.join(root, "tmp", "cybertrain-dev", "build.pid"))
    Process.kill(:KILL, first)
    Process.wait(first)
    File.delete(File.join(root, "build-pids"))
    second = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") && File.exist?(File.join(root, "build-pids")) },
           "the second supervisor serves and builds:\n#{log_of(root)}"
    assert_includes log_of(root), "=> stopping a build left by an earlier cybertrain server (pid #{build[0]})"
    assert_gone_within(build, 0.5)
    rebuilt = build_pids(root)
    assert_equal rebuilt[0].to_s, File.read(File.join(root, "tmp", "cybertrain-dev", "build.pid"))
    Process.kill(:TERM, second)
    assert_equal 0, exit_status(second)&.exitstatus
    assert_gone_within(rebuilt)
  end
end

test "a leftover child holding the port is stopped, and the new supervisor serves on it" do
  with_driver_app do |root, start|
    leftover = Process.spawn(RbConfig.ruby, File.join(root, "bin", "app.rb"), "leftover", chdir: root)
    Process.detach(leftover)
    assert wait_until { File.exist?(File.join(root, "port")) }
    port = File.read(File.join(root, "port")).to_i
    FileUtils.mkdir_p(File.join(root, "tmp", "cybertrain-dev"))
    File.write(File.join(root, "tmp", "cybertrain-dev", "child.pid"), leftover.to_s)
    pid = start.call
    assert wait_until(10) { log_of(root).include?("=> preview: CRuby (") }, "the CRuby child became ready:\n#{log_of(root)}"
    assert gone?(leftover), "the leftover is gone"
    assert_equal port, listening_port(root)
    Process.kill(:TERM, pid)
    assert_equal 0, exit_status(pid)&.exitstatus
  end
end

# A runner whose processes are scripted: the first poll receives the INT
# a terminal's Ctrl-C sends (the trap sets the driver's flag), then
# reports the CRuby child dead of it, as a child in the same process group
# would be. Records what the machine asks of it.
class ScriptedRunner
  attr_reader :calls

  def initialize(**_options)
    @calls = []
    @polls = 0
  end

  def watch = nil
  def start_watching = nil
  def wait_for_activity(_timeout) = nil

  def poll(machine)
    @polls += 1
    return unless @polls == 1

    Process.kill(:INT, Process.pid)
    # The trap runs at the next interrupt check, at the latest in a sleep.
    sleep 0.05
    machine.on_child_exit(:cruby, 1, "signal 2 (INT)")
  end

  def close = @calls << [:close]
  def run_gen = [true, ""]
  def start_child(kind, generation) = @calls << [:start_child, kind, generation]
  def stop_child = @calls << [:stop_child]
  def start_build(generation) = @calls << [:start_build, generation]
  def cancel_build = @calls << [:cancel_build]
  def hold(title, _text) = @calls << [:hold, title]
  def release_hold = @calls << [:release_hold]
  def write_state(*) = nil
  def log(_line) = nil
  def build_locked? = false
  def change_pending? = false
  def now = 0.0
end

test "a child that dies of the Ctrl-C that stops the driver is not reported as a death" do
  runner = ScriptedRunner.new
  original = DevServer.method(:new_runner)
  DevServer.define_singleton_method(:new_runner) { |**_options| runner }
  listener = TCPServer.new("127.0.0.1", 0)
  saved = $stdout
  $stdout = StringIO.new
  code = nil
  Dir.mktmpdir("dev-server-gate") do |root|
    code = Timeout.timeout(20) { DevServer.serve(root, "app", [], "127.0.0.1", listener) }
  end
  $stdout = saved
  assert_equal 130, code
  refute runner.calls.any? { |call| call[0] == :hold }, "the death put up no hold page: #{runner.calls.inspect}"
  assert_equal [[:start_child, :cruby, 1], [:start_build, 1], [:cancel_build], [:stop_child], [:release_hold], [:close]],
               runner.calls
  assert listener.closed?, "the socket is closed"
ensure
  $stdout = saved
  DevServer.define_singleton_method(:new_runner, original)
end

# A stop that raises (here the build's cancel) still has the runner remove
# the files (its close), closes the socket and restores the signal handlers; the error comes out
# after them.
class RaisingRunner < ScriptedRunner
  def cancel_build
    super
    raise "the cancel failed"
  end
end

test "every cleanup step runs when the machine's stop raises" do
  runner = RaisingRunner.new
  original = DevServer.method(:new_runner)
  DevServer.define_singleton_method(:new_runner) { |**_options| runner }
  listener = TCPServer.new("127.0.0.1", 0)
  saved = $stdout
  $stdout = StringIO.new
  before = trap(:INT, "DEFAULT")
  trap(:INT, before)
  raised = nil
  Dir.mktmpdir("dev-server-cleanup") do |root|
    begin
      Timeout.timeout(20) { DevServer.serve(root, "app", [], "127.0.0.1", listener) }
    rescue RuntimeError => e
      raised = e.message
    end
  end
  $stdout = saved
  assert_equal "the cancel failed", raised
  assert_equal [:close], runner.calls.last
  assert listener.closed?, "the socket is closed"
  assert_equal before, trap(:INT, before)
ensure
  $stdout = saved
  DevServer.define_singleton_method(:new_runner, original)
end

# The children run the `ruby` on PATH, which a version manager can make
# another CRuby than the supervisor's: the banner names theirs, and the
# fiddle check is theirs.
test "the banner's CRuby version is the one the children run" do
  Dir.mktmpdir("dev-server-ruby") do |dir|
    File.write(File.join(dir, "ruby"), "#!/bin/sh\nprintf '9.8.7 fiddle'\n")
    File.chmod(0o755, File.join(dir, "ruby"))
    saved = ENV["PATH"]
    ENV["PATH"] = "#{dir}:#{saved}"
    begin
      assert_equal ["9.8.7", true], DevServer.child_ruby
      File.write(File.join(dir, "ruby"), "#!/bin/sh\nprintf '9.8.7'\n")
      assert_equal ["9.8.7", false], DevServer.child_ruby
      File.write(File.join(dir, "ruby"), "#!/bin/sh\nprintf '9.8.7 fiddle'\nexit 1\n")
      assert_equal ["(unknown version)", false], DevServer.child_ruby
      File.write(File.join(dir, "ruby"), "#!/bin/sh\nexit 1\n")
      assert_equal ["(unknown version)", false], DevServer.child_ruby
      ENV["PATH"] = File.join(dir, "nothing-here")
      assert_equal ["(unknown version)", false], DevServer.child_ruby
    ensure
      ENV["PATH"] = saved
    end
  end
end

# The rule the driver applies to the runner's events once a stop was asked:
# a child that dies of the same Ctrl-C is part of stopping, not a death.
test "the gate passes events to the machine until a stop is asked" do
  calls = []
  machine = Object.new
  %i[on_change on_child_ready on_child_exit on_build_done].each do |event|
    machine.define_singleton_method(event) { |*args| calls << [event, *args] }
  end
  stopping = false
  gate = DevServer::Gate.new(machine) { stopping }
  gate.on_child_ready(:cruby, 1)
  stopping = true
  gate.on_child_exit(:cruby, 1, "signal 2 (INT)")
  gate.on_build_done(1, true, "")
  gate.on_change(["app/models/a.rb"])
  gate.on_child_ready(:cruby, 1)
  assert_equal [[:on_child_ready, :cruby, 1]], calls
end

Cybertrain::Test.run!
