# The HTTP layer's contract

CyberTrain's server is its own HTTP/1.1 implementation (`cybertrain/http/*`,
[docs/design.md](design.md) D5, D6, D36), so the framework, not a library,
decides what it speaks. This page is that decision in one place: what the
server accepts, what it refuses and with which answer, what it leaves to
the reverse proxy in front of it, when a connection ends, and the test that
pins each line. It is the list to read before changing `Server`,
`HttpParser`, `Request` or `Response`, and the list to extend when a new
case is decided. It describes the code; it is not a plan.

The layer stays liftable: `script/check-http-layer` (part of the commit
gate) fails when `cybertrain/http/server` loads anything outside
`cybertrain/http/` besides `params.rb` and `logger.rb`.

## Who does what

A production deployment puts a reverse proxy (Caddy, nginx, kamal-proxy) in
front of the binary ([docs/deploy.md](deploy.md)). The split:

| Concern | Owner | Notes |
| --- | --- | --- |
| TLS, certificates, HTTP/2 and HTTP/3 | the proxy | the server speaks cleartext HTTP/1.0 and 1.1 only; `force_ssl` and `X-Forwarded-Proto` are how the application learns the outer scheme (D61) |
| Request bodies sent with `Transfer-Encoding: chunked` | the proxy | it must buffer and forward with `Content-Length` (Caddy, nginx and kamal-proxy do by default); the server answers a transfer coding with 411 |
| Slow or hostile clients, connection limits, request rate | the proxy first | the server bounds every wait itself (`read_timeout`, `max_head_bytes`, `max_body_bytes`), and `rate_limit` works per action, but it has no cap on open connections apart from the stream endpoint's `stream_max_connections` |
| Compression of responses | the proxy | the server never encodes a response; it inflates a gzip **request** body on demand (`request.decoded_body`) |
| The client's address | both | the server reports the peer; `request.client_ip` reads `X-Forwarded-For` only from `trusted_proxy` / `trusted_proxies` (D26) |
| `Host` validation | the application stack | `HostAuthorization` (development, or `CYBERTRAIN_HOSTS`), not the server: a request without `Host` is served |
| Request framing, limits, keep-alive, pipelining, HEAD, streaming, the WebSocket upgrade, graceful shutdown | the server | below |

Run without a proxy (development, a private network), the server is still
safe to expose to its own clients in the sense of the tables below, but it
has no TLS and no chunked request bodies.

## Requests

