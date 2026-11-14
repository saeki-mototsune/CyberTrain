# spikes/NOTES.md rule 112: File#flock, and which stat a File answers.
# Run under CRuby and compiled (`spinel spikes/phase5/flock_fstat.rb -o
# /tmp/flock_fstat && /tmp/flock_fstat`); the lines differ only where marked.
require "tmpdir"

dir = Dir.mktmpdir("flock-fstat")
path = "#{dir}/probe.lock"

puts "constants #{File::LOCK_EX} #{File::LOCK_SH} #{File::LOCK_NB} #{File::LOCK_UN}"
a = File.open(path, File::RDWR | File::CREAT, 0o644)
b = File.open(path, File::RDWR | File::CREAT, 0o644)
# 0 on success; false (no EWOULDBLOCK raised) when LOCK_NB cannot have it.
# Two opens in one process conflict: flock is per open file description.
puts "a ex #{a.flock(File::LOCK_EX | File::LOCK_NB).inspect}"
puts "b ex #{b.flock(File::LOCK_EX | File::LOCK_NB).inspect}"
puts "b sh #{b.flock(File::LOCK_SH | File::LOCK_NB).inspect}"

old = File.stat(path).ino
File.delete(path)
c = File.open(path, File::RDWR | File::CREAT, 0o644)
# CRuby: fstat of a's descriptor, the unlinked inode ("old").
# Spinel: stat(2) of the path, now c's file ("new").
own = "raised"
begin
  own = a.stat.ino == old ? "old" : "new"
rescue StandardError
  own = "raised"
end
puts "a.stat names the #{own} file"
# Both: IO.for_fd's handle is fstat(2) of the descriptor ("old").
io = IO.for_fd(a.fileno, autoclose: false)
fd = io.stat.ino == old ? "old" : "new"
# Spinel's for_fd IO is a dup of the descriptor that would keep the flock
# alive after a closes: closed here. CRuby's shares a's descriptor: left.
io.close unless RUBY_ENGINE == "ruby"
puts "IO.for_fd(a.fileno).stat names the #{fd} file"

a.close
puts "b ex once a is closed #{b.flock(File::LOCK_EX | File::LOCK_NB).inspect}"
b.close
c.close
File.delete(path)
Dir.rmdir(dir)
