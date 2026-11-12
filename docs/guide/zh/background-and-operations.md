---
source_sha256: ef8c5bc57b3af6efc730c5a1f8f518d1f37931f4349c672de3518febebd3b834
---
# 后台任务与运维

## 后台任务

需要在请求之外做事情的应用（在响应发出之后发送通知、每晚清理旧行、重试失败的调用），会把这些工作交给框架，由框架在提供服务的进程或单独的 worker 进程的后台线程上运行。作业是 `app/jobs/` 中的一个类，与 Rails 一样：

```ruby
# app/jobs/welcome_job.rb
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError

  def perform(args)
    user = User.find(Cybertrain::Cast.int(args["user_id"]))
    Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  end
end
```

```ruby
# 在某个动作中，保存用户之后
WelcomeJob.perform_later("user_id" => @user.id)
WelcomeJob.perform_in(600, "user_id" => @user.id)   # 或者 perform_at(time, args)
```

```ruby
# config/app.rb（或 bin/<app>.rb 在 Cybertrain::Main.run 之前 require 的某个文件）
Cybertrain::Scheduler.cron("0 4 * * *", "nightly digest", job: "DigestJob")
Cybertrain::Scheduler.every(300, "refresh rates") { Rates.refresh }
```

- **在哪里运行。** 作业在 `job_threads` 个作业线程上运行（3 个，`CYBERTRAIN_JOB_THREADS`）；定时任务在它们专属的一个调度器线程上运行，所以耗时的作业永远不会拖延定时任务。两者都在二进制文件提供服务（`./<app>`、`./<app> server`）或作为 worker 运行（`./<app> worker`，参见[进程角色](#process-roles)）时启动，时间是在启动过程连接好数据库并设置 `SPINEL_WORKERS` 之后；`migrate`、`db ...`、`jobs ...`、`console` 和 `Main.command` 命令从不启动它们，`Cybertrain::Test::Client` 也不会。即使应用没有任何作业类，作业线程也会在每个这样的进程中启动：框架注册了它自己的邮件作业（`Mailer.deliver_later`，[发送电子邮件](external-services.md#sending-e-mail)）。
- **数据表。** 作业是 `cybertrain_jobs` 中的行，这张表由框架自己创建（`CREATE TABLE IF NOT EXISTS`，在首次使用时），并且不写入 `db/schema.rb`。在 `DB.transaction` 内部，这一行会与其他内容一起提交或回滚。每个作业线程在一个简短的 `BEGIN IMMEDIATE` 事务中认领最早到期的行，在事务之外运行它，然后寻找下一个；没有到期的行时，它等待 `job_poll_interval` 秒（1 秒），所以由请求入队的作业大约在一秒内开始。一行的状态是 `queued`、`running`、`done`、`failed`（重试已用尽；它会保留下来供你查看）或 `discarded`（被 `discard_on` 终止）。

### 作业类

`spin run gen` 读取 `app/jobs/` 下的每个文件（包括嵌套目录：`Admin::ReportJob` 位于 `app/jobs/admin/report_job.rb`），并把以 `Cybertrain::Job::Base` 为祖先的每个类的另一半写入 `gen/jobs.rb`：`perform_later`、`perform_at`、`perform_in`、`perform_now`、`job_kind` 以及运行它的代码，然后注册这个类。`cybertrain generate job send_digest --retry Cybertrain::Mailer::TimeoutError:60:5` 会写出一个类文件和它的测试。

- **`args`** 是传给 `perform_later` 的 Hash，以 JSON 形式保存，读回时是 `Hash<String, Object>`：用 `Cybertrain::Cast.int(args["user_id"])`、`Cast.str`、`Cast.hash`、`Cast.array` 收窄其中的值。一个作业只接收这一个 Hash；请传递 id，而不是记录（这也是 Rails 的建议）。`perform_later` 对任何不是 Hash 的参数抛出 `ArgumentError`，不带参数时发送 `{}`。
- **入队。** `perform_later(args)`、`perform_at(time, args)` 和 `perform_in(seconds, args)` 返回该行的 id；该行的种类就是类名（`"WelcomeJob"`、`"Admin::ReportJob"`）。`perform_now(args)` 在调用它的线程上运行 `perform`，没有队列、没有重试策略、也没有 rescue，并返回 `nil`：这正是测试需要的形式。
- **类的主体。** 每个作业类都要定义 `perform(args)`（既没有定义也没有继承它的类会被生成器拒绝）。`retry_on`、`discard_on` 和 `limits_concurrency` 是作为文本读取的，每行一个，使用字面值（`wait:` 用 Integer 或 `:polynomially_longer`，`attempts:` 和 `to:` 用 Integer，`key:` 用带引号的 String）；块、lambda、`5.minutes`、哈希火箭写法或行尾注释都会让 `spin run gen` 停下，并给出文件、行号以及应该改写成什么。
- **哪些异常类。** `retry_on` 或 `discard_on` 指定的类必须是程序在该作业之前定义的类：核心类（`ArgumentError`、`KeyError` 等）、框架的某个 `...Error` 类（生成器会补上所需的 require），或者在 `app/models/`、`app/jobs/application_job.rb` 中、或在作业自身文件中该行之上定义的应用类。其他任何类都会让 `spin run gen` 停下：在 Spinel 下，一个指定了程序未定义的类的 `rescue` 可能会吞掉所有异常（spikes/NOTES.md 规则 89）。
- **`ApplicationJob`。** `app/jobs/application_job.rb` 中的 `ApplicationJob < Cybertrain::Job::Base` 本身不是一个作业：它的 `retry_on` 和 `discard_on` 行适用于每个继承它的作业，排在作业自己的行之后；它的 `limits_concurrency` 适用于没有声明的作业。任何其他作业类都可以作为父类；这时它本身也是一个作业。
- **简短形式 `Job.handle`。** 以 String 种类注册的块不需要类，也不需要生成器；它接收 String 类型的负载，并遵循下面的默认策略：

  ```ruby
  # config/app.rb
  Cybertrain::Job.handle("notify", concurrency: 1) { |payload| Notifier.post(payload) }

  # 任何地方，稍后
  Cybertrain::Job.enqueue("notify", JSON.generate({ "text" => "Deployed" }), run_at: Time.now + 60)
  ```

  作业类和 `Job.handle` 的种类共享同一个命名空间，所以 `Job.enqueue("WelcomeJob", json)` 添加的行与 `perform_later` 相同。`Job.enqueue` 会拒绝未注册的种类。

### 重试与丢弃

- **默认策略。** 类中没有任何一行匹配的异常（以及 `Job.handle` 块中的任何异常）会依次在 1、5、15 分钟之后，然后在 60 分钟之后重试，并把 `Class: message`（最多 1000 个字符）写入 `last_error`，直到失败次数达到 `job_max_attempts`（5）次；此时这一行变为 `failed`。作业代码抛出的 `NotImplementedError`（尚未编写的辅助方法）、`SystemStackError` 或其他 `ScriptError` 虽然都不是 `StandardError`，也遵循这一策略；`StandardError` 之外的其他异常会被记录（`[ERROR] Job thread N: ...`），作业线程继续运行，这一行保持 `running`，直到恢复（见下文）接手。
- **`retry_on Klass, wait: 60, attempts: 5`。** `wait:` 是秒数（省略时为 3，即 Rails 的默认值）或 `:polynomially_longer`（`attempts ** 4 + 2` 秒：3、18、83、258……）；`attempts:`（省略时为 5）计算每一次尝试，包括第一次。可以写多行：第一个其类与异常匹配（子类也算匹配）的行胜出，所以请先写范围较窄的类。在 `discard_on ArgumentError` 之前写 `retry_on StandardError`，会让 `ArgumentError` 被重试。
- **`discard_on Klass`** 立即停止：这一行变为 `discarded`，错误写入 `last_error`，并且永不重试。
- **`def retries_exhausted(error)`** 在某个 `retry_on` 行的尝试次数用尽、这一行真正变为 `failed` 之后运行（对于另一个 worker 接手的尝试永远不会运行，因为那次运行仍可能成功）。它对应 Rails 的 `retry_on ... do |job, error|` 块；它抛出的异常会被记录。
- **回收**（见下文）同样遵循类的设置：一个 `attempts: 20` 的类的行，如果其进程在第 5 次尝试时死掉，会被重新排队，而不会被标为失败。

### 按种类和按键限制并发

`limits_concurrency to: 1, key: "account_id"` 让该类的作业在所有共享该数据库的进程中同时最多运行 `to:` 个，按 `args["account_id"]` 的值分别计数（只写 `to:` 时按整个类计数；对于块，`Job.handle(kind, concurrency: n)` 起同样的作用）。与此同时，其他种类和其他键照常运行。把一个带键的作业入队而其 `args` 中缺少该键，会抛出 `ArgumentError`。这个上限统计的是 `running` 行，所以只在心跳持续期间成立：心跳过期后仍在运行的作业，会与被回收的行的下一次运行重叠（见下文）；绝不能重叠的工作需要自己的保护。

### 定时任务

`Scheduler.every(seconds, name) { ... }` 每隔 `seconds` 秒运行一个块；`Scheduler.cron(expr, name, ...)` 在一个五字段的 cron 表达式匹配的分钟运行：

```ruby
Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
                           job: "MorningReportJob", args: { "scope" => "all" })
Cybertrain::Scheduler.cron("*/5 * * * *", "poll feeds", catch_up: true) { Feeds.poll }
```

- **表达式。** 分、时、日、月、星期，支持 `*`、`*/n`、`a-b`、`a,b`、`a-b/n` 以及名称 `jan`–`dec` 和 `sun`–`sat`（星期中的 `0` 和 `7` 都是星期日）；不接受 `@hourly` 之类的写法。无法解析或永远不会匹配的表达式，会在加载 `config/app.rb` 时抛出指明任务名的 `ArgumentError`，从而让启动停止。
- **时区。** `tz:` 指定一个 IANA 时区（[时区](configuration.md#time-zones)）；没有它时，任务按 `scheduler_tz`（`CYBERTRAIN_SCHEDULER_TZ`，`UTC`）读取。夏令时跳过的墙上时间当天不会运行。在秋季切换时重复的那一小时里，时字段以 `*` 开头的表达式在两次出现时都会运行，固定小时的表达式只运行一次，与 Vixie cron 一样。
- **`job:`** 指定一个作业种类（String 形式的类名，或 `Job.handle` 的种类），`args:` 指定它的参数：此时任务只负责把它入队，有实际工作的任务就应该这样做。未知的种类会让启动停止，并列出已注册的种类。
- **时间表**保存在数据库中（`cybertrain_schedules`，不写入 `db/schema.rb`）：每个任务上次运行和下次运行的时间。重启，或者另一个进程接过领导权，都会从它继续。一个 `every` 任务的时间如果在没有任何进程运行时过去了，会在启动时运行一次；在没有任何进程运行时错过的 `cron` 时段会被跳过（cron 的规则），除非任务写了 `catch_up: true`，这时它会在启动时运行一次。在进程都在运行、但没有领导者运行它的期间到期的时段（租约易手时），会在接手时运行一次。你改名或删除的任务会保留它的行，直到下次启动。一个还没有运行过的任务，如果它当前的计划比之前的版本保存的下次运行时间更早，就按当前的计划运行（在第一次运行之前从每周改为每小时的任务，会在一小时之内运行）。
- **任务如何运行。** 块在调度器线程上运行，一次一个任务；每次运行都包在一个 rescue 中，它会记录 `[ERROR] Scheduled task "name" failed: ...`，然后循环继续。块不接收参数（Spinel 没有 `instance_eval`）。一次 SQLite 调用会占用它的操作系统工作线程直到返回：在 `SPINEL_WORKERS=1`（默认值）时，一个耗时的查询会让所有请求和所有其他线程停顿同样长的时间。把有实际工作的任务交给作业（`job:`，或在块中 `Job.enqueue`），并把大量工作分批进行（每次运行一千行，每个条目一个作业）。`Cybertrain::Scheduler.last_tick` 是最后一次心跳的纪元秒数，可用于你自己的健康检查。

### 作业页面和 `jobs` 命令

```ruby
# config/routes.rb
Cybertrain::Routes.draw do
  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
end
```

`jobs_page` 挂载的页面列出每种状态的行数、排队的数量和下一个到期时间、`failed` 和 `discarded` 的行（种类、参数、错误、尝试次数、时间）以及 `running` 的行（由谁认领、心跳有多旧），每个列表 `jobs_page_per_page` 行（50，`CYBERTRAIN_JOBS_PAGE_PER_PAGE`）。失败的行可以重试（立即重新排队，尝试次数清零）、丢弃或删除，已丢弃的行可以重试或删除，还可以一次重试或丢弃所有失败的行；每个操作只触及 `failed` 和 `discarded` 的行，所以 worker 刚刚认领的行不会被动到。

- 生成的控制器继承 `ApplicationController`，所以应用的布局、辅助方法和 CSRF 保护都会生效，`before_action:` 指定它的一个方法：要拒绝访问，这个方法必须渲染或重定向。`cybertrain generate authentication` 用其关注点的 `require_admin`（除非管理员已登录，否则返回 404；[管理员用户](authentication.md#admin-users-and-the-jobs-page)）画出上面那一行。没有 `before_action:` 时，页面对每个访问者开放，`spin run gen` 会打印一条警告说明这一点。
- `skip_before_action:` 指定页面不运行的一个继承的 before 回调。指定 `:require_authentication` 时，只有 `require_admin` 回答访客，返回 404，而不是重定向到登录。没有 `before_action:` 时，或者它指向 `before_action:` 本身时，gen 会拒绝。
- 页面上的按钮是带 CSRF 令牌的表单。不要把页面的路径放进 `csrf_exempt_prefixes`：在豁免的前缀之下，这些表单会接受来自任何网站的提交。

在 shell 中，`./<app> jobs` 对配置的数据库做同样的事（它不启动任何线程）：

```sh
./blog jobs list               # 失败的行，最新的在前（最新的 1000 行）；或者：list queued|running|done|discarded
./blog jobs retry 42           # 或者：retry --all（所有失败的行）
./blog jobs discard 42
./blog jobs delete 42
./blog jobs prune --before 30  # 删除 30 天前的 failed 和 discarded 行（默认 7 天）
```

`done` 的行会一直保留，直到有东西删除它们：在任务中调用 `Job.prune_done(before_epoch)`（`Cybertrain::Scheduler.cron("0 3 * * *", "prune done jobs") { Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400) }`）。`Job.state_count("failed")` 可用于你自己的健康页面。

### 多个 worker、至少一次、关闭

- **每个数据库可以有多个 worker。** 每个运行作业的进程每隔 `job_heartbeat_interval`（30 秒）为它正在运行的作业写入心跳。心跳早于 `job_heartbeat_stale` 的 `running` 行（来自崩溃了或在作业中途被停止的进程）会由下一个检查的进程重新排队，检查发生在它启动时，之后每分钟一次；但如果那次尝试已是最后一次（`job_max_attempts` 与该类最大的 `attempts:` 中较大的那个），这一行会被标为 `failed`，`last_error` 为 `process stopped (heartbeat stale)`，这样会让进程崩溃的作业不会被无休止地重试。定时任务每次只在一个进程中运行：各进程在数据库中共享一个租约（`cybertrain_leases`，每次心跳续约，`scheduler_lease_ttl` 为 30 秒），只有租约持有者运行到期的任务；持有者停止续约后，另一个进程会接手。租约在每个任务之前续约，而不是在任务运行期间，所以比 ttl 更长的任务可能与下一个持有者的任务重叠：请让任务保持短小并且可以安全重复。因此，两个 `worker` 进程，或一个服务器和一个 worker，可以共享同一个 SQLite 文件；`CYBERTRAIN_WORKER=0` 会在只应提供 HTTP 的 `server` 进程中关闭作业、定时任务和数据订阅。
- **至少一次。** 一个作业可能运行两次：被杀掉的进程，或停顿超过 `job_heartbeat_stale`（300 秒）的进程，在另一个进程收回这一行时可能仍在运行该作业。只有持有该行的认领所写入的结果才算数（较早认领迟到的结果会被丢弃），但作业的副作用已经发生了两次，所以请像使用任何作业队列一样，编写可以安全重复运行的作业（检查邮件是否已经发出，使用 upsert 而不是 insert）。出于同样的原因，定时任务在领导者更换前后也可能运行两次。
- **关闭。** 收到 `SIGTERM` 时，作业线程停止认领新作业，进程最多等待 `job_drain_timeout`（10 秒）让进行中的作业完成。届时仍在运行的作业的行保持 `running`；它的心跳已经停止，所以一旦过期，另一个进程会再次运行它。
- **测试。** `WelcomeJob.perform_now(args)` 运行一个作业，`Cybertrain::Scheduler.run_due(now)` 运行一次心跳，`Cybertrain::Job.work_one(now)` 运行一个排队的作业，时间是你选定的纪元时间，所以测试永远不必休眠；断言见[测试作业](testing.md#testing-jobs)。

### 从 0.4 升级

- `cybertrain_jobs` 新增 `concurrency_key` 列和 `discarded` 状态；第一个接触这张表的进程会添加该列。列举状态的代码（基于 `Job.state_count` 的仪表板）要加上 `discarded`。`Job.prune_done` 仍然只清理 `done` 的行。
- `every` 任务在重启之后从时间表继续，而不是从头开始：进程停止期间过去的间隔会在启动时运行一次。
- 给已有的种类加上键（`limits_concurrency ... key:`）：与任何升级一样，在第一个新进程启动之前停止所有旧进程（[进程角色](#process-roles)）。第一个新进程会为之前入队的 `queued` 行设置键（对负载中没有该字段的行，它会记录其 id），旧进程留下的 `running` 行会在被回收时获得它的键。
- `jobs` 现在是一个内置命令：名为 `jobs` 的应用命令必须改名。

尚未实现：作业优先级、队列名称和唯一性、供测试使用的内联作业模式（`perform_now` 和 `perform_enqueued_jobs` 已覆盖测试的需要）。设计说明：`docs/design.md` D28 以及 D51 至 D53。

## 进程角色

同一个二进制文件以三种角色运行。默认情况下 `./<app> server` 做所有事情，就像在 Puma 中运行 Solid Queue 的 `rails server` 那样；另外两种角色让部署可以把工作分散到多个进程或容器中，全部来自同一个镜像、使用同一个数据库：

| 命令 | 运行的内容 | 监听端口 |
| --- | --- | --- |
| `./<app> server [PORT]` | HTTP、[流端点](realtime.md#which-process-does-what)，以及在没有设置 `CYBERTRAIN_WORKER=0` 时的定时任务、作业线程和 WebSocket 数据订阅 | 是 |
| `./<app> worker` | 定时任务（借助租约，每次只在一个进程中）、作业线程、心跳和回收 | 否 |
| `./<app> feeds [NAME...]` | 全部或指定名称的 [WebSocket 数据订阅](external-services.md#consuming-websocket-feeds) | 否 |

- `worker` 和 `feeds` 会打印一条横幅（`=> worker: 3 job threads, 2 scheduled tasks`），一直运行到收到 `SIGTERM` 或 `SIGINT`（Ctrl-C），然后像服务器一样停止。它们总是执行自己的工作：为 Web 角色设置的 `CYBERTRAIN_WORKER=0` 不会关闭它们。
- 带名称的 `feeds` 只运行这些订阅（每个订阅一个容器），未知的名称会让启动停止，并列出已注册的名称。当数据订阅在自己的进程中运行时，请在服务器上设置 `CYBERTRAIN_WORKER=0`，否则每个进程都会接收每个订阅。
- `feeds` 进程会重启线程已死掉的数据订阅，而当某一个订阅不断死掉时（在 `feed_restart_window` 内重启了 `feed_restart_limit` 次），它会以状态 1 退出；所以请在重启策略之下运行它（Docker 的 `restart: unless-stopped`、systemd 的 `Restart=always`）；详情见[订阅 WebSocket 数据流](external-services.md#consuming-websocket-feeds)。`./<app> feeds status` 打印每个数据订阅最后报告的状态。
- 典型的拆分方式：代理之后是设置了 `CYBERTRAIN_WORKER=0` 的 `server`，一个或多个 `worker`，有订阅时再加上 `feeds`。`cybertrain new` 会在 `config/deploy.yml` 中写入 `web` 和 `worker` 角色（以及被注释掉的 `feeds`）；systemd 单元见 [docs/deploy.en.md](../deploy.en.md) 第 7 部分 “Splitting the roles”。
- **从没有心跳的版本升级时**：在启动第一个新进程之前，先停止所有旧进程。旧进程不写心跳，所以新的 worker 会把旧 worker 仍在运行的作业当作被遗弃的作业取走。
- `Cybertrain::Main.worker?(ARGV)` 和 `Main.feeds?(ARGV)` 与 `Main.server?(ARGV)` 一样，告诉 `bin/<app>.rb` 它正在启动哪种角色。

## 缓存存储

`Cybertrain::Cache` 把答案在应用自己的数据库中保留一段时间，这样下一个请求就不必再去问那个很慢的 API。它不在 `require "cybertrain"` 之中；请在用到它的地方 require：

```ruby
require "cybertrain/cache"

text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  client.get("https://api.llama.fi/tvl").body
end
data = Cybertrain::Cache.fetch_hash("prices/#{sym}", expires_in: 60) { { "usd" => price } }
count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)   # 写入时为 true
```

- **值是 String。** `fetch(key, expires_in:, race_condition_ttl:) { String }` 返回仍然有效的值，或者运行块并保存它的返回值；`fetch_hash`、`fetch_array` 和 `fetch_int` 保存 JSON 或 Integer 文本，并在取出时解析，所以损坏的单元格会读作 `{}`、`[]` 或 `0`，直到它过期、块再次运行（Spinel 没有 `Marshal`，而且一个方法只返回一种类型）。其余的是 `read(key)`（String 或 nil）、`write(key, value, expires_in:, unless_exist:)`、`delete`、`exist?`、`increment(key, by: 1, expires_in:)`（一条语句；过期的计数器从 `by` 重新开始，`expires_in:` 只在计数器开始时设定期限，所以一分钟的计数器统计的就是那一分钟）和 `clear`。
- **过期。** `expires_in:` 以秒计；默认值 `0` 永不过期（负值也一样）。`race_condition_ttl: n`：当某一行已过期时，第一个调用者把它延长 `n` 秒并计算新值，其他调用者在此期间继续读取旧值，与 Rails 一样；没有它时，过期键的每个调用者都会计算。抛出异常的块什么也不写入。
- **存储。** 这些行位于 `cybertrain_cache` 中，这张表由框架在首次使用时创建，并且不写入 `db/schema.rb`。内存中什么也不保留：每次读取都是一条 SELECT，由 SQLite 从它的页缓存中作答。每次写入都会获取数据库的写锁，写入自己行的请求要等待它：请缓存作业产生的结果，或者读取远多于变化的值，而不要在繁忙的请求路径中写入。
- **清理。** require 这个文件会注册定时任务 `"cybertrain cache prune"`，它每隔 `cache_prune_interval` 秒（300，`CYBERTRAIN_CACHE_PRUNE_INTERVAL`）删除过期的行，每条语句一千行。这个间隔在 require 文件时读取：请设置该环境变量，或者在 require 之前运行的 `Cybertrain.configure` 块中设置 `c.cache_prune_interval`。`Cache.prune(now)` 是测试的入口。

尚未实现：单独的缓存数据库文件、大小上限、内存中的存储。设计说明：`docs/design.md` D54。

## 控制台

`./<app> console` 是一个操作应用模型的提示符。Spinel 没有 `eval`，所以它不运行 Ruby：它求值的是模板中 `<%= %>` 所求值的表达式（[模板语言](template-language.md#expressions)，不含块），外加模型名称。在开发环境中，用 `cybertrain spin run <app> -- console` 运行它。

```console
$ ./blog console
Cybertrain console (production). Type help for commands, exit to quit.
>> Article.where(title: "Hello").count
1
>> a = Article.find(1)
#<Article id: 1, title: "Hello", body: "First post", created_at: 2026-11-05 10:00:00 UTC, updated_at: 2026-11-05 10:00:00 UTC>
>> a.update(title: "Hello again")
true
```

- 模型名称就是它的关系（`Article`），可以使用 `where`、`where_like`、`order`、`limit`、`offset`、`page`、`first`、`last`、`find`、`find_by`、`to_a`、`count`、`exists?`、`pluck_str` / `pluck_int` / `pluck_float`、`sum_int`、`count_by`、`delete_all`、`to_sql` 和 `create`。记录有它的属性和方法，以及 `update`、`save`、`destroy`、`reload`、`valid?`、`errors` 和 `attributes`。`help` 会把它们全部列出来。
- `x = expr` 把一个值留给后面的行使用，`_` 是上一个值。`sql "..."` 执行 SQL 并以表格形式打印各行，单元格中的控制字符会被转义（`\e`、`\n`），因此数据既不能向终端发送转义序列，也不会打乱表格（含有 NUL 字节的 TEXT 值在读取时会在 NUL 处被截断，与所有原始 SQL 读取一样；BLOB 保留每一个字节）；`tables` 列出所有表；`exit`、`quit` 或 Ctrl-D 退出。
- 无法解析的行会打印它的错误，抛出异常的行会打印 `Class: message`，然后提示符回来。二进制值打印为 `<N bytes>`。
- 写入是真实的。在生产环境中，控制台会先用一条横幅说明这一点。

`./<app> dbconsole` 在配置的数据库（`CYBERTRAIN_DATABASE`）上打开 `sqlite3` shell，与 Rails 的 `dbconsole` 一样；它需要安装 `sqlite3` 命令，并原样传回其退出状态。这两个命令都不会启动调度器、作业或数据订阅。

## 运维：备份、VACUUM、健康检查

已部署应用的数据就是一个 SQLite 文件，所以二进制文件自带这类应用所需的三种运维工具。带有文件上传的应用还会把上传文件的字节保存在其上传根目录下（`upload_root`，默认为 `storage/uploads/`）：请把这个目录与数据库一起备份和恢复，否则恢复后的记录会指向不存在的文件（[添加文件上传](tutorial.md#attachments)）。

**备份。** `./<app> db backup PATH` 在服务器继续运行的同时写出所配置数据库（`CYBERTRAIN_DATABASE`）的一致副本：SQLite 的 `VACUUM INTO`（3.27 或更新版本；二进制文件会检查）读取一个快照，而在 WAL 模式下，服务器的写入在此期间照常进行。副本先写入 `PATH` 旁边的一个临时文件，该文件以独占方式、权限 0600 创建（文件中含有密码摘要和会话令牌），经过 fsync，然后才重命名为 `PATH`，所以失败或中断的复制永远不会在真实名称下留下不完整的文件（临时文件会被删除）。已存在的 `PATH` 会被拒绝，除非你传入 `--force`；数据库本身永远不能作为目标，`:memory:` 数据库也不能作为来源。

```sh
./blog db backup /srv/blog/backups/before-upgrade.sqlite3
./blog db backup /srv/blog/backups/ --keep 14    # blog-20261025T031500Z.sqlite3，保留最新的 14 个
```

以 `/` 结尾的目标（或已存在的目录）会得到带日期的名称，即 UTC 时间的 `<app>-<YYYYmmddTHHMMSSZ>.sqlite3`，放在一个目录中，该目录不存在时以权限 0700 创建；`--keep N` 随后删除恰好符合这种形式、超出 N 个的最旧文件，不会动那里的其他任何东西。恢复就是在服务器停止时用备份覆盖数据库文件（并删除它旁边的 `-wal` 和 `-shm` 文件）。

**VACUUM。** 删除行会在文件中留下空闲页。`./<app> db vacuum` 运行 `VACUUM`，然后运行 `PRAGMA wal_checkpoint(TRUNCATE)`，这样重建后的页面会写入数据库文件，文件被截断为新的大小，WAL 也被清空；它会打印前后在磁盘上占用的大小（数据库加 WAL）。`VACUUM` 会重写整个文件，并在此期间持有写锁，所以请在应用空闲时运行它。如果某个读取者让检查点无法完成，它会说明这一点，WAL 会在之后的某次检查点时缩小。

**在服务器之外运行备份。** 一次 SQLite 调用会占用它的操作系统工作线程直到返回，所以在 `Scheduler` 任务中执行大型 `VACUUM INTO` 会让请求（在 `SPINEL_WORKERS=1` 时是所有请求）在复制期间一直停顿。请改为从 cron 或 systemd 定时器中，以单独进程的方式运行这条命令：

```sh
# 应用所属用户的 crontab：每晚 03:15，保留两周
15 3 * * * cd /srv/blog/current && ./blog db backup /srv/blog/backups/ --keep 14
```

想要自己进行备份的应用，可以从定时任务中以子进程方式运行它自己的二进制文件，而不是在自己的线程上执行 SQL：`system` 只在调度器的线程上等待子进程，在此期间请求照常得到处理（请使用带参数列表的 `system`，绝不要使用含有请求数据的字符串）。耗时超过 `health_worker_stale` 的复制会让健康检查在完成之前一直返回 `worker stale`。

```ruby
# config/app.rb，用于从自己的目录（dist/）启动并提供服务的二进制文件
Cybertrain::Scheduler.every(86_400, "nightly backup") do
  system("./blog", "db", "backup", "storage/backups/", "--keep", "14")
end
```

**健康检查。** 当健康检查启用时（默认启用；空的 `config.health_path` 会关闭它），提供服务的应用会在静态文件、会话、CSRF 和路由器之前响应 `GET /up`（以及 `HEAD`）：不涉及任何控制器，登录用的 `before_action` 也无法重定向它，并且它不设置 cookie。它运行 `SELECT count(*) FROM sqlite_master`，这必须从文件中读取 schema 页（单纯的 `SELECT 1` 从不访问文件），并以 `text/plain` 和 `Cache-Control: no-store` 作答：

| 状态码 | 响应体 | 何时 |
| --- | --- | --- |
| 200 | `ok` | 查询成功 |
| 503 | `database unavailable` | 查询抛出了 `Cybertrain::DB::Error`（文件缺失或不可读，连接池已关闭） |
| 503 | `worker stale` | 后台 `Scheduler` 在运行，而它的最后一次心跳早于 `health_worker_stale` 秒（300）之前：某个任务卡住了，或者运行时间过长 |
| 503 | `feed stale` | 本进程或其他进程中的某个 [WebSocket 数据订阅](external-services.md#consuming-websocket-feeds)已有 `health_feed_stale` 秒（180）没有报告状态，或者什么也没有收到（连 pong 也没有）；参见[数据订阅的健康状况](realtime.md#feed-health) |

每次轮询都像任何请求一样被记录（两行）。路径为 `config.health_path`（`CYBERTRAIN_HEALTH_PATH`，默认为 `/up`；空值会关闭检查，此时该路径会像以前一样交给 `public/` 和路由器处理）。负载均衡器、kamal-proxy 或部署脚本都可以轮询它；`public/up.html` 由 `cybertrain new` 写出，其 Kamal 配置仍然轮询它，但它只能说明进程能够响应 HTTP。
