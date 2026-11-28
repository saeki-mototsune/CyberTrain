---
source_sha256: 3481073c4117c9ba8efb72dfab303d8797ba831aa29ca72f28a91b6b47466da0
---
# 升级

如何把应用迁移到更新的 CyberTrain 版本。每个版本的流程都相同：下面每一节是一个步骤，按顺序排列，附有命令以及正确结果的样子。某个版本在流程之外还要求的事情，见[各版本说明](#notes-by-version)。

## 开始之前

在应用目前所用的版本上，从一个可以退回的状态开始：

```shell 终端 — 应用目录
git status --short
cybertrain version
cybertrain test
```

<!-- list: points -->
- `git status --short` 什么也不打印：一切都已提交，这样后面每个步骤都会显示为各自的差异。
- `cybertrain version` 打印命令的版本。应用的版本是 `spin.lock` 中 `[lock.cybertrain]` 下的 `version`。两者相同，否则 `cybertrain test` 会停下。
- `cybertrain test` 通过。现在失败的测试要先在旧版本上修好：之后你就分不清它和升级造成的失败了。
- 生产环境有今天的备份（[运维：备份、VACUUM、健康检查](background-and-operations.md#operations-backups-vacuum-health-check)）。某个版本可能会改变数据库中存储的内容。

在改动任何东西之前，先阅读目标版本的说明。跳过若干版本的应用，要按从旧到新的顺序阅读中间每个版本的说明。

## 安装新命令

gem 和框架从同一个标签发布，每个版本都针对一个 Spinel 版本编写，并用它编译应用（[Spinel 是如何安装的](install.md#how-spinel-is-installed)）。所以升级从新命令和它固定的 Spinel 开始：

```shell 终端 — 任意目录
gem install cybertrain -v X.Y.Z
cybertrain version
cybertrain doctor
cybertrain setup
```

`cybertrain version` 打印 `cybertrain X.Y.Z`。`cybertrain doctor` 的输出以版本及其固定的 Spinel 开头，`cybertrain X.Y.Z, pinned to Spinel SPINEL_TAG`；这台机器上已有该 Spinel 时，有一行 `spinel    ok`。已有时，`cybertrain setup` 会说 `nothing to install`，这个版本没有移动固定的 Spinel 时就是如此。没有时，`cybertrain setup` 把新的 Spinel 构建到 `~/.cybertrain/spinel/<release>/`，需要几分钟；旧的保留不动，`~/.cybertrain/bin` 中的链接改为指向新的。

运行 spin 的命令在第一次需要时会自己完成同样的安装，下一步的 `cybertrain spin lock` 也在其中。在这里运行 `cybertrain setup` 只决定等待发生在什么时候。

## 修改版本

`cybertrain` 命令会拒绝框架版本与自己不同的应用（[把应用迁移到新版本](install.md#moving-an-app-to-a-new-release)）。所以应用要在两个文件中跟上命令：

1. `spin.toml`：`[dependencies]` 下的 `cybertrain` 一行指向新标签，`ref = "vX.Y.Z"`。
2. `spin.lock`，从零重新写出：

```shell 终端 — 应用目录
rm spin.lock
cybertrain spin lock
```

它打印 `locked 2 package(s)`，`git diff spin.lock` 显示 `[lock.cybertrain]` 下新的 `version` 和新的 `ref`（标签对应的提交），框架依赖的 HTTP 层换了版本时，还在 `[lock.spinel-http]` 下显示它（[HTTP 服务器](how-it-works.md#the-http-server)）。不执行 `rm` 的话，`spin lock` 会保留已锁定的提交，差异为空。有其他依赖的应用，或者依赖 spin 索引中某个版本的应用，按[把应用迁移到新版本](install.md#moving-an-app-to-a-new-release)所述重新锁定。

`cybertrain new` 写出的文件中还有两个写明了版本。应用里有它们时一并修改：

<!-- list: points -->
- `Dockerfile`：`gem install cybertrain -v X.Y.Z`。镜像用这个命令构建，版本与锁定的不一致时，其中的 `cybertrain build` 会停下。
- `.github/workflows/ci.yml`：`setup-cybertrain@` 后面的标签（[持续集成](testing.md#continuous-integration)）。

在命令与 `spin.lock` 一致之前，`server`、`build`、`db`、`test` 和 `generate` 会在运行 spin 或写出文件之前停下，退出状态为 1，并显示“`error: this application's framework is cybertrain A.B.C (spin.lock), but this cybertrain command is X.Y.Z.`”。`cybertrain spin ...` 从不做这项检查。

## 重新生成并阅读差异

`gen/` 中的生成代码是提交到仓库的，新框架的生成器可能把它写得不一样（[构建时代码生成](how-it-works.md#build-time-code-generation)）：

```shell 终端 — 应用目录
SPIN_DEBUG=1 cybertrain spin run gen
git status --short gen/
git diff gen/
```

生成器对它改动的每个文件打印 `wrote`，对其余文件打印 `identical`。请阅读差异：这就是该版本在应用所编译的代码中改变的部分；版本说明中写着“在 `spin run gen` 之后”的条目，由这一步完成。差异为空，说明该版本在这里没有任何改变。

生成器拒绝应用代码中的某些内容时，会停下并给出说明原因的消息。要改什么写在该版本的说明里；改好后再次运行命令。

## 再次运行生成器

生成器写进 `app/`、`config/` 和 `test/` 的代码属于应用，`spin run gen` 不会碰它。能把这类代码更新到最新的生成器，要在应用中再运行一次。目前这样的生成器是 `generate authentication`，适用于用了它的应用：

```shell 终端 — 应用目录
cybertrain generate authentication > authentication.upgrade 2>&1
patch -p1 < authentication.upgrade
```

传入生成应用时用过的选项（`--invite-only`、`--confirmable`）。生成器写出缺少的文件和一个补充所缺列的迁移；对于每个它会写成不同内容的已有文件，它不做改动，而是打印一行 `manual` 和一段差异。`patch -p1` 应用这些差异；你编辑过的文件的差异要手工应用，`manual` 行指出已被替换的文件要删除（[再次运行生成器](authentication.md#running-the-generator-again)）。

再运行一次而不再打印 `manual` 行时，这一步就完成了。这时删除 `authentication.upgrade`。其他生成器（`scaffold`、`attachment`、`job`、`helper`、`component`）只写新代码；某个版本对它们以前写出的代码有什么改变，列在该版本的说明里。

## 迁移数据库

```shell 终端 — 应用目录
cybertrain db migrate
cybertrain db status
```

`db migrate` 对生成器添加的每个迁移打印 `== <version> <Name>: migrating` 并应用它，然后重新写出 `db/schema.rb` 和 `gen/` 中的模型；之后 `db status` 的每一行都显示 `up`。框架自己的表（`cybertrain_jobs`）不需要迁移：第一个接触它的进程会补上缺少的列。

改变已有数据存储方式的版本，会在说明中指定一个 `db` 命令。在这里对开发数据库运行它，部署时再对生产数据库运行一次（[部署](#deploy)）。这样的命令运行两次也是安全的。

## 应用版本说明

逐个主题过一遍[各版本说明](#notes-by-version)中该版本的那一节。每一条都写明什么变了、该怎么做。应用没有用到的内容，对应的条目不需要处理。

大多数条目会在下一步以编译错误或失败的测试的形式被发现。发现不了的，是那些关于已存储的数据、cookie、日志以及应用代码之外其他东西的条目：读取日志的脚本、代理、监控。这些要靠阅读来确认。

## 运行测试

```shell 终端 — 应用目录
cybertrain test
cybertrain build
```

`cybertrain test` 针对新框架编译测试并通过。`cybertrain build` 编译生产环境运行的二进制文件 `dist/<app>`，其中嵌入了视图。新版本要求的设置如果缺失，这个二进制文件会在启动时停下，并给出指明该设置的消息，所以部署之前要按生产环境的方式启动它一次（[生产预演](../deploy.en.md#2-6-a-production-rehearsal)）。

然后提交各步骤改动的所有内容：`spin.toml`、`spin.lock`、`gen/`、`db/`、生成器的文件以及你自己的修改。

## 部署

按以下顺序：

1. 在每台构建应用的机器上安装新命令（在[部署教程](../deploy.en.md#upgrading-the-framework)中是服务器；使用 Kamal 时是 `Dockerfile`），并在那里运行 `cybertrain setup`。命令与 `spin.lock` 不一致时，部署的构建会停下。
2. 把说明中指出的设置和密钥加入环境（[配置与环境变量](configuration.md#configuration-and-environment-variables)）。
3. 做一次备份。
4. 说明有要求时，在第一个新进程启动之前停止所有旧进程（`server`、`worker`、`feeds`）（[进程角色](background-and-operations.md#process-roles)）。
5. 照常部署：构建，`./<app> migrate`，然后是说明指定的 `db` 命令，最后是新进程。

要退回时，切换到上一次的构建并重启（[回滚](../deploy.en.md#rolling-back)）。这样做不会回滚迁移，改写过已存储数据的 `db` 命令也不会被撤销。除非该版本的说明写明旧版本能读取改写后的数据，否则在运行这样的命令之后退回，就意味着恢复第 3 步的备份。

## 一个版本需要哪些步骤

每个版本都要执行所有步骤；版本不需要某个步骤时，大多数步骤会立刻结束。是否需要，由每个步骤自己说明：

| 步骤 | 无事可做的情形 |
| --- | --- |
| 安装新命令 | 命令：没有。它的 Spinel：`cybertrain setup` 说 `nothing to install` 时 |
| 修改版本 | 没有：每个版本都会改 |
| 重新生成 | `git status --short gen/` 什么也不打印 |
| 再次运行生成器 | 运行后既没有 `manual` 行也没有 `create` 行 |
| 迁移 | `cybertrain db status` 没有 `down` 行 |
| 应用说明 | 下面没有该版本的一节 |
| 测试、部署 | 没有 |

补丁版本（`X.Y.Z` 到 `X.Y.Z+1`）不含兼容性变更，也没有说明。次版本（`X.Y` 到 `X.Y+1`）可能包含，这时下面会有它的一节（[兼容性契约](../compatibility.md#changing-a-contract)）。

## 各版本说明

这一节之后的各节，按从新到旧的顺序，记录每个版本在流程之外要求的事情。每一节以它前后两个版本命名，内部按主题划分。版本说明只写在这里：各主题的指南描述框架现在的样子，上面的流程不提任何具体版本。

## 从 0.4 到 0.5

### 从 0.4：请求

为 0.4 编写的应用需要注意的变化：

- 每个会话都会结束一次：加密的 cookie 不读取旧的签名 cookie，所以用户需要重新登录。调用 `Session.load` 或 `Session.dump` 的代码要传入派生的密钥 `Crypto.derive_key(secret, SessionStore::SESSION_KEY_LABEL)`；传入原始密钥会抛出 `Encryptor::Error`。
- 每个应用都链接 OpenSSL（[安装](install.md#requirements)）；以前由 `cybertrain new` 写出的 Dockerfile 需要在构建阶段加入 `libssl-dev`，在运行阶段加入 `libssl3t64`。
- 在接受格式的路由中，动态段不再捕获 `.`：含点号的 id 需要在其路由上写 `format: false`。
- 手写的 `url_resolver` lambda 接受三个参数 `->(name, args, options)`；传入 `Gen::Routes.url_resolver` 的应用只需运行 `spin run gen`。
- `params.permit` 返回 `Hash{String => Object}`：把值当作 String 使用之前，先对它调用 `Cast.str` 或 `.to_s`。
- `rate_limit` 在缓存中计数：`store: :memory` 保留原来的按进程计数，同一控制器中的两个限制需要各自的 `name:`，返回 nil 或 `""` 的 `by:` 方法会抛出异常，什么都不渲染的 `with:` 方法之后仍返回 429。
- 数字辅助方法对不是数字的值，以及超出 0 到 100 的精度，会抛出异常（nil 在模板中仍渲染为 `""`）。
- 控制器或模型中的 `include A, B` 与 Ruby 一样先包含 B；`include` 一个不是 concern 的模块会留给 Ruby。
- 所有 ETag 变化一次（现在包含请求的格式和构建摘要），由 `Accept` 决定的响应会发送 `Vary: Accept`，html 回退适用于任何列出 `text/html` 或 `*/*` 的 `Accept`。可能回退到 html 的请求（`application/json, text/html`）有自己的 ETag，与只请求该格式的请求不同；`Accept` 中的 `text/html;q=0` 不会得到 html 回退（只有 html 的动作响应 406），旁边有 `*/*` 时也一样；`If-None-Match: *` 对只用 `last_modified:` 验证的响应也会得到 304。
- `permit` 和 `expect` 对不是 Array 的过滤器抛出 `ArgumentError`；`layout` 指向不存在的布局会抛出 `MissingTemplate`（默认的 `application` 布局仍是可选的）；jar cookie 超过 4096 字节会抛出 `Session::CookieOverflow`。
- `public/style.css` 继续可用；把它移到 `app/assets/stylesheets/` 是可选的（[资源](assets.md#moving-publicstylecss)）。
- 验证消息来自捆绑的词典（[国际化](i18n.md#models-and-validation-messages)），英语文本相同，只有三处不同：`:base` 上的消息不再以 "Base" 开头，以 `_id` 结尾的属性名不带 "id"（"Article can't be blank"，而不是 "Article id can't be blank"），长度上限为 1 时显示 "1 character"。比较这些消息的测试会改变。
- 不带 `format:` 或带格式名的 `time_tag` 通过 `I18n.l` 格式化（在英语页面中与以前的英语文本相同）。
- gen 写出 `gen/locales.rb`（没有 `config/locales/` 时为空）并加载 `app/mailers/**/*.rb`；`cybertrain new` 写出 `config/locales/en.yml`，较早的应用也可以添加它。
- `allow_unauthenticated_access` 现在是框架的方法；0.4 的生成器写进 `ApplicationController` 的那个仍然有效并优先。再次运行 `cybertrain generate authentication` 会加入密码重置、锁定、保持登录、账户页面和管理员用户，并为 0.4 写的文件打印差异（[从 0.4：认证](#from-04-authentication)）。
- HTTP 层成为一个独立的库 spinel-http，框架依赖它（[HTTP 服务器](how-it-works.md#the-http-server)）。spin 也为应用锁定它，所以上面重新锁定之后，`spin.lock` 里还有一个 `[lock.spinel-http]` 表：请提交它。之前的版本写的锁文件没有这个表；spin 仍会通过框架找到 spinel-http，应用可以构建，但它没有被锁定，`cybertrain new` 写的 CI 步骤 `spin.lock is current` 会失败，直到运行 `cybertrain spin lock` 并提交锁文件。`Cybertrain::Server`、`Request` 等这一层的名字和 `require "cybertrain/http/..."` 路径保持不变；类的 `name`（日志行里打印的那样）变成 `SpinelHttp::Server`。上传文件的 `inspect`（`#<SpinelHttp::UploadedFile ...>`）和错误事件的 `error_class`（Sentry 的 `exception.type`）也一样：在这些地方匹配 `"Cybertrain::QueryMalformed"` 的测试或告警，现在看到的是 `"SpinelHttp::QueryMalformed"`（`assert_raises` 的字符串形式仍接受 `Cybertrain::` 的名字）。重新打开层的类来添加方法的代码仍可以写 `Cybertrain::Request`，但通过这个名字添加的常量在编译后的程序中从类外读取时会引发 `NameError`：请改为重新打开 `SpinelHttp::Request`（真正的名字）来添加。

### 从 0.4：模型与数据库

下面每一项都是为 CyberTrain 0.4 编写的应用一次就能改完的修改：

1. `has_many` 读取方法返回 relation，而不是 Array：在仅 Array 才有的方法（`map`、`select`、`[]`、`+`）前加 `.to_a`。模板不变。
2. 日期时间以 Rails 的格式存储：升级后运行一次 `db normalize`（[日期时间与 `db normalize`](models.md#datetimes-and-db-normalize)）；在那之前，混有两种格式的列按格式排序。
3. `as_json` 和 `to_json` 把时间写成 `2026-10-05T09:00:00.000Z`（以前是 `2026-10-05T09:00:00Z`）：测试中的 JSON 快照会变化。
4. `t.date` 属性是 `Date`，不是 String：`strftime` 仍然可用，拼接需要 `to_s`。NOT NULL 的日期列现在会校验存在性。
5. 没有 `optional: true` 的已声明 `belongs_to` 会校验其外键；未声明的不变。
6. Integer 端点的 `where(x: a..b)` 是范围条件（以前是与 Range 文本的相等比较，永远不会匹配）；Time 和 Date 边界使用 `where_between`。
7. `Cybertrain::Cast.iso8601` 是显示格式：用它拼 SQL 文本的代码改用 `Cast.sql_datetime`，`Cast.binds` 以存储格式绑定 Time。
8. `validates` 行上的 `allow_blank: true` 也让该行的 `presence` 放过空白值，与 Rails 相同（以前只作用于 `length`）。
9. 与每个模型现在都有的方法同名的列（`update_columns`、`destroy_dependents`、`run_custom_validations` 等）会生成为 `<column>_column`（[列名](models.md#column-names)）。
10. `belongs_to` 读取方法会记住读到的父记录，直到外键改变（以前每次调用都会重新读取）：要看到其他进程所做的修改，请调用 `reload`。

### 从 0.4：认证

在 0.4 生成的应用中再次运行 `cybertrain generate authentication`（[再次运行生成器](#run-the-generators-again)）。

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) 是针对 0.4 生成的开放注册应用的完整输出。

<!-- list: points -->
- `ApplicationController` 中 0.4 的代码块变为 `include Authentication`。`--force` 只有在它与 0.4 所写完全相同时才会替换它。
- 使用 `--confirmable` 时，sessions 和 registrations 控制器的差异带有一行 `IMPORTANT:`：在应用它们之前，未确认的账户不会被告知为何无法登录，注册也不会收到链接邮件。在 0.4 的应用中关注点是新文件，连同确认检查一起写出，所以即使这些差异从未应用，它仍然不会为未确认的账户开始会话（并记录 `WARN [<request id>] no session started: user <id> has not confirmed its address`）。
- 升级时每个会话都会结束一次（cookie 现在是加密的）。

### 从 0.4：配置

有两个默认值在 0.4 之后发生了变化（[配置与环境变量](configuration.md#configuration-and-environment-variables)）：

- 渲染嵌套以前没有限制，现在由 `max_render_depth` 限制，默认为 12。局部模板树更深的应用（分层评论、分类菜单）在调高这个设置之前会得到模板错误。
- `job_poll_interval` 以前是 5 秒，现在是 1 秒：作业在自己的线程上运行，空闲的线程每秒查找一次工作。

### 从 0.4：作业

- `cybertrain_jobs` 新增 `concurrency_key` 列和 `discarded` 状态；第一个接触这张表的进程会添加该列。列举状态的代码（基于 `Job.state_count` 的仪表板）要加上 `discarded`。`Job.prune_done` 仍然只清理 `done` 的行。
- `every` 任务在重启之后从时间表继续，而不是从头开始：进程停止期间过去的间隔会在启动时运行一次。
- 运行作业的应用要在第一个新进程启动之前停止所有旧进程（[部署](#deploy)的第 4 步）。0.4 不为正在运行的作业写心跳，所以新进程会把这个作业当作被遗弃的，重新排队，并与旧进程同时再运行一次。
- 给已有的种类加上键（`limits_concurrency ... key:`）依赖这次停止。第一个新进程会为之前入队的 `queued` 行设置键（对负载中没有该字段的行，它会记录其 id），旧进程留下的 `running` 行会在被回收时获得它的键。
- `jobs` 现在是一个内置命令：名为 `jobs` 的应用命令必须改名。

### 从 0.4：日志与错误报告

- 每一行日志的形状都变了：行首方括号中的级别（`[INFO]`）换成了时间、级别和标签，`2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`。读取日志的东西（脚本中对 `[ERROR]` 的 grep、告警）也要随之修改；查找整行的测试改为分别查找级别和消息（`" ERROR "` 和消息；[从 0.4：测试](#from-04-tests)）。
- 应用返回的每个响应都带 `X-Request-Id`（服务器对无法读取的请求返回的 400 和 413 除外）。设置了它的代理，只有在受信任时才会采用它的值。
- `cybertrain_jobs` 增加 `request_id` 列；第一个访问该表的进程会添加它。
- 文本日志行不再延续到后面的行：消息或标签中的换行和回车写成 `\n` 和 `\r`。从多行读取多行消息的东西改为读取转义。
- 名为 `handle` 的模型列现在读作 `handle_column`：有 `users.handle` 列的应用把 `user.handle` 的调用改为 `user.handle_column`（查询仍用 SQL 名称）。不是文本的 `request_id` 或 `release` 列会被 gen 拒绝（[列名](models.md#column-names)）。
- 除非 `config/app.rb` 设置了它们，`cybertrain test` 忽略导出的 `CYBERTRAIN_LOG_FORMAT` 和 `CYBERTRAIN_SENTRY_DSN`（测试读取文本行，不发送任何东西）。`generate authentication` 写的密码测试会在其 `with_config` 中关闭 JSON 行；以前生成的、测试以 `log_format :json` 运行的应用，请重新运行生成器或照搬这一修改。
- `require "cybertrain"` 现在通过 Sentry 发送器链接 `HttpClient` 和 TLS 层。
- 约束失败会抛出 `Cybertrain::DB::UniqueViolation` 或 `Cybertrain::DB::ForeignKeyViolation`，它们是 `Cybertrain::DB::Error` 的子类：针对 `DB::Error` 的 `rescue`、`rescue_from`、`retry_on` 和 `discard_on` 仍然能捕获它们，但失败作业的 `last_error`、其日志行和错误报告的类型现在显示子类的名称（`Cybertrain::DB::UniqueViolation: UNIQUE constraint failed: ...`）。匹配文本 `Cybertrain::DB::Error:` 的告警、仪表板或测试，也要匹配子类的名称。

### 从 0.4：测试

- 添加 `test/test_helper.rb`（[编写测试](testing.md#writing-a-test)），并把支持文件在加载时做的事（`AppTest.boot`、`BlogTest.boot`、迁移数据库）移出来：测试程序会在第一个测试之前在新数据库上启动，第二次启动只会浪费时间。
- 把 CI 步骤从 `spin test` 改为 `cybertrain test`。
- 定义了同一个顶层辅助方法或常量的两个文件（像 0.4 的生成器写的那样，各有一个 `new_client`）会一起被拒绝：把辅助方法移到 `test/support/`，或给其中一个改名。
- 每个测试之前所有表都会被清空，所以后面的测试不能再依赖前面的测试创建的行：把这样的数据移到夹具或 `setup` 中。
- 时钟的注入点已移除：`Cybertrain::Cache.clock=`、`Cache.system_clock`、`RateLimit.current_time=`、`SessionStore#fixed_now=`、`Application.status_now=` 和 `Background.supervisor_clock=`。请使用 `travel_to`、`travel` 或 `freeze_time`，它们的块形式不需要你自己写 `ensure` 就会恢复时间。
- 测试中的邮件保存在 `Cybertrain::Mailer.deliveries` 中；在 `Test::SmtpReceiver` 上读取邮件的测试要先设置 `Cybertrain.config.mail_delivery_method = :smtp`。
- 0.4 的 `generate helper` 写出的辅助方法测试定义了顶层的 `render_inline(source)`，它与框架的冲突：在那个文件中把它（包括调用处）改名为 `render_helper_template`。
- `1.month.ago` 写作 `Time.current.months_ago(1)`。
- `assert_equal` 以 Minitest 的两行文本失败；通过的测试快照不变。
- 再次运行 `cybertrain generate authentication` 会写出类形式的测试，并指出它们替代的每个旧文件（`test/authentication.rb`、`test/support/app_test.rb` 等）；`--force` 会删除它们。
- 以前查找整行日志（以方括号中的级别开头）的测试，改为分别查找级别和消息（`" ERROR "` 和 `"password reset mail not sent: "`）：现在一行以时间开头，可能带有请求的 ID（[日志](logs-and-errors.md#logs)）。
- 导出的 `CYBERTRAIN_LOG_FORMAT` 或 `CYBERTRAIN_SENTRY_DSN` 不再影响测试；要用它们测试，请在 `config/app.rb` 中设置，或在测试中给 DSN 赋值。
