---
source_sha256: 5fd1dcbbdc9f9499d55d66c8be021ada6717fce4bdd06c2b3f16f4702d16f6fa
---
# 后台任务与运维

## 后台任务

需要在请求之外做事情的应用（在响应发出之后发送通知、每小时清理旧行、重试失败的调用），会把这些工作注册到框架中，由框架在提供服务的进程的一个后台线程上运行：

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

- **运行时机。** 这个线程在二进制文件提供服务时启动（`./<app>`、`./<app> server`），时间是在启动过程连接好数据库、绑定端口并设置 `SPINEL_WORKERS` 之后；`migrate`、`db ...` 和 `Main.command` 命令从不启动它，`Cybertrain::Test::Client` 也不会。任务在启动后 `seconds` 秒首次运行，之后在每次运行开始后 `seconds` 秒再次运行。每次运行都包在一个 rescue 中，它会记录 `[ERROR] Scheduled task
  "name" failed: ...`，然后循环继续。块不接收参数（Spinel 没有 `instance_eval`）。`Cybertrain::Scheduler.last_tick` 是最后一次心跳的纪元秒数，可用于你自己的健康检查。
- **作业。** `Job.enqueue` 向 `cybertrain_jobs` 表添加一行，这张表由框架自己创建（`CREATE TABLE IF NOT EXISTS`，在首次使用时），并且不写入 `db/schema.rb`。负载是一个 String：结构化的数据请编码为 JSON。在 `DB.transaction` 内部，这一行会与其他内容一起提交或回滚。工作线程是一个每 `job_poll_interval` 秒（5 秒）轮询一次的调度任务，它在一个简短的 `BEGIN IMMEDIATE` 事务中认领最早到期的作业，在事务之外运行其处理器，然后把它标记为 `done`。抛出异常的处理器会依次在 1、5、15 分钟之后，然后在 60 分钟之后重试，并把 `Class: message`（最多 1000 个字符）写入 `last_error`，直到失败次数达到 `job_max_attempts`（5）次：此时这一行变为 `failed`，并保留下来供你查看。种类没有处理器的作业会立即变为 `failed`；`Job.enqueue` 会拒绝未注册的种类。崩溃的进程遗留为 `running` 的行会在工作线程启动时重新排队。`Job.state_count("failed")` 和 `Job.prune_done(before_epoch)` 可用于健康页面和日常清理。
- **每个数据库一个工作线程。** 每个提供服务的进程都会运行这个线程，除非设置了 `CYBERTRAIN_WORKER=0`（`config.worker = false`）：当多个进程共享一个 SQLite 文件时，请在除一个之外的所有进程中关闭它，否则每个定时任务会在每个进程中各运行一次。
- **让任务保持简短。** 任务和处理器在那一个线程上逐个运行，而一次 SQLite 调用会占用它的操作系统工作线程直到返回：在 `SPINEL_WORKERS=1`（默认值）时，一个耗时的查询会让所有请求停顿同样长的时间。请把大量工作分批进行（每次运行删除一千行，每个条目入队一个作业），而不是一次做完。
- **测试。** `Cybertrain::Scheduler.run_due(now)` 运行一次心跳，`Cybertrain::Job.work_one(now)` 运行一个作业，时间是你选定的纪元时间，所以测试永远不必休眠。

没有 cron 语法，作业没有优先级或唯一性，也没有邮件程序：这里涵盖的是“稍后发送”和“每 N 秒运行一次”（`docs/design.md` D28）。

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

想要自己进行备份的应用，可以从定时任务中以子进程方式运行它自己的二进制文件，而不是在自己的线程上执行 SQL：`system` 只在调度器的线程上等待子进程，在此期间请求照常得到处理（Spinel 没有 `Process.wait`，而不配合它使用的 `Process.spawn` 会留下僵尸进程，所以请使用带参数列表的 `system`，绝不要使用含有请求数据的字符串）。耗时超过 `health_worker_stale` 的复制会让健康检查在完成之前一直返回 `worker stale`。

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
