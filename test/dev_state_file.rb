# Dev::StateFile, the file through which `cybertrain server` tells the child
# it supervises about the background Spinel build (three header lines, an
# empty line, then the output of a failure), its Reader, and Dev::BuildStatus,
# what the development error page asks "did the build fail, and with what
# output". It links no FFI, so it runs under CRuby too and its snapshot
# comes from `spin test --regen`.
require "cybertrain/dev/state_file"
require "cybertrain/dev/build_status"
require "cybertrain/test"

F = Cybertrain::Dev::StateFile

test "format and parse agree" do
  s = F.parse(F.format(12, "cruby", "failed", "app/models/a.rb:3: error\nsecond line\n"))
  assert_equal 12, s.generation
  assert_equal "cruby", s.serving
  assert_equal "failed", s.build
  assert_equal "app/models/a.rb:3: error\nsecond line\n", s.output
end

test "an empty output and an output with an empty line survive" do
  assert_equal "", F.parse(F.format(1, "spinel", "ready", "")).output
  assert_equal "a\n\nb", F.parse(F.format(1, "cruby", "failed", "a\n\nb")).output
end

test "anything else is the default snapshot" do
  ["", "generation x\nserving cruby\nbuild ready\n\n", "serving cruby\n", "generation 3\nserving root\nbuild ready\n\n",
   "generation 3\nserving cruby\nbuild done\n\n"].each do |text|
    s = F.parse(text)
    assert_equal 0, s.generation
    assert_equal "", s.serving
    assert_equal "idle", s.build
    assert_equal "", s.output
  end
end

test "the reader rereads a file that changed and survives its absence" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_test"
  File.delete(path) if File.exist?(path)
  reader = F::Reader.new(path)
  assert_equal 0, reader.current.generation
  File.write(path, F.format(2, "cruby", "building", ""))
  assert_equal 2, reader.current.generation
  File.write(path, F.format(3, "spinel", "ready", ""))
  assert_equal "spinel", reader.current.serving
  File.delete(path)
  assert_equal 0, reader.current.generation
end

test "build status fails for failed and binary_failed only" do
  status = Cybertrain::Dev::BuildStatus.new
  assert !status.failed
  status.update(F.parse(F.format(1, "cruby", "binary_failed", "signal 11")))
  assert status.failed
  assert_equal "signal 11", status.output
  status.update(F.parse(F.format(2, "cruby", "building", "")))
  assert !status.failed
end

test "a build status with a reader answers from the state file as it is now" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_status_test"
  File.delete(path) if File.exist?(path)
  status = Cybertrain::Dev::BuildStatus.new(F::Reader.new(path))
  assert !status.failed
  assert_equal "", status.output
  File.write(path, F.format(4, "cruby", "failed", "app/models/a.rb:3: syntax error\n"))
  assert status.failed
  assert_equal "app/models/a.rb:3: syntax error\n", status.output
  File.write(path, F.format(5, "cruby", "building", ""))
  assert !status.failed
  assert_equal "", status.output
  File.delete(path)
  assert !status.failed
end

Cybertrain::Test.run!
