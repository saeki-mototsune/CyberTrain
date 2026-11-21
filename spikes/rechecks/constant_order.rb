# Reduced shapes only: NOTES 17. A constant assigned with `=` and read before
# its assignment, at top level, in a module body and in a class body, each
# rescued; and one read from a method called after the assignment. The
# messages are not printed: they differ (CRuby names `Early::Late`, the
# compiled program `Late::MAX`, since it knows the class `Late` early). A
# class used above its `class` statement still differs on 2026.11.04.7026
# (NOTES status 17), so it is not here.
module M
  def self.early = LATE + 1
end
begin
  A = B + 1
rescue NameError => e
  puts "top level: NameError"
end
B = 2
module M; LATE = 41; end
puts M.early

module Retry; end
begin
  module Job
    BACKOFF = Retry::BACKOFF
  end
rescue NameError => e
  puts "module body: NameError"
end
module Retry
  BACKOFF = [1, 2, 3]
end
begin
  class Early
    LIMIT = Late::MAX + 1
  end
rescue NameError => e
  puts "class body: NameError"
end
class Late
  MAX = 9
end
puts Retry::BACKOFF.size + Late::MAX
