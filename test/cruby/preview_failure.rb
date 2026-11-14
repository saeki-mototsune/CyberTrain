require "cybertrain/test"
require "tmpdir"
require "rbconfig"

# Cybertrain::Preview::Failure: a process that ends with an exception leaves
# "<Class>: <message>" and the head of its backtrace in
# CYBERTRAIN_DEV_FAILURE_FILE, for the dev supervisor to show.

def run_preview(*args, failure_file)
  env = { "CYBERTRAIN_DEV_FAILURE_FILE" => failure_file }
  system(env, RbConfig.ruby, "-E", "UTF-8", "-I.", "-r", "cybertrain/preview", *args,
         out: File::NULL, err: File::NULL)
end

test "an uncaught exception is written to the failure file" do
  Dir.mktmpdir("preview-failure") do |dir|
    file = File.join(dir, "failure")
    run_preview("-e", 'raise ArgumentError, "bad"', file)
    text = File.read(file)
    assert text.start_with?("ArgumentError: bad\n"), text
    assert text.lines.size <= 11, "the message and at most ten backtrace lines"
  end
end

test "exit leaves no failure file" do
  Dir.mktmpdir("preview-failure") do |dir|
    file = File.join(dir, "failure")
    run_preview("-e", "exit 3", file)
    assert !File.exist?(file), "exit is not a failure"
  end
end

test "a syntax error in a required file is written" do
  Dir.mktmpdir("preview-failure") do |dir|
    file = File.join(dir, "failure")
    broken = File.join(dir, "broken.rb")
    File.write(broken, "def (\n")
    run_preview("-e", "require #{broken.inspect}", file)
    text = File.read(file)
    assert text.start_with?("SyntaxError:"), text
  end
end

Cybertrain::Test.run!
