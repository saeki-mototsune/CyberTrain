# Reduced shapes only: NOTES 12, 18 and 60. Not a framework-wide verdict.
key, value = "key=value".split("=", 2)
puts "destructure: #{key}/#{value}"

module Recheck
  module Earlier; end
end
module Recheck
  class Label
    def text = "kept"
  end
  @@label = Label.new
  def self.label_text = @@label.text
end
puts "module class variable: #{Recheck.label_text}"

def append_after_slice(bytes)
  rest = bytes.byteslice(0, bytes.bytesize)
  i = 0
  while i < 1
    rest << "!"
    i += 1
  end
  rest
end
puts "NUL bytes: #{append_after_slice("ab\x00cd").bytes.join(',')}"
