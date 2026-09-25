# SPIKE (throwaway): does system(), $?, backtick-style stderr capture, and Process.pid compile & work?
puts "pid=#{Process.pid}"

ok = system("true")
puts "ok=#{ok} status=#{$?}"

ok2 = system("false")
puts "ok2=#{ok2} status2=#{$?}"

ok3 = system("sh", "-c", "echo out1; echo err1 1>&2")
puts "ok3=#{ok3}"

# capture combined stdout+stderr via shell redirection + system, writing to a temp file
tmp = "/tmp/sp_spike_out_#{Process.pid}.txt"
system("sh -c 'echo hello_out; echo hello_err 1>&2' > #{tmp} 2>&1")
puts File.read(tmp)
File.delete(tmp)
