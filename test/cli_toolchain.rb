require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli/toolchain"

# Toolchain without a network, a compiler or a real Spinel: the version
# parsing, the managed layout under CYBERTRAIN_HOME, the lock, and how a
# spinel of the pinned release is picked from PATH / CYBERTRAIN_SPINEL_HOME /
# the managed copy. Fake spinel/spin shell scripts stand in for the
# binaries. Every path is under a fresh temp dir; absolute paths are
# compared, never printed (macOS's /bin/sh prints `command -v` hits as
# absolute paths, dash prints them as given), so the output is the same on
# every machine. CRuby-portable.
TMP = Dir.mktmpdir("cybertrain-cli-toolchain")
Dir.chdir(TMP)
ORIGINAL_PATH = ENV["PATH"].to_s
ORIGINAL_HOME = ENV["HOME"].to_s
ENV["CYBERTRAIN_HOME"] = ""
ENV["CYBERTRAIN_SPINEL_HOME"] = ""
ENV["CC"] = ""
TAG = Cybertrain::SPINEL_TAG
Toolchain = Cybertrain::CLI::Toolchain

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  ENV["PATH"] = ORIGINAL_PATH
  ENV["HOME"] = ORIGINAL_HOME
  Dir.chdir("/")
  rm_tree(TMP)
end

# Pure Ruby: some tests below empty PATH, so /bin/mkdir cannot be relied on.
def mkdir_p(dir)
  parent = File.dirname(dir)
  mkdir_p(parent) unless parent == "." || parent == "/" || File.directory?(parent)
  Dir.mkdir(dir) unless File.directory?(dir)
end

# An absolute path under the temp dir. (One argument, joined by the
# caller: a splatted `File.join(Dir.pwd, *parts)` passes only the first
# element under Spinel 2026.09.12.)
def here(path)
  File.join(Dir.pwd, path)
end

# Every test starts from the same environment, whatever an earlier one
# (or an earlier failure) left behind.
def reset_env
  ENV["PATH"] = ORIGINAL_PATH
  ENV["HOME"] = ORIGINAL_HOME
  ENV["CYBERTRAIN_HOME"] = ""
  ENV["CYBERTRAIN_SPINEL_HOME"] = ""
  ENV["CC"] = ""
end

# A directory holding a `spinel` that prints the given release and a `spin`.
def fake_toolchain(dir, release)
  mkdir_p(dir)
  File.write(File.join(dir, "spinel"), "#!/bin/sh\necho \"spinel abc123def456 (#{release}) [cc 13.3.0]\"\n")
  File.write(File.join(dir, "spin"), "#!/bin/sh\necho spin\n")
  File.chmod(0o755, File.join(dir, "spinel"))
  File.chmod(0o755, File.join(dir, "spin"))
end

fake_toolchain("good", TAG)
fake_toolchain("old", "2026.09.08")
fake_toolchain("prefix/bin", TAG)
fake_toolchain("home/spinel/#{TAG}/bin", TAG)
mkdir_p("onlyspin")
File.write("onlyspin/spin", "#!/bin/sh\necho spin\n")
File.chmod(0o755, "onlyspin/spin")
mkdir_p("empty")

test "release_of reads the release out of spinel --version" do
  reset_env
  assert_equal "2026.09.12", Toolchain.release_of("spinel 112bae85c1a2 (2026.09.12) [cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0]")
  assert_equal "2026.09.08+1", Toolchain.release_of("spinel 281cd145ffb4 (2026.09.08+1) [cc ...]")
  assert_equal "unreleased", Toolchain.release_of("spinel 6b8ddcd88dd9 (unreleased) [cc ...]")
  assert_equal "", Toolchain.release_of("spinel 6b8ddcd88dd9 [cc (Ubuntu 13.3.0) 13.3.0]")
  assert_equal "", Toolchain.release_of("spinel: command not found")
  assert_equal "", Toolchain.release_of("")
  assert_equal "", Toolchain.release_of(") backwards (")
end

