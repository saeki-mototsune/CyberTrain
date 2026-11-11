# Reduced shapes only: NOTES 46 (names), 47 (is_a?), 53 (unraised message)
# and 54 (hierarchy). The raised class is chosen at run time and caught by
# `rescue StandardError`, the shape rules 47 and 54 were seen in. The
# superclass walk covers user-defined classes only: on 2026.11.04.7026 it
# still fails for a package class such as JSON::ParserError (NOTES status 54).
require "json"
module Recheck
  class Invalid < StandardError; end
  class LimitExceeded < Invalid; end
  class TooDeep < LimitExceeded; end
  class Other < StandardError; end
end

def raise_one(kind)
  raise Recheck::TooDeep, "deep" if kind == 0
  raise Recheck::Other, "other" if kind == 1
  JSON.parse("{")
end

def describe(kind)
  raise_one(kind)
rescue StandardError => e
  "#{e.class.name} is_a LimitExceeded: #{e.is_a?(Recheck::LimitExceeded)}"
end

def chain(kind)
  raise_one(kind)
rescue StandardError => e
  names = []
  c = e.class
  while c
    names << c.name
    c = c.superclass
  end
  names.join(" < ")
end

puts "unraised message: #{Recheck::TooDeep.new('kept').message}"
puts describe(0)
puts describe(1)
puts describe(ARGV.size + 2)
puts chain(0)
puts chain(1)
