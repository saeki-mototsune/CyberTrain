require "openssl"
class Lg
  def initialize = (@io = nil)
  def log(line)
    @io.puts(line) if @io
    nil
  end
end
Lg.new.log("hello")
puts "ok"                # CRuby: ok
