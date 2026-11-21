# Reduced shapes only: NOTES 32, 44, 45, 47 and 50, one section each, in one
# program. The value of a rescuing yielding call is never appended here: that
# is rule 79, which still fails on 2026.11.04.7026.

# 32: a yielding method with `rescue => e`, called from a block nested in a
# block, with a valued inner block and with one whose only expression is
# `raise`.
class Conn
  attr_reader :log
  def initialize; @log = +""; end
  def transaction
    @log << "begin;"
    begin
      yield
      @log << "commit;"
    rescue => e
      @log << "rollback(#{e.message});"
      raise
    end
  end
end
conn = Conn.new
[1, 2].each do |i|
  [10].each do |j|
    conn.transaction { conn.log << "work#{i + j};" }
  end
end
begin
  [1].each do |i|
    [2].each do |j|
      conn.transaction do
        conn.log << "boom;"
        raise ArgumentError, "bad" if i + j == 3
        conn.log << "unreached;"
      end
    end
  end
rescue ArgumentError => e
  puts "outer " + e.message
end
begin
  [1].each do |i|
    [2].each do |j|
      conn.transaction { raise ArgumentError, "only raise" }
    end
  end
rescue ArgumentError => e
  puts "outer " + e.message
end
puts conn.log

# 45/50: `rescue => e` and a bookkeeping `ensure` in a re-entrant yielding
# method called from nested blocks, nested and with a failing inner call.
class Reentrant
  attr_reader :log
  def initialize; @log = +""; @depth = 0; @broken = false; end
  def transaction
    completed = false
    @depth += 1
    @log << "begin#{@depth};"
    begin
      yield
      completed = true
      @log << "commit#{@depth};"
    rescue => e
      completed = true
      @log << "rollback#{@depth}(#{e.message});"
      raise
    ensure
      @broken = true unless completed
      @depth -= 1
    end
  end
  def broken? = @broken
end
nested = Reentrant.new
[1].each do |i|
  [2].each do |j|
    nested.transaction do
      nested.transaction { nested.log << "inner;" }
      nested.log << "outer;"
    end
  end
end
puts nested.log
puts nested.broken?
failing = Reentrant.new
begin
  [1].each do |i|
    [2].each do |j|
      failing.transaction do
        begin
          failing.transaction { raise ArgumentError, "inner fails" }
        rescue ArgumentError
          failing.log << "inner rescued;"
        end
        failing.log << "outer continues;"
      end
    end
  end
end
puts failing.log
puts failing.broken?

# 44: `break` past a `begin/rescue` and past an `ensure`, `return` from a
# block given to a user-defined yielding method, `break` in a forwarded block.
def guarded
  begin
    yield 1
    yield 2
  rescue ArgumentError => e
    puts "rescued"
  end
  "end of guarded"
end
broke = guarded { |x| break "broke at #{x}" if x == 1 }
puts broke
def ensured
  yield 1
ensure
  puts "ensure ran"
end
puts(ensured { |x| break "broke ensured" })
def yielder; yield 1; yield 2; "yielder done"; end
def user
  yielder { |x| return "returned from user at #{x}" }
  "fell through"
end
puts user
def fwd(&block) = yielder(&block)
puts(fwd { |x| break "broke forwarded #{x}" })

# 47: `is_a?` after `rescue StandardError`, and `begin ... ensure ... end`
# ending a block.
class QueryLimitExceeded < StandardError; end
class QueryTooDeep < QueryLimitExceeded; end
def boom(n)
  raise QueryTooDeep, "deep" if n == 1
  raise KeyError, "k" if n == 2
  raise ArgumentError, "a"
end
[1, 2, 3].each do |n|
  begin
    boom(n)
  rescue StandardError => e
    puts "#{e.class.name} limit=#{e.is_a?(QueryLimitExceeded)} index=#{e.is_a?(IndexError)} std=#{e.is_a?(StandardError)}"
  end
end
trace = +""
[1, 2].each do |i|
  begin
    trace << "body#{i};"
  ensure
    trace << "ensure#{i};"
  end
end
puts trace
doubled = [1, 2].map do |i|
  begin
    i * 2
  ensure
    trace << "m;"
  end
end
puts doubled.sum
