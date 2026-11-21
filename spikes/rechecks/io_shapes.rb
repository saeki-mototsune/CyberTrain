# Reduced shapes only: NOTES 19 and 28.
require "stringio"
require "uri"

# 28: `URI.decode_www_form_component` on malformed escapes.
["%ZZ", "a%", "%4", "ok%41", "%"].each do |s|
  begin
    puts URI.decode_www_form_component(s)
  rescue ArgumentError => e
    puts "ArgumentError for " + s
  end
end

# 19: STDOUT, STDERR and a StringIO behind one `@io.puts` / `io.puts` site.
class Log
  def initialize(io); @io = io; end
  def line(s); @io.puts(s); end
  def raw(s); @io.write(s); end
end
buf = StringIO.new
to_out = Log.new(STDOUT)
to_buf = Log.new(buf)
to_out.line("to stdout")
to_buf.line("to buffer")
to_out.raw("w1\n"); to_buf.raw("w2\n")
puts buf.string
def emit(io, s) = io.puts(s)
emit(STDOUT, "direct")
emit(buf, "direct2")
puts buf.string.size
# Standard error last and after a flush, so that the order of the two
# streams in one captured file does not depend on buffering.
STDOUT.flush
to_err = Log.new(STDERR); to_err.line("to stderr")
