require "cybertrain/test"
require "cybertrain/logger"

# A server's stdout is usually a pipe or a file (a process manager,
# `server > log`), where it is block-buffered: before the logger flushed
# each line, the request log only appeared when the server exited. This
# program runs itself as a child whose stdout is a file and reads that file
# while the child is still alive.
CHILD_FLAG = "CYBERTRAIN_LOGGER_FLUSH_CHILD"

if ENV[CHILD_FLAG] == "1"
  Cybertrain.logger.info("Started GET \"/\" for 127.0.0.1")
  sleep 10 # killed by the parent long before this ends
  exit(0)
end

# Under Spinel $0 is the compiled test binary; under CRuby it is this file.
def spawn_child(log_path)
  ENV[CHILD_FLAG] = "1"
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", File.expand_path("..", __dir__), $0, out: log_path)
  else
    pid = Process.spawn(File.expand_path($0), out: log_path)
  end
  ENV.delete(CHILD_FLAG)
  pid
end

# What the child has written to log_path so far, waiting up to 5 s for it.
def logged_while_running(log_path)
  text = ""
  50.times do
    text = File.exist?(log_path) ? File.read(log_path) : ""
    break unless text.empty?

    sleep 0.1
  end
  text
end

test "the default logger's lines reach a redirected stdout while the process runs" do
  log_path = "/tmp/cybertrain-logger-flush-#{Process.pid}.log"
  pid = spawn_child(log_path)
  text = logged_while_running(log_path)
  Process.kill("KILL", pid)
  Process.waitpid2(pid)
  File.delete(log_path) if File.exist?(log_path)
  assert_equal "[INFO] Started GET \"/\" for 127.0.0.1\n", text
end

Cybertrain::Test.run!
