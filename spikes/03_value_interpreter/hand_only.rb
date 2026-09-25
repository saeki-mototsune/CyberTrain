# SPIKE (throwaway): baseline - hand-written compiled renderer alone (no interpreter in the program to widen shared helpers)
require_relative "models"
iters = (ARGV[0] || "10000").to_i
posts = build_posts
nav = [{ "label" => "Home", "url" => "/" }, { "label" => "About & Contact", "url" => "/about?a=1&b=2" }]
owner = User.new("Matz <admin>")
out = render_hand("My Blog", nav, posts, owner, "(c) 2026 'cybertrain'")
File.write(File.join(__dir__, "out_hand_only.html"), out)
total = 0
t0 = now_s
iters.times { total += render_hand("My Blog", nav, posts, owner, "(c) 2026 'cybertrain'").bytesize }
th = now_s - t0
puts "hand_only: #{iters} renders #{th.round(3)} s = #{(th / iters * 1_000_000).round(1)} us/render (#{out.bytesize} bytes, checksum #{total})"
