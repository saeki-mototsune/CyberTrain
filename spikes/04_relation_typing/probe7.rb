# SPIKE (throwaway): which from_row cast formulations give concrete ivar types (Integer, Integer?, String?, Time?) from poly row values, and does nil survive?
class Rec
  attr_accessor :i, :in, :sn, :tn, :tn2
  def initialize
    @i = 0
    @in = nil
    @sn = nil
    @tn = nil
    @tn2 = nil
  end
end
def cast_i(v) = v.to_i
def cast_in(v) = v.nil? ? nil : v.to_i
def cast_sn(v) = v.nil? ? nil : v.to_s
def cast_tn(v) = v.nil? ? nil : Time.at(v.to_i)
row1 = {"i" => 7, "in" => 5, "sn" => "s", "t" => 1700000000, "x" => 1.5}
row2 = {"i" => 8, "in" => nil, "sn" => nil, "t" => nil, "x" => "q"}
rows = [row1, row2]
rows.each do |row|
  r = Rec.new
  r.i = cast_i(row["i"])
  r.in = cast_in(row["in"])
  r.sn = cast_sn(row["sn"])
  r.tn = cast_tn(row["t"])
  r.tn2 = Time.at(row["t"].to_i) unless row["t"].nil?
  puts "i+1=#{r.i + 1} in=#{r.in.inspect} sn=#{r.sn.inspect} tn.nil?=#{r.tn.nil?} tn2.nil?=#{r.tn2.nil?}"
  puts "tn.year=#{r.tn.year}" unless r.tn.nil?
end
