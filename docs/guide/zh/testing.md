---
source_sha256: 99e2fb00f24486c6277c57d7be1d6a62713b2318a44182d7fe3391ab2f9827bf
---
# 测试应用

应用的测试是位于 `test/` 下的普通 Spinel 程序，与框架自己的测试一样：

```ruby
require_relative "support/blog_test"   # 应用、BLOG 和 Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

断言：`assert`、`refute`、`assert_equal`、`assert_nil`、`assert_includes`、`assert_raises("Class") { }`、`flunk`。对于控制器和完整的 HTTP 流程，`Cybertrain::Test::Client` 在进程内（不经过套接字）驱动应用，并带有一个 cookie 存储，所以会话和 CSRF 的行为与在浏览器后面时一样：

```ruby
require_relative "support/blog_test"   # 应用、BLOG 和 Cybertrain::Test

test "POST /articles creates an article and redirects to it" do
  client = Cybertrain::Test::Client.new(BLOG)
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, BlogTest.article_path(Article.last)
  assert_response res, :see_other
end
```

两段代码都以示例中的辅助文件 [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb) 为起点：把它复制到应用的 `test/support/` 中，那里的文件会被 require，而不会被运行。它对一个全新的 `storage/test.sqlite3` 执行迁移，把应用启动为 `BLOG`，加载 `Cybertrain::Test` 及其客户端，并从最后渲染的表单中读出 CSRF 令牌（`BlogTest.form_token`）。每个测试文件都以 `Cybertrain::Test.run!` 结尾；`examples/blog/test/articles.rb` 和 `comments.rb` 展示了完整的写法。

测试客户端发送的每个请求都来自 `127.0.0.1`（`request.remote_addr`，因此 `request.loopback?` 为 true）。要查看页面对另一台机器上的访客有何表现，请在请求之前设置 `client.peer_address = "203.0.113.7"`。

用 `cybertrain spin test` 运行：它把每个 `test/*.rb` 编译成各自的程序，并把其输出（标准输出和标准错误合在一起）与 `test/<name>.rb.expected` 进行比较。用 `cybertrain spin test --regen
test/<name>.rb` 重新生成；FFI/数据库测试无法在 CRuby 下运行，所以它们的快照改从编译后的二进制文件获取：`rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1`（快照过时时 `cybertrain spin test` 以非零状态退出，所以后面接的是 `;` 而不是 `&&`；`[ -x ]` 检查会在编译失败时跳过捕获，从而保留旧的快照；在框架的检出代码中，`script/regen-snapshot test/<name>.rb` 恰好完成这些操作，并打印差异统计）。

## 测试出站调用

当被测代码发送 webhook（[出站 HTTP](external-services.md#outbound-http)）或电子邮件（[发送电子邮件](external-services.md#sending-e-mail)）时，测试在进程内接收它：`Cybertrain::Test::HttpReceiver` 和 `Cybertrain::Test::SmtpReceiver` 在 `127.0.0.1` 上监听，记录收到的内容，并以预设的应答作答。

```ruby
require_relative "support/app_test"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

test "a sign-up posts a webhook" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  hook.start                                   # 绑定一个空闲端口并返回它
  Cybertrain.config.http_allow_private = true  # 否则 HttpClient 会拒绝环回地址
  SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # 应用的代码
  req = hook.received_request                  # 最多等待 5 秒；没有收到任何内容时为 nil
  hook.stop
  assert_equal "POST", req.http_method
  assert_equal "/hooks/signup", req.http_target
  assert_equal "application/json", req.http_header("Content-Type")
  assert_includes req.http_body, "ann@example.com"
end

test "a refused recipient is reported" do
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
  port = smtp.start
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
  assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
  mail = smtp.received_message
  smtp.stop
  assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
               mail.transcript.first(3)
  refute mail.delivered?
end
```

`HttpReceiver.new` 接收预设的 `status:`、`headers:`、`body:` 和 `chunked:`（`respond_with` 可以在请求之间修改它们）；请求以 `ReceivedRequest` 的形式返回（`http_method`、`http_target`、`http_path`、名称为小写的 `http_headers`、`http_header(name)`、已解码分块请求体的 `http_body`）。`SmtpReceiver` 依次扮演 220、EHLO（带 8BITMIME，除非 `eight_bit_mime: false`；`auth: true` 时带 AUTH PLAIN）、MAIL、RCPT、DATA 和 QUIT；`reject:` 会让 `:greeting`、`:ehlo`、`:mail`、`:rcpt`、`:data` 或 `:message` 中的任意一步以给定的应答失败。`ReceivedMessage` 带有 `envelope_from`、`envelope_recipients`、`message_data`（已还原点填充）、`message_header(name)`、`message_body` 以及命令的 `transcript`。两者都只接受一个连接，除非 `max:` 指定了更多（`received_requests` / `received_messages` 会返回全部）。每次等待都有上限：接收器在 `accept_window:`（10 秒）内没有连接就会放弃，客户端静默超过 `read_timeout:`（5 秒）也会放弃，`stop`（可以安全地调用两次）会结束并 join 接收器的线程、关闭其端口，所以接收器永远不会接走后续测试的连接。它们只需要 Ruby 的 socket 库，不需要 openssl。

数据流也以同样的方式测试，使用 `Cybertrain::Test::WebSocketReceiver`，它是 `127.0.0.1` 上一个按脚本运行的 WebSocket 服务器：每个连接依次执行一组 `Cybertrain::Test::WsStep`（`"accept"`、`"send_text"`、`"expect"`、`"silent"`、`"close"`、`"drop"`、`"echo_until_close"` 等），客户端发送的帧会以去掉掩码的形式从 `ws_received` 返回。

```ruby
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # 一个常量：块看不到局部变量

# 这些块写在一个方法中，它们的参数在那里被使用，
# 而不是写在测试块内部。
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

test "a trade message is stored" do
  rx = Cybertrain::Test::WebSocketReceiver.new
  rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
  rx.start
  subscribe_trades(rx.url("/trades"))
  Cybertrain::WebSocket.start!               # Test::Client 从不启动订阅
  # ……最多花几秒轮询 TICKS……
  Cybertrain::WebSocket.stop!
  assert_equal ["tick"], TICKS
  assert_equal "subscribe", rx.ws_received[0].rec_data
  rx.stop
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` 让重试延迟变得精确。本仓库中的 `test/websocket_integration.rb` 展示了一个完整的测试。

## 持续集成

`cybertrain new` 会为应用写出 `.github/workflows/ci.yml`。它调用本仓库的 `setup-cybertrain` action（[.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)），并固定在 CLI 的发布标签上；该 action 会安装 SQLite、zlib 和 OpenSSL 头文件以及 Ruby，从 `spin.lock` 中读出应用锁定的框架提交，拉取该提交的框架，并运行其中的 `cybertrain
doctor` 和 `cybertrain setup`（`~/.cybertrain/spinel` 按 Spinel 版本和运行器镜像缓存）。随后，工作流检查 `spin.lock` 是否最新（`spin lock && git diff --exit-code spin.lock`）、`gen/` 是否为新生成的（`spin run gen -- --check`），并在 `test/` 中有测试程序后运行 `spin test`。工具链步骤发生变化时，改变的是这个 action，而不是每个应用中的副本。提交是从 `spin.lock` 中读取的，所以工作流假定使用默认的 git 依赖；用 `--path` 创建的应用要把框架的检出代码作为 `framework-path` 传给这个 action。
