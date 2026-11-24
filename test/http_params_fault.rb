# A bare HttpHandler that loads cybertrain/params but not cybertrain/context:
# Params#require's ParameterMissing is still the client's fault, a 400, on
# Server#respond's bare-app path. cybertrain/params.rb registers it with
# ClientError.extra_faults at load (through cybertrain/http/extra_faults.rb,
# which loads nothing else of the layer); it once did so in context.rb, and a
# program like this one answered 500. Any other exception is still a 500,
# and each is logged at its level (info for the 400, error for the 500).
require "socket"
require "cybertrain/http/server"
require "cybertrain/params"

# Keeps the Server's log lines, printed after the exchanges so the snapshot
# does not depend on how standard output and standard error interleave.
class RecordingHttpLog < Cybertrain::HttpLog
  attr_reader :recorded

  def initialize
    @recorded = Array.new(0) { "" }
  end

  def info(msg)
    @recorded << "info: #{msg}"
    nil
  end

  def error(msg)
    @recorded << "error: #{msg}"
    nil
  end
end

# /missing requires `article[...]`, which the query does not send; /found
# sends it; /boom raises the app's own error.
class ParamsFaultHandler < Cybertrain::HttpHandler
  def call(request)
    response = Cybertrain::Response.new
    response.content_type = "text/plain"
    params = Cybertrain::Params.new
    title = request.query_value("title")
    params.set_path(["article", "title"], title) unless title.empty?
    case request.path
    when "/missing", "/found"
      response.body = params.require(:article)[:title].to_s
    when "/boom"
      raise ArgumentError, "the app's own"
    else
      response.status = 404
      response.body = "Not Found"
    end
    response
  end
end

# Sends one request and prints the status code and the body.
def exchange(port, target)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET #{target} HTTP/1.1\r\nHost: params-fault\r\nConnection: close\r\n\r\n")
  buf = +""
  loop do
    break if sock.wait_readable(5).nil?

    begin
      buf << sock.readpartial(16384)
    rescue EOFError, Errno::ECONNRESET
      break
    end
  end
  sock.close
  idx = buf.index("\r\n\r\n")
  if idx.nil?
    puts "no response head: #{buf.inspect}"
  else
    status = buf[0, buf.index("\r\n")].split(" ")[1]
    puts "#{target} #{status} #{buf[idx + 4, buf.length - idx - 4]}"
  end
end

puts "registered: #{Cybertrain::ClientError.extra_faults.include?("SpinelHttp::Params::ParameterMissing")}"
log = RecordingHttpLog.new
server = Cybertrain::Server.new(ParamsFaultHandler.new, port: 0, logger: log)
server.start
port = server.port

exchange(port, "/found?title=Hi")
exchange(port, "/missing")
exchange(port, "/boom")

server.stop
log.recorded.each { |line| puts line }
