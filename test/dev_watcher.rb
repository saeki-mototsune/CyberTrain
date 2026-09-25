# Cybertrain::Dev::Watcher: mtime snapshots over Dir.glob patterns and the
# changed? semantics the development loop polls with. Runs under CRuby too.
require "cybertrain/dev/watcher"
require "cybertrain/test"

ROOT = "tmp/dev_watcher_test"

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

def reset_root
  remove_tree(ROOT)
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  Dir.mkdir(ROOT)
  Dir.mkdir("#{ROOT}/app")
  Dir.mkdir("#{ROOT}/app/models")
  File.write("#{ROOT}/app/models/post.rb", "class Post\nend\n")
  File.write("#{ROOT}/app/application.rb", "# app\n")
  File.write("#{ROOT}/app/notes.txt", "not watched\n")
  nil
end

# Filesystem timestamps can be coarse (a few ms on Linux): leave a gap so a
# rewrite gets a different mtime than the snapshot saw.
def pause
  sleep 0.05
end

def watcher
  Cybertrain::Dev::Watcher.new(["#{ROOT}/app/**/*.rb"], 0.05)
end

at_exit { remove_tree(ROOT) }

test "snapshot maps every matching file to its mtime" do
  reset_root
  snap = watcher.snapshot
  assert_equal ["#{ROOT}/app/application.rb", "#{ROOT}/app/models/post.rb"], snap.keys.sort
  t = File.mtime("#{ROOT}/app/models/post.rb")
  assert_equal t.to_i * 1_000_000_000 + t.nsec, snap["#{ROOT}/app/models/post.rb"]
end

test "changed? is false before anything changes" do
  reset_root
  w = watcher
  refute w.changed?
  refute w.changed?
end

test "changed? is true after a file is rewritten" do
  reset_root
  w = watcher
  pause
  File.write("#{ROOT}/app/models/post.rb", "class Post\n  # edited\nend\n")
  assert w.changed?
end

test "changed? is true after a file is added" do
  reset_root
  w = watcher
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  assert w.changed?
end

test "changed? is true after a file is removed" do
  reset_root
  w = watcher
  File.delete("#{ROOT}/app/application.rb")
  assert w.changed?
end

test "changed? is false again once the change has been seen" do
  reset_root
  w = watcher
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  assert w.changed?
  refute w.changed?
end

test "files outside the patterns are ignored" do
  reset_root
  w = watcher
  pause
  File.write("#{ROOT}/app/notes.txt", "still not watched\n")
  refute w.changed?
end

test "changed_paths lists what was added, modified and removed" do
  reset_root
  w = watcher
  pause
  File.write("#{ROOT}/app/models/post.rb", "class Post\n  # edited\nend\n")
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  File.delete("#{ROOT}/app/application.rb")
  assert_equal ["#{ROOT}/app/application.rb", "#{ROOT}/app/models/comment.rb", "#{ROOT}/app/models/post.rb"],
               w.changed_paths
  assert_equal [], w.changed_paths
end

test "start yields the changed paths from its polling thread until stop" do
  reset_root
  w = watcher
  seen = []
  w.start { |paths| paths.each { |p| seen << p } }
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  waited = 0
  while seen.empty? && waited < 100
    sleep 0.02
    waited += 1
  end
  w.stop
  assert_equal ["#{ROOT}/app/models/comment.rb"], seen
  File.write("#{ROOT}/app/models/tag.rb", "class Tag\nend\n")
  sleep 0.15
  assert_equal 1, seen.size
end

def wait_for_calls(calls, count)
  waited = 0
  while calls.size < count && waited < 150
    sleep 0.02
    waited += 1
  end
  nil
end

test "an edit saved while the block runs is reported next time; generated files are absorbed" do
  reset_root
  Dir.mkdir("#{ROOT}/gen")
  File.write("#{ROOT}/gen/routes.rb", "# routes v1\n")
  w = Cybertrain::Dev::Watcher.new(["#{ROOT}/app/**/*.rb", "#{ROOT}/gen/**/*.rb"], 0.05, ["#{ROOT}/gen/"])
  calls = []
  w.start do |paths|
    calls << paths.join(",")
    if calls.size == 1
      # What a rebuild does to gen/, and a developer saving a fix meanwhile.
      pause
      File.write("#{ROOT}/gen/routes.rb", "# routes v2\n")
      File.write("#{ROOT}/gen/models.rb", "# models\n")
      File.write("#{ROOT}/app/models/post.rb", "class Post\n  # fixed during the build\nend\n")
    end
  end
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  wait_for_calls(calls, 2)
  sleep 0.15
  w.stop
  assert_equal ["#{ROOT}/app/models/comment.rb", "#{ROOT}/app/models/post.rb"], calls
end

test "without generated prefixes every change made by the block is reported next time" do
  reset_root
  w = watcher
  calls = []
  w.start do |paths|
    calls << paths.join(",")
    File.write("#{ROOT}/app/models/tag.rb", "class Tag\nend\n") if calls.size == 1
  end
  File.write("#{ROOT}/app/models/comment.rb", "class Comment\nend\n")
  wait_for_calls(calls, 2)
  sleep 0.15
  w.stop
  assert_equal ["#{ROOT}/app/models/comment.rb", "#{ROOT}/app/models/tag.rb"], calls
end

Cybertrain::Test.run!
