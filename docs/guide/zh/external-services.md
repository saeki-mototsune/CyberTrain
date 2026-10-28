---
source_sha256: 0a5a051dced3255b5cbc72eeeaa180f28cc8bf726dc0fce839c7885938c65379
---
# 出站 HTTP、WebSocket 订阅与电子邮件

## 出站 HTTP

调用其他服务器（webhook、Slack 传入 webhook、第三方 API）的应用使用 `Cybertrain::HttpClient`。它不在 `require "cybertrain"` 之中；请在使用它的地方 require 它，如果有任何 URL 是 https，还要 require TLS 层：

```ruby
require "json"
require "cybertrain/http_client"
require "cybertrain/net/tls"   # 仅用于 https://；会链接系统的 libssl

client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15, max_body: 1 << 20)
begin
  res = client.post(ENV["SLACK_WEBHOOK_URL"], JSON.generate({ "text" => "Deployed" }),
                    content_type: "application/json")
  Cybertrain.logger.warn("slack answered #{res.status}") unless res.success?
rescue Cybertrain::HttpClient::Error => e
  Cybertrain.logger.warn("slack: #{e.message}")   # 只给出 host:port，从不包含路径
end

res = client.get("https://api.example.com/v1/status", headers: { "Authorization" => "Bearer #{token}" })
res.status              # 200
res.header("ETag")      # 名称不区分大小写；res.headers 中的名称为小写
res.body                # 原始字节，已去除分块编码
```

它为什么存在：Spinel 的 `Net::HTTP` 以阻塞的 C 调用完成 TLS 握手以及第一个字节之后的每次读取，每次调用都会占用一个操作系统工作线程——在默认的 `SPINEL_WORKERS=1` 下，那就是整个 Web 服务器——时间长短全由停滞的端点决定。`HttpClient` 从不因网络而阻塞工作线程：

- **每次等待都有上限。** 连接（非阻塞连接；Spinel 的 `TCPSocket.new` 会忽略 `connect_timeout:`）、TLS 握手的每一步、每次读取和每次写入最多等待 `timeout` 秒（默认 5 秒），整个请求最多 `deadline` 秒（默认 15 秒）。超过任一上限即为 `HttpClient::TimeoutError`。读取经过一个由 `read_nonblock` 填充的字节缓冲区，所以永远不会去等待已经收到的字节。
- **域名解析会阻塞。** `getaddrinfo` 在运行时中没有非阻塞形式：发出请求的线程要等待 DNS（通常只需几毫秒，但失效的解析器可能耗尽系统的超时时间，每次尝试约 5 秒）。截止时间会把这段时间计算在内，但无法中断它。
- **非公网目标会被拒绝**，在发送任何内容之前：环回地址（`127.0.0.0/8`、`::1`）、私有地址（`10/8`、`172.16/12`、`192.168/16`、`fc00::/7`）、链路本地地址（`169.254/16`，其中包括云元数据服务，`fe80::/10`）、未指定地址（`0.0.0.0/8`、`::`）、组播、广播、CGNAT（`100.64/10`）、文档和基准测试用的地址范围，以及这些地址的 IPv4 映射、NAT64 和 6to4 形式（`Cybertrain::Net::Address.blocked_reason`）。主机名只解析一次，被检查和拨号的就是解析得到的那些地址（不会再次查询），所以解析为私有地址的名称（`/etc/hosts` 条目、DNS 重绑定）与字面地址一样会被拒绝；TLS 证书仍然按名称检查。检查是逐个地址进行的：被拒绝的地址会被跳过，只有所有地址都被拒绝时请求才会失败。`HttpClient::BlockedAddressError` 会说明原因。要调用你自己网络中的服务，或在测试中调用本地服务器，请在 `config/app.rb` 中设置 `c.http_allow_private =
  true`（或 `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`），或者向 `HttpClient.new` 传入 `allow_private: true`；只要 URL 可能来自用户，就不要开启它。
