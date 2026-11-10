# Testing an app

App tests are plain Spinel programs under `test/`, like the framework's own:

```ruby
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Assertions: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. For controllers and
full HTTP flows, `Cybertrain::Test::Client` drives an app in-process (no
socket) with a cookie jar, so sessions and CSRF behave as behind a browser:

```ruby
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

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

Both snippets start from the example's helper,
[`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb):
copy it into an app's `test/support/`, where files are required, not run.
It migrates a fresh `storage/test.sqlite3`, boots the app as `BLOG`, loads
`Cybertrain::Test` and its client, and reads the CSRF token out of the last
rendered form (`BlogTest.form_token`). End each test file with
`Cybertrain::Test.run!`; `examples/blog/test/articles.rb` and `comments.rb`
show the full pattern.

Every request a test client sends comes from `127.0.0.1` (`request.remote_addr`,
so `request.loopback?` is true). To see what a page does for a visitor on
another machine, set `client.peer_address = "203.0.113.7"` before the
request.

Run with `cybertrain spin test`: it compiles each `test/*.rb` into its own
program and diffs its output (stdout and stderr together) against
`test/<name>.rb.expected`. Regenerate with `cybertrain spin test --regen
test/<name>.rb`; FFI/database tests can't run under CRuby, so their snapshot
comes from the compiled binary instead: `rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1` (`cybertrain spin test` exits non-zero while the
snapshot is stale, so it is followed by `;`, not `&&`; the `[ -x ]` check skips
the capture when the compile failed, so the old snapshot is kept; in the
framework checkout, `script/regen-snapshot test/<name>.rb` does exactly this and
prints the diff stat).

## Testing outbound calls

When the code under test sends a webhook ([Outbound HTTP](external-services.md#outbound-http)) or
an e-mail ([Sending e-mail](external-services.md#sending-e-mail)), the test receives it
in-process: `Cybertrain::Test::HttpReceiver` and `Cybertrain::Test::SmtpReceiver`
listen on `127.0.0.1`, record what arrives and answer with a canned reply.
The file starts from the same helper as above, `support/blog_test`;
`require "cybertrain"` loads the mailer, and the explicit require below does
no harm.

```ruby
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test
require "cybertrain/mailer"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

test "a sign-up posts a webhook" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  hook.start                                   # binds a free port, returns it
  Cybertrain.config.http_allow_private = true  # HttpClient refuses loopback otherwise
  SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # the app's code
  req = hook.received_request                  # waits at most 5 s; nil if nothing came
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

Cybertrain::Test.run!
```

`HttpReceiver.new` takes the canned `status:`, `headers:`, `body:` and
`chunked:` (`respond_with` changes them between requests); the request comes
back as a `ReceivedRequest` (`http_method`, `http_target`, `http_path`,
`http_headers` with lowercased names, `http_header(name)`, `http_body` with a
chunked body decoded). `SmtpReceiver` plays 220, EHLO (with 8BITMIME unless
`eight_bit_mime: false`, AUTH PLAIN with `auth: true`), MAIL, RCPT, DATA and
QUIT; `reject:` fails any of `:greeting`, `:ehlo`, `:mail`, `:rcpt`, `:data`
or `:message` with the reply given. A `ReceivedMessage` has the
`envelope_from`, `envelope_recipients`, the `message_data` (dot-stuffing
undone), `message_header(name)`, `message_body` and the `transcript` of
commands; for an HTML message, `message_parts` decodes it into
`"subject"`, `"text"` and `"html"`. Both accept one connection unless `max:` says more
(`received_requests` / `received_messages` return them all). Every wait is
bounded: a receiver gives up after `accept_window:` (10 s) without a
connection, a silent client after `read_timeout:` (5 s), and `stop` (safe
to call twice) ends and joins the receiver's thread and closes its port, so
a receiver never takes a later test's connection. They need only Ruby's
socket library, not openssl.

A feed is tested the same way with `Cybertrain::Test::WebSocketReceiver`, a
scripted WebSocket server on `127.0.0.1`: each connection plays a list of
`Cybertrain::Test::WsStep`s (`"accept"`, `"send_text"`, `"expect"`,
`"silent"`, `"close"`, `"drop"`, `"echo_until_close"`, ...), and the frames
the client sent come back unmasked from `ws_received`.

```ruby
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # a constant: the blocks cannot see locals

# The blocks are written in a method, where their parameters are used,
# not inside the test block.
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
  Cybertrain::WebSocket.start!               # Test::Client never starts feeds
  # ... poll TICKS for at most a few seconds ...
  Cybertrain::WebSocket.stop!
  assert_equal ["tick"], TICKS
  assert_equal "subscribe", rx.ws_received[0].rec_data
  rx.stop
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` makes the retry delays exact.
`test/websocket_integration.rb` in this repository shows a complete test.

## Testing jobs

`require "cybertrain/test/jobs"` adds five helpers over the job queue of
the test database. The support file `cybertrain generate authentication`
writes (`test/support/app_test.rb`) requires it; an application without one
adds the line to its own support file, as examples/blog's does.

```ruby
require_relative "support/blog_test"
require "cybertrain/test/jobs"

test "a notification is enqueued, then runs" do
  clear_enqueued_jobs
  NotifyCommentJob.perform_later("comment_id" => 7, "article_id" => 1)
  assert_enqueued_jobs 1, "NotifyCommentJob"
  assert_enqueued_with "NotifyCommentJob", { "comment_id" => 7 }
  assert_equal 1, perform_enqueued_jobs
  assert_no_enqueued_jobs
end

test "the job itself" do
  assert_nil NotifyCommentJob.perform_now("comment_id" => 1, "article_id" => 1)
end
```

<!-- list: points -->
- `assert_enqueued_jobs(count, kind = "")` counts the `queued` rows (of one
  kind when given); `assert_no_enqueued_jobs(kind = "")` wants none.
- `assert_enqueued_with(kind, args)` wants a queued row of that kind whose
  args hold every given key with an equal value, both sides compared as
  `Cast.str`, so `"comment_id" => 7` matches a JSON `7`.
- `perform_enqueued_jobs(now = Time.now)` runs every due job on the calling
  thread, one by one (`Job.work_one`), until none is due, and returns how
  many ran. A retry scheduled for later stays queued: pass a later `now` to
  run it. A job that enqueues itself again, due at once, keeps it running.
- `clear_enqueued_jobs` deletes every `queued` row; `failed` and
  `discarded` rows stay, so a test that makes them deletes them itself.
- `WelcomeJob.perform_now(args)` runs one job directly, with no queue and
  no rescue: an exception reaches the test.
- A mail sent with `deliver_later` is a `"cybertrain mail"` job:
  `perform_enqueued_jobs` sends it to a `SmtpReceiver` (with
  `smtp_host` and `smtp_port` pointing at it).
- Scheduled tasks run one tick at a time with `Cybertrain::Scheduler.run_due(now)`,
  and `Cybertrain::Cache.prune(now)` prunes the cache at a time you choose.

## Testing streams and components

`require "cybertrain/test/views"` adds two renderers that need no request,
for asserting on the HTML of a partial or a [component](template-language.md#components):

```ruby
require_relative "support/blog_test"
require "cybertrain/test/views"

test "the comment component names its author" do
  html = Cybertrain::Test.render_component(CommentComponent.new(comment: Comment.first))
  assert_includes html, "<strong>"
end

test "the article partial links to the article" do
  article = Article.create(title: "Hello", body: "Rendered for the test")
  html = Cybertrain::Test.render_partial("articles/article", article: article)
  assert_includes html, BlogTest.article_path(article)
end
```

`Test.render_component(component, content: "")` passes `content:` as the
block's HTML. Both render as a broadcast does, so a helper that needs a
request raises `Cybertrain::Views::OutsideRequest` here too.

A [stream](realtime.md) is tested through the endpoint.
`client.get_stream(path, events: n, timeout: 2, headers: {})` runs a streaming
response in memory until `n` events have been written (pings do not count)
or the timeout has passed, and returns it with what was written as its body.
The endpoint answers 503 until the stream poller runs, and a test client does
not start it, so start it once in the file:

```ruby
Cybertrain::Stream::Poller.start!

test "a new comment is broadcast to the article's stream" do
  article = Article.create(title: "Live comments", body: "Posted for the test")
  Cybertrain::Stream.broadcast_append_to(article, target: "comments", html: "hi")
  token = Cybertrain::Stream.sign([Cybertrain::Stream.name_for(article)])
  client = Cybertrain::Test::Client.new(BLOG)
  res = client.get_stream("/cybertrain/stream?s=#{token}", events: 1, headers: { "last-event-id" => "0" })
  assert_includes res.body, '<turbo-stream action="append" target="comments">'
end
```

A new connection receives only what is broadcast after it connects;
`last-event-id` set to `0` replays what is already in the table, which is
what lets a test broadcast first and read after. To check only that an action
broadcast, read the table: `Cybertrain::DB.with { |c| c.execute("SELECT
stream, payload FROM cybertrain_messages ORDER BY id DESC LIMIT 1") }`.

## Continuous integration

`cybertrain new` writes `.github/workflows/ci.yml` for the app. It calls the
`setup-cybertrain` action of this repository
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
pinned to the CLI's release tag, which installs the SQLite, zlib and OpenSSL
headers and Ruby, reads the framework commit the app is locked to out of
`spin.lock`, fetches the framework at that commit and runs its `cybertrain
doctor` and `cybertrain setup` (with `~/.cybertrain/spinel` cached per Spinel
release and runner image). The workflow then checks that `spin.lock` is
current (`spin lock && git diff --exit-code spin.lock`) and `gen/` is fresh
(`spin run gen -- --check`), and runs `spin test` once `test/` has a test
program. When the toolchain steps change, the action changes, not every app's
copy. The commit is read from `spin.lock`, so the workflow assumes the
default git dependency; an app made with `--path` passes the framework
checkout to the action as `framework-path`.
