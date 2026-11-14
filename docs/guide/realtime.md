# Realtime: streams to the browser

Push changes to open pages without a reload: Turbo Streams over Server-Sent
Events or WebSocket, a broadcast from an action, a job or a feed, and the same
streams for your own JavaScript.

## How a broadcast reaches a page

A page subscribes to one or more named streams; anything in the application
broadcasts to a stream by name; every page subscribed to it receives the
message within about a tenth of a second.

- **Streams have names.** A name is any short text (`"alerts"`), or a record,
  whose name is its table and id (`"articles:12"`,
  `Cybertrain::Stream.name_for(@article)`).
- **A broadcast is a row.** `Cybertrain::Stream.broadcast(name, payload)`
  inserts a row into `cybertrain_messages`, a table the framework creates
  itself in the application's database. Inside a `DB.transaction` the
  message goes out only if the transaction commits. Because it is a row, a
  broadcast works from any process that shares the database: a request, a
  job in a `worker` process, a feed callback, a `Main.command`.
- **Each web process polls the table.** One thread per `server` process (the
  stream poller) reads the new rows every `stream_poll_ms` (100 ms) and hands
  each one to the browsers that process holds. It deletes rows older than
  `stream_retention` (60 seconds) once a minute.
- **The browser connects to one endpoint**, `/cybertrain/stream`, over
  Server-Sent Events (`EventSource`) or a WebSocket, with a signed token that
  names the streams it may read ([Signed stream names](#signed-stream-names)).

There is nothing to start: `./<app> server` runs the poller and serves the
endpoint. `config.stream_path = ""` turns the whole feature off.

## Turbo Streams

[Turbo](https://turbo.hotwired.dev) updates a page from
`<turbo-stream action="append" target="comments">` elements, the way Rails 8
applications do. Load Turbo in the layout (there is no asset pipeline: a CDN
or a copy in `public/`), and subscribe a page with `turbo_stream_from`.
Broadcasts, the stream endpoint and the stream helpers need
`require "cybertrain/streams"` in `bin/<app>.rb` and `bin/db.rb`; without
it `spin run gen` stops at the first `turbo_stream_from` and names the
line ([Subsystems](how-it-works.md#subsystems)):

```erb app/views/layouts/application.html.erb (excerpt)
<head>
  <%= csrf_meta_tags %>
  <script type="module" src="https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/dist/turbo.es2017-esm.js"></script>
</head>
```

```erb app/views/articles/show.html.erb (excerpt)
<%= turbo_stream_from @article %>
<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render "comments/comment", comment: comment %>
  <% end %>
</div>
```

`turbo_stream_from` takes Strings and records, any number of them, and
writes one `<turbo-stream-source>` element whose URL carries one token for
all of them. Turbo opens it as an `EventSource`; `turbo_stream_from @article,
ws: true` gives a `ws://` URL (`wss://` behind HTTPS) instead, which Turbo
opens as a WebSocket. Either way the page needs no JavaScript of yours. Turbo
does not reopen a WebSocket it lost (a network cut, a restart of the server):
that page gets no more updates until it is reloaded, where an `EventSource`
reconnects by itself and replays what it missed. Keep the default unless you
need WebSocket, or reconnect from your own JavaScript (`&after=`, below).

Then broadcast from the action that changed something:

```ruby app/controllers/comments_controller.rb (excerpt)
def create
  @comment = Comment.new(comment_params)
  @comment.article_id = @article.id
  if @comment.save
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           partial: "comments/comment", locals: { comment: @comment })
  end
  redirect_to article_path(@article), status: :see_other
end
```

`broadcast_append_to(stream, target:, ...)` renders the content, wraps it in
a `<turbo-stream>` element and broadcasts it. The content is one of
`partial:` with `locals:` (rendered by `Cybertrain::Views.render_partial`),
`component:` (a [view component](template-language.md#components)) or
`html:` (escaped unless it is a `SafeString`). The target is a DOM id, or a
record, whose DOM id is `dom_id(record)` (`"comment_7"`). The others work the
same way: `broadcast_replace_to`, `broadcast_update_to`,
`broadcast_prepend_to`, `broadcast_before_to`, `broadcast_after_to`,
`broadcast_remove_to(stream, target:)` and `broadcast_refresh_to(stream)`
(Turbo 8 reloads the page with morphing).

Turbo also turns links and forms into fetch requests (Turbo Drive). The
scaffold already answers the way Turbo expects: a redirect with 303 after a
successful form, and 422 with the form again after a failed one.

### Answering a form with a Turbo Stream

A form Turbo submits accepts `text/vnd.turbo-stream.html`. To answer with a
stream instead of a redirect, render the element yourself;
`Cybertrain::Turbo` builds them (`replace`, `update`, `append`, `prepend`,
`before`, `after`, `remove`, `refresh`):

```ruby
def destroy
  @comment = Comment.where(article_id: @article.id).find(params[:id])
  @comment.destroy
  if request.header("accept").to_s.include?("text/vnd.turbo-stream.html")
    render html: Cybertrain::Turbo.remove(@comment), content_type: "text/vnd.turbo-stream.html"
  else
    redirect_to article_path(@article), status: :see_other
  end
end
```

### Broadcasting from a job, a task or a feed

A broadcast needs no request, so a job can render and send one:

```ruby config/app.rb (excerpt)
Cybertrain::Job.handle("price_refresh") do |payload|
  item = Item.find(Cybertrain::Cast.int(payload))
  item.refresh_price!
  Cybertrain::Stream.broadcast_replace_to("prices", target: item,
                                          partial: "items/price", locals: { item: item })
end
```

The partial is rendered by `Cybertrain::Views.render_partial`, which renders
with no request: path helpers (`item_path(item)`) work, and the helpers that
need a request (`csrf_token`, `params`, `flash`, `request_path`, `*_url`)
raise `Cybertrain::Views::OutsideRequest` (see [Rendering outside a
request](template-language.md#rendering-outside-a-request)). A job runs in a
`worker` process as well as in a server, and the row it writes reaches every
server's pages.

## Server-Sent Events from JavaScript

For a page that is not driven by Turbo (a chart, a ticker), ask for the
streams in JSON. `stream_source_path` gives the endpoint's path with the
token and `mode=json`, and `signed_stream_name` the token alone:

```erb app/views/dashboards/show.html.erb (excerpt)
<div id="price" data-src="<%= stream_source_path "prices", "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("price");
  const source = new EventSource(el.dataset.src);
  source.addEventListener("prices", (event) => {
    const message = JSON.parse(event.data);   // {"stream":"prices","id":42,"data":"..."}
    el.textContent = JSON.parse(message.data).price;
  });
  source.addEventListener("alerts", (event) => console.log(JSON.parse(event.data).data));
</script>
```

In `mode=json` each message is an event named after its stream, whose data
is `{"stream": ..., "id": ..., "data": ...}` with the payload as `data`
(broadcast JSON as a String: `Stream.broadcast("prices",
JSON.generate({ "price" => 12.5 }))`). In the default `mode=raw` the payload
goes out as it is, as a plain `message` event, which is what Turbo reads.

The browser reconnects by itself when the connection drops, and sends the
id of the last event it saw (`Last-Event-ID`). The endpoint then first
replays every message of those streams with a larger id that is still in the
table (within `stream_retention`), so nothing in between is lost. A page
away for longer than that should reload. Before its first event arrives the
browser has no id to send, so a connection that drops in that window replays
nothing: what the page rendered on load is its state until the next
broadcast. A comment line (`: ping`) goes out
after 15 seconds of silence so that proxies keep the connection open.

## WebSocket from JavaScript

The same URL answers a WebSocket. A page builds a `ws://` or `wss://` URL
from it. Pass the path and tokens through `data-` attributes, as here: a
`<%= %>` inside a `<script>` element is HTML-escaped, and the browser does not
decode it there (`&amp;` would reach the server).

```erb app/views/dashboards/show.html.erb (excerpt)
<div id="ticker" data-src="<%= stream_source_path "prices" %>" data-alerts="<%= signed_stream_name "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("ticker");
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  const socket = new WebSocket(scheme + location.host + el.dataset.src);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.stream) console.log(message.stream, message.id, message.data);
  });
  socket.addEventListener("open", () => {
    socket.send(JSON.stringify({ subscribe: el.dataset.alerts }));
  });
</script>
```

With `mode=json` each message is one text frame holding the same
`{"stream", "id", "data"}` envelope, and the page may change its streams
while connected by sending a JSON text frame:

| The page sends | The server answers |
| --- | --- |
| `{"subscribe":"<token>"}` | `{"subscribed":["prices","alerts"]}`: every stream the connection now reads |
| `{"unsubscribe":"<token>"}` | `{"unsubscribed":["alerts"]}` |
| a token that does not verify | `{"error":"bad token"}` |
| anything else | `{"error":"bad message"}` |

A `mode=json` connection may also open with no token and subscribe by
message; one that still reads no stream after 15 seconds is closed (code
1008). A WebSocket has no `Last-Event-ID`: to catch up after a reconnect,
add `&after=<the last id you saw>` to the URL. The server pings every 15
seconds of silence and answers pings; binary frames from the page are
ignored. Close codes: 1000 when the server stops, 1008 for a bad token, 1009
for a frame over `stream_max_message`, 1013 when the process is full or the
page fell too far behind.

## Streaming from an action

An action can keep its own response open, as Rails' `ActionController::Live`
does: `stream` runs the block after the action, on the connection's thread,
and gives it the socket as a `Cybertrain::Sink`.

```ruby app/controllers/reports_controller.rb (excerpt)
def progress
  stream do |out|
    10.times do |i|
      out.write(Cybertrain::SSE.event(JSON.generate({ "done" => i * 10 }), event: "progress", id: i.to_s))
      break if out.wait_closed(1)   # true when the client went away
    end
  end
end
```

`stream(content_type: "text/event-stream", status: :ok)` answers with
`Transfer-Encoding: chunked` and closes the connection when the block
returns. `SSE.event(data, event: "", id: "", retry_ms: 0)` formats one event;
`out.closed?` turns true once the client is gone, and writes after that do
nothing. The block must not touch the session, flash or headers: they were
sent with the head.

## Signed stream names

A page may read a stream only with a token that names it. The token is the
stream names and an HMAC-SHA256 signature made with a key derived from
`secret_key_base` for streams alone (as Rails'
`turbo/signed_stream_verifier_key`), so a token is never a valid session
cookie; the endpoint checks the signature and reads neither the session nor the
database. That is Turbo's model: whoever could render the page could read
its streams. Tokens do not expire; changing `secret_key_base` invalidates
every one, and a page open across that deploy stops receiving (an
`EventSource` treats the 403 as final) until it is reloaded.

<!-- list: points -->
- A stream for one user is a stream named after that user's record,
  `turbo_stream_from @user` (`"users:7"`), rendered only on that user's
  pages. Anyone who gets hold of the token can read that stream, for
  as long as the secret stays the same.
- Tokens do not expire. Changing `CYBERTRAIN_SECRET_KEY_BASE` invalidates
  every token (and every session).
- The token travels in the URL, so a reverse proxy's access log records it.
  The framework's own request log writes it as `[FILTERED]`; turn the
  proxy's logging off for `/cybertrain/stream`, or keep those logs as private
  as the streams.
- A bad or missing token is a 403 over SSE, and a close with 1008 right after
  the handshake over WebSocket.
- A name is 1 to 200 bytes with no control character and no comma; a token
  carries at most 16 names, a connection at most 64.

## Limits and settings

Set these in `config/app.rb` (`c.stream_poll_ms = 250`); the boot stops
with a message for a value out of range.

| Setting | Default | What it does |
| --- | --- | --- |
| `stream_path` | `"/cybertrain/stream"` (`CYBERTRAIN_STREAM_PATH`) | The endpoint's path; `""` turns streams off |
| `stream_poll_ms` | `100` | How often each server process reads new messages (at least 10) |
| `stream_retention` | `60` | Seconds a message stays in the table, and so how far a reconnect can catch up |
| `stream_ping_interval` | `15` | Seconds of silence before a ping; also how long one write to a client may wait |
| `stream_max_connections` | `1000` | Open streams per process; past it SSE gets 503 and WebSocket a close with 1013 |
| `stream_max_message` | `65536` | Bytes in one WebSocket frame from the page (close 1009 past it) |
| `stream_max_backlog` | `1000` | Messages waiting for one slow client before it is dropped (it reconnects and replays) |

Each open stream holds one connection, and its green thread, for as long as
the page is open. Behind nginx the response's `X-Accel-Buffering: no` header
turns buffering off; for WebSocket the proxy must pass `Upgrade` and
`Connection` (Caddy and kamal-proxy do).

## Which process does what

<!-- list: points -->
- **`./<app> server`** runs the poller and the endpoint, always, also with
  `CYBERTRAIN_WORKER=0`: it delivers to the browsers it holds. Until the
  poller runs, the endpoint answers 503 (`stream poller is not running`);
  `serve` starts it before the port opens, so a served process never shows
  it.
- **`./<app> worker`** and **`./<app> feeds`** serve no HTTP and run no
  poller. Their broadcasts are rows, which the servers deliver
  ([Process roles](background-and-operations.md#process-roles)).
- Several servers on one database each deliver every message to their own
  browsers, in the same order and with the same ids.

Testing a page's stream: [Testing streams and
components](testing.md#testing-streams-and-components). The design:
[docs/design.md](../design.md) D36 and D37.

## Feed health

A [WebSocket feed](external-services.md#consuming-websocket-feeds) often runs
in a `feeds` process, which serves no HTTP, so its health travels through
the database: the supervisor of every process that runs feeds writes one row
per subscription into `cybertrain_feeds` every `feed_status_interval`
seconds (10). The table is the framework's own (created on first use, left
out of `db/schema.rb`). `GET /up` in a `server` process reads it and answers
`503 feed stale` when, for any row:

<!-- list: points -->
- the publisher is stale: the row was last written more than
  `health_feed_stale` seconds ago (180, `CYBERTRAIN_HEALTH_FEED_STALE`), so
  the process that runs the feed died, hangs or lost its database; or
- the feed is silent: the row is fresh, but the feed has neither delivered a
  message nor answered a ping for that long (a feed that never received
  anything counts from its start).

The two are checked separately, so a live publisher never hides a silent
feed. Only rows of feeds this application still subscribes count: every
role runs the same binary, so a row whose name no `subscribe` registers (a
feed you removed or renamed) is ignored. `health_feed_stale` must be more
than `feed_status_interval`, or every row would be stale between two writes;
boot refuses it otherwise. `CYBERTRAIN_HEALTH_FEEDS=0` (or `false`) turns
the check off, for a feed that is legitimately quiet for longer than the
threshold or a deployment that watches its feeds some other way. A table
that cannot be read leaves `/up` at 200 and logs one `WARN` line until it
can be read again.

`./<app> feeds status` prints the rows for an operator, one line per feed:

```console
$ ./blog feeds status
trades  connected  web-1:4242  last activity 3s ago  restarts 0  updated 4s ago
```

<!-- list: points -->
- A row is keyed by the feed's name only: two processes that run the same
  feed overwrite each other's row, which is one more reason to run each
  feed in one process.
- A `feeds` process stopped cleanly (TERM or INT: a deploy, a scale-down)
  deletes the rows it wrote, so a role you stop on purpose stops counting.
  One that crashed, or exited after repeated feed deaths, leaves them to go
  stale, which is what `/up` is there to report.
- A feed you remove or rename leaves its row, which `/up` ignores and
  `feeds status` marks `(not registered)`; delete it when you like
  (`./<app> dbconsole`, then `DELETE FROM cybertrain_feeds WHERE name =
  'trades';`).
- `status` is not a feed name: `subscribe("status", ...)` raises
  ArgumentError, since `./<app> feeds status` prints the table.
- `/up` restarts nothing. Kamal polls it only for the web role during a
  deploy, and Docker restarts a container when its process exits, which a
  `feeds` process does after repeated feed deaths; give the role a restart
  policy ([Process roles](background-and-operations.md#process-roles)).

The design: [docs/design.md](../design.md) D56.
