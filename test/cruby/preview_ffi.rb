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

# A cache directory removed while the compiler ran: the rename fails, and
# that is not "the C compiler could not be run".
test "a failing rename is reported as itself" do
  Dir.mktmpdir("preview-ffi") do |dir|
    cache = File.join(dir, "cache")
    Dir.mkdir(cache)
    cc = File.join(dir, "remove-cc")
    File.write(cc, "#!/bin/sh\ncat > /dev/null\nrm -rf '#{cache}'\n")
    File.chmod(0o755, cc)
    with_cc(cc) do
      message = assert_raises("Errno::ENOENT") { Cybertrain::Preview::FFILibrary.build("int three(void){return 3;}", [], cache) }
      assert message.index("could not be run").nil?, message
    end
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
