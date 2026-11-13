require "cybertrain/test"
require "cybertrain/preview"
require "tmpdir"

# The CRuby preview's Fiddle shim for the ffi_* DSL (cybertrain/preview/).
# CRuby only: Spinel compiles the DSL itself.

module Probe
  ffi_lib "z"
  ffi_source <<~C
    #include <string.h>
    long probe_add(long a, long b) { return a + b; }
    static int hidden(void) { return 7; }
    int probe_hidden(void) { return hidden(); }
    void probe_store(void *slot, long v) { *(long *)slot = v; }
    const char *probe_hello(void) { return "h\\xc3\\xa9llo"; }
    const char *probe_bytes(long n) { sp_ffi_bin_len = (int)n; return "a\\0b\\0c"; }
  C
  ffi_func :probe_add, [:long, :long], :long
  ffi_func :probe_hidden, [], :int
  ffi_func :probe_store, [:ptr, :long], :void
  ffi_func :probe_hello, [], :str
  ffi_func :probe_bytes, [:long], :binstr
  ffi_func :zlibVersion, [], :str, blocking: true
  ffi_const :ANSWER, 42
  ffi_read_ptr :read_ptr, 0
end

test "calls a function from ffi_source and one from ffi_lib" do
  assert_equal 5, Probe.probe_add(2, 3)
  assert_equal 7, Probe.probe_hidden
  assert Probe.zlibVersion.start_with?("1."), "zlib answers its version"
end

test "constants, malloc, read_ptr and free" do
  assert_equal 42, Probe::ANSWER
  slot = Probe.malloc(8)
  Probe.probe_store(slot, 1234)
  assert_equal 1234, Probe.read_ptr(slot)
  Probe.free(slot)
end

test ":str and :binstr results" do
  assert_equal "héllo", Probe.probe_hello
  assert_equal Encoding::UTF_8, Probe.probe_hello.encoding
  assert_equal 3, Probe.probe_bytes(3).bytesize   # "a\0b": NULs kept, length from sp_ffi_bin_len
  assert_equal "a\0b".b, Probe.probe_bytes(3)
  assert_equal Encoding::BINARY, Probe.probe_bytes(3).encoding
end

test "an unknown type is refused by name" do
  message = assert_raises("Cybertrain::Preview::Unsupported") do
    Module.new { ffi_func :x, [:wchar], :int }
  end
  assert message.include?("type :wchar is not implemented by the CRuby preview")
  assert_equal "ffi_func :x: type :wchar is not implemented by the CRuby preview", message
end

test "the compiled library is cached by content" do
  dir = Dir.mktmpdir("preview-ffi")
  first = Cybertrain::Preview::FFILibrary.build("int one(void){return 1;}", [], dir)
  stamp = File.mtime(first)
  assert_equal first, Cybertrain::Preview::FFILibrary.build("int one(void){return 1;}", [], dir)
  assert_equal stamp, File.mtime(first)
  assert first != Cybertrain::Preview::FFILibrary.build("int one(void){return 2;}", [], dir)
end

# A fake compiler: writes a damaged library where its -o says, and records
# each run.
def fake_cc(dir)
  path = File.join(dir, "fake-cc")
  File.write(path, <<~SH)
    #!/bin/sh
    echo run >> '#{dir}/runs'
    out=''
    while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out=$2; fi; shift; done
    cat > /dev/null
    printf 'not a shared library' > "$out"
  SH
  File.chmod(0o755, path)
  path
end

def with_cc(cc)
  saved = ENV["CC"]
  ENV["CC"] = cc
  yield
ensure
  ENV["CC"] = saved
end

def runs(dir)
  File.exist?(File.join(dir, "runs")) ? File.read(File.join(dir, "runs")).lines.size : 0
end

test "a cached library that cannot be loaded is built once more" do
  Dir.mktmpdir("preview-ffi") do |dir|
    source = "int cached_one(void){return 11;}"
    path = Cybertrain::Preview::FFILibrary.build(source, [], dir)
    File.write(path, "damaged")
    handle = Cybertrain::Preview::FFILibrary.open_library(source, [], dir)
    assert_equal 11, Fiddle::Function.new(handle.sym("cached_one"), [], Fiddle::TYPE_INT).call
  end
end

test "a library that still does not load after one more build is reported" do
  Dir.mktmpdir("preview-ffi") do |dir|
    with_cc(fake_cc(dir)) do
      assert_raises("Fiddle::DLError") { Cybertrain::Preview::FFILibrary.open_library("int two(void){return 2;}", [], dir) }
      assert_equal 2, runs(dir)
    end
  end
end

test "the cache key covers the machine's architecture and the flags" do
  library = Cybertrain::Preview::FFILibrary
  here = library.send(:key, "int x;", [], "cc 1")
  assert_equal here, library.send(:key, "int x;", [], "cc 1", RbConfig::CONFIG["arch"])
  assert here != library.send(:key, "int x;", [], "cc 1", "aarch64-other")
  assert_equal ["-shared", "-fPIC", "-O2"], library::FLAGS
end

# A cache directory removed while the compiler ran: setting the library's
# mode and the rename fail, and that is not "the C compiler could not be
# run". 0700, as the shim requires of a cache directory whatever the umask.
test "a failing rename is reported as itself" do
  Dir.mktmpdir("preview-ffi") do |dir|
    cache = File.join(dir, "cache")
    Dir.mkdir(cache, 0o700)
    cc = File.join(dir, "remove-cc")
    File.write(cc, "#!/bin/sh\ncat > /dev/null\nrm -rf '#{cache}'\n")
    File.chmod(0o755, cc)
    with_cc(cc) do
      message = assert_raises("Errno::ENOENT") { Cybertrain::Preview::FFILibrary.build("int three(void){return 3;}", [], cache) }
      assert message.index("could not be run").nil?, message
    end
  end
