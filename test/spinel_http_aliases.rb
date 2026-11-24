# The HTTP layer is spinel-http's (docs/design.md D91): cybertrain/http/*.rb
# alias its classes into Cybertrain, and cybertrain reopens some of them.
# These cases pin that the aliases are the layer's own class objects, that
# the reopenings reached them, that what an application sees is unchanged
# (a missing parameter and a malformed query are 400s through
# ContextHandler, `rescue Cybertrain::PortInUse` catches a busy port and
# `cybertrain server`'s hint follows it), and that the String form of
# assert_raises still matches a `"Cybertrain::..."` name.
#
# cybertrain/i18n loads first here, before the layer: its Request reopening
# must not depend on the order (test/http_request.rb loads them the other
# way round).
require "cybertrain/i18n"
require "socket"
require "cybertrain/context_handler"
require "cybertrain/middleware"
require "cybertrain/params"
require "cybertrain/request_format"
require "cybertrain/http/server"
require "cybertrain/http/cookies"
require "cybertrain/http/sse"
require "cybertrain/http/gzip_ffi"
require "cybertrain/http/multipart"
require "cybertrain/http/parameter_filter"
require "cybertrain/roles/server"
require "cybertrain/test"

test "each Cybertrain:: name of the layer is SpinelHttp's class or module" do
  assert Cybertrain::BodyWriter.equal?(SpinelHttp::BodyWriter)
  assert Cybertrain::BlockWriter.equal?(SpinelHttp::BlockWriter)
  assert Cybertrain::Sink.equal?(SpinelHttp::Sink)
  assert Cybertrain::ClientError.equal?(SpinelHttp::ClientError)
  assert Cybertrain::Cookies.equal?(SpinelHttp::Cookies)
  assert Cybertrain::GzipDecoder.equal?(SpinelHttp::GzipDecoder)
  assert Cybertrain::GzipFFI.equal?(SpinelHttp::GzipFFI)
  assert Cybertrain::GzipFFIDecoder.equal?(SpinelHttp::GzipFFIDecoder)
  assert Cybertrain::HttpHandler.equal?(SpinelHttp::HttpHandler)
  assert Cybertrain::HeaderName.equal?(SpinelHttp::HeaderName)
  assert Cybertrain::IpAddress.equal?(SpinelHttp::IpAddress)
  assert Cybertrain::Key.equal?(SpinelHttp::Key)
  assert Cybertrain::HttpLog.equal?(SpinelHttp::HttpLog)
  assert Cybertrain::HttpLogContext.equal?(SpinelHttp::HttpLogContext)
  assert Cybertrain::HttpLogSwitch.equal?(SpinelHttp::HttpLogSwitch)
  assert Cybertrain::Multipart.equal?(SpinelHttp::Multipart)
  assert Cybertrain::MultipartFormParser.equal?(SpinelHttp::MultipartFormParser)
  assert Cybertrain::MultipartForm.equal?(SpinelHttp::MultipartForm)
  assert Cybertrain::MultipartParser.equal?(SpinelHttp::MultipartParser)
  assert Cybertrain::MultipartMalformed.equal?(SpinelHttp::MultipartMalformed)
  assert Cybertrain::MultipartTooManyParts.equal?(SpinelHttp::MultipartTooManyParts)
  assert Cybertrain::MultipartPartTooLarge.equal?(SpinelHttp::MultipartPartTooLarge)
  assert Cybertrain::MultipartHeaderTooLarge.equal?(SpinelHttp::MultipartHeaderTooLarge)
  assert Cybertrain::UnsupportedMediaType.equal?(SpinelHttp::UnsupportedMediaType)
  assert Cybertrain::Params.equal?(SpinelHttp::Params)
  assert Cybertrain::HttpParser.equal?(SpinelHttp::HttpParser)
  assert Cybertrain::RequestHead.equal?(SpinelHttp::RequestHead)
  assert Cybertrain::Query.equal?(SpinelHttp::Query)
  assert Cybertrain::QueryInvalid.equal?(SpinelHttp::QueryInvalid)
  assert Cybertrain::QueryLimitExceeded.equal?(SpinelHttp::QueryLimitExceeded)
  assert Cybertrain::QueryTooDeep.equal?(SpinelHttp::QueryTooDeep)
  assert Cybertrain::QueryTooMany.equal?(SpinelHttp::QueryTooMany)
  assert Cybertrain::QueryMalformed.equal?(SpinelHttp::QueryMalformed)
  assert Cybertrain::Request.equal?(SpinelHttp::Request)
  assert Cybertrain::BodyUndecodable.equal?(SpinelHttp::BodyUndecodable)
  assert Cybertrain::BodyTooLarge.equal?(SpinelHttp::BodyTooLarge)
  assert Cybertrain::Response.equal?(SpinelHttp::Response)
  assert Cybertrain::Server.equal?(SpinelHttp::Server)
  assert Cybertrain::PortInUse.equal?(SpinelHttp::PortInUse)
  assert Cybertrain::SSE.equal?(SpinelHttp::SSE)
  assert Cybertrain::StreamFailure.equal?(SpinelHttp::StreamFailure)
  assert Cybertrain::UploadedFile.equal?(SpinelHttp::UploadedFile)
  assert Cybertrain::Server::Rejected.equal?(SpinelHttp::Server::Rejected)
  assert Cybertrain::HttpParser::ParseError.equal?(SpinelHttp::HttpParser::ParseError)
  assert_equal "SpinelHttp::Server", Cybertrain::Server.name
