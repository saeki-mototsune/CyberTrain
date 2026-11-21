---
source_sha256: 95aa532ab50c281cb5b22692324ab27171bb65213f7c46a6ea6c7903d5bb5d88
---
# 日志与错误报告

运行中的应用写入日志的内容（行的格式、级别、JSON 行、请求 ID 与标签），以及请求、作业、定时任务和数据订阅的异常如何送达应用的订阅者和 Sentry。作业、进程角色和健康检查见[后台任务与运维](background-and-operations.md)。

## 日志

框架和应用通过 `Cybertrain.logger` 记录日志，每条消息在标准输出上占一行，每行之后都会刷新，正如十二要素应用那样（systemd 的 journal、Kamal 和 Docker 会收集它）：

```text 输出 — ./blog server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 127.0.0.1
2026-11-14T09:30:00.132Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-14T09:30:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: RuntimeError: smtp down; retrying in 60 s
2026-11-14T09:30:02.410Z WARN [feed:prices] WebSocket "prices" silent for 60s; reconnecting
```

一行依次是精确到毫秒的 UTC 时间（在测试中它跟随 `travel_to`）、大写的级别、方括号中的标签和消息。`Cybertrain.logger` 有 `debug`、`info`、`warn`、`error` 和 `fatal`，每个都接受一个 String。多个线程的行永远不会混在一起：每一行都先完整构建，再在只为这一次写入而持有的锁下用一次 write 写出。写入失败（管道已关闭）时丢弃这一行；记录日志永远不会向调用方抛出异常。读取标准输出的一方停止读取时（管道已满），所有记录日志的线程都会阻塞，直到它再次读取，所以请保持日志收集器运行。

**一个事件一行。** 消息或标签中的换行写成两个字符 `\n`，回车写成 `\r`，所以多行的消息或伪造的消息无法另起一行：`Cybertrain.logger.info("ok\n2026-11-11T12:00:00.000Z ERROR fake")` 写出一行：

```text 输出 — 一个事件一行
2026-11-14T09:30:00.120Z INFO ok\n2026-11-11T12:00:00.000Z ERROR fake
```

消息末尾恰好一个换行是这一行自己的结尾，不转义（`info("done\n")` 写出 `done`）；第二个会转义。其他什么都不转义：反斜杠仍是反斜杠，制表符、其他控制字节和无效的 UTF-8 原样写出。JSON 行的转义与以前相同。

**级别。** `config/app.rb` 中的 `c.log_level`，或 `CYBERTRAIN_LOG_LEVEL`（`debug`、`info`、`warn`、`error`、`fatal` 或 `none`，不区分大小写），是写出的最低级别；默认为 `:info`。`:none` 还会关闭请求日志，但仍然写出错误行。`config/app.rb` 中的赋值优先于变量。其他值会让启动停止：`error: log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)`。

**JSON 行。** `c.log_format = :json`（或 `CYBERTRAIN_LOG_FORMAT=json`）改为每行写一个 JSON 对象，供日志收集器使用：