- **解析得到的每个地址都会尝试**，按解析器给出的顺序，IPv6 和 IPv4 一视同仁：当一个地址拒绝连接、不可达、重置连接或在 `timeout` 内没有应答时，就拨号下一个，全部在 `deadline` 之内完成；所有地址都失败时，抛出最后一个地址的错误。正因如此，`localhost` 才能在 macOS 上工作：那里它首先解析为 `::1`，而监听 `127.0.0.1` 的服务器会拒绝该连接。`Cybertrain::Mailer` 也以同样的方式拨号。
- **TLS** 来自 openssl 包：根据操作系统的信任存储进行 `VERIFY_PEER`（`SSL_CERT_FILE` / `SSL_CERT_DIR` 可以把它指向别处；该包没有可用于自定义存储的 `X509::Store`）、主机名检查、SNI、TLS 1.2 或更新版本。https URL 需要主机名：IP 地址无法与证书中的名称匹配。没有 `require
  "cybertrain/net/tls"` 时，https 请求会抛出 `HttpClient::TLSError` 并说明这一点；单独的 `cybertrain/http_client` 从不链接 libssl。
- **是通知客户端，而不是浏览器**：使用 HTTP/1.1 和 `Connection:
  close`，每个请求一个连接，没有 keep-alive，不跟随重定向（3xx 原样返回），没有代理、cookie 或压缩。响应可以是 `Content-Length`、分块编码或一直读到连接关闭；响应头上限为 64 KiB 和 100 行，响应体上限为 `max_body`（默认 1 MiB），超过即为 `HttpClient::TooLargeError`。不是 HTTP/1.x 或提前结束的响应为 `HttpClient::BadResponseError`；被拒绝或被重置的连接，或无法解析的名称，为 `HttpClient::RefusedError`。在 TLS 握手期间被重置或关闭的连接（不支持 TLS 的服务器）在所有平台上都是 `HttpClient::TLSError`（"TLS handshake failed"），与被 OpenSSL 拒绝的握手一样。它们都是 `HttpClient::Error`。
- **错误中从不包含路径或查询字符串**，因为 webhook URL 的机密就在其中：消息只给出主机和端口。格式错误的 URL 或含有 CR/LF 的请求头会引发 `ArgumentError`，其中同样不会重复这些内容。`Host`、`Connection`、`Content-Length` 和 `Transfer-Encoding` 由客户端负责；`User-Agent` 默认为 `cybertrain/<version>`。

请求在调用它的线程上运行，那是一个绿色线程，与正在处理的请求一样，所以在它等待期间，其他连接仍然照常得到处理。套接字层（`cybertrain/net/socket.rb`：有上限的连接、带缓冲的读取、有上限的写入）与 HTTP 层分开，以便其他协议也能使用它。设计说明：[docs/design.md](../design.md) D24。

## 订阅 WebSocket 数据流

在服务器运行期间监听外部数据流（行情报价、设备遥测、事件流）的应用，用 `Cybertrain::WebSocket.subscribe` 订阅它。与 HTTP 客户端一样，它不在 `require "cybertrain"` 之中；请在编写订阅的地方 require 它，使用 `wss://` 时还要 require TLS 层：

```ruby
# config/app.rb（或 bin/<app>.rb 在 Cybertrain::Main.run 之前 require 的某个文件）
require "json"
require "cybertrain/websocket"
require "cybertrain/net/tls"   # 仅用于 wss://；会链接系统的 libssl

Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"],
    headers: { "Authorization" => "Bearer #{ENV["FEED_TOKEN"]}" },
    stale_after: 30)
  .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe", "channel" => "trades" })) }
  .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
```

require `cybertrain/websocket` 会把这些订阅注册到 `Cybertrain::Background`，`Application#serve` 在调度器之后启动它，并在关闭时停止它，所以无需调用任何东西。每个订阅有一个线程。它会建立连接，运行 `on_open`（在那里发送你的订阅消息：每次重连之后它都会再次运行），然后把每条消息连同 `Connection`（`send_text`、`send_binary`、`close`，以及 `last_opcode`，值为 `:text` 或 `:binary`）交给 `on_message`。这些块接收参数，不能使用 `self`（Spinel 没有 `instance_eval`）。

