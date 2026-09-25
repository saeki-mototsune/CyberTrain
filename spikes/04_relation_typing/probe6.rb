# SPIKE (throwaway): what element type does Array<obj> built via << in a block get; first -> Obj|nil?
class Po
  attr_accessor :t
  def initialize = (@t = "")
end
def rows = [{"t" => "a"}, {"t" => 1}]
def mk_a
  out = []
  rows.each { |r| m = Po.new; m.t = r["t"].to_s; out << m }
  out
end
def mk_b = rows.map { |r| m = Po.new; m.t = r["t"].to_s; m }
def mk_c
  out = [Po.new].clear
  rows.each { |r| m = Po.new; m.t = r["t"].to_s; out << m }
  out
end
def first_a = mk_a.first
def first_b = mk_b.first
def first_c = mk_c.first
puts first_a.t, first_b.t, first_c.t
puts mk_a.size
