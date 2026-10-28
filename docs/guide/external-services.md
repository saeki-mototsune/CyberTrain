# Outbound HTTP, WebSocket feeds and e-mail

## Outbound HTTP

An application that calls another server (a webhook, a Slack incoming
webhook, a third-party API) uses `Cybertrain::HttpClient`. It is not in
`require "cybertrain"`; require it where it is used, and the TLS layer too
when any URL is https:

```ruby
require "json"
require "cybertrain/http_client"
require "cybertrain/net/tls"   # only for https://; links the system libssl

client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15, max_body: 1 << 20)
begin
  res = client.post(ENV["SLACK_WEBHOOK_URL"], JSON.generate({ "text" => "Deployed" }),
                    content_type: "application/json")
  Cybertrain.logger.warn("slack answered #{res.status}") unless res.success?
rescue Cybertrain::HttpClient::Error => e
  Cybertrain.logger.warn("slack: #{e.message}")   # names host:port, never the path
end

res = client.get("https://api.example.com/v1/status", headers: { "Authorization" => "Bearer #{token}" })
res.status              # 200
res.header("ETag")      # names in any case; res.headers has them lowercase
res.body                # the bytes, chunked coding removed
```

Why it exists: Spinel's `Net::HTTP` does the TLS handshake and every read
after the first byte as blocking C calls, and each one holds an OS worker,
which with the default `SPINEL_WORKERS=1` is the whole web server, for as
long as a stalled endpoint likes. `HttpClient` never blocks a worker on the
network:

- **Every wait is bounded.** Connecting (a non-blocking connect; Spinel's
  `TCPSocket.new` ignores `connect_timeout:`), each TLS handshake step, each
  read and each write waits at most `timeout` seconds (default 5), and the
  whole request at most `deadline` seconds (default 15). Past either,
  `HttpClient::TimeoutError`. Reads go through a byte buffer fed by
  `read_nonblock`, so bytes already received are never waited for.
- **Name resolution blocks.** `getaddrinfo` has no non-blocking form in the
  runtime: the thread making the request waits for DNS (usually
  milliseconds, but a dead resolver can take the system's timeout, about 5 s
  per attempt). The deadline counts that time but cannot interrupt it.
- **Non-public destinations are refused** before anything is sent:
  loopback (`127.0.0.0/8`, `::1`), private (`10/8`, `172.16/12`,
  `192.168/16`, `fc00::/7`), link-local (`169.254/16`, which includes cloud
  metadata services, `fe80::/10`), unspecified (`0.0.0.0/8`, `::`),
  multicast, broadcast, CGNAT (`100.64/10`), the documentation and
  benchmarking ranges, and IPv4-mapped, NAT64 and 6to4 forms of those
  (`Cybertrain::Net::Address.blocked_reason`). The host name is resolved
  once and the addresses it resolved to are the ones checked and dialled
  (nothing is looked up again), so a name that resolves to a private
  address (an `/etc/hosts` entry, DNS rebinding) is refused like the
  literal; the TLS certificate is still checked against the name. The
  check is per address: a refused address is skipped, and only when every
  address is refused does the request fail.
  `HttpClient::BlockedAddressError` says why. To call a service on your
  own network, or a local server in a test, set `c.http_allow_private =
  true` in `config/app.rb` (or `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`), or pass
  `allow_private: true` to `HttpClient.new`; leave it off whenever a URL
  can come from a user.
- **Every resolved address is tried**, in the order the resolver gives
  them, IPv6 and IPv4 alike: when one refuses, is unreachable, resets or
  does not answer within `timeout`, the next is dialled, all of them
  within `deadline`, and when every one fails the last one's error is
  raised. This is what makes `localhost` work on macOS, where it resolves
  to `::1` first and a server listening on `127.0.0.1` refuses that.
  `Cybertrain::Mailer` dials the same way.