test "the managed copy lives under CYBERTRAIN_HOME/spinel/<tag>, as an absolute path" do
  reset_env
  ENV["CYBERTRAIN_HOME"] = "home"
  assert_equal here("home"), Toolchain.home
  assert_equal here("home/spinel/#{TAG}"), Toolchain.prefix
  assert_equal here("home/spinel/#{TAG}/bin"), Toolchain.bin_dir
  assert_equal here("home/bin"), Toolchain.stable_bin_dir
  assert_equal here("home/spinel/#{TAG}/.cybertrain-complete"), Toolchain.stamp
  assert_equal here("home/src/spinel-#{TAG}"), Toolchain.src_dir
  assert_equal here("home/log/spinel-#{TAG}-build.log"), Toolchain.log_path
  assert_equal here("home/spinel/#{TAG}.lock"), Toolchain.lock_dir
  ENV["CYBERTRAIN_HOME"] = "~/ct-test-home"
  assert_equal File.join(ORIGINAL_HOME, "ct-test-home"), Toolchain.home
  ENV["CYBERTRAIN_HOME"] = ""
  assert_equal File.join(ORIGINAL_HOME, ".cybertrain"), Toolchain.home
  ENV["HOME"] = ""
  assert_equal "", Toolchain.home
  ENV["CYBERTRAIN_HOME"] = "~/x"
  assert_equal "", Toolchain.home
  ENV["HOME"] = ORIGINAL_HOME
  ENV["CYBERTRAIN_HOME"] = ""
end

test "usable? wants an executable spinel and spin of the pinned release" do
  reset_env
  assert Toolchain.usable?("good")
  refute Toolchain.usable?("old")
  refute Toolchain.usable?("missing")
  refute Toolchain.usable?("empty")
  refute Toolchain.usable?("onlyspin")
  mkdir_p("nospin")
  File.write("nospin/spinel", "#!/bin/sh\necho \"spinel x (#{TAG})\"\n")
  File.chmod(0o755, "nospin/spinel")
  refute Toolchain.usable?("nospin")
  mkdir_p("notexec")
  File.write("notexec/spinel", "#!/bin/sh\necho \"spinel x (#{TAG})\"\n")
  File.write("notexec/spin", "#!/bin/sh\n")
  refute Toolchain.usable?("notexec")
end

test "a spinel of the pinned release on PATH is used as it is" do
  reset_env
  ENV["PATH"] = "good:#{ORIGINAL_PATH}"
  assert_equal here("good/spinel"), Toolchain.spinel_on_path
  assert Toolchain.on_path?
  assert Toolchain.ensure!
  assert_equal "good:#{ORIGINAL_PATH}", ENV["PATH"]
  assert_equal "", Toolchain.other_release_note
end

test "another release on PATH, or a spin from elsewhere, does not count" do
  reset_env
  ENV["CYBERTRAIN_HOME"] = "home"
  ENV["PATH"] = "old"
  refute Toolchain.on_path?
  puts Toolchain.other_release_note.gsub("#{Dir.pwd}/", "")
  ENV["PATH"] = "onlyspin:good"
  refute Toolchain.on_path?
  ENV["PATH"] = "empty"
  assert_equal "", Toolchain.spinel_on_path
  assert_equal "", Toolchain.other_release_note
  ENV["CYBERTRAIN_HOME"] = ""
end

test "CYBERTRAIN_SPINEL_HOME names a prefix or its bin directory, absolute" do
  reset_env
  ENV["PATH"] = "empty"
  ENV["CYBERTRAIN_SPINEL_HOME"] = "prefix"
  assert_equal here("prefix/bin"), Toolchain.explicit_bin_dir
  assert Toolchain.ensure!
  assert_equal "#{here("prefix/bin")}:empty", ENV["PATH"]
  ENV["CYBERTRAIN_SPINEL_HOME"] = "prefix/bin"
  assert_equal here("prefix/bin"), Toolchain.explicit_bin_dir
  ENV["CYBERTRAIN_SPINEL_HOME"] = "old" # holds spinel directly, of another release
  assert_equal here("old"), Toolchain.explicit_bin_dir
  refute Toolchain.usable?(Toolchain.explicit_bin_dir)
  ENV["CYBERTRAIN_SPINEL_HOME"] = "missing"
  assert_equal here("missing/bin"), Toolchain.explicit_bin_dir
  ENV["CYBERTRAIN_SPINEL_HOME"] = ""
  assert_equal "", Toolchain.explicit_bin_dir
