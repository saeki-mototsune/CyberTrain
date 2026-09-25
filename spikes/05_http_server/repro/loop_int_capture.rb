# SPIKE (throwaway): minimal: int local mutated in loop-do block plus interpolation in rescue
def m(a)
  n = 0
  loop do
    x = a.shift
    raise EOFError, "done" if x.nil?
    n += x.bytesize
  end
  n
rescue EOFError
  "eof #{n}"
end
p m(["ab", "cde"])
