# Cybertrain::Dev::GenStamp: which edits make the compiled generator stale.
# The rebuild loop skips compiling bin/gen.rb when nothing gen is made of has
# changed, so a wrong "fresh" here regenerates gen/ from an old binary. Runs
# under CRuby too.
require "cybertrain/dev/gen_stamp"
require "cybertrain/test"

ROOT = "tmp/dev_gen_stamp_test"

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

def write_file(path, content)
  current = +""
  File.dirname(path).split("/").each do |part|
    current << "/" unless current.empty?
    current << part
    Dir.mkdir(current) unless Dir.exist?(current)
  end
  File.write(path, content)
  nil
end

def app_at(root, toml)
  write_file("#{root}/bin/gen.rb", "# gen\n")
  write_file("#{root}/config/routes.rb", "# routes\n")
  write_file("#{root}/db/schema.rb", "# schema\n")
  write_file("#{root}/spin.toml", toml)
  write_file("#{root}/spin.lock", "# lock\n")
  write_file("#{root}/app/controllers/a.rb", "# a\n")
  write_file("#{root}/build/bin/gen", "binary\n")
  nil
end

def reset_app(toml)
  remove_tree(ROOT)
  app_at(ROOT, toml)
end

PLAIN_TOML = "[package]\nname = \"blog\"\n"
PATH_TOML = "[dependencies]\ncybertrain = { path = \"fw\" }\n"

# A stamp recorded for the app as it stands, then the pause that gives the
# next write a different mtime (filesystem timestamps can be coarse).
def recorded(root)
  stamp = Cybertrain::Dev::GenStamp.new(root)
  stamp.record(stamp.signature)
  sleep 0.05
  stamp
end

def assert_stale_after_rewrite(path)
  reset_app(PLAIN_TOML)
  write_file("#{ROOT}/#{path}", "# before\n")
  stamp = recorded(ROOT)
  assert stamp.fresh?, "fresh before #{path} changes"
  write_file("#{ROOT}/#{path}", "# after, longer\n")
  refute stamp.fresh?, "stale after #{path} changes"
end

at_exit { remove_tree(ROOT) }

test "fresh after record" do
  reset_app(PLAIN_TOML)
  assert recorded(ROOT).fresh?
end

test "stale with no stamp" do
  reset_app(PLAIN_TOML)
  refute Cybertrain::Dev::GenStamp.new(ROOT).fresh?
end

test "stale when build/bin/gen is missing" do
  reset_app(PLAIN_TOML)
  stamp = recorded(ROOT)
  File.delete("#{ROOT}/build/bin/gen")
  refute stamp.fresh?
end

test "stale after bin/gen.rb changes" do
  assert_stale_after_rewrite("bin/gen.rb")
end

test "stale after config/routes.rb changes" do
  assert_stale_after_rewrite("config/routes.rb")
end

test "stale after any other config/**/*.rb changes" do
  assert_stale_after_rewrite("config/app.rb")
  assert_stale_after_rewrite("config/routes/admin/deep.rb")
end

test "stale after db/schema.rb changes" do
  assert_stale_after_rewrite("db/schema.rb")
end

test "stale after spin.toml changes" do
  assert_stale_after_rewrite("spin.toml")
end

test "stale after spin.lock changes" do
  assert_stale_after_rewrite("spin.lock")
end

test "stale after a rewrite of the same size: the mtime counts" do
  reset_app(PLAIN_TOML)
  stamp = recorded(ROOT)
  File.write("#{ROOT}/config/routes.rb", "# ROUTES\n")
  refute stamp.fresh?
end

test "stale after a file of the same mtime changes size: the size counts" do
  reset_app(PLAIN_TOML)
  before = File.mtime("#{ROOT}/config/routes.rb")
  stamp = recorded(ROOT)
  File.write("#{ROOT}/config/routes.rb", "# routes, longer\n")
  File.utime(before, before, "#{ROOT}/config/routes.rb")
  refute stamp.fresh?
end

test "stale after a config file is added" do
  reset_app(PLAIN_TOML)
  stamp = recorded(ROOT)
  write_file("#{ROOT}/config/routes/admin.rb", "# admin\n")
  refute stamp.fresh?
