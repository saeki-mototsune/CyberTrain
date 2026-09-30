require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli/toolchain"

# Toolchain without a network, a compiler or a real Spinel: the version
# parsing, the managed layout under CYBERTRAIN_HOME, and how a spinel of the
# pinned release is picked from PATH / CYBERTRAIN_SPINEL_HOME / the managed
# copy. Fake spinel/spin shell scripts stand in for the binaries. Every path
# is relative to a fresh temp dir (PATH entries and env values included) so
# the output is the same on every machine. CRuby-portable.
TMP = Dir.mktmpdir("cybertrain-cli-toolchain")
Dir.chdir(TMP)
ORIGINAL_PATH = ENV["PATH"].to_s
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
  Dir.chdir("/")
  rm_tree(TMP)
end

# Pure Ruby: some tests below empty PATH, so /bin/mkdir cannot be relied on.
def mkdir_p(dir)
  parent = File.dirname(dir)
  mkdir_p(parent) unless parent == "." || parent == "/" || File.directory?(parent)
  Dir.mkdir(dir) unless File.directory?(dir)
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
mkdir_p("empty")

test "release_of reads the release out of spinel --version" do
  assert_equal "2026.09.12", Toolchain.release_of("spinel 112bae85c1a2 (2026.09.12) [cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0]")
  assert_equal "2026.09.08+1", Toolchain.release_of("spinel 281cd145ffb4 (2026.09.08+1) [cc ...]")
  assert_equal "unreleased", Toolchain.release_of("spinel 6b8ddcd88dd9 (unreleased) [cc ...]")
  assert_equal "", Toolchain.release_of("spinel: command not found")
  assert_equal "", Toolchain.release_of("")
  assert_equal "", Toolchain.release_of(") backwards (")
end

test "the managed copy lives under CYBERTRAIN_HOME/spinel/<tag>" do
  ENV["CYBERTRAIN_HOME"] = "home"
  assert_equal "home/spinel/#{TAG}", Toolchain.prefix
  assert_equal "home/spinel/#{TAG}/bin", Toolchain.bin_dir
  assert_equal "home/src/spinel-#{TAG}", Toolchain.src_dir
  assert_equal "home/log/spinel-#{TAG}-build.log", Toolchain.log_path
  assert_equal "home/spinel/#{TAG}.lock", Toolchain.lock_dir
  ENV["CYBERTRAIN_HOME"] = ""
  assert_equal File.join(ENV["HOME"].to_s, ".cybertrain"), Toolchain.home
end

test "usable? wants an executable spinel and spin of the pinned release" do
  assert Toolchain.usable?("good")
  refute Toolchain.usable?("old")
  refute Toolchain.usable?("missing")
  refute Toolchain.usable?("empty")
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
  ENV["PATH"] = "good:#{ORIGINAL_PATH}"
  assert_equal "good/spinel", Toolchain.spinel_on_path
  assert Toolchain.on_path?
  assert Toolchain.ensure!
  assert_equal "good:#{ORIGINAL_PATH}", ENV["PATH"]
end

test "another release on PATH does not count" do
  ENV["CYBERTRAIN_HOME"] = "home"
  ENV["PATH"] = "old:#{ORIGINAL_PATH}"
  refute Toolchain.on_path?
  Toolchain.note_other_release
  ENV["PATH"] = "empty:#{ORIGINAL_PATH}"
  Toolchain.note_other_release
  ENV["CYBERTRAIN_HOME"] = ""
end

test "CYBERTRAIN_SPINEL_HOME names a prefix or its bin directory" do
  ENV["PATH"] = "empty"
  ENV["CYBERTRAIN_SPINEL_HOME"] = "prefix"
  assert_equal "prefix/bin", Toolchain.explicit_bin_dir
  assert Toolchain.ensure!
  assert_equal "prefix/bin:empty", ENV["PATH"]
  ENV["CYBERTRAIN_SPINEL_HOME"] = "prefix/bin"
  assert_equal "prefix/bin", Toolchain.explicit_bin_dir
  ENV["CYBERTRAIN_SPINEL_HOME"] = "old"
  refute Toolchain.ensure!
  ENV["CYBERTRAIN_SPINEL_HOME"] = ""
  assert_equal "", Toolchain.explicit_bin_dir
end

test "the managed copy is picked up when PATH has no match" do
  ENV["PATH"] = "old"
  ENV["CYBERTRAIN_HOME"] = "home"
  assert Toolchain.ensure!
  assert_equal "home/spinel/#{TAG}/bin:old", ENV["PATH"]
  ENV["CYBERTRAIN_HOME"] = ""
end

test "install refuses to start without the build tools, before touching anything" do
  ENV["PATH"] = "empty"
  ENV["CYBERTRAIN_HOME"] = "home2"
  missing = Toolchain.missing_requirements
  assert_includes missing, "git"
  assert_includes missing, "make"
  assert_includes missing, "curl"
  refute Toolchain.install(false)
  refute File.exist?("home2")
  ENV["CYBERTRAIN_HOME"] = ""
  ENV["PATH"] = ORIGINAL_PATH
end

test "the build lock is a directory holding the builder's pid" do
  ENV["CYBERTRAIN_HOME"] = "home3"
  assert Toolchain.take_lock
  assert File.directory?("home3/spinel/#{TAG}.lock")
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  Toolchain.release_lock
  refute File.exist?("home3/spinel/#{TAG}.lock")
  # A lock left by a process that is gone is taken over.
  mkdir_p("home3/spinel/#{TAG}.lock")
  File.write("home3/spinel/#{TAG}.lock/pid", "999999999")
  assert Toolchain.take_lock
  assert_equal Process.pid.to_s, Toolchain.lock_pid
  Toolchain.release_lock
  ENV["CYBERTRAIN_HOME"] = ""
end

test "tail, jobs and shell_quote" do
  File.write("log.txt", "one\ntwo\nthree\nfour\n")
  assert_equal ["three", "four"], Toolchain.tail("log.txt", 2)
  assert_equal ["one", "two", "three", "four"], Toolchain.tail("log.txt", 10)
  assert_equal [], Toolchain.tail("nope.txt", 3)
  assert Toolchain.jobs >= 1
  assert_equal "'a b'", Toolchain.shell_quote("a b")
  assert_equal "'it'\\''s'", Toolchain.shell_quote("it's")
  assert Toolchain.install_hints.size >= 1
end

Cybertrain::Test.run!
