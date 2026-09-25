# SPIKE (throwaway): the "gen 2" target of the execv spike; ARGV[0] carries the marker execv passed as argv[1].
puts "gen 2, pid=#{Process.pid}, marker=#{ARGV[0]}"