end

test "stale after an input is removed" do
  reset_app(PLAIN_TOML)
  stamp = recorded(ROOT)
  File.delete("#{ROOT}/spin.lock")
  refute stamp.fresh?
end

test "not stale after app/controllers/a.rb changes" do
  reset_app(PLAIN_TOML)
  stamp = recorded(ROOT)
  write_file("#{ROOT}/app/controllers/a.rb", "# a, longer\n")
  write_file("#{ROOT}/app/controllers/b.rb", "# b\n")
  assert stamp.fresh?
end

# The framework is compiled into gen, and with a path dependency nothing moves
# spin.lock when it is edited.
test "stale after a path dependency's generator changes" do
  reset_app(PATH_TOML)
  write_file("#{ROOT}/fw/cybertrain/generator/runner.rb", "# runner\n")
  stamp = recorded(ROOT)
  assert stamp.fresh?
  write_file("#{ROOT}/fw/cybertrain/generator/runner.rb", "# runner, longer\n")
  refute stamp.fresh?
end

test "stale after a path dependency's cybertrain.rb changes" do
  reset_app(PATH_TOML)
  write_file("#{ROOT}/fw/cybertrain.rb", "# entry\n")
  stamp = recorded(ROOT)
  write_file("#{ROOT}/fw/cybertrain.rb", "# entry, longer\n")
  refute stamp.fresh?
end

test "a path dependency is found however spin.toml spells it" do
  outside = File.expand_path("#{ROOT}/outside")
  ["cybertrain = { path = \"../outside\" }\n",
   "cybertrain = { path = \"#{outside}\" }\n",
   "cybertrain = { path = '#{outside}' }\n",
   "cybertrain = {path=\"#{outside}\"}\n",
   "[dependencies.cybertrain]\npath = \"#{outside}\"\n",
   "other = { path = \"elsewhere\" }\ncybertrain = { path = \"#{outside}\" }\n"].each do |toml|
    remove_tree(ROOT)
    app_at("#{ROOT}/app", toml)
    write_file("#{ROOT}/outside/cybertrain/router.rb", "# router\n")
    stamp = recorded("#{ROOT}/app")
    assert stamp.fresh?, toml
    write_file("#{ROOT}/outside/cybertrain/router.rb", "# router, longer\n")
    refute stamp.fresh?, toml
  end
end

# Dir.glob would read these names as patterns, match nothing, and leave every
# edit under them unseen.
test "directories whose names hold glob characters are still walked" do
  root = "#{ROOT}/my [app]"
  remove_tree(ROOT)
  app_at(root, "[dependencies]\ncybertrain = { path = \"fw {1}\" }\n")
  write_file("#{root}/fw {1}/cybertrain/router.rb", "# router\n")
  stamp = recorded(root)
  write_file("#{root}/config/extra.rb", "# extra\n")
  refute stamp.fresh?
  stamp = recorded(root)
  write_file("#{root}/fw {1}/cybertrain/router.rb", "# router, longer\n")
  refute stamp.fresh?
end

test "a dependency directory that does not exist is no error" do
  reset_app("[dependencies]\ncybertrain = { path = \"missing\" }\n")
  assert recorded(ROOT).fresh?
end

test "a root with nothing in it signs nothing and is stale" do
  remove_tree(ROOT)
  stamp = Cybertrain::Dev::GenStamp.new(ROOT)
  assert_equal "", stamp.signature
  refute stamp.fresh?
end

test "record writes tmp/gen-inputs, creating tmp" do
  reset_app(PLAIN_TOML)
  stamp = Cybertrain::Dev::GenStamp.new(ROOT)
  refute File.directory?("#{ROOT}/tmp")
  assert stamp.record("the signature").nil?
  assert_equal "the signature", File.read("#{ROOT}/tmp/gen-inputs")
end

test "a stamp that cannot be written costs a compile, not the rebuild" do
  reset_app(PLAIN_TOML)
  File.write("#{ROOT}/tmp", "a file where the directory goes\n")
  stamp = Cybertrain::Dev::GenStamp.new(ROOT)
  assert stamp.record(stamp.signature).nil?
  refute stamp.fresh?
end

Cybertrain::Test.run!
