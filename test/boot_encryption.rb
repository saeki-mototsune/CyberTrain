require "tmpdir"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"

# Application#boot's encryption check, end to end: boot exits 1 through
# fail_boot, so each case runs this program again as a child (as
# test/logger_flush.rb does) and reads its stdout and exit status. The
# child sets Config.encryption_required, as gen/app.rb does for an app
# whose models declare `encrypts`; the flag is the child's, so the parent
# (and every other test) never sees it set. Boot connects SQLite (FFI), so
# the snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
CHILD_FLAG = "CYBERTRAIN_BOOT_ENCRYPTION_CHILD"
VALID_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

if ENV[CHILD_FLAG] == "1"
  Cybertrain::Config.encryption_required = ENV["CT_TEST_REQUIRED"] == "1"
  conf = Cybertrain::Config.new
  conf.database_path = ":memory:"
  conf.secret_key_base = "boot-encryption-secret"
  conf.log_level = :none
  conf.views_root = "test/fixtures/views"
  views = { "" => "" }
  views.delete("")
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, views: views,
                              config: conf).boot
  puts "booted"
  exit(0)
end

OUT_DIR = Dir.mktmpdir("cybertrain-boot-encryption")
OUT_PATH = "#{OUT_DIR}/stdout.log"
at_exit do
  File.delete(OUT_PATH) if File.exist?(OUT_PATH)
  Dir.rmdir(OUT_DIR)
end

# Runs the child with this key and requirement; [exit status, stdout].
def boot_child(key, required)
  ENV[CHILD_FLAG] = "1"
  ENV["CYBERTRAIN_ENCRYPTION_KEY"] = key
  ENV["CT_TEST_REQUIRED"] = required ? "1" : "0"
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", File.expand_path("..", __dir__), $0, out: OUT_PATH)
  else
    pid = Process.spawn(File.expand_path($0), out: OUT_PATH)
  end
  ENV.delete(CHILD_FLAG)
  ENV.delete("CYBERTRAIN_ENCRYPTION_KEY")
  ENV.delete("CT_TEST_REQUIRED")
  status = Process.waitpid2(pid)[1].exitstatus.to_i
  [status.to_s, File.read(OUT_PATH)]
end

test "encryption required and no key: boot fails with the configuration message" do
  assert_equal ["1", "error: CYBERTRAIN_ENCRYPTION_KEY is not set; make one with `cybertrain secret --hex`\n"],
               boot_child("", true)
end

test "a malformed key fails boot whether or not encryption is required" do
  malformed = "error: CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; make one with `cybertrain secret --hex`\n"
  assert_equal ["1", malformed], boot_child("abc", true)
  assert_equal ["1", malformed], boot_child("abc", false)
end

test "a valid key boots; no key boots when nothing is encrypted" do
  assert_equal ["0", "booted\n"], boot_child(VALID_KEY, true)
  assert_equal ["0", "booted\n"], boot_child("", false)
  refute Cybertrain::Config.encryption_required
end

Cybertrain::Test.run!
