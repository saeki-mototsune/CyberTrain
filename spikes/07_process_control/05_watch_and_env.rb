# SPIKE (throwaway): File.mtime + Dir.glob polling for a file watcher; ENV reads; Kernel#exit(status).
require "fileutils"

dir = "watch_tmp"
FileUtils.mkdir_p(dir)
f1 = File.join(dir, "a.rb")
File.write(f1, "one")

def snapshot(dir)
  h = {}
  Dir.glob(File.join(dir, "**", "*.rb")).each do |path|
    h[path] = File.mtime(path).to_f
  end
  h
end

before = snapshot(dir)
puts "initial: #{before.keys.sort.inspect}"

sleep 1.1
File.write(f1, "one-changed")
f2 = File.join(dir, "b.rb")
File.write(f2, "two")

changed = false
5.times do
  after = snapshot(dir)
  if after != before
    changed = true
    puts "change detected: #{(after.keys - before.keys).sort.inspect} added, mtimes differ=#{after[f1] != before[f1]}"
    break
  end
  sleep 0.5
end
puts "changed=#{changed}"

puts "ENV HOME set? #{!ENV["HOME"].nil?}"
puts "ENV MISSING_XYZ_VAR nil? #{ENV["MISSING_XYZ_VAR"].nil?}"

FileUtils.rm_rf(dir)

exit 3