end

test "the managed copy counts only once its completion stamp is there" do
  reset_env
  ENV["PATH"] = "old"
  ENV["CYBERTRAIN_HOME"] = "home"
  assert Toolchain.usable?(Toolchain.bin_dir)
  refute Toolchain.managed_ok?
  File.write(Toolchain.stamp, "#{TAG}\n")
  assert Toolchain.managed_ok?
  assert Toolchain.ensure!
  assert_equal "#{here("home/spinel/#{TAG}/bin")}:old", ENV["PATH"]
  ENV["CYBERTRAIN_HOME"] = ""
end

test "install refuses to start without the build tools, before touching anything" do
  reset_env
  ENV["PATH"] = "empty"
  ENV["CYBERTRAIN_HOME"] = "home2"
  missing = Toolchain.missing_requirements
  assert_includes missing, "git"
  assert_includes missing, "make"
  assert_includes missing, "curl"
  assert_includes Toolchain.missing_app_requirements, "a C compiler (cc)"
  refute Toolchain.install(false)
  refute File.exist?("home2")
  ENV["CC"] = "ccache gcc -O1"
  assert_equal "ccache", Toolchain.cc_program
  assert_includes Toolchain.missing_app_requirements, "a C compiler (ccache gcc -O1)"
  ENV["CC"] = ""
  ENV["CYBERTRAIN_HOME"] = ""
  ENV["PATH"] = ORIGINAL_PATH
end

test "install refuses a home it cannot write, without hanging" do
  reset_env
  ENV["CYBERTRAIN_HOME"] = "/proc/cybertrain-test"
  refute Toolchain.take_lock
  ENV["CYBERTRAIN_HOME"] = ""
end

test "the build lock is a directory holding the builder's pid, taken atomically" do
  reset_env
  ENV["CYBERTRAIN_HOME"] = "home3"
  lock = here("home3/spinel/#{TAG}.lock")
  assert Toolchain.take_lock
  assert File.directory?(lock)
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  refute File.exist?("#{lock}.#{Process.pid}")
  Toolchain.release_lock
  refute File.exist?(lock)
  # A lock left by a process that is gone is taken over ...
  mkdir_p(lock)
  File.write(File.join(lock, "pid"), "999999999")
  assert Toolchain.lock_stale?
  assert Toolchain.take_lock
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  Toolchain.release_lock
  # ... so is one without a valid pid, or an empty one.
  mkdir_p(lock)
  File.write(File.join(lock, "pid"), "-1")
  assert Toolchain.lock_stale?
  assert Toolchain.take_lock
  Toolchain.release_lock
  mkdir_p(lock)
  assert Toolchain.take_lock
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  Toolchain.release_lock
  # release_lock only removes a lock this process holds.
  mkdir_p(lock)
  File.write(File.join(lock, "pid"), "999999999")
  Toolchain.release_lock
  assert File.directory?(lock)
  rm_tree(lock)
  ENV["CYBERTRAIN_HOME"] = ""
end

