# Runs ARGV under a pty: what it shows in the first second before a line is
# typed, then after "hi\n" is typed.
require "pty"
require "io/wait"
PTY.spawn(*ARGV) do |r, w, pid|
  before = +""
  deadline = Time.now + 1.0
  while Time.now < deadline
    if r.wait_readable(0.05)
      begin
        before << r.read_nonblock(100)
      rescue IO::WaitReadable, EOFError, Errno::EIO
      end
    end
  end
  w.write("hi\n")
  after = +""
  deadline = Time.now + 2.0
  while Time.now < deadline
    if r.wait_readable(0.05)
      begin
        after << r.read_nonblock(100)
      rescue EOFError, Errno::EIO
        break
      rescue IO::WaitReadable
      end
    end
  end
  Process.wait(pid)
  puts "before typing: #{before.inspect}"
  puts "after typing: #{after.inspect}"
end