- **运行时机。** 与调度器一样，订阅在二进制文件提供服务时启动（[后台任务](background-and-operations.md#background-work)）；`migrate`、`db ...`、`Main.command` 命令和 `Cybertrain::Test::Client` 从不启动它们。在 `CYBERTRAIN_WORKER=0`（`config.worker = false`）时，它们不会在该进程中运行（只是不启动；唯一的提示是调度器的 "run elsewhere" 那一行，直接调用的 `WebSocket.start!` 则会记录自己的提示）：当多个进程提供服务时，请在除一个之外的所有进程中关闭它，否则每个进程都会接收完整的数据流。`subscribe` 必须在服务器启动之前调用；服务器运行期间无法添加或移除订阅。名称必须唯一（否则引发 `ArgumentError`），没有 `on_message` 的订阅会在绑定端口之前让启动失败（`error: WebSocket subscription "trades" has no on_message`，退出码 1）。
- **选项。** `headers:`（额外的握手请求头）、`timeout:`（连接时每次等待以及每次写入 5 秒）、`max_message:`（1 MiB；更大的消息会以 1009 关闭连接）、`ping_interval:`（15）和 `stale_after:`（45），以及 `allow_private:`（与下文的 `HttpClient` 相同）。
- **等待与重连。** 任何失败之后，线程会等待 `min(60, 2 ** (attempt - 1))` 秒，上下各有 20% 的随机抖动：1、2、4……60。持续了 60 秒的连接会从 1 重新开始。每次等待都有上限。无论服务器如何表现，`WebSocket.stop!` 都会在大约 2 秒内返回：它为所有线程合计最多等待 2 秒，已连接的订阅会发送关闭帧（1000），并最多等待 1 秒的服务器应答，它返回时每个订阅的 `connected?` 都为 false（仍在关闭中的线程会自行结束）。
- **静默。** 数据流可能在不关闭连接的情况下变得安静，所以线程会在 `ping_interval` 秒内没有收到任何帧之后发送 ping（之后每个间隔一次）；如果在 `stale_after` 秒内完全没有收到任何帧（包括 pong），它就关闭连接并重连。`stale_after` 必须大于 `ping_interval`，而后者必须至少为 1（否则 `subscribe` 会引发 `ArgumentError`）。
- **你的块中的错误。** `on_message` 中的异常会被记录，连接保持不变。`on_open` 中的异常会被记录，连接会被关闭并重试，因为没有完成订阅的数据流毫无用处。
- **记录的内容。**

  | 何时 | 级别 | 日志行 |
  | --- | --- | --- |
  | 启动 | INFO | `WebSocket started: trades (wss://feed.example.com:443)` |
  | 已连接 | INFO | `WebSocket "trades" connected to feed.example.com:443` |
  | 已断开 | WARN | `WebSocket "trades" disconnected: Cybertrain::WebSocket::ClosedError: feed.example.com:443: closed by the server (1001) (retry in 2s)` |
  | 静默 | WARN | `WebSocket "trades" silent for 45s; reconnecting` |
  | 块抛出了异常 | ERROR | `WebSocket "trades" on_message failed: KeyError: ...`（或 `on_open`） |

  路径和查询字符串从不会被记录，也不会放进错误消息：它们往往带有令牌。
- **错误。** 所有错误都是 `Cybertrain::WebSocket::Error`，消息中只有主机和端口。握手完成后，连接丢失或被服务器关闭是 `ClosedError`（`close_code`、`close_reason`；被重置或没有关闭帧就结束的情况为 1006）；超时或在 TLS 中失败的写入仍然是 `TimeoutError` 或 `TLSError`。在连接期间，错误为 `RefusedError`、`TimeoutError`、`TLSError`、`BlockedAddressError`（非公网地址，默认被拒绝，与[出站 HTTP](#outbound-http) 中完全相同，使用同样的 `allow_private:` 和 `http_allow_private` 设置）或 `HandshakeError`（不是 101、`Sec-WebSocket-Accept` 不正确，或者服务器以扩展或子协议作答）。`ProtocolError`（服务器破坏了帧格式；客户端会发送 1002）和 `TooLargeError` 随时可能出现。
- **健康状况。** `Cybertrain::WebSocket.feed_status("trades")` 返回一个 `Status`：`connected?`、`last_message_at`（纪元秒数，收到第一条消息之前为 0）和 `reconnects`。它不属于 `GET /up`；请在你自己的检查中使用它。这三项是依次读取的，而不是作为一个快照，并且 `connected?` 在连接建立时就变为 true，早于 `on_open` 运行。
- **让 `on_message` 保持简短。** 线程用 `wait_readable` 或 `sleep` 等待，所以停滞的数据流在等待期间不会占用操作系统工作线程。有两件事会占用：每次连接尝试都用阻塞的 `getaddrinfo` 解析主机名（参见[出站
  HTTP](#outbound-http) 中的“域名解析会阻塞”；在 `SPINEL_WORKERS=1` 时，失效的解析器会让每个请求停顿解析器的超时时间，每个订阅每次尝试一次，而在 URL 中使用 IP 地址可以避免查询），以及 `on_message` 中的 SQLite 调用，直到它返回为止，与定时任务中一样（[后台任务
  ](background-and-operations.md#background-work)）：在 `SPINEL_WORKERS=1` 时，一次耗时的写入会让每个请求停顿。对于繁忙的数据流，请只插入一个小行，或者把消息收集在内存中，再从 `Scheduler.every` 任务中分批写入。
- **未实现。** 不协商扩展（`permessage-deflate`）和子协议。不支持代理、重定向或 cookie，不会自动保存消息，也没有 WebSocket 服务器（ActionCable）。文本帧不检查是否为有效的 UTF-8（与 RFC 6455 第 8.1 节不同）：字节按收到时的原样传递。`Connection` 只在回调期间有效；不支持从请求或任务中发送。

对于不需要重连循环的单个连接（脚本、一次性读取），请使用同步客户端：

```ruby
require "cybertrain/websocket"
require "cybertrain/net/tls"   # 仅用于 wss://

client = Cybertrain::WebSocket::Client.connect("wss://feed.example.com/v1", timeout: 5)
client.send_text("hello")
msg = client.receive(10)      # 最多等待 10 秒；没有收到任何内容时为 nil
msg.ws_opcode                 # :text 或 :binary
msg.ws_data                   # 原始字节
client.close
```

设计说明：[docs/design.md](../design.md) D33。

## 发送电子邮件

`Cybertrain::Mailer` 通过 SMTP 服务器（你的邮件服务商的提交服务器，或本地中继）发送纯文本电子邮件。与 HTTP 客户端一样，它不在 `require "cybertrain"` 之中，TLS 也需要单独 require：

```ruby
require "cybertrain/mailer"
require "cybertrain/net/tls"   # 用于 starttls（默认）和 tls；会链接系统的 libssl

# 设置来自 CYBERTRAIN_SMTP_HOST、_PORT、_USER、_PASSWORD、_FROM、_TLS：
begin
  Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello #{user.name},\n...")
rescue Cybertrain::Mailer::Error => e
  Cybertrain.logger.warn("mail: #{e.message}")   # 从不包含密码
end

# 或者使用显式设置，绕过 Config：
mailer = Cybertrain::Mailer.new(host: "smtp.example.com", port: 587, tls: "starttls",
                                user: "app", password: ENV["SMTP_PASSWORD"].to_s,
                                from: "noreply@example.com", timeout: 10, deadline: 60)
mailer.deliver(to: "a@example.com, b@example.com", subject: "Report", body: report)
```

| 变量 | 属性 | 默认值 |
| --- | --- | --- |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`（设置之前 `Mailer.new` 会抛出 `ArgumentError`） |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`：`starttls` 为 587，`tls` 为 465，`none` 为 25 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`：不使用 AUTH |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`（机密） |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`；`tls` 或 `none` |

- **TLS 模式。** `starttls` 以明文连接，要求服务器提供 STARTTLS（否则为 `Mailer::TLSError`），并在说任何其他内容之前升级连接；服务器在其 STARTTLS 应答之后发送的字节会被拒绝。`tls` 从第一个字节起就使用 TLS（端口 465）。两者都像 HTTP 客户端一样根据 `host` 检查证书（请给出主机名，而不是 IP 地址），并且都需要 `require "cybertrain/net/tls"`：没有它时，`deliver` 会在连接之前抛出 `Mailer::TLSError` 并说明这一点。`none` 是明文，用于同一台机器上的中继或测试服务器：配置了用户时它会拒绝（在连接之前引发 `Mailer::InsecureError`），除非主机解析为环回地址，此时它只拨号该主机的环回地址。
- **密码从不会被记录或显示。** 它不在启动横幅、`help`、日志或任何错误消息中；它只在 AUTH PLAIN 命令中通过 TLS 发送（或发往环回地址）。不要对持有密码的 `Mailer` 或 `Config` 使用 `p` 或 `inspect`。
- **每次等待都有上限**，与[出站 HTTP](#outbound-http) 中一样：连接、TLS 的每一步以及每个应答最多等待 `timeout` 秒（默认 10 秒），整个投递最多 `deadline` 秒（默认 60 秒），否则为 `Mailer::TimeoutError`。域名解析会阻塞调用它的线程。
- **对话过程**：220 问候、`EHLO`（名称为 `helo:`，默认 `localhost`）、`STARTTLS` 和再次 `EHLO`、设置了用户时的 `AUTH PLAIN`（服务器必须提供 PLAIN）、`MAIL FROM`、每个收件人一条 `RCPT TO`、`DATA`、`QUIT`。代码不符合预期的应答为 `Mailer::RejectedError`，其 `smtp_code` 是服务器给出的代码（421、535、550 等），其消息包含所在步骤和服务器的文本。返回值是服务器对该邮件的应答（`"250 2.0.0 Ok: queued
  as ..."`）。
- **邮件内容**：`Date`、`From`、`To`、`Subject`、`MIME-Version: 1.0`、`Content-Type: text/plain; charset=UTF-8`。非 ASCII 的主题按 RFC 2047 编码（`=?UTF-8?B?...?=`，在字符之间拆分）。正文的行尾会变成 CRLF，以 `.` 开头的行会进行点填充。其 `Content-Transfer-Encoding` 对 ASCII 为 `7bit`，对 UTF-8 在服务器声明支持 8BITMIME 时为 `8bit`（配合 `MAIL FROM
  ... BODY=8BITMIME`），其他情况或某一行长于 998 字节时为 `base64`。不会添加 `Message-ID`（提交服务器会添加）。
- **会被拒绝的内容**，在连接之前以 `ArgumentError` 拒绝：不是纯 ASCII `local@domain` 的地址（不能有显示名称，不能有 `<>`、空格、逗号、引号、CR 或 LF；最多 254 字节），含有 CR、LF 或 NUL（请求头注入）或超过 998 字节的主题，不是有效 UTF-8 或含有 NUL 的正文，超过 100 个收件人。`to:` 接收一个地址，或用逗号分隔的多个地址。
- **尚未支持**：HTML 和 multipart 邮件、附件、模板、显示名称、`Cc`/`Bcc` 头（请改为发送给多个收件人）、AUTH LOGIN/CRAM-MD5、SMTPUTF8 地址、流水线，以及投递队列（投递在调用它的线程上运行，那是一个绿色线程，与请求一样）。`cybertrain generate authentication` 仍然不会写出密码重置功能。

设计说明：[docs/design.md](../design.md) D27。