```json
{"time":"2026-11-14T09:30:00.132Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

只有当这一行带有请求 ID（在请求中，或在请求加入队列的作业中）并且 `log_tags` 显示它时，才有 `request_id`；`tags` 按顺序包含其他标签。当一条消息（或一个标签）不是合法 UTF-8 时，它从 0x80 起的每个字节（包括合法字符的字节）在 JSON 中都写成转义 `\ufffd`，所以一个坏字节会让这条消息的所有非 ASCII 文字都变成替换字符；合法的消息原样写出，文本行保留记录时的原始字节。`:text` 和 `:json` 以外的格式会让启动停止：`error: log_format must be :text or :json (got :xml)`。启动自身的第一行（测试之外 `mail_delivery_method :test` 的警告）遵循该格式；关于值无效的应用设置（`setting_int`、`setting_bool` 退回默认值时）的警告是在 `config/app.rb` 运行时、格式确定之前记录的，因此总是文本行。

级别和格式适用于 `./<app> server`、`worker` 和 `feeds`，也适用于注册的命令、`jobs` 和 `console`；它们以同样的消息拒绝未知的值，并在打开数据库之前以退出状态 1 结束。`migrate`、`db` 和 `dbconsole` 不应用它们：它们的行是 `info` 级别的文本。

### 请求 ID

每个请求都有一个 ID，即版本 4 的 UUID；动作通过 `request.request_id` 读取它，响应在 `X-Request-Id` 中返回它，主机检查的 403、`force_ssl` 的 https 重定向、错误页面、开发环境的诊断页面和服务器自己的 500 也都带有它。服务器对无法读取的请求、在应用看到之前就返回的 400 和 413 不带它。请求运行期间记录的每一行都把这个 ID 作为标签（默认的 `log_tags` 下是第一个标签），应用自己的 `Cybertrain.logger.info` 行也一样；流式响应体（`stream do ... end`、Server-Sent Events）和请求打开的 WebSocket 连接在保持打开期间也是如此。

```ruby
Cybertrain.logger.info("export #{report.id} for #{request.request_id}")
```

只有来自应用信任的代理时，才使用代理的 ID：当连接来自受信任的代理（`CYBERTRAIN_TRUSTED_PROXY` 或 `CYBERTRAIN_TRUSTED_PROXIES`，与 `request.client_ip` 做的检查相同；[代理之后的客户端地址](requests.md#the-client-address-behind-a-proxy)），且它的 `X-Request-Id` 是 1 到 255 个 ASCII 字母、数字和连字符时，请求采用这个 ID，这样代理的日志和应用的日志共享它。任何其他 `X-Request-Id`（包括发送了两次的请求头）都会被丢弃并生成新的 ID；它永远不会被改写。

`c.log_tags` 按顺序选择请求的标签：默认为 `[:request_id]`，`[:request_id, :remote_ip]` 加上 `request.client_ip`（默认关闭：地址属于个人数据），`[]` 表示不显示（请求头仍然发送）。其他值会让启动停止：`error: log_tags may hold :request_id and :remote_ip (got :user_agent)`。

### 标签

`Cybertrain.logger.tagged` 在块运行期间，给这个线程记录的每一行在请求自己的标签之后加上标签，并在块结束时去掉，块抛出异常时也是如此；它返回块的值。块可以嵌套。没有不带块的形式。

```ruby
Cybertrain.logger.tagged("billing", "order #{order.id}") do
  Cybertrain.logger.info("charged 300")
  # 2026-11-14T09:30:00.140Z INFO [3f2a9c1e-...] [billing] [order 7] charged 300
end
```

标签属于线程：你启动的线程从没有标签开始，无论启动它的线程有什么标签。框架也以同样的方式给自己的工作加标签：

- **作业。** 每次尝试的行带有 `[<JobClass> <id>]`（对于来自 `Job.handle` 的块作业，是它的种类），然后是把它加入队列的请求的 ID：`INFO [WelcomeJob 7] [3f2a9c1e-...] welcome 1`。无论 `log_tags` 如何，ID 都会记录在作业的行中（`cybertrain_jobs.request_id`），当 `log_tags` 包含 `:request_id` 时显示。由作业加入队列的作业记录其父作业的 ID；由定时任务、数据订阅或命令加入队列的作业不记录 ID。
- **定时任务。** 任务运行期间为 `[schedule:<name>]`，失败的行也一样。
- **数据订阅。** 数据订阅线程记录的每一行（包括它的回调）都带 `[feed:<name>]`。监督线程在自己的线程上记录的重启和放弃的行不带标签。

## 错误报告

`Cybertrain.error` 收集结束了请求、作业的一次尝试、定时任务或数据订阅的异常，以及应用自己报告的异常，把每一个交给应用添加的订阅者，并在设置了 DSN 时发送给 Sentry（或 GlitchTip）。它在核心中；发送给 Sentry 是单独的一行，`require "cybertrain"` 会加载它，基于 `cybertrain/core` 的应用把它加到 `bin/<app>.rb`（不是 `bin/db.rb`；[子系统](how-it-works.md#subsystems)）。`cybertrain new` 会把本节的这些行以注释形式写出：`.env.example` 中的变量、`config/app.rb` 中的订阅者、`config/deploy.yml` 和 `.kamal/secrets` 中的 DSN，以及 `bin/<app>.rb` 注释中的这一行：

```ruby
require "cybertrain/error_reporter/sentry"   # bin/<app>.rb 中 require "cybertrain/core" 之后
```

```ruby
# 应用捕获的异常，连同它知道的信息：
begin
  charge(order)