test "a lock is removed only by the one process holding its reclaim marker" do
  reset_env
  ENV["CYBERTRAIN_HOME"] = "home3"
  lock = here("home3/spinel/#{TAG}.lock")
  # A stale lock another process has marked is left to that process ...
  mkdir_p(File.join(lock, "reclaim"))
  File.write(File.join(lock, "pid"), "999999999")
  assert Toolchain.lock_stale?
  refute Toolchain.reclaim_stale_lock
  assert File.directory?(File.join(lock, "reclaim"))
  rm_tree(lock)
  # ... an unmarked stale one is taken over, through the marker ...
  mkdir_p(lock)
  File.write(File.join(lock, "pid"), "999999999")
  assert Toolchain.reclaim_stale_lock
  refute File.exist?(lock)
  refute File.exist?("#{lock}.old.#{Process.pid}")
  # ... and a live one is neither taken nor left marked.
  assert Toolchain.take_lock
  refute Toolchain.reclaim_stale_lock
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  refute File.exist?(File.join(lock, "reclaim"))
  # A marker in a live lock does not make it stale.
  assert Toolchain.mark_lock
  refute Toolchain.lock_stale?
  Toolchain.unmark_lock
  # The holder is known by pid and start time: the same pid started at
  # another time is a different process (when ps can tell; without it, the
  # pid existing has to do).
  start = Toolchain.process_start(Process.pid.to_s)
  assert_equal start, Toolchain.lock_start
  assert Toolchain.holder_alive?(Process.pid.to_s, start)
  assert Toolchain.holder_alive?(Process.pid.to_s, "")
  assert_equal start == "", Toolchain.holder_alive?(Process.pid.to_s, "Thu Jan  1 00:00:00 1970")
  refute Toolchain.holder_alive?("999999999", "")
  refute Toolchain.holder_alive?("999999999", start)
  File.write(File.join(lock, "start"), "Thu Jan  1 00:00:00 1970")
  assert_equal start != "", Toolchain.lock_stale?
  File.write(File.join(lock, "start"), start)
  refute Toolchain.lock_stale?
  # The holder cannot release a lock a taker-over has marked.
  mkdir_p(File.join(lock, "reclaim"))
  Toolchain.release_lock
  assert File.directory?(lock)
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  # Once the lock is someone else's, the holder stops its build.
  assert Toolchain.holding_lock?
  File.write(File.join(lock, "pid"), "999999999")
  refute Toolchain.holding_lock?
  rm_tree(lock)
  ENV["CYBERTRAIN_HOME"] = ""
end

test "setup needs a home for the managed copy, and a directory PATH can hold" do
  reset_env
  ENV["PATH"] = "empty"
  ENV["HOME"] = ""
  assert_equal "a directory to keep Spinel in (set CYBERTRAIN_HOME or HOME)", Toolchain.home_problem
  refute Toolchain.managed_ok?
  assert_includes Toolchain.doctor_problems(false), "a directory to keep Spinel in (set CYBERTRAIN_HOME or HOME)"
  assert_nil Toolchain.doctor_problems(true).index("a directory to keep Spinel in (set CYBERTRAIN_HOME or HOME)")
  refute Toolchain.install(false)
  ENV["CYBERTRAIN_HOME"] = "odd:home"
  assert_equal "a CYBERTRAIN_HOME without spaces, quotes, $ or : in its path (now #{here("odd:home")})", Toolchain.home_problem
  assert_includes Toolchain.doctor_problems(false), Toolchain.home_problem
  ENV["CYBERTRAIN_HOME"] = "home"
  assert_equal "", Toolchain.home_problem
  assert_nil Toolchain.doctor_problems(false).index("")
  ENV["CYBERTRAIN_SPINEL_HOME"] = "missing"
  assert_includes Toolchain.doctor_problems(false), "a usable CYBERTRAIN_SPINEL_HOME"
  ENV["CYBERTRAIN_SPINEL_HOME"] = ""
  assert_equal "", Toolchain.path_problem("good")
  assert_equal "odd:dir cannot go on PATH: its name contains ':'", Toolchain.path_problem("odd:dir")
  refute Toolchain.use("odd:dir")
  assert_equal "empty", ENV["PATH"]
  assert Toolchain.use("good")
  assert_equal "good:empty", ENV["PATH"]
  ENV["HOME"] = ORIGINAL_HOME
  ENV["CYBERTRAIN_HOME"] = ""
end

test "tail, jobs, quoting and hints" do
  reset_env
  File.write("log.txt", "one\ntwo\nthree\nfour\n")
  assert_equal ["three", "four"], Toolchain.tail("log.txt", 2)
  assert_equal ["one", "two", "three", "four"], Toolchain.tail("log.txt", 10)
  assert_equal [], Toolchain.tail("nope.txt", 3)
  assert Toolchain.jobs >= 1
  assert_equal "'a b'", Toolchain.shell_quote("a b")
  assert_equal "'it'\\''s'", Toolchain.shell_quote("it's")
  assert_equal "a b|c", Toolchain.sh_read("echo 'a b|c'")
  assert_equal "second", Toolchain.sh_read("false || echo second")
  assert_equal "", Toolchain.sh_read("no-such-command-cybertrain 2>/dev/null")
  assert Toolchain.install_hints.size >= 1
end

Cybertrain::Test.run!
