---
source_sha256: 2b56112469f77822eff135a926be5aadaa4c4f8c9e6c75c262213c049b39f367
---
# 实时：推送到浏览器的流

无需刷新即可把变化推送到已打开的页面：基于 Server-Sent Events 或 WebSocket 的 Turbo Streams，来自动作、作业或数据订阅的广播，以及供你自己的 JavaScript 使用的同一批流。

## 广播如何到达页面

页面订阅一个或多个具名的流；应用中的任何部分都可以按名称向某个流广播；每个订阅了该流的页面大约在十分之一秒内收到消息。

- **流有名称。** 名称可以是任意简短的文本（`"alerts"`），也可以是一条记录，其名称是它的表名和 id（`"articles:12"`，`Cybertrain::Stream.name_for(@article)`）。
- **一次广播就是一行。** `Cybertrain::Stream.broadcast(name, payload)` 向 `cybertrain_messages` 插入一行，这张表由框架自己在应用的数据库中创建。在 `DB.transaction` 内部，只有事务提交时消息才会发出。因为它是一行，所以任何共享该数据库的进程都可以广播：请求、`worker` 进程中的作业、订阅回调、`Main.command`。
- **每个 Web 进程轮询这张表。** 每个 `server` 进程有一个线程（流轮询器），每 `stream_poll_ms`（100 毫秒）读取新行，并把每一行交给该进程持有的浏览器。它每分钟删除一次早于 `stream_retention`（60 秒）的行。
- **浏览器连接到同一个端点** `/cybertrain/stream`，通过 Server-Sent Events（`EventSource`）或 WebSocket，并带上一个签名令牌，令牌指明它可以读取哪些流（[签名的流名称](#signed-stream-names)）。

不需要启动任何东西：`./<app> server` 会运行轮询器并提供该端点。`config.stream_path = ""` 关闭整个功能。

## Turbo Streams

[Turbo](https://turbo.hotwired.dev) 根据 `<turbo-stream action="append" target="comments">` 元素更新页面，就像 Rails 8 应用那样。在布局中加载 Turbo（没有资源管道：使用 CDN 或放在 `public/` 中的副本），然后用 `turbo_stream_from` 让页面订阅。广播、流端点和流辅助方法需要在 `bin/<app>.rb` 和 `bin/db.rb` 中写 `require "cybertrain/streams"`；缺少它时，`spin run gen` 会停在第一个 `turbo_stream_from` 处并指出那一行（[子系统](how-it-works.md#subsystems)）：

```erb app/views/layouts/application.html.erb（节选）
<head>
  <%= csrf_meta_tags %>
  <script type="module" src="https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/dist/turbo.es2017-esm.js"></script>
</head>
```

```erb app/views/articles/show.html.erb（节选）
<%= turbo_stream_from @article %>
<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render "comments/comment", comment: comment %>
  <% end %>
</div>
```

`turbo_stream_from` 接受任意数量的 String 和记录，并输出一个 `<turbo-stream-source>` 元素，其 URL 为它们全部携带一个令牌。Turbo 把它作为 `EventSource` 打开；`turbo_stream_from @article, ws: true` 则改为给出一个 `ws://` URL（在 HTTPS 之后为 `wss://`），Turbo 把它作为 WebSocket 打开。无论哪种方式，页面都不需要你写任何 JavaScript。不过 Turbo 不会重新打开丢失的 WebSocket（网络中断、服务器重启）：那个页面在重新加载之前收不到更多更新，而 `EventSource` 会自行重连并重放错过的内容。除非确实需要 WebSocket，否则请保留默认方式，或者用你自己的 JavaScript 重连（见下文的 `&after=`）。

然后在改变了数据的动作中广播：

```ruby app/controllers/comments_controller.rb（节选）
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

`broadcast_append_to(stream, target:, ...)` 渲染内容，把它包进一个 `<turbo-stream>` 元素并广播出去。内容是以下之一：带 `locals:` 的 `partial:`（由 `Cybertrain::Views.render_partial` 渲染）、`component:`（一个[视图组件](template-language.md#components)），或 `html:`（除非是 `SafeString`，否则会被转义）。目标是一个 DOM id，或一条记录，其 DOM id 为 `dom_id(record)`（`"comment_7"`）。其他方法用法相同：`broadcast_replace_to`、`broadcast_update_to`、`broadcast_prepend_to`、`broadcast_before_to`、`broadcast_after_to`、`broadcast_remove_to(stream, target:)` 和 `broadcast_refresh_to(stream)`（Turbo 8 以变形方式重新加载页面）。

Turbo 还会把链接和表单变成 fetch 请求（Turbo Drive）。scaffold 已经按 Turbo 期望的方式响应：表单成功后以 303 重定向，失败后以 422 重新显示表单。

### 用 Turbo Stream 响应表单

Turbo 提交的表单接受 `text/vnd.turbo-stream.html`。要用流而不是重定向来响应，就自己渲染这个元素；`Cybertrain::Turbo` 负责构建它们（`replace`、`update`、`append`、`prepend`、`before`、`after`、`remove`、`refresh`）：

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

### 从作业、定时任务或数据订阅中广播

广播不需要请求，因此作业可以渲染并发送一条广播：

```ruby config/app.rb（节选）
Cybertrain::Job.handle("price_refresh") do |payload|
  item = Item.find(Cybertrain::Cast.int(payload))
  item.refresh_price!
  Cybertrain::Stream.broadcast_replace_to("prices", target: item,
                                          partial: "items/price", locals: { item: item })
end
```

partial 由 `Cybertrain::Views.render_partial` 渲染，它在没有请求的情况下渲染：路径辅助方法（`item_path(item)`）可以使用，而需要请求的辅助方法（`csrf_token`、`params`、`flash`、`request_path`、`*_url`）会抛出 `Cybertrain::Views::OutsideRequest`（参见[在请求之外渲染](template-language.md#rendering-outside-a-request)）。作业既在服务器中运行，也在 `worker` 进程中运行，它写入的行会到达所有服务器的页面。

## 在 JavaScript 中使用 Server-Sent Events

对于不由 Turbo 驱动的页面（图表、行情条），以 JSON 方式请求流。`stream_source_path` 给出带令牌和 `mode=json` 的端点路径，`signed_stream_name` 只给出令牌：

```erb app/views/dashboards/show.html.erb（节选）
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

在 `mode=json` 下，每条消息都是一个以其流命名的事件，其数据为 `{"stream": ..., "id": ..., "data": ...}`，负载放在 `data` 中（以 String 的形式广播 JSON：`Stream.broadcast("prices", JSON.generate({ "price" => 12.5 }))`）。在默认的 `mode=raw` 下，负载原样作为普通的 `message` 事件发出，这正是 Turbo 读取的内容。

连接断开时浏览器会自动重连，并发送它看到的最后一个事件的 id（`Last-Event-ID`）。端点随后会先重发这些流中 id 更大、且仍在表中（在 `stream_retention` 之内）的所有消息，因此中间的内容不会丢失。离开时间更长的页面应当重新加载。在第一个事件到达之前，浏览器没有可发送的 id，所以在这段窗口内断开的连接不会得到任何重放：页面加载时渲染的内容就是它在下一次广播到达之前的状态。静默 15 秒后会发出一行注释（`: ping`），以便代理保持连接打开。

## 在 JavaScript 中使用 WebSocket

同一个 URL 也响应 WebSocket。页面由它构造出一个 `ws://` 或 `wss://` URL。请像这里一样通过 `data-` 属性传递路径和令牌：`<script>` 元素中的 `<%= %>` 会被 HTML 转义，而浏览器在那里不会解码它（服务器会收到 `&amp;`）。

```erb app/views/dashboards/show.html.erb（节选）
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

在 `mode=json` 下，每条消息是一个文本帧，包含同样的 `{"stream", "id", "data"}` 信封，页面可以在连接期间发送 JSON 文本帧来更改它的流：

| 页面发送 | 服务器回答 |
| --- | --- |
| `{"subscribe":"<token>"}` | `{"subscribed":["prices","alerts"]}`：该连接现在读取的所有流 |
| `{"unsubscribe":"<token>"}` | `{"unsubscribed":["alerts"]}` |
| 无法验证的令牌 | `{"error":"bad token"}` |
| 其他任何内容 | `{"error":"bad message"}` |

`mode=json` 的连接也可以不带令牌打开，然后通过消息订阅；15 秒后仍未读取任何流的连接会被关闭（代码 1008）。WebSocket 没有 `Last-Event-ID`：要在重连后补上错过的内容，请在 URL 上加上 `&after=<the last id you saw>`。服务器在每次静默 15 秒后发送 ping，并回应 ping；来自页面的二进制帧会被忽略。关闭代码：服务器停止时为 1000，令牌无效时为 1008，帧超过 `stream_max_message` 时为 1009，进程已满或页面落后太多时为 1013。

## 从动作中流式输出

动作可以让自己的响应保持打开，就像 Rails 的 `ActionController::Live` 那样：`stream` 在动作之后、在连接的线程上运行这个块，并把套接字作为 `Cybertrain::Sink` 交给它。

```ruby app/controllers/reports_controller.rb（节选）
def progress
  stream do |out|
    10.times do |i|
      out.write(Cybertrain::SSE.event(JSON.generate({ "done" => i * 10 }), event: "progress", id: i.to_s))
      break if out.wait_closed(1)   # 客户端离开时为 true
    end
  end
end
```

`stream(content_type: "text/event-stream", status: :ok)` 以 `Transfer-Encoding: chunked` 响应，并在块返回时关闭连接。`SSE.event(data, event: "", id: "", retry_ms: 0)` 格式化一个事件；客户端离开后 `out.closed?` 变为 true，之后的写入什么也不做。块不能再碰会话、flash 或响应头：它们已经随响应头部一起发出。

## 签名的流名称

页面只有持有指明某个流的令牌，才能读取该流。令牌由流名称和一个 HMAC-SHA256 签名组成，签名的密钥是从 `secret_key_base` 专为流派生出来的（如同 Rails 的 `turbo/signed_stream_verifier_key`），因此令牌绝不会是有效的会话 cookie；端点检查签名，既不读取会话，也不读取数据库。这就是 Turbo 的模型：能够渲染该页面的人就能读取它的流。令牌不会过期；更改 `secret_key_base` 会使所有令牌失效，跨越这次部署仍然打开的页面在重新加载之前收不到更新（`EventSource` 把 403 视为最终结果）。

<!-- list: points -->
- 专属于某个用户的流，是以该用户的记录命名的流 `turbo_stream_from @user`（`"users:7"`），只在该用户的页面上渲染。任何拿到该令牌的人，只要密钥不变，都能读取这个流。
- 令牌不会过期。更改 `CYBERTRAIN_SECRET_KEY_BASE` 会使所有令牌（以及所有会话）失效。
- 令牌放在 URL 中传递，因此反向代理的访问日志会记录它。框架自己的请求日志把它写成 `[FILTERED]`；请为 `/cybertrain/stream` 关闭代理的日志，或者让这些日志与流本身同样保密。
- 无效或缺失的令牌在 SSE 下是 403，在 WebSocket 下则是握手之后立即以 1008 关闭。
- 名称为 1 到 200 字节，不含控制字符和逗号；一个令牌最多携带 16 个名称，一个连接最多 64 个。

## 限制与设置

在 `config/app.rb` 中设置（`c.stream_poll_ms = 250`）；值超出范围时，启动会给出消息并停止。

| 设置 | 默认值 | 作用 |
| --- | --- | --- |
| `stream_path` | `"/cybertrain/stream"`（`CYBERTRAIN_STREAM_PATH`） | 端点的路径；`""` 关闭流 |
| `stream_poll_ms` | `100` | 每个服务器进程读取新消息的频率（至少 10） |
| `stream_retention` | `60` | 消息在表中保留的秒数，也就是重连最多能补回多久 |
| `stream_ping_interval` | `15` | 发送 ping 之前的静默秒数；也是对客户端的一次写入最多可以等待的时间 |
| `stream_max_connections` | `1000` | 每个进程打开的流数量；超过后 SSE 得到 503，WebSocket 以 1013 关闭 |
| `stream_max_message` | `65536` | 来自页面的单个 WebSocket 帧的字节数（超过则以 1009 关闭） |
| `stream_max_backlog` | `1000` | 为一个慢客户端积压的消息数，超过后将其断开（它会重连并获得重发） |

每个打开的流在页面打开期间占用一个连接及其绿色线程。在 nginx 之后，响应的 `X-Accel-Buffering: no` 头会关闭缓冲；对于 WebSocket，代理必须传递 `Upgrade` 和 `Connection`（Caddy 和 kamal-proxy 都会）。

## 哪个进程做什么

<!-- list: points -->
- **`./<app> server`** 总是运行轮询器和端点，在 `CYBERTRAIN_WORKER=0` 时也是如此：它向自己持有的浏览器投递消息。在轮询器运行之前，端点回答 503（`stream poller is not running`）；`serve` 会在打开端口之前启动它，所以提供服务的进程从不会出现这个回答。
- **`./<app> worker`** 和 **`./<app> feeds`** 不提供 HTTP，也不运行轮询器。它们的广播是行，由服务器投递（[进程角色](background-and-operations.md#process-roles)）。
- 共享一个数据库的多个服务器，各自把每条消息以相同的顺序和相同的 id 投递给自己的浏览器。

测试页面的流：[测试流和组件](testing.md#testing-streams-and-components)。设计：[docs/design.md](../design.md) D36 和 D37。

## 数据订阅的健康状况

[WebSocket 数据订阅](external-services.md#consuming-websocket-feeds)通常运行在不提供 HTTP 的 `feeds` 进程中，所以它的健康状况通过数据库传递：每个运行数据订阅的进程的监督线程，每隔 `feed_status_interval` 秒（10）为每个订阅向 `cybertrain_feeds` 写入一行。这张表属于框架（在首次使用时创建，不写入 `db/schema.rb`）。`server` 进程中的 `GET /up` 会读取它，当任何一行满足以下条件时返回 `503 feed stale`：

<!-- list: points -->
- 发布者过期：这一行最后一次写入是在 `health_feed_stale` 秒（180，`CYBERTRAIN_HEALTH_FEED_STALE`）之前，说明运行该订阅的进程已死掉、卡住或失去了数据库；或者
- 订阅陷入沉默：这一行是新的，但订阅在这么长的时间里既没有送来消息，也没有回应 ping（从未收到过任何东西的订阅从它启动时算起）。

两者分别检查，所以活着的发布者永远不会掩盖一个沉默的订阅。只有应用仍在订阅的数据订阅的行才计入：每个角色运行同一个二进制文件，所以名称没有被任何 `subscribe` 注册的行（你删除或改名的订阅）会被忽略。`health_feed_stale` 必须大于 `feed_status_interval`，否则每一行在两次写入之间都会过期，启动时会拒绝这样的设置。`CYBERTRAIN_HEALTH_FEEDS=0`（或 `false`）会关闭这项检查，适用于合理地安静超过阈值的订阅，或用其他方式监视订阅的部署。无法读取这张表时，`/up` 仍返回 200，并只记录一条 `[WARN]`，直到它再次可读。

`./<app> feeds status` 为运维人员打印这些行，每个订阅一行：

```console
$ ./blog feeds status
trades  connected  web-1:4242  last activity 3s ago  restarts 0  updated 4s ago
```

<!-- list: points -->
- 每一行只以订阅的名称为键：运行同一个订阅的两个进程会互相覆盖对方的行，这也是让每个订阅只在一个进程中运行的又一个理由。
- 被干净地停止的 `feeds` 进程（TERM 或 INT：一次部署、一次缩容）会删除它写入的行，所以你有意停止的角色不再被计入。崩溃的进程，或在订阅反复死掉之后退出的进程，会留下这些行让它们过期，而这正是 `/up` 要报告的。
- 你删除或改名的订阅会留下它的行，`/up` 会忽略它，`feeds status` 会把它标记为 `(not registered)`；你可以随时删除它（`./<app> dbconsole`，然后 `DELETE FROM cybertrain_feeds WHERE name = 'trades';`）。
- `status` 不能用作订阅名称：`subscribe("status", ...)` 会抛出 ArgumentError，因为 `./<app> feeds status` 会打印这张表。
- `/up` 不会重启任何东西。Kamal 只在部署期间为 web 角色轮询它，而 Docker 在进程退出时重启容器，`feeds` 进程在订阅反复死掉之后就会退出；请给这个角色设置重启策略（[进程角色](background-and-operations.md#process-roles)）。

设计说明：[docs/design.md](../design.md) D56。