- **TLS** is the openssl package's: `VERIFY_PEER` against the operating
  system's trust store (`SSL_CERT_FILE` / `SSL_CERT_DIR` point it
  elsewhere; the package has no `X509::Store` for a custom one), host-name
  checking, SNI, TLS 1.2 or newer. An https URL needs a host name: an IP
  address does not match a certificate's name. Without `require
  "cybertrain/net/tls"`, an https request raises `HttpClient::TLSError`
  saying so; `cybertrain/http_client` alone never links libssl.
- **A notification client, not a browser:** HTTP/1.1 with `Connection:
  close`, one connection per request, no keep-alive, no redirects (a 3xx is
  returned as it is), no proxy, no cookies, no compression. Responses may be
  `Content-Length`, chunked or read to the close; the headers are capped at
  64 KiB and 100 lines, the body at `max_body` (default 1 MiB), past which
  `HttpClient::TooLargeError`. A response that is not HTTP/1.x, or ends
  early, is `HttpClient::BadResponseError`; a refused or reset connection, or
  a name that does not resolve, `HttpClient::RefusedError`. A connection
  that is reset or closed during the TLS handshake (a server that does not
  speak TLS) is `HttpClient::TLSError` ("TLS handshake failed") on every
  platform, like a handshake OpenSSL rejects. All of them are
  `HttpClient::Error`s.
- **Errors never contain the path or the query**, where a webhook URL
  carries its secret: messages name the host and port only. A malformed URL
  or a header with CR/LF is an `ArgumentError` that does not repeat it
  either. `Host`, `Connection`, `Content-Length` and `Transfer-Encoding` are
  the client's; `User-Agent` defaults to `cybertrain/<version>`.

The request runs on the calling thread, a green thread like the request
being served, so other connections keep being served while it waits. The
socket layer (`cybertrain/net/socket.rb`: bounded connect, buffered reads,
bounded writes) is separate from the HTTP layer so that other protocols can
use it. The design: [docs/design.md](../design.md) D24.

## Consuming WebSocket feeds

An application that listens to an outside feed (market ticks, device
telemetry, an event stream) while the server runs subscribes to it with
`Cybertrain::WebSocket.subscribe`. Like the HTTP client it is not in
`require "cybertrain"`; require it where the subscription is written, and the
TLS layer too for `wss://`:

```ruby
# config/app.rb (or a file bin/<app>.rb requires before Cybertrain::Main.run)
require "json"
require "cybertrain/websocket"
require "cybertrain/net/tls"   # only for wss://; links the system libssl

Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"],
    headers: { "Authorization" => "Bearer #{ENV["FEED_TOKEN"]}" },
    stale_after: 30)
  .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe", "channel" => "trades" })) }
  .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
```

Requiring `cybertrain/websocket` registers the feeds with
`Cybertrain::Background`, which `Application#serve` starts after the
scheduler and stops at shutdown, so there is nothing to call. Each
subscription gets one thread. It connects, runs `on_open` (send your
subscribe message there: it runs again after every reconnect), then hands
each message to `on_message` with the `Connection` (`send_text`,
`send_binary`, `close`, and `last_opcode`, `:text` or `:binary`). The
blocks take their arguments and cannot use `self` (Spinel has no
`instance_eval`).

