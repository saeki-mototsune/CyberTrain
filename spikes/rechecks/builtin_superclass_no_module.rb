# Reduced shape only: the passing half of NOTES 104. This program defines no
# module and requires nothing, and in it `superclass` on Ruby's own
# exception classes answers the whole chain on 2026.11.04.7026. Adding one
# `module Pkg; end` line makes the compiled program stop with NoMethodError
# (differing/builtin_superclass_with_module.rb), so keep this file free of
# modules and of requires.

def chain(kind)
  raise "rt" if kind == 1
  Integer("zz")
rescue StandardError => e
  names = []
  c = e.class
  while c
    names << c.name
    c = c.superclass
  end
  names.join(" < ")
end

2.times { |i| puts chain(i) }