rescue PaymentError => e
  Cybertrain.error.report(e, context: { "order_id" => order.id })
end

# 运行一个块，报告它抛出的异常，然后以 nil 继续：
price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)
end
```

`report(e, handled: true, context: {})` 立即返回 nil：报告在报告器自己的线程上投递。上下文的键和值会变成 String，并覆盖在框架添加的上下文（作业的 ID 和尝试次数）之上。`handle(context: {}) { }` 返回块的值；块抛出 `StandardError`（或 `JSON::ParserError`、`JSON::NestingError`）时，报告它并返回 nil；块中的 `break v` 让 `handle` 返回 `v`，`return` 从外围的方法返回。块中抛出的其他类的异常会传到调用方。报告本身从不向调用方抛出异常：如果报告失败，日志会以 error 级别记录 `error report failed: <Class>: <message>`。

**订阅者。** 订阅者是应用自己的类，是定义了 `report(event)` 的 `Cybertrain::ErrorSubscriber` 子类：

```ruby
# config/app.rb 中、订阅它的那一行之上（bin/<app>.rb 在 app/ 之前
# 加载 config/app，所以这里还没有加载 app/ 下的类）
class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message} at #{event.error_where}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)
```

每个订阅者都在报告器的线程上收到每一个报告，而不是在失败的请求或作业中。抛出异常的订阅者会以 error 级别记录 `error subscriber AuditSubscriber failed: <Class>: <message>`，它本身永远不会被报告；其他订阅者照样收到事件。事件是由 String 组成的值：

| 读取方法 | 内容 |
| --- | --- |
| `error_class` | 异常的类名，带命名空间（`"Cybertrain::DB::Error"`） |
| `error_message` | 它的消息 |
| `error_where` | `"ArticlesController#create"`、`"request"`（没有动作运行）、作业的类或种类、`"cybertrain mail"`、`"job thread"`、`"schedule:<name>"`、`"feed:<name>"`，或 `""` |
| `error_request_id`、`error_request_method`、`error_request_path` | 请求的这些值，路径不含查询字符串并像请求日志那样过滤；在作业中，是把它加入队列的请求的 ID；请求之外为 `""` |
| `error_environment`、`error_release` | `Cybertrain.config.env` 和 `c.release` |
| `error_handled` | `report` 和 `handle` 为 true，框架报告的为 false |
| `error_context` | `Hash{String => String}`：应用的上下文，在作业中还有 `job.id`、`job.attempt`、`job.max_attempts` |
| `error_backtrace` | `Array<String>`，在 `cybertrain build` 构建的二进制中为空（见下文） |
| `error_occurred_at` | `Time`，来自时钟 |

**不用你写一行就会报告的：**

- 以 500 结束的请求，只报告一次（如果之后返回错误页面时又抛出新的异常，比如 `public/500.html` 无法读取，那个异常也会被报告：两个报告，各自都是真实的失败）：`Cybertrain::ClientError.status_for` 映射为 500 或以上的异常。从不报告 4xx（错误的参数、CSRF 失败、404），也从不报告 `rescue_from` 处理过的异常。
- 作业的失败尝试（`where` 是它的类或种类；上下文中有 `job.attempt` 和 `job.max_attempts`），无论是默认策略、`retry_on` 还是 `discard_on`。在作业中，去重的键也包含作业的 ID（[投递](#error-reporting)，见下文）：同一种类的两个作业以相同方式失败是两个报告；一个作业的某次尝试如果以它自己一分钟内已报告的尝试的类和消息失败，会被记录但不会再次报告（默认策略下第一次重试要等一分钟，所以每次尝试都会报告；`retry_on ..., wait: 30` 时，已报告的尝试 30 秒后的那次尝试不会报告）。丢弃报告一次。`job.max_attempts` 在默认策略下是 `job_max_attempts`，在 `retry_on` 下是策略的 `attempts:`，在 `discard_on` 下是结束时的尝试次数。失败的 `deliver_later` 邮件属于 `cybertrain mail` 作业。从作业线程的循环中逃出的异常，或那里的数据库错误，`where` 为 `job thread`。
- 块抛出异常的定时任务，或五年内没有下一次运行的 `cron` 任务（`schedule:<name>`）。
- 抛出异常的数据订阅的 `on_open`、`on_message` 或 `on_tick`、死掉的数据订阅线程，以及放弃某个数据订阅的监督线程（`Cybertrain::Background::FeedFailed`，一个背后没有类的名字，消息为 `feed <name> restarted <n> times in <w> s; exiting`），都是 `feed:<name>`。

写流式响应体（`stream do ... end`、Server-Sent Events）或升级后的 WebSocket 连接期间抛出的异常，会在服务器的 `stream error: <Class>: <message>` 行之后报告一次，带有请求的 ID、方法和路径，`where` 为 `ArticlesController#index (stream)`（没有动作运行时为 `request (stream)`）。已离开的客户端（写入器抛出的 `EOFError`、`IOError`、`Errno::ECONNRESET`、`Errno::EPIPE`）只以那一行记录，不报告。不报告：没有处理器的种类的作业，以及在开发环境中，诊断页面在显示一个已报告的异常时自身抛出的异常。框架以前写的每一行日志都保持原样；报告是额外的。

