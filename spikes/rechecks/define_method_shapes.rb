# Reduced shapes only: `define_method` called while a class body runs, which
# compiles on 2026.11.04.7026. NOTES, "Permanent: how CyberTrain is written
# for an ahead-of-time compiler", cites this file for what "no
# `define_method`" does and does not mean. A method defined while the program
# runs is still refused (`self.class.send(:define_method, name) { ... }` from
# an instance method; `Conf.send(:define_method, name.to_sym) { ... }` with a
# name read from ARGV), so those shapes are not here: their source is in the
# note under that table.

# A literal name in the class body, with and without a block parameter.
class Greeter
  define_method(:greet) { "hello" }
  define_method(:twice) { |x| x * 2 }
end
g = Greeter.new
puts g.greet
puts g.twice(4)

# A class macro that defines two methods with literal names, whose blocks
# read and write an ivar; called from a subclass body. The shape of Rails'
# `has_secure_password`, without what it does.
class MacroBase
  def self.has_secret
    define_method(:authenticate) { |plain| plain == @secret }
    define_method(:secret=) { |v| @secret = v }
  end
end
class Account < MacroBase
  has_secret
end
a = Account.new
a.secret = "s3"
puts a.authenticate("s3")
puts a.authenticate("no")

# A macro that takes the name as its parameter, called with literal Symbols
# from a class body; the second macro's block reads an ivar by the name.
class ReaderBase
  def self.constant_reader(name)
    define_method(name) { 42 }
  end

  def self.value_reader(name)
    define_method(name) { @vals[name.to_s] }
  end

  def initialize
    @vals = { "a" => "1", "b" => "2" }
  end
end
class Settings < ReaderBase
  constant_reader :answer
  constant_reader :other
  value_reader :a
  value_reader :b
end
s = Settings.new
puts s.answer
puts s.other
puts s.a
puts s.b
