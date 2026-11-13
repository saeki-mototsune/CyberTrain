require "tmpdir"
require "socket"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"

# The server role under `cybertrain server`'s supervision, when the
# descriptor it was handed is unusable: CYBERTRAIN_DEV_LISTEN_FD that is not
# a number, or a number that is not a listening socket (closed, a regular
# file). Each is a boot failure: the `error:` line on STDOUT, exit 1, and
# the same line in CYBERTRAIN_DEV_FAILURE_FILE. Outside development, or
# without the descriptor variable, the variables are ignored: the port is
# bound as always and no failure file is written. fail_boot exits, so
# each case runs this program again as a child (as test/boot_encryption.rb
# does) and reads its stdout, exit status and failure file. Boot connects
# SQLite (FFI), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
CHILD_FLAG = "CYBERTRAIN_DEV_SUPERVISED_BOOT_CHILD"

if ENV[CHILD_FLAG] == "1"
  # A regular file's descriptor, opened here so the child holds it.
  if ENV["CYBERTRAIN_DEV_LISTEN_FD"] == "file"
    held_file = File.open($0)
    ENV["CYBERTRAIN_DEV_LISTEN_FD"] = held_file.fileno.to_s
  end
  conf = Cybertrain::Config.new
  conf.database_path = ":memory:"
  conf.secret_key_base = "dev-supervised-boot-secret"
  conf.log_level = :none
  conf.views_root = "test/fixtures/views"
  conf.port = ENV["CT_TEST_PORT"].to_i
  views = { "" => "" }
  views.delete("")
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" }, views: views,
                              config: conf, name: "blog").run([])
  puts "served"
  exit(0)
end

OUT_DIR = Dir.mktmpdir("cybertrain-dev-supervised-boot")
OUT_PATH = "#{OUT_DIR}/stdout.log"
FAILURE_PATH = "#{OUT_DIR}/failure"
at_exit do
  [OUT_PATH, FAILURE_PATH].each { |path| File.delete(path) if File.exist?(path) }
  Dir.rmdir(OUT_DIR)
end

# A port nothing listens on, but which is bound here while a child runs:
# a child that binds instead of using its descriptor fails on it, visibly.
BUSY = TCPServer.new("127.0.0.1", 0)
BUSY_PORT = BUSY.addr[1]

# Runs the child in env with this descriptor variable; [exit status,
# stdout, failure file ("" when none was written)].
def boot_child(env, listen_fd)
  File.delete(FAILURE_PATH) if File.exist?(FAILURE_PATH)
  ENV[CHILD_FLAG] = "1"
  ENV["CYBERTRAIN_ENV"] = env
  ENV["CYBERTRAIN_DEV_LISTEN_FD"] = listen_fd
  ENV["CYBERTRAIN_DEV_FAILURE_FILE"] = FAILURE_PATH
  ENV["CT_TEST_PORT"] = BUSY_PORT.to_s
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", File.expand_path("..", __dir__), $0, out: OUT_PATH)
  else
    pid = Process.spawn(File.expand_path($0), out: OUT_PATH)
  end
  ["CYBERTRAIN_DEV_LISTEN_FD", "CYBERTRAIN_DEV_FAILURE_FILE", "CYBERTRAIN_ENV", "CT_TEST_PORT", CHILD_FLAG].each do |name|
    ENV.delete(name)
  end
  status = Process.waitpid2(pid)[1].exitstatus.to_i
  failure = File.exist?(FAILURE_PATH) ? File.read(FAILURE_PATH) : ""
  # The port in a message is this run's: written as PORT for the snapshot.
  [status.to_s, File.read(OUT_PATH).gsub(BUSY_PORT.to_s, "PORT"), failure.gsub(BUSY_PORT.to_s, "PORT")]
end

NOT_A_NUMBER = "error: CYBERTRAIN_DEV_LISTEN_FD is not a descriptor number"
NOT_LISTENING = "error: port PORT on 127.0.0.1 cannot be served: the inherited descriptor is not a listening socket"

test "a descriptor variable that is not a number is a boot failure, not a bind" do
  assert_equal ["1", "#{NOT_A_NUMBER}\n", NOT_A_NUMBER], boot_child("development", "7; rm")
  assert_equal ["1", "#{NOT_A_NUMBER}\n", NOT_A_NUMBER], boot_child("development", "1234567890123456789")
end

# A number far above what the child opens: nothing is there.
test "a descriptor that is not open is a boot failure" do
  assert_equal ["1", "#{NOT_LISTENING}\n", NOT_LISTENING], boot_child("development", "900")
end

test "a regular file's descriptor is a boot failure, not a hang" do
  assert_equal ["1", "#{NOT_LISTENING}\n", NOT_LISTENING], boot_child("development", "file")
end

test "outside development the variables are ignored: the port is bound as always, and no failure file is written" do
  in_use = "error: port PORT on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}"
  assert_equal ["1", "#{in_use}\n", ""], boot_child("test", "7; rm")
end

test "a production boot failure writes no failure file, whatever the variables say" do
  no_views = "error: views are not embedded in this binary; build with `cybertrain build` (or run with CYBERTRAIN_ENV=development)"
  assert_equal ["1", "#{no_views}\n", ""], boot_child("production", "7; rm")
end

test "in development without the descriptor variable no failure file is written" do
  in_use = "error: port PORT on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}"
  assert_equal ["1", "#{in_use}\n", ""], boot_child("development", "")
end

Cybertrain::Test.run!
