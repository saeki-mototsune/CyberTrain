# SPIKE (throwaway): which html_escape formulation is fastest under Spinel?
def esc_chars(s)
  out = String.new
  s.each_char do |c|
    if c == "&" then out << "&amp;"
    elsif c == "<" then out << "&lt;"
    elsif c == ">" then out << "&gt;"
    elsif c == "\"" then out << "&quot;"
    elsif c == "'" then out << "&#39;"
    else out << c
    end
  end
  out
end
def esc_gsub(s) = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;").gsub("'", "&#39;")
def esc_bytes(s)
  n = s.bytesize
  i = 0
  start = 0
  out = nil
  while i < n
    b = s.getbyte(i)
    rep = nil
    if b == 38 then rep = "&amp;"
    elsif b == 60 then rep = "&lt;"
    elsif b == 62 then rep = "&gt;"
    elsif b == 34 then rep = "&quot;"
    elsif b == 39 then rep = "&#39;"
    end
    if rep
      out = String.new if out.nil?
      out << s.byteslice(start, i - start) if i > start
      out << rep
      start = i + 1
    end
    i += 1
  end
  return s if out.nil?
  out << s.byteslice(start, n - start) if n > start
  out
end

def esc_cgi(s) = esc_bytes(s)
s = "Post 12: \"quotes\" & <tags> and a longer tail of ordinary text here"
p2 = "Body of post 3. Body of post 3. Body of post 3. "
[esc_chars(s), esc_gsub(s), esc_bytes(s), esc_cgi(s)].each { |x| puts x }
n = 200_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC); tot = 0
n.times { tot += esc_chars(s).size + esc_chars(p2).size }
puts "chars #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9).round} ns"
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times { tot += esc_gsub(s).size + esc_gsub(p2).size }
puts "gsub  #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9).round} ns"
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times { tot += esc_bytes(s).size + esc_bytes(p2).size }
puts "bytes #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9).round} ns"
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times { tot += esc_cgi(s).size + esc_cgi(p2).size }
puts "cgi   #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9).round} ns #{tot}"
