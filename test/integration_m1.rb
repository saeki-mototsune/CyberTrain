# Requires the whole framework entry point at once: cross-file compile
# problems (require order, duplicated names) surface here, not in the
# per-feature tests that require only their own files.
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/client"

test "the entry point exposes every M1 feature" do
  head = Cybertrain::HttpParser.parse_head("GET /posts?id=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1")
  req = Cybertrain::Request.new(head.method, head.target, head.headers, "", "127.0.0.1", head.http_version)
  ctx = Cybertrain::Context.new(req)
  ctx.params = Cybertrain::Query.parse(req.query_string)
  assert_equal "1", ctx.params[:id]
  assert_equal({ "a" => "1" }, Cybertrain::Cookies.parse(req.cookie_header))
  ctx.response.body = Cybertrain::Html.escape("<b>")
  assert_includes ctx.response.to_http, "&lt;b&gt;"
  Cybertrain.logger.info("m1 ok")
  assert_equal "0.1.0", Cybertrain::VERSION
end

test "an App routes a request through the default stack" do
  router = Cybertrain::Router.new
  router.get("/hello/:name", "hello") { |c| c.response.body = "hi #{c.params[:name]}" }
  router.post("/items", "items") { |c| c.response.redirect("/hello/created", 303) }
  app = Cybertrain::App.new(router, logging: false)
  client = Cybertrain::Test::Client.new(app)
  res = client.get("/hello/world")
  assert_response res, :ok
  assert_equal "hi world", res.body
  res = client.post("/items", { "x" => "1" })
  assert_redirected_to res, "/hello/created"
  res = client.follow_redirect!
  assert_equal "hi created", res.body
  assert_response client.get("/missing"), :not_found
  assert_equal "/hello/x", router.path_for("hello", { "name" => "x" })
end

test "the Server serves the same App over a socket" do
  router = Cybertrain::Router.new
  router.get("/ping", "ping") { |c| c.response.body = "pong" }
  app = Cybertrain::App.new(router, logging: false)
  server = Cybertrain::Server.new(app, port: 0, logger: Cybertrain::Logger.new(nil, :error))
  server.start
  sock = TCPSocket.new("127.0.0.1", server.port)
  sock.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  raw = +""
  loop do
    break if sock.wait_readable(5).nil?
    begin
      raw << sock.readpartial(4096)
    rescue EOFError
      break
    end
  end
  sock.close
  server.stop
  assert_includes raw, "HTTP/1.1 200 OK"
  assert_includes raw, "pong"
end

test "the database layer opens a pooled in-memory SQLite connection" do
  Cybertrain::DB.connect(":memory:", size: 1)
  Cybertrain::DB.with do |c|
    c.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)")
    c.execute("INSERT INTO notes (body) VALUES (?)", ["hello"])
    rows = c.execute("SELECT id, body FROM notes")
    assert_equal 1, rows.size
    assert_equal "hello", rows[0]["body"]
  end
  Cybertrain::DB.disconnect
  assert_equal "2026-01-02T03:04:05Z", Cybertrain::Cast.iso8601(Time.utc(2026, 1, 2, 3, 4, 5))
end

Cybertrain::Test.run!