**从不发送的。** 参数、请求头、cookie、会话、客户端的地址和查询字符串不在事件中；请求的路径像请求日志那样被过滤。只添加应用放进 `context:` 的内容。异常消息原样发送，除非过滤器修改它们：含有个人数据的消息（SMTP 服务器点名收件人的拒绝）需要一个过滤器。

**过滤器。** 过滤器是定义了 `filter_event(event)` 的 `Cybertrain::ErrorReporter::Filter` 子类，返回 true 保留事件，返回 false 丢弃它。它可以修改消息（`event.error_message =`）和上下文（`event.set_error_context(key, value)`、`event.delete_error_context(key)`）。下面一个遮盖不带引号的简单 ASCII 电子邮件地址，另一个丢弃应用不想报告的类：

```ruby
# config/app.rb
class MaskAddresses < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_message = event.error_message.gsub(/[\w.+-]+@[\w-]+(\.[\w-]+)+/, "[email]")
    event.delete_error_context("email")
    true
  end
end

class DropDeclinedCards < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_class != "PaymentGateway::Declined"
  end
end

Cybertrain.error.add_filter(MaskAddresses.new)
Cybertrain.error.add_filter(DropDeclinedCards.new)
```

`MaskAddresses` 中的模式会漏掉两种地址。一种含有 ASCII 以外的字符，例如 `alice@例え.テスト`：除非要求 Unicode 属性，Ruby 的 `\w` 只匹配 ASCII 字母、数字和 `_`。另一种的本地部分带引号，例如 `"alice smith"@example.com`：模式要求 `@` 前面紧挨着一个字母、数字、`.`、`+`、`-` 或 `_`，而右引号之后没有，它在其中什么也匹配不到，所以整个地址都留在消息中。请为你预期的地址编写模式，或者改为丢弃事件。

过滤器在报告器的线程上按添加顺序运行，在订阅者和发送器之前；下一个过滤器、订阅者和 Sentry 看到过滤器所做的修改。一旦某个过滤器丢弃了事件，后面的过滤器不再运行，也没有人收到它（它不计入队列的丢弃数）。抛出异常的过滤器会丢弃事件，因为过滤器的存在就是为了不让某些东西发出去，并以 error 级别记录 `error filter failed: <Filter class>: <Class>: <message>`；它从不被报告。去重在过滤器之前、按未经过滤的类、消息和 `where` 决定：过滤器的改写不改变哪些报告被合并，过滤器丢弃的事件仍在这一分钟内占着它的位置。框架自己的 `ERROR` 日志行在事件产生之前写出，不经过滤。仅有过滤器不会让报告入队（需要订阅者或 DSN）。在 `config/app.rb` 中添加的过滤器在每个测试中保留；在测试中添加的会在下一个测试之前移除。

