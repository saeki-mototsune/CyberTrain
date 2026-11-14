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

# The supervisor writes serving none while no child runs: at the first
# round's opening write, after a build that succeeded with a change
# pending, and at the opening write of the round after that.
test "every serving the supervisor writes parses, none included" do
  ["cruby", "spinel", "holding", "none"].each do |serving|
    assert_equal serving, F.parse(F.format(4, serving, "ready", "")).serving
  end
  s = F.parse(F.format(0, "none", "idle", ""))
  assert_equal 0, s.generation
  assert_equal "none", s.serving
  assert_equal "idle", s.build
  assert_equal 7, F.parse(F.format(7, "none", "ready", "")).generation
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
  assert_equal 0, reader.current_snapshot.generation
  File.write(path, F.format(2, "cruby", "building", ""))
  assert_equal 2, reader.current_snapshot.generation
  File.write(path, F.format(3, "spinel", "ready", ""))
  assert_equal "spinel", reader.current_snapshot.serving
  File.delete(path)
  assert_equal 0, reader.current_snapshot.generation
end

test "build status fails for failed and binary_failed only" do
  status = Cybertrain::Dev::BuildStatus.new
  assert !status.failed
  status.update(F.parse(F.format(1, "cruby", "binary_failed", "signal 11")))
  assert status.failed
  assert_equal "signal 11", status.output
  status.update(F.parse(F.format(2, "cruby", "building", "")))
  assert !status.failed
  # What the supervisor writes with serving none: no failure, no output.
  status.update(F.parse(F.format(2, "none", "ready", "")))
  assert !status.failed
  assert_equal "", status.output
  status.update(F.parse(F.format(0, "none", "idle", "")))
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

# The supervisor's way of writing: the whole file to PATH.tmp, renamed over
# PATH.
def write_into_place(path, text)
  File.write("#{path}.tmp", text)
  File.rename("#{path}.tmp", path)
  nil
end

test "two readers on one path are independent" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_two_readers_test"
  File.delete(path) if File.exist?(path)
  first = F::Reader.new(path)
  write_into_place(path, F.format(6, "cruby", "building", ""))
  assert_equal 6, first.current_snapshot.generation
  write_into_place(path, F.format(7, "spinel", "ready", ""))
  second = F::Reader.new(path)
  assert_equal 7, second.current_snapshot.generation
  assert_equal "spinel", second.current_snapshot.serving
  assert_equal 7, first.current_snapshot.generation
  File.delete(path)
end

test "a same-size rewrite renamed into place is noticed" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_same_size_test"
  File.delete(path) if File.exist?(path)
  reader = F::Reader.new(path)
  write_into_place(path, F.format(8, "cruby", "failed", "aaaa"))
  assert_equal "aaaa", reader.current_snapshot.output
  write_into_place(path, F.format(8, "cruby", "failed", "bbbb"))
  assert_equal "bbbb", reader.current_snapshot.output
  write_into_place(path, F.format(8, "cruby", "failed", "cccc"))
  assert_equal "cccc", reader.current_snapshot.output
  File.delete(path)
end

test "a file that goes away reads as the default snapshot, and is read again when it comes back" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_reappearing_test"
  File.delete(path) if File.exist?(path)
  reader = F::Reader.new(path)
  write_into_place(path, F.format(9, "cruby", "failed", "first"))
  assert_equal "failed", reader.current_snapshot.build
  File.delete(path)
  s = reader.current_snapshot
  assert_equal 0, s.generation
  assert_equal "idle", s.build
  assert_equal "", s.output
  write_into_place(path, F.format(10, "cruby", "binary_failed", "second"))
  assert_equal 10, reader.current_snapshot.generation
  assert_equal "second", reader.current_snapshot.output
  File.delete(path)
end

Cybertrain::Test.run!