end

test "assert_raises' list of aliased names is the shims' alias lines" do
  found = Array.new(0) { "" }
  Dir.glob("cybertrain/http/*.rb").sort.each do |path|
    File.read(path).each_line do |line|
      text = line.strip
      next unless text.include?(" = SpinelHttp::")

      found << text.split(" = ")[0].to_s
    end
  end
  assert_equal Cybertrain::Test::SPINEL_HTTP_ALIASES.sort, found.sort
end

test "the String form of assert_raises matches a layer class by its Cybertrain name" do
  assert_raises("Cybertrain::QueryMalformed") { Cybertrain::Query.parse("a=%zz") }
  assert_raises("Cybertrain::Params::ParameterMissing") { Cybertrain::Params.new.require(:post) }
  assert_raises("SpinelHttp::QueryMalformed") { Cybertrain::Query.parse("a=%zz") }
  assert_raises("QueryMalformed") { Cybertrain::Query.parse("a=%zz") }
  assert_equal "Cybertrain::Params::ParameterMissing",
               Cybertrain::Test.cybertrain_name("SpinelHttp::Params::ParameterMissing")
  assert_equal "", Cybertrain::Test.cybertrain_name("SpinelHttp::NotAliased")
  assert_equal "", Cybertrain::Test.cybertrain_name("Cybertrain::RecordNotFound")
end

test "the reopenings reached the layer's classes" do
  params = Cybertrain::Query.parse("post[title]=Hi&post[x]=1")
  assert_equal({ "title" => "Hi" }, params.require(:post).permit(:title))
  assert SpinelHttp::Params.new.permit(:title).empty?
  req = SpinelHttp::Request.new("GET", "/a.json", { "Accept-Language" => "ja" }, "")
  assert_equal :ja, req.preferred_locale([:en, :ja])
  assert_equal "", req.format_extension
  assert_equal :html, req.format
  req.format_extension = "json"
  assert_equal :json, req.format
  assert_equal "application/json; charset=utf-8", SpinelHttp::Request.mime_type(:json)
  assert Cybertrain.stream_failure.equal?(SpinelHttp.stream_failure)
end

# /missing requires `post[...]`; /malformed parses its query, which holds a
# bad escape; /hello answers.
class AliasesApp < Cybertrain::Middleware
  def call(ctx)
    req = ctx.request
    res = ctx.response
    res.content_type = "text/plain"
    case req.path
    when "/missing"
      Cybertrain::Params.new.require(:post)
      res.body = "found"
    when "/malformed"
      res.body = Cybertrain::Query.parse(req.query_string).empty? ? "none" : "some"
    else
      res.body = "hi"
    end
    nil
  end
end

# The status code of one request.
def status_of(port, target)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET #{target} HTTP/1.1\r\nHost: aliases\r\nConnection: close\r\n\r\n")
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
  line = buf.split("\r\n")[0].to_s
  line.split(" ")[1].to_s
end

# Keeps the server's log lines out of the snapshot.
class QuietHttpLog < Cybertrain::HttpLog
  def info(msg)
    nil
  end

  def error(msg)
    nil
  end
end

test "through ContextHandler a missing parameter and a malformed query are 400s" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(AliasesApp.new), port: 0, logger: QuietHttpLog.new)
  server.start
  port = server.port
  assert_equal "200", status_of(port, "/hello")
  assert_equal "400", status_of(port, "/missing")
  assert_equal "400", status_of(port, "/malformed?a=%zz")
  server.stop
end

test "rescue Cybertrain::PortInUse catches a busy port, and cybertrain server's hint follows it" do
  first = Cybertrain::Server.new(Cybertrain::ContextHandler.new(AliasesApp.new), port: 0, logger: QuietHttpLog.new)
  first.start
  port = first.port
  second = Cybertrain::Server.new(Cybertrain::ContextHandler.new(AliasesApp.new), port: port, logger: QuietHttpLog.new)
  message = ""
  begin
    second.start
  rescue Cybertrain::PortInUse => e
    message = Cybertrain::Roles::ServerRunner.port_message(e)
  end
  first.stop
  assert_equal "port #{port} on 127.0.0.1 is already in use (stop the other server or set PORT)", message
  named = Cybertrain::PortInUse.new("db.internal", 3000, Cybertrain::PortInUse::REUSE_PORT_HOST)
  assert Cybertrain::Roles::ServerRunner.port_message(named).end_with?("(check CYBERTRAIN_HOST)")
end

Cybertrain::Test.run!