end

# The cache's ownership check (decision P26): a library is code loaded into
# the developer's process, so the directory and the file must be this
# user's alone.
def mode_of(path)
  File.stat(path).mode & 0o777
end

test "a cache directory its group may write to is refused, naming it, and nothing is compiled" do
  library = Cybertrain::Preview::FFILibrary
  Dir.mktmpdir("preview-ffi") do |dir|
    File.chmod(0o770, dir)
    before = library.built
    message = assert_raises("Cybertrain::Preview::CacheError") { library.build("int g(void){return 1;}", [], dir) }
    assert message.include?(dir), message
    assert message.include?("writable by its group or others (mode 0770)"), message
    assert_equal before, library.built
    assert_equal [], Dir.children(dir)
  end
end

test "a cache directory others may write to is refused by open_library too" do
  Dir.mktmpdir("preview-ffi") do |dir|
    File.chmod(0o702, dir)
    message = assert_raises("Cybertrain::Preview::CacheError") do
      Cybertrain::Preview::FFILibrary.open_library("int o(void){return 1;}", [], dir)
    end
    assert message.include?("mode 0702"), message
  end
end

# Another user's directory or file, without running as another user: the
# check itself, given a stat.
test "a directory or file owned by another user is unsafe, whatever its mode" do
  library = Cybertrain::Preview::FFILibrary
  stat = Struct.new(:uid, :mode)
  me = Process.euid
  assert_equal "is owned by uid #{me + 1}, not by this process's user (uid #{me})",
               library.problem(stat.new(me + 1, 0o40700), me)
  assert_equal nil, library.problem(stat.new(me, 0o40700), me)
  assert_equal nil, library.problem(stat.new(me, 0o100755), me)
  assert_equal "is writable by its group or others (mode 0664)", library.problem(stat.new(me, 0o100664), me)
end

test "a library of ours that its group and others may write to is removed and compiled again, 0700" do
  library = Cybertrain::Preview::FFILibrary
  Dir.mktmpdir("preview-ffi") do |dir|
    source = "int loose(void){return 21;}"
    path = library.build(source, [], dir)
    File.chmod(0o666, path)
    before = library.built
    assert_equal path, library.build(source, [], dir)
    assert_equal before + 1, library.built
    assert_equal 0o700, mode_of(path)
    handle = library.open_library(source, [], dir)
    assert_equal 21, Fiddle::Function.new(handle.sym("loose"), [], Fiddle::TYPE_INT).call
    assert_equal before + 1, library.built
  end
end

test "a good cache loads without compiling, and keeps the file as it was" do
  library = Cybertrain::Preview::FFILibrary
  Dir.mktmpdir("preview-ffi") do |dir|
    source = "int good(void){return 31;}"
    path = library.build(source, [], dir)
    assert_equal 0o700, mode_of(path)
    stamp = File.mtime(path)
    before = library.built
    with_cc(File.join(dir, "no-such-compiler")) do
      handle = library.open_library(source, [], dir)
      assert_equal 31, Fiddle::Function.new(handle.sym("good"), [], Fiddle::TYPE_INT).call
    end
    assert_equal before, library.built
    assert_equal stamp, File.mtime(path)
  end
end

test "a missing cache directory is created 0700 whatever the umask, its parents too" do
  Dir.mktmpdir("preview-ffi") do |dir|
    cache = File.join(dir, "tmp", "cybertrain-dev", "ffi")
    saved = File.umask(0o002)
    begin
      Cybertrain::Preview::FFILibrary.build("int fresh(void){return 1;}", [], cache)
    ensure
      File.umask(saved)
    end
    assert_equal 0o700, mode_of(cache)
    assert File.directory?(File.join(dir, "tmp", "cybertrain-dev"))
  end
end

test "an existing cache directory is checked, never changed" do
  Dir.mktmpdir("preview-ffi") do |dir|
    cache = File.join(dir, "ffi")
    Dir.mkdir(cache, 0o755)
    File.chmod(0o755, cache)
    Cybertrain::Preview::FFILibrary.build("int kept(void){return 1;}", [], cache)
    assert_equal 0o755, mode_of(cache)
  end
end

test "a C error carries the compiler's output" do
  message = assert_raises("Cybertrain::Preview::CompileError") do
    Cybertrain::Preview::FFILibrary.build("int broken( {", [], Dir.mktmpdir("preview-ffi"))
  end
  assert message.include?("error"), message
end

test "no file under cybertrain/preview/ declares an Error class by a `class` line (test/gen_jobs.rb scans for them)" do
  assert_equal "Cybertrain::Preview::CompileError", Cybertrain::Preview::CompileError.name
  # gen_jobs matches `class <Name>Error <` with a plain name; this also
  # catches a namespaced `class Foo::BarError <`, so it is the wider check.
  offenders = []
  Dir.glob("cybertrain/preview/**/*.rb").sort.each do |path|
    File.read(path, encoding: "UTF-8").each_line do |line|
      offenders << "#{path}: #{line.chomp}" if line.match?(/\A\s*class\s+[\w:]*Error\b.*</)
    end
  end
  assert_equal [], offenders
end

Cybertrain::Test.run!
