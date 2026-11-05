---
source_sha256: 9a38157ca8fcf9552b83fff749960770a975fe4abdfa33b4dce1ffb2b4b16a70
---
# 后台任务与运维

## 后台任务

需要在请求之外做事情的应用（在响应发出之后发送通知、每小时清理旧行、重试失败的调用），会把这些工作注册到框架中，由框架在提供服务的进程或单独的 worker 进程的后台线程上运行：

```ruby
# config/app.rb（或 bin/<app>.rb 在 Cybertrain::Main.run 之前 require 的某个文件）
Cybertrain::Scheduler.every(3600, "prune sessions") do
  Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
end

Cybertrain::Job.handle("welcome_mail") do |payload|
  data = Cybertrain::Cast.hash(JSON.parse(payload))
  WelcomeMail.deliver(data["email"].to_s)   # 抛出异常即可让它重试
end
```

```ruby
# 在某个动作中，保存用户之后
Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => @user.email }))
Cybertrain::Job.enqueue("reminder", @order.id.to_s, run_at: Time.now + 600)
```

- **在哪里运行。** 定时任务在一个调度器线程上运行；作业在它们专属的 `job_threads` 个作业线程上运行（3 个，`CYBERTRAIN_JOB_THREADS`），所以耗时的作业永远不会拖延定时任务。两者都在二进制文件提供服务（`./<app>`、`./<app> server`）或作为 worker 运行（`./<app> worker`，参见[进程角色](#process-roles)）时启动，时间是在启动过程连接好数据库并设置 `SPINEL_WORKERS` 之后；`migrate`、`db ...`、`console` 和 `Main.command` 命令从不启动它们，`Cybertrain::Test::Client` 也不会。任务在启动后 `seconds` 秒首次运行，之后在每次运行开始后 `seconds` 秒再次运行。每次运行都包在一个 rescue 中，它会记录 `[ERROR] Scheduled task "name" failed: ...`，然后循环继续。块不接收参数（Spinel 没有 `instance_eval`）。`Cybertrain::Scheduler.last_tick` 是最后一次心跳的纪元秒数，可用于你自己的健康检查。
- **作业。** `Job.enqueue` 向 `cybertrain_jobs` 表添加一行，这张表由框架自己创建（`CREATE TABLE IF NOT EXISTS`，在首次使用时），并且不写入 `db/schema.rb`。负载是一个 String：结构化的数据请编码为 JSON。在 `DB.transaction` 内部，这一行会与其他内容一起提交或回滚。每个作业线程在一个简短的 `BEGIN IMMEDIATE` 事务中认领最早到期的作业，在事务之外运行其处理器，把它标记为 `done`，然后寻找下一个；没有到期的作业时，它等待 `job_poll_interval` 秒（1 秒），所以由请求入队的作业大约在一秒内开始。抛出异常的处理器会依次在 1、5、15 分钟之后，然后在 60 分钟之后重试，并把 `Class: message`（最多 1000 个字符）写入 `last_error`，直到失败次数达到 `job_max_attempts`（5）次：此时这一行变为 `failed`，并保留下来供你查看。种类没有处理器的作业会立即变为 `failed`；`Job.enqueue` 会拒绝未注册的种类。`Job.state_count("failed")` 和 `Job.prune_done(before_epoch)` 可用于健康页面和日常清理。
- **至少一次。** 一个作业可能运行两次：被杀掉的进程，或停顿超过 `job_heartbeat_stale`（300 秒）的进程，在另一个进程收回这一行时（见下文）可能仍在运行该作业。只有最先写入的结果才算数，但处理器的副作用已经发生了两次，所以请像使用任何作业队列一样，编写可以安全重复运行的处理器（检查邮件是否已经发出，使用 upsert 而不是 insert）。
- **按种类限制并发。** `Job.handle("sync_account", concurrency: 1) { ... }` 让该种类的作业在所有共享该数据库的进程中同时最多运行这么多个（用于有速率限制的 API，或不能重叠的工作）；默认值 0 表示不限制。与此同时，其他种类照常运行。
- **每个数据库可以有多个 worker。** 每个运行作业的进程每隔 `job_heartbeat_interval`（30 秒）为它正在运行的作业写入心跳。心跳早于 `job_heartbeat_stale` 的 `running` 行（来自崩溃了或在作业中途被停止的进程）会由下一个检查的进程重新排队，检查发生在它启动时，之后每分钟一次；但如果那次尝试已是最后一次（`job_max_attempts`，认领时就计入一次尝试），这一行会被标为 `failed`，`last_error` 为 `process stopped (heartbeat stale)`，这样会让进程崩溃的作业不会被无休止地重试。定时任务每次只在一个进程中运行：各进程在数据库中共享一个租约（`cybertrain_leases`，每次心跳续约，`scheduler_lease_ttl` 为 30 秒），只有租约持有者运行到期的任务；持有者停止续约后，另一个进程会接手。因此，两个 `worker` 进程，或一个服务器和一个 worker，可以共享同一个 SQLite 文件；`CYBERTRAIN_WORKER=0` 会在只应提供 HTTP 的 `server` 进程中关闭作业、定时任务和数据订阅。
- **关闭。** 收到 `SIGTERM` 时，作业线程停止认领新作业，进程最多等待 `job_drain_timeout`（10 秒）让进行中的作业完成。届时仍在运行的作业的行保持 `running`；它的心跳已经停止，所以一旦过期，另一个进程会再次运行它。
- **让定时任务保持简短。** 定时任务在调度器线程上逐个运行，而一次 SQLite 调用会占用它的操作系统工作线程直到返回：在 `SPINEL_WORKERS=1`（默认值）时，一个耗时的查询会让所有请求和所有其他线程停顿同样长的时间。把真正繁重的工作交给作业（在定时任务中 `Job.enqueue`），并把大量工作分批进行（每次运行删除一千行，每个条目入队一个作业），而不是一次做完。
- **测试。** `Cybertrain::Scheduler.run_due(now)` 运行一次心跳，`Cybertrain::Job.work_one(now)` 运行一个作业，时间是你选定的纪元时间，所以测试永远不必休眠。

没有 cron 语法，作业没有优先级或唯一性，也没有 `deliver_later`：发送邮件的作业自己调用 `Cybertrain::Mailer`（[发送电子邮件](external-services.md#sending-e-mail)）。这里涵盖的是“稍后发送”和“每 N 秒运行一次”（`docs/design.md` D28）。

## 进程角色

同一个二进制文件以三种角色运行。默认情况下 `./<app> server` 做所有事情，就像在 Puma 中运行 Solid Queue 的 `rails server` 那样；另外两种角色让部署可以把工作分散到多个进程或容器中，全部来自同一个镜像、使用同一个数据库：

| 命令 | 运行的内容 | 监听端口 |
| --- | --- | --- |
| `./<app> server [PORT]` | HTTP、[流端点](realtime.md#which-process-does-what)，以及在没有设置 `CYBERTRAIN_WORKER=0` 时的定时任务、作业线程和 WebSocket 数据订阅 | 是 |
| `./<app> worker` | 定时任务（借助租约，每次只在一个进程中）、作业线程、心跳和回收 | 否 |
| `./<app> feeds [NAME...]` | 全部或指定名称的 [WebSocket 数据订阅](external-services.md#consuming-websocket-feeds) | 否 |

- `worker` 和 `feeds` 会打印一条横幅（`=> worker: 3 job threads, 2 scheduled tasks`），一直运行到收到 `SIGTERM` 或 `SIGINT`（Ctrl-C），然后像服务器一样停止。它们总是执行自己的工作：为 Web 角色设置的 `CYBERTRAIN_WORKER=0` 不会关闭它们。
- 带名称的 `feeds` 只运行这些订阅（每个订阅一个容器），未知的名称会让启动停止，并列出已注册的名称。当数据订阅在自己的进程中运行时，请在服务器上设置 `CYBERTRAIN_WORKER=0`，否则每个进程都会接收每个订阅。
- 典型的拆分方式：代理之后是设置了 `CYBERTRAIN_WORKER=0` 的 `server`，一个或多个 `worker`，有订阅时再加上 `feeds`。`cybertrain new` 会在 `config/deploy.yml` 中写入 `web` 和 `worker` 角色（以及被注释掉的 `feeds`）；systemd 单元见 [docs/deploy.en.md](../deploy.en.md) 第 7 部分 “Splitting the roles”。
- **从没有心跳的版本升级时**：在启动第一个新进程之前，先停止所有旧进程。旧进程不写心跳，所以新的 worker 会把旧 worker 仍在运行的作业当作被遗弃的作业取走。
- `Cybertrain::Main.worker?(ARGV)` 和 `Main.feeds?(ARGV)` 与 `Main.server?(ARGV)` 一样，告诉 `bin/<app>.rb` 它正在启动哪种角色。

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
- `x = expr` 把一个值留给后面的行使用，`_` 是上一个值。`sql "..."` 执行 SQL 并以表格形式打印各行，单元格中的控制字符会被转义（`\e`、`\n`），因此数据既不能向终端发送转义序列，也不会打乱表格；`tables` 列出所有表；`exit`、`quit` 或 Ctrl-D 退出。
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

每次轮询都像任何请求一样被记录（两行）。路径为 `config.health_path`（`CYBERTRAIN_HEALTH_PATH`，默认为 `/up`；空值会关闭检查，此时该路径会像以前一样交给 `public/` 和路由器处理）。负载均衡器、kamal-proxy 或部署脚本都可以轮询它；`public/up.html` 由 `cybertrain new` 写出，其 Kamal 配置仍然轮询它，但它只能说明进程能够响应 HTTP。
