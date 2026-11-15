class C
  def x = 7
end
blk = proc { x }
puts C.new.instance_exec(&blk)