- **When it runs.** The feeds start when the binary serves, like the
  scheduler ([Background work](background-and-operations.md#background-work)); `migrate`, `db ...`,
  `Main.command` commands and `Cybertrain::Test::Client` never start them.
  With `CYBERTRAIN_WORKER=0` (`config.worker = false`) they do not run in
  that process (they simply do not start; the only notice is the
  scheduler's "run elsewhere" line, and `WebSocket.start!` called directly
  logs its own): turn it off in all but one when
  several processes serve, or each one receives the whole feed.
  `subscribe` must be called before the server starts; there is no adding or
  removing a feed while it runs. A name is unique (`ArgumentError`), and a
  feed without `on_message` fails the boot before the port is bound
  (`error: WebSocket subscription "trades" has no on_message`, exit 1).
- **Options.** `headers:` (extra handshake headers), `timeout:` (5 seconds
  per wait while connecting and per write), `max_message:` (1 MiB; a larger
  message closes the connection with 1009), `ping_interval:` (15) and
  `stale_after:` (45), and `allow_private:` (as `HttpClient`, below).
- **Waiting and reconnecting.** After any failure the thread waits
  `min(60, 2 ** (attempt - 1))` seconds, with 20 % of jitter either way: 1, 2,
  4, ... 60. A connection that lasted 60 seconds starts again from 1. Every
  wait is bounded. `WebSocket.stop!` returns within about 2 seconds
  whatever the servers do: it waits at most 2 seconds for all the threads
  together, a connected feed sends a close (1000) and waits at most 1 second
  for the server's answer, and every feed's `connected?` is false once it
  returns (a thread still closing finishes on its own).
- **Silence.** A feed can go quiet without ever closing the connection, so
  the thread pings after `ping_interval` seconds without any frame (and then
  once per interval), and when no frame at all, a pong included, has arrived
  for `stale_after` seconds it closes the connection and reconnects.
  `stale_after` must be more than `ping_interval`, which must be at least 1
  (`ArgumentError` from `subscribe`).
- **Errors in your blocks.** An exception in `on_message` is logged and the
  connection stays. An exception in `on_open` is logged and the connection is
  closed and retried, since a feed that did not subscribe is of no use.
- **What is logged.**

  | When | Level | Line |
  | --- | --- | --- |
  | start | INFO | `WebSocket started: trades (wss://feed.example.com:443)` |
  | connected | INFO | `WebSocket "trades" connected to feed.example.com:443` |
  | disconnected | WARN | `WebSocket "trades" disconnected: Cybertrain::WebSocket::ClosedError: feed.example.com:443: closed by the server (1001) (retry in 2s)` |
  | silent | WARN | `WebSocket "trades" silent for 45s; reconnecting` |
  | a block raised | ERROR | `WebSocket "trades" on_message failed: KeyError: ...` (or `on_open`) |

  The path and the query are never logged or put in an error message: they
  often carry a token.
- **Errors.** All are `Cybertrain::WebSocket::Error`s, with host and port
  only in the message. Once the handshake is done, a lost connection or a
  close by the server is a `ClosedError` (`close_code`, `close_reason`; a
  reset or an end without a close frame is 1006); a write that times out or
  fails in TLS is still a `TimeoutError` or `TLSError`. While connecting it
  is `RefusedError`, `TimeoutError`, `TLSError`, `BlockedAddressError` (a non-public address,
  refused by default exactly as in [Outbound HTTP](#outbound-http), with
  the same `allow_private:` and `http_allow_private` setting) or
  `HandshakeError` (not a 101, a wrong `Sec-WebSocket-Accept`, or the
  server answering with an extension or subprotocol). `ProtocolError`
  (the server broke the framing; the client sends 1002) and
  `TooLargeError` can come at any time.
- **Health.** `Cybertrain::WebSocket.feed_status("trades")` answers a
  `Status`: `connected?`, `last_message_at` (epoch seconds, 0 before the
  first message) and `reconnects`. It is not part of `GET /up`; use it in
  your own check. The three are read one after the other, not as one
  snapshot, and `connected?` turns true when the connection is made, before
  `on_open` has run.
- **Keep `on_message` short.** The thread waits with `wait_readable` or
  `sleep`, so a stalled feed does not hold an OS worker while it waits. Two
  things do hold one: each connect attempt resolves the host name with a
  blocking `getaddrinfo` (see "Name resolution blocks" in [Outbound
  HTTP](#outbound-http); with `SPINEL_WORKERS=1` a dead resolver stalls
  every request for the resolver's timeout, once per attempt per feed, and
  an IP address in the URL avoids the lookup), and a SQLite call inside
  `on_message` until it returns, as in a scheduled task ([Background
  work](background-and-operations.md#background-work)): with `SPINEL_WORKERS=1` a long write stalls every
  request. For a busy feed insert one small row, or collect messages in
  memory and write them in batches from a `Scheduler.every` task.
- **Not built.** Extensions (`permessage-deflate`) and subprotocols are not
  negotiated. There is no proxy, redirect or cookie support, no automatic
  saving of messages, and no WebSocket server (ActionCable). Text frames are
  not checked for valid UTF-8 (a departure from RFC 6455 section 8.1): the
  bytes are passed on as they came. The `Connection` is valid only during
  the callback; sending from a request or a task is not supported.

For one connection without the reconnect loop (a script, a one-shot read)
use the synchronous client:

```ruby
require "cybertrain/websocket"
require "cybertrain/net/tls"   # only for wss://

client = Cybertrain::WebSocket::Client.connect("wss://feed.example.com/v1", timeout: 5)
client.send_text("hello")
msg = client.receive(10)      # waits at most 10 s; nil when nothing came
msg.ws_opcode                 # :text or :binary
msg.ws_data                   # the bytes
client.close
```

The design: [docs/design.md](../design.md) D33.

## Sending e-mail

`Cybertrain::Mailer` sends plain-text e-mail through an SMTP server (your
provider's submission server, or a local relay). Like the HTTP client it is
not in `require "cybertrain"`, and TLS is a separate require:

```ruby
require "cybertrain/mailer"
require "cybertrain/net/tls"   # for starttls (the default) and tls; links the system libssl

# Settings from CYBERTRAIN_SMTP_HOST, _PORT, _USER, _PASSWORD, _FROM, _TLS:
begin
  Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello #{user.name},\n...")
rescue Cybertrain::Mailer::Error => e
  Cybertrain.logger.warn("mail: #{e.message}")   # never contains the password
end

# Or explicit settings, bypassing Config:
mailer = Cybertrain::Mailer.new(host: "smtp.example.com", port: 587, tls: "starttls",
                                user: "app", password: ENV["SMTP_PASSWORD"].to_s,
                                from: "noreply@example.com", timeout: 10, deadline: 60)
mailer.deliver(to: "a@example.com, b@example.com", subject: "Report", body: report)
```

| Variable | Attribute | Default |
| --- | --- | --- |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""` (`Mailer.new` raises `ArgumentError` until it is set) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`: 587 for `starttls`, 465 for `tls`, 25 for `none` |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`: no AUTH |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""` (secret) |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`; `tls` or `none` |

- **TLS modes.** `starttls` connects in plain text, requires the server to
  offer STARTTLS (else `Mailer::TLSError`) and upgrades before anything
  else is said; bytes the server sends after its STARTTLS reply are
  refused. `tls` speaks TLS from the first byte (port 465). Both check the
  certificate against `host` as the HTTP client does (give a host name, not
  an IP address), and both need `require "cybertrain/net/tls"`: without
  it, `deliver` raises `Mailer::TLSError` saying so, before connecting.
  `none` is plain text, for a relay on the same machine or a test server:
  with a user configured it refuses (`Mailer::InsecureError`, before
  connecting) unless the host resolves to a loopback address, and then
  dials only its loopback addresses.
- **The password is never logged or shown.** It is not in the boot banner,
  `help`, the log or any error message; it is sent only inside the AUTH
  PLAIN command, over TLS (or to loopback). Do not `p` or `inspect` a
  `Mailer` or the `Config`, which hold it.
- **Every wait is bounded**, as in [Outbound HTTP](#outbound-http): connecting, each TLS
  step and each reply waits at most `timeout` seconds (default 10), the
  whole delivery at most `deadline` seconds (default 60), else
  `Mailer::TimeoutError`. Name resolution blocks the calling thread.
- **The dialogue:** the 220 greeting, `EHLO` (the name is `helo:`, default
  `localhost`), `STARTTLS` and `EHLO` again, `AUTH PLAIN` when a user is
  set (the server must offer PLAIN), `MAIL FROM`, one `RCPT TO` per
  recipient, `DATA`, `QUIT`. A reply with another code is a
  `Mailer::RejectedError` whose `smtp_code` is the server's (421, 535,
  550, ...) and whose message has the step and the server's text. The
  return value is the server's reply to the message (`"250 2.0.0 Ok: queued
  as ..."`).
- **The message:** `Date`, `From`, `To`, `Subject`, `MIME-Version: 1.0`,
  `Content-Type: text/plain; charset=UTF-8`. A non-ASCII subject is RFC 2047
  encoded (`=?UTF-8?B?...?=`, split between characters). The body's line
  endings become CRLF and lines starting with `.` are dot-stuffed. Its
  `Content-Transfer-Encoding` is `7bit` for ASCII, `8bit` (with `MAIL FROM
  ... BODY=8BITMIME`) for UTF-8 when the server advertises 8BITMIME, and
  `base64` otherwise or when a line is longer than 998 bytes. No
  `Message-ID` is added (submission servers add one).
- **What is refused** with an `ArgumentError`, before connecting: an
  address that is not a bare ASCII `local@domain` (no display name, no
  `<>`, spaces, commas, quotes, CR or LF; at most 254 bytes), a subject with
  CR, LF or NUL (header injection) or over 998 bytes, a body that is not
  valid UTF-8 or holds a NUL, more than 100 recipients. `to:` takes one
  address or several separated by commas.
- **Not yet:** HTML and multipart messages, attachments, templates, display
  names, `Cc`/`Bcc` headers (send to several recipients instead), AUTH
  LOGIN/CRAM-MD5, SMTPUTF8 addresses, pipelining, and a delivery queue (a
  delivery runs on the calling thread, a green thread like a request).
  `cybertrain generate authentication` still writes no password reset.

The design: [docs/design.md](../design.md) D27.
