# SPIKE (throwaway): File.mtime polling loop for change detection, plus
# Dir.glob recursion, ENV reads, and Kernel#exit with a status code.
require "fileutils"

watchdir = File.expand_path("watchtmp", __dir__)
FileUtils.mkdir_p(watchdir)
f1 = File.join(watchdir, "a.rb")
File.write(f1, "one")

files = Dir.glob(File.join(watchdir, "**", "*.rb"))
puts "globbed=#{files.sort}"

mtimes = {}
files.each { |f| mtimes[f] = File.mtime(f) }

puts "ENV HOME set? #{!ENV["HOME"].nil?}"
puts "ENV MISSING_XYZ=#{ENV["MISSING_XYZ"].inspect}"

changed = false
5.times do |i|
  sleep 0.3
  if i == 2
    File.write(f1, "two-#{i}")
  end
  files.each do |f|
    nm = File.mtime(f)
    if nm != mtimes[f]
      puts "CHANGE DETECTED: #{f} old=#{mtimes[f]} new=#{nm}"
      mtimes[f] = nm
      changed = true
    end
  end
end

FileUtils.rm_rf(watchdir)
if changed
  puts "watch loop: change detected as expected"
  exit 0
else
  puts "watch loop: NO change detected (bug)"
  exit 7
end