**投递。** 报告进入一个容量为 100 的队列，由一个线程投递。相同的类、消息和 `where`（在作业中还有作业的 ID）每分钟最多入队一次，所以对每个访问者都以相同消息失败的页面每分钟只产生一个报告（带有 ID 的消息，如 `Couldn't find Article with id=5`，每个不同的消息各产生一个）；队列满时，报告被丢弃并计数，`error reports dropped: <n>` 以 warn 级别每分钟最多记录一次。没有订阅者也没有 DSN 时，什么都不入队，也不启动线程。投递失败会被记录为 `error delivery failed: <Class>: <message>`，如果旧线程已结束，下一个报告会启动新线程。服务器、worker 或 feeds 进程停止时，会在其服务停止后最多等待 2 秒，让队列中的报告送出；剩下的会丢失。开发中的重新构建也会等待，注册的命令、`./<app> jobs` 和 `./<app> console` 在关闭数据库并退出之前也会等待。

**发送到 Sentry 或 GlitchTip。** `bin/<app>.rb` 中有那一行时，把 `CYBERTRAIN_SENTRY_DSN`（或 `c.sentry_dsn`）设为项目的 DSN，就会把每个报告作为 Sentry 事件发送：

```sh
export CYBERTRAIN_SENTRY_DSN=https://PUBLIC_KEY@o1.ingest.sentry.io/42
export CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # 可选：作为事件的 release 发送
export CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # 可选：发送其中四分之一
```

- DSN 的形式为 `http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>`（secret，即 Sentry 旧的后半部分，会被忽略）；事件发送到 `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/`，Sentry 和 GlitchTip 都接受。它含有密钥：放在部署的机密中，而不是提交的文件中。无法读取的 DSN 会让启动停止，指出出错的部分，从不显示密钥：`error: sentry_dsn must look like https://<public key>@<host>/<project id>: the project id must be digits`。
- 在没有链接发送器的程序中设置 DSN 会让启动停止，注册的命令、`jobs` 和 `console` 也会在打开数据库之前被拒绝（退出状态 1）：`error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`。你自己的发送器类（`Cybertrain::ErrorReporter::Sender` 的子类）要定义返回非空名字的 `sender_name`，否则会遇到同样的拒绝。
- `CYBERTRAIN_ERROR_SAMPLE_RATE`（`c.error_sample_rate`，1.0）是发送的报告所占的比例，0.0 到 1.0；订阅者仍然看到每一个报告。变量必须是数字加可选的 `.数字`，否则启动停止：`error: error_sample_rate must be a number from 0.0 to 1.0 (got "x")`。
- `CYBERTRAIN_RELEASE`（`c.release`，默认为空）标明版本或提交；不做检查。
- 解析主机名之后，每次发送最多等待 5 秒（名称解析会阻塞投递线程，截止时间无法中断它，所以停滞的解析器可能让一次发送等得更久），从不重试。拒绝会以 warn 级别记录为 `error report not sent: Sentry answered 429`，连接失败也一样：`error report not sent: <Class>: <message>`。
- 事件包含类和消息、作为 transaction 的 `where`、环境、release、作为标签的请求 ID、请求的方法和路径、作为 `extra` 的上下文，以及有回溯时的帧。
- 调用经过 `Cybertrain::HttpClient` 及其针对私有地址的防护（[出站 HTTP](external-services.md#outbound-http)）：在私有网络或同一台机器上的 GlitchTip 需要 `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`，这会为应用的每一个出站调用解除防护。

**回溯。** `cybertrain build` 构建的二进制是 Spinel 的发布构建，其异常不带回溯：它的报告包含类、消息和 `where`。在 `--debug` 构建中以及在 CRuby 下，会附带帧。

`cybertrain test` 不向 Sentry 发送任何东西：除非 `config/app.rb` 赋了值，它会清空导出的 `CYBERTRAIN_SENTRY_DSN`，测试改为把 DSN 指向 `Test::SentryReceiver`（[测试日志与错误报告](testing.md#testing-logs-and-error-reports)）。设计：[docs/design.md](../design.md) D86 和 D88。

### 升级日志与错误报告

某个版本在日志和错误报告方面的变化，按版本列在[升级](upgrading.md#notes-by-version)中。
