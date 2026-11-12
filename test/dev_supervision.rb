require "cybertrain/dev/supervision"
require "cybertrain/test"

# Dev::Supervision reads the variables `cybertrain server` sets for the
# child it supervises: the inherited listening descriptor, the readiness and
# failure files, the generation. It links no FFI, so it runs under CRuby too
# and its snapshot comes from `spin test --regen`.
S = Cybertrain::Dev::Supervision
DIR = "tmp/dev_supervision_test"
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def with_env(pairs)
  saved = { "" => "" }
  saved.delete("")
  pairs.each { |key, value| saved[key] = ENV[key].to_s; ENV[key] = value }
  yield
  saved.each { |key, value| value.empty? ? ENV.delete(key) : ENV[key] = value }
  nil
end

test "inactive without the descriptor, and outside development" do
  ENV.delete("CYBERTRAIN_DEV_LISTEN_FD")
  assert !S.active?("development")
  assert_equal(-1, S.listen_fd)
  with_env("CYBERTRAIN_DEV_LISTEN_FD" => "7") do
    assert S.active?("development")
    assert !S.active?("production")
    assert !S.active?("test")
    assert_equal 7, S.listen_fd
  end
end

test "a descriptor that is not a number is none" do
  with_env("CYBERTRAIN_DEV_LISTEN_FD" => "7; rm") { assert_equal(-1, S.listen_fd) }
end

test "mark_ready writes the generation; write_failure writes the message" do
  with_env("CYBERTRAIN_DEV_READY_FILE" => "#{DIR}/ready", "CYBERTRAIN_DEV_FAILURE_FILE" => "#{DIR}/failure",
           "CYBERTRAIN_DEV_GENERATION" => "12") do
    S.mark_ready
    S.write_failure("error: port 3000 is in use")
    assert_equal "12", File.read("#{DIR}/ready")
    assert_equal "error: port 3000 is in use", File.read("#{DIR}/failure")
  end
end

test "without the paths both are no-ops" do
  ENV.delete("CYBERTRAIN_DEV_READY_FILE")
  ENV.delete("CYBERTRAIN_DEV_FAILURE_FILE")
  S.mark_ready
  S.write_failure("x")
  assert_equal "", S.ready_file
end

test "runtime names this runtime" do
  assert_equal(RUBY_ENGINE == "ruby" ? "cruby" : "spinel", S.runtime)
end

Cybertrain::Test.run!