| Case | Behaviour | Test |
| --- | --- | --- |
| Versions | `HTTP/1.1` and `HTTP/1.0`; anything else is 400 | test/http_parser.rb ("HTTP/1.0 is accepted", "HTTP/2.0 raises ParseError") |
| Request line | exactly `METHOD SP target SP version`; otherwise 400 and the connection closes. Empty lines before it are skipped (RFC 9112 2.2) | test/http_parser.rb, test/server.rb ("malformed request line gets 400 ...") |
| Target | origin-form. It is passed on undecoded (`Query` and the `Router` decode); an absolute-form target (`GET http://host/path`) is not rewritten and reaches the handler as the path, so it is a 404 unless routed; `OPTIONS *` likewise | test/server.rb ("an absolute-form target is not rewritten ...") |
| Method | any token; unknown methods reach the router (404 / 405 are the application's) | test/router.rb |
| Line endings | CRLF. A head ended by bare LFs is never recognised: nothing is answered, and the connection closes at `read_timeout` | test/server.rb ("a head ended by bare LFs is not a head ...") |
| Header lines | `name: value`; names lowercased, values stripped, duplicates joined with `", "` in arrival order. Whitespace before the colon or in the name, a line without a colon, a bare CR, and obs-fold continuation lines are 400 | test/http_parser.rb |
| Head size | more than `max_head_bytes` (64 KiB) before the blank line is 400 | test/server.rb ("an oversized head ...", "a head over max_head_bytes with no blank line yet ...") |
| `Host` | not required and not checked here | test/server.rb ("HTTP/1.1 without a Host header is served ..."), test/host_authorization.rb |
| Body framing | `Content-Length` only, counted in bytes. Absent means no body. Not a plain decimal number, or sent twice, is 400; above `max_body_bytes` (`Config#max_body_bytes`, 10 MiB) is 413 before any of the body is read; more than 18 digits is 413 without parsing the number | test/server.rb ("POST with a Content-Length body ...", "an invalid Content-Length gets 400", "duplicate Content-Length headers ...", "a body over max_body_bytes gets 413 ...", "a Content-Length too large for an Integer gets 413", "a zero-padded Content-Length ...", the multibyte and NUL framing cases) |
| `Transfer-Encoding` | any value, `chunked` or `identity`, with or without a `Content-Length`: 411 and the connection closes, so bytes after the head are never read as a second request (no request smuggling through a CL/TE disagreement) | test/server.rb ("chunked transfer encoding gets 411 ...", "Transfer-Encoding beside a Content-Length is refused ...", "Transfer-Encoding: identity ...") |
| `Expect: 100-continue` | no interim `100` is sent; the server waits for the body for `read_timeout` and then answers. Clients that wait for the `100` send the body after their own timeout (curl: one second) | test/server.rb ("Expect: 100-continue gets no interim response ...") |
| `Content-Encoding: gzip` | the body is kept as sent; `request.decoded_body` inflates it under a ceiling, and a corrupt or oversized one is a 400 | test/http_request.rb, test/http_gunzip.rb |
| Query string, form and JSON bodies, multipart | parsed lazily by `Query` and `Multipart` under count, depth and size limits; past a limit is a 400 (`ClientError`), never a 500 | test/query.rb, test/params_limits.rb, test/multipart.rb, test/server.rb ("parameters past Query's limits get 400 ...") |
| Trailers, `TE`, `Upgrade: h2c`, CONNECT, pipelined requests after an error | not supported: trailers cannot arrive without chunked; `h2c` is ignored (the request is served as HTTP/1.1); a rejected request closes the connection and what was pipelined behind it is dropped | test/server.rb ("a rejected request ends the connection ...") |

Every refusal is a plain-text response with `Connection: close`, written
once, after which the socket is closed: 400 (malformed), 411 (a transfer
coding), 413 (too large). A client that sends nothing gets nothing: an idle
or half-sent request is closed silently at `read_timeout` (15 s).

## Responses

| Case | Behaviour | Test |
| --- | --- | --- |
| Status line | always `HTTP/1.1`, also to an HTTP/1.0 request | test/http_response.rb |
| Framing | `Content-Length` in bytes on every non-streaming response; a header the application set by that name is replaced by the real length | test/http_response.rb |
| HEAD | the head of the same response, with its `Content-Length`, and no body; the next request on the connection is read cleanly | test/server.rb ("HEAD returns headers with Content-Length and no body") |
| 304 | no `Content-Type`, no `Content-Length`, no body | test/http_caching.rb |
| 204 and 1xx | written like any other status: `Content-Length: 0` is sent. **Known deviation** from RFC 9110 8.6 (a 204 should carry no `Content-Length`); harmless to browsers and proxies, kept until changed on purpose | test/http_response.rb (the 204 case) |
| Defaults on every response | `Content-Type: text/html; charset=utf-8` unless set, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, the configured `Permissions-Policy`; an upgrade carries none of them | test/server.rb ("every response the server writes carries the security defaults") |
| Keep-alive | HTTP/1.1 stays open unless the request said `Connection: close`; HTTP/1.0 closes unless it said `keep-alive`; tokens are compared whole, and `close` wins. The response always names the outcome (`Connection: keep-alive` or `close`) | test/http_request.rb (`keep_alive?`), test/server.rb ("two keep-alive requests ...", "Connection: close ...", "HTTP/1.0 without keep-alive ...", "HTTP/1.0 with Connection: keep-alive ...") |
| Pipelining | requests already in the buffer are answered in order, one at a time | test/server.rb ("pipelined requests are answered in order") |
| An exception in the application | 500 and the connection stays usable; a client's fault (`ClientError`) is its 4xx. `JSON::ParserError` and `JSON::NestingError` are caught by name | test/server.rb, test/client_error.rb |

## When a connection ends

| Kind | It ends when | Test |
| --- | --- | --- |
| An ordinary response | the client asked for `close`, the request was HTTP/1.0 without `keep-alive`, the request was refused, the server is stopping (the response says `Connection: close`), or the client is silent for `read_timeout` between requests | test/server.rb ("an idle keep-alive connection is closed after read_timeout") |
| A streaming response (`Controller#stream`, Server-Sent Events) | always after the stream: there is no keep-alive after one. HTTP/1.1 gets `Transfer-Encoding: chunked` and the terminating chunk when the writer returns; HTTP/1.0 gets the body unframed and the close is the end; HEAD gets the head only. A writer that raises is logged and the connection is closed **without** the terminator, so the client sees a truncated stream, not a complete one. A client that stops reading ends the stream when one write waits longer than `stream_write_timeout` (`stream_ping_interval`); a client that disconnects is seen by the next write or by `Sink#closed?` | test/response_stream.rb (every case there), test/sse.rb |
| An upgrade (`101`, the WebSocket endpoint) | the head carries `Connection: Upgrade` and no framing; the writer owns the socket until it returns, and the connection closes then. The endpoint closes with a WebSocket status: 1000 on shutdown, 1008 for a bad token or a connection that subscribes to nothing, 1009 for an oversized message | test/websocket_server.rb |
| Shutdown (`SIGTERM`, `Server#stop`) | the listener closes first; a request in flight is answered completely with `Connection: close`; idle keep-alive connections are closed at once; a stream's read side is shut so its writer sees the end and returns; the wait is bounded by `drain_timeout` (10 s), after which the process goes on stopping | test/server.rb ("request_stop waits for a request in flight ...", "an idle keep-alive connection does not hold up shutdown", "many idle keep-alive connections ...", "drain_timeout bounds the wait ..."), test/stream_endpoint.rb ("stopping the server ends an open stream"), test/websocket_server.rb ("stopping the server closes the WebSocket with 1000") |

## Changing this page

A change to the server's behaviour changes the row and its test in the same
pull request; a case that is decided for the first time gets a row. A row
without a test is a claim, and the "Known deviation" rows are the list of
what is knowingly not RFC-conformant. Replacing the server is not planned
(D5): the interface it sits behind (`HttpHandler#call(request)` answering a
`Response`) is what keeps that possible.
