---
description: CyberTrain 应用如何构建和运行（构建时代码生成、可选的子系统、解释执行的视图、HTTP 服务器、通过 FFI 使用 SQLite、开发循环），以及与 Rails 的差异。
source_sha256: 749be6fc8b6dade60fb439154deed33ef7b2a64f609fb26257c2c8a61ced695c
---
# 工作原理

本页说明 CyberTrain 应用如何构建和运行：构建时生成的代码、应用 require 的子系统、请求时解释执行的视图、HTTP 服务器、通过 FFI 使用 SQLite 以及开发循环，然后是一张与 Rails 的差异表。首页的[性能一节](site:index.html#performance)把结果与用 Rails 8.1 编写的同一个博客作了对比。测量方法、全部数字以及如何重新测量，见 [docs/benchmark.md](../benchmark.md)。

## 构建时代码生成

`spin run gen`（`bin/gen.rb`）执行 `db/schema.rb` 的 `create_table` DSL 和 `config/routes.rb` 的 `Routes.draw` DSL，以获得表和路由的*数据*。另外，它还对 `app/controllers/**/*.rb` 和 `app/models/**/*.rb` 进行**词法扫描**（用正则表达式，而不是解析器——Spinel 在运行时不提供解析器），查找 `@ivar =` 赋值、`before_action`/`after_action`/`rescue_from ... with:` 的名称、`helper_method`、`layout` 和 `rate_limit` 行、对 concern 的 `include` 以及无参数的 `def`。它还给 `app/assets/`、`app/javascript/` 和 `vendor/javascript/` 下的文件加上摘要，把 `config/importmap.rb` 当作文本读取，并用自己的 YAML 读取器读取 `config/locales/` 中的词典。

据此，它在 `gen/` 下写出朴素、易读的 Ruby 代码：

- `gen/models/<name>.rb`：访问器、类型转换、查找方法、由外键推导出的关联；
- `gen/routes.rb`：路由表、分派器、`*_path`/`*_url` 辅助方法；
- `gen/controllers.rb`：每个控制器的 `view_assigns`、`run_callback`、`helper_method` 表和 `controller_layout`；
- `gen/concerns.rb` 和 `gen/concerns/**`：插入到每个包含类中的 concern 的 `included` 块，以及清空了这些块的 concern 模块（[Concern](requests.md#concerns-and-helper_method)）；
- `gen/assets.rb`：带摘要的资源路径和 import map（[资源](assets.md)），带摘要的文件放在 `public/assets/` 中；
- `gen/locales.rb`：应用的词典，存为两个 Hash，供 `I18n.t` 读取（[国际化](i18n.md#dictionaries)）；
- `gen/migrations.rb`；
- `gen/views.rb`：内嵌视图表，除非为部署而构建，否则为空；
- `gen/app.rb`：`require_relative` 清单；
- `gen/tests.rb` 和 `gen/test/**`：把 `test/` 的所有测试合成一个程序，每个测试类改写成方法，`gen/test/data.rb` 中是表和夹具（[测试应用](testing.md#running-the-tests)）。

`gen/` 要提交，而不是加入 gitignore：`spin build`/`spin test` 没有先运行生成的钩子，所以签入的输出必须已经是可以编译的代码。CI 会重新运行 `spin run gen`，出现差异就失败，因此过时的生成代码无法合并。

## 子系统

Spinel 会编译程序 require 的每个文件里的每个方法，无论是否被调用，而它对整个程序的分析占了每次构建的大部分时间。所以应用可能用不到的框架部分是分开的，由 `bin/<app>.rb` 指明应用用到哪些，就像 Rails 的 `config/application.rb` 列出 railtie 一样：

| 行 | 加载的内容 |
| --- | --- |
| `require "cybertrain/core"` | HTTP、路由、控制器、模型、视图与辅助方法（包括 `turbo_frame_tag`、`dom_id`、`render turbo_stream:` 和 `format.turbo_stream`）、资源、会话、CSRF、CSP、控制台、`db` 与 `migrate` |
| `require "cybertrain/jobs"` | `Job` 与作业类、`Scheduler`（`every`、`cron`）、`worker` 角色、`jobs` 命令和作业页面 |
| `require "cybertrain/streams"` | `Stream.broadcast_*`、流端点（SSE 与 WebSocket）、`Controller#turbo_stream`，以及辅助方法 `turbo_stream_from`、`turbo_stream`、`signed_stream_name` 和 `stream_source_path` |
| `require "cybertrain/feeds"` | `Background`、`feeds` 角色及其健康检查；`require "cybertrain/websocket"`（`WebSocket.subscribe`）会加载它 |
| `require "cybertrain/mailer"` | `Mailer.deliver` |
| `require "cybertrain/mailer/later"` | `Mailer.deliver_later`；同时加载邮件发送器和作业 |
| `require "cybertrain/cache"` | `Cache` |
| `require "cybertrain/rate_limit"` | 控制器中的 `rate_limit`；同时加载缓存 |
| `require "cybertrain/error_reporter/sentry"` | Sentry 发送器：`CYBERTRAIN_SENTRY_DSN` 把每个错误报告发送到 Sentry 或 GlitchTip（[错误报告](background-and-operations.md#error-reporting)）；加载 `HttpClient` 和 TLS。只写在 `bin/<app>.rb` 中 |
| `require "cybertrain"` | 以上全部 |

每一行都写在 `require "cybertrain/core"` 之后（`cybertrain/jobs` 和 `cybertrain/feeds` 会自己加载核心，其他行不会），行的顺序无关紧要：框架按自己的固定顺序启动和停止各子系统。在一个用脚手架生成的应用上，只用核心时编译 2,205 个方法而不是 2,767 个，分析用 38 秒而不是 52 秒；完整构建用 83 秒而不是 108 秒，修改一次控制器约 47 秒而不是约 65 秒（[docs/performance-next.md](../performance-next.md)）。

`cybertrain new` 在 `bin/<app>.rb` 和 `bin/db.rb`（它加载 `config/app.rb`，所以需要相同的行）中写入 `require "cybertrain/core"`。`cybertrain generate job` 向两者添加 `require "cybertrain/jobs"`，`generate authentication` 添加其代码用到的四行（`cybertrain/jobs`、`cybertrain/mailer`、`cybertrain/mailer/later` 和 `cybertrain/rate_limit`：作业页面、用 `deliver_later` 发送的邮件、有速率限制的登录）；其余的行由你自己添加。拆分之前编写的应用里是 `require "cybertrain"`，它仍然加载全部内容：应用照旧构建和运行；把这一行换成核心加上用到的行，构建才会变快。

缺少的行会在应用运行之前被发现：

<!-- list: points -->
- 引用了缺失子系统的 Ruby 代码（`ReportJob.perform_later`、`Cybertrain::Stream.broadcast_append_to`、`Cybertrain::Mailer.deliver`、`rate_limit to:`）无法编译；错误会指出常量或方法，上表给出对应的行。
- 调用子系统辅助方法的视图会让 `spin run gen`（以及 `spin run gen -- --check`）以退出状态 1 停止：`app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb`。如果模板仍被渲染，会抛出 `undefined helper 'turbo_stream_from'`。
- `./<app> worker`、`./<app> jobs` 和 `./<app> feeds` 会打印例如 `the worker role needs require "cybertrain/jobs" in bin/<app>.rb`，并以 1 退出。
- `/up` 只报告已加载的部分：没有作业就不检查 worker 是否停滞，没有 feed 就不检查 feed 是否停滞。
- 设置了 DSN 却没有 Sentry 发送器的那一行，会拒绝启动：`error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`。错误报告器本身、它的订阅者以及日志的请求 ID 都在核心中。

gen 把 `bin/<app>.rb` 当作文本读取，只看其中字面写出的 `require "cybertrain"` 和 `require "cybertrain/..."` 行：把它们移到 `bin/<app>.rb` 用 `require_relative` 加载的文件里，gen 就会拒绝本来能用的辅助方法。请把它们留在 `bin/<app>.rb` 中。

没有作业时，缓存自己清除过期的行：进程的第一次写入，以及每过 `cache_prune_interval` 后的第一次写入，最多删除一千行。有作业时，仍由计划任务 `"cybertrain cache prune"` 完成（[缓存存储](background-and-operations.md#the-cache-store)）。

有两种情况 gen 不会发现：没有 `cybertrain/jobs` 时在 `config/routes.rb` 中写了 `jobs_page` 行，会成为生成的控制器的编译错误，而不是 gen 的提示；`retry_on` 或 `discard_on` 引用了 `Cybertrain::Mailer` 错误的作业，会让生成的 `gen/app.rb` 自己 require `cybertrain/mailer`。

测试不受这些行的裁剪：`cybertrain test` 编译的程序（`gen/tests.rb`）无论 `bin/<app>.rb` require 了什么，都会 require `cybertrain`，即所有子系统，以及 Sentry 发送器。因此 `perform_enqueued_jobs`、`assert_emails`、`assert_broadcasts` 和 `Test::SentryReceiver` 在任何应用中都可用，基于 `cybertrain/core` 的应用会连同所有子系统一起编译其测试，而引用了某个子系统却没有其 require 行的代码会通过测试，在 `spin build` 时才停下（[测试应用](testing.md)）。

## 视图是解释执行的

`app/views/**/*.html.erb` 文件看起来像 Rails 的 ERB，但在请求时被解析为 AST，然后由一个遍历树的解释器执行。Spinel 没有 `eval`，所以这是一套封闭的语法（字面量、`@ivar`/局部变量查找、通过按类型固定的分派表进行的调用、`if`/`unless`、`each`/`each_with_index`/单个辅助方法块），而不是真正的 Ruby。完整的语法、辅助方法和缺失功能见[模板语言参考](template-language.md)。

源代码来自哪里取决于模式：

- 在开发（和测试）模式下，引擎从磁盘读取 `app/views/`，并且在开发模式下，模板改动后会重新解析，所以修改视图无需重新构建。
- `cybertrain build` 会运行 `SPIN_DEBUG=1 spin run gen -- --embed-views`，为那一次 `spin build` 把每个模板的源代码作为字符串表写入 `gen/views.rb`，然后再次运行 `SPIN_DEBUG=1 spin run gen`，恢复已提交的空表。
- 生产环境的二进制文件只渲染这张表（每个模板解析一次），表为空时拒绝启动（`error: views are not embedded in this binary`）。

## HTTP 服务器

`Cybertrain::Server` 是纯 Ruby 实现的 HTTP/1.1：`TCPServer#accept` 加上每个连接一个 Spinel 绿色线程（M:N 调度，没有 GVL），带类型的 `Request`/`Response`，没有 Rack 层。TLS/HTTP/2 交给反向代理处理。`SPINEL_WORKERS` 默认为 `1`——实验发现，对于这种 I/O 密集型、100 个并发连接的场景，这样更快且不会卡顿。

服务器调用一个 `HttpHandler`（`call(request) -> Response`）；`ContextHandler` 把它与中间件栈连接起来，所以 HTTP 层（`cybertrain/http/`，以及 `Params` 和 `Logger`）不依赖框架的其他部分；`script/check-http-layer` 在 CI 中强制保证这一点。

## 通过 FFI 使用 SQLite

模型直接通过 Spinel 的 `ffi_func`/`ffi_lib` 与 SQLite 通信——没有 C 扩展，也没有 gem。每个查询都使用绑定参数，从不做字符串插值。这是目前唯一的适配器（通过 `libpq` FFI 支持 PostgreSQL 被记为未来可能的工作）。

一个连接池（`SizedQueue`，默认 4 个连接）分发连接，这些连接带有：

- WAL；
- 约五秒的忙等待超时，通过绿色线程的 `sleep` 等待（起初 100 µs，之后最多 1 ms），因此即使只有一个 worker，持有锁的连接也能继续运行；模式脚本则在 SQLite 内部等待（SQLite 自己的 `busy_timeout` 每次会休眠一毫秒或更久）；
- 最多 64 条缓存的预编译语句；
- 开启的外键。

事务如何取出其中一个连接，以及在它上面运行什么：[事务](models.md#transactions)。

## 开发循环

在 `development` 模式下（默认的 `CYBERTRAIN_ENV`，`cybertrain build` 构建的二进制文件除外），`cybertrain server` 是一个监管进程。它运行在 CRuby 上，也就是运行 `cybertrain` 命令的那个 Ruby，自己持有监听套接字，并在上面一次只运行一个子进程：改动之后立刻是 CRuby 上的应用，等 Spinel 在后台构建完成后则是编译好的二进制文件。Ruby 的修改会立即由 CRuby 预览响应（在 examples/blog 上不到一秒），随后编译好的程序会接管端口，你什么都不用做。

启动时，监管进程用 CRuby 运行 gen（`ruby bin/gen.rb`，写出的 `gen/` 与 `spin run gen` 相同），用 CRuby 启动应用（`ruby -r cybertrain/preview bin/NAME.rb`），并开始构建。两者都由 `PATH` 上的 `ruby` 运行，也就是 `cybertrain doctor` 检查能否加载 `fiddle` 的那个 Ruby，它可能与运行 `cybertrain` 命令的 Ruby 不是同一个。预览通过 Ruby 的 `fiddle` 之上的一层垫片为框架提供 FFI（SQLite、zlib），这层垫片把二进制文件所用的同一份 C 代码一次性编译到 `tmp/cybertrain-dev/ffi/`。第一次构建是 `spin build NAME`，所以自二进制文件构建以来没有改动过的应用什么都不编译，二进制文件在一秒内就开始响应。当二进制文件比某个 Ruby 文件旧时的第一次构建，以及之后的每一次构建，都是 `spin build NAME -- --incremental`：Spinel 的增量构建，只重新编译这次编辑改动了的 C 单元。不支持 `--incremental` 的 Spinel 版本会拒绝这个参数，此时构建不带它进行。输出写入 `tmp/rebuild.log`。

监管进程每秒十次轮询 `app/**/*.rb`、`config/**/*.rb`、`db/schema.rb`、`gen/**/*.rb` 以及资源的根（`app/assets/**`、`app/javascript/**`、`vendor/javascript/**`）。视图被排除在外（两种运行时都会从磁盘重新读取它们），`gen/views.rb` 也被排除，它在开发模式下为空。发生改动时，会取消正在进行的构建，用 CRuby 运行 gen，把子进程换成新的 CRuby 子进程，并开始新的构建。当构建成功且期间没有新的改动时，监管进程停止 CRuby 子进程，并在同一个套接字上启动 `build/bin/NAME`：先停止，再启动，期间套接字一直保持打开，因此切换过程中到来的请求会稍等片刻再得到响应。不会拒绝任何请求。

应用的每个响应都带有 `X-Cybertrain-Runtime: cruby` 或 `spinel`，每个 HTML 页面的右下角都有一行不起眼的文字：

- `CRuby preview · Spinel building…`：构建进行中时由 CRuby 渲染了这个页面。
- `Spinel ready — reload`：现在由编译好的二进制文件响应；重新加载即可看到它的页面。
- `CRuby preview · Spinel build failed`：CRuby 继续响应，页面以横幅显示编译器输出。
- `CRuby preview · Spinel binary failed`：二进制文件没有启动，或者已经退出；CRuby 重新响应，横幅显示二进制文件报告的内容，下一次改动会重新构建并再次尝试它。
- `Spinel`：由编译好的二进制文件渲染了这个页面。
- `Source changed — reload`：页面渲染之后有文件发生了改动。
- `CRuby preview`：由 CRuby 渲染了这个页面，且以上情况都不适用。

这一行会自己保持最新；应用的页面从不自动重新加载，所以正在填写的表单不会丢失。当 gen 失败，或应用无法在 CRuby 上启动（例如 `SyntaxError`）时，监管进程自己用 503 页面响应每个请求，页面显示错误以及它在等待什么；这个属于监管进程自己的页面每 2 秒自动重新加载一次，直到有子进程能够响应，保存修正错误的文件后应用就会回来。`cybertrain build` 持有 `tmp/cybertrain-build.lock` 期间，不会重新生成也不会重启；锁消失后服务器会自己跟上。监管进程把它的文件放在 `tmp/cybertrain-dev/`；每个应用只运行一个，Ctrl-C 会停止构建、子进程和服务器。

预览看不到的东西：

- 代码能否编译。后台构建结束时会告诉你。
- [spikes/NOTES.md](../../spikes/NOTES.md) 中记录的运行时差异（异常的继承关系、套接字上 String 的编码、收窄后的 Float 上的 `Float#round` 等）。它们在二进制文件开始响应后才会出现。
- 时序和并发：CRuby 有 GVL 和操作系统线程，`SPINEL_WORKERS` 对它没有意义。

后台工作（作业、调度器、流的轮询器、WebSocket 订阅源）在正在响应的那个子进程中运行，所以一次编辑会让它们重启两次，先进入 CRuby，再进入二进制文件，Server-Sent Events 和 WebSocket 客户端也会重连两次。在预览中能用的页面，只有当二进制文件也能提供它时才算完成，并且只有编译后的测试（`spin test`）才算数。

`cybertrain server --spinel` 则运行编译版的循环，直接输入的 `spin run NAME` 和 `spin install` 构建的原生 CLI 也是如此：先 `SPIN_DEBUG=1 spin run gen`；若有 Ruby 文件比 `build/bin/NAME` 新，则运行 `spin build NAME -- --incremental`；再 `spin run NAME`。二进制文件自己每半秒轮询同样的文件，发生改动时在后台运行 `SPIN_DEBUG=1 spin run gen && spin build NAME -- --incremental`，成功后停止监听并等待进行中的请求完成，然后在同一端口和 PID 上 `execv` 新的二进制文件；构建失败时继续用旧的二进制文件提供服务，并在每个 HTML 响应上以横幅显示编译器输出，`cybertrain build` 持有它的锁期间会跳过重新构建。CLI 和这个循环以 spin 的调试模式（`SPIN_DEBUG=1`，`-O0`）构建 gen，CLI 还以同样的模式构建 `bin/db.rb`：它们只运行几毫秒，而 gen 的编译时间只是 `-O2` 时的一小部分；应用本身始终是发布构建。预览无法运行时，`cybertrain server` 会输出一行以 `preview unavailable:` 开头的信息，然后运行编译版的循环。这发生在以下情况：`CYBERTRAIN_ENV` 指定了 `development` 以外的环境；应用的框架比预览旧（缺少 `cybertrain/preview.rb` 或 `cybertrain/dev/supervision.rb`）；`PATH` 上没有 `ruby`；或者那个 `ruby` 无法启动、10 秒内没有响应、无法加载 `fiddle`（`cybertrain doctor` 会检查）。这些在生产环境中都不会加载。

## 与 Rails 的差异

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`、`rails dbconsole` | `./<app> console` 在模型上求值模板的表达式语言（Spinel 没有 `eval`，所以不是 Ruby）；`./<app> dbconsole` 打开 `sqlite3`（[控制台](background-and-operations.md#the-console)） |
| `config/application.rb` require 应用用到的 railtie | `bin/<app>.rb` 和 `bin/db.rb` require `cybertrain/core` 以及应用用到的[子系统](#subsystems)；`require "cybertrain"` 就是全部 |
| `rails runner`、`lib/tasks/*.rake` | 在 `bin/<app>.rb` 中写 `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` 会在连接好数据库的情况下运行它 |
| 修改代码，正在运行的应用会自动采用 | Ruby 的改动立即通过 CRuby 预览生效；构建完成后，编译好的二进制文件接管端口（`cybertrain server`） |
| 修改视图，无需重新加载 | 相同——开发时视图在每次请求时从磁盘解析 |
| `def new` | `def new_action`（`new` 会遮蔽 `Klass.new(ctx)`） |
| `before_action { do_thing }`（隐式的 `self`） | `before_action { \|c\| c.do_thing }`——无法对存储的块使用 `instance_exec`，所以回调显式接收控制器或记录 |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end`——嵌套块显式接收 mapper |
| ERB 编译为方法；任意对象、任意方法 | 按固定的语法和分派表解释执行（[模板语言](template-language.md)） |
| 会话可以保存任何序列化的对象 | 会话的值只能是 String，与 Rails 的 cookie store 一样存放在用 AES-256-GCM 加密的 cookie 中（[Cookie 与会话](requests.md#cookies-and-the-session)） |
| 多种数据库适配器 | 只有 SQLite，通过 FFI |
| `Article.transaction { ... }` 返回块的值；`raise ActiveRecord::Rollback`；`requires_new: true` 保存点 | `Article.transaction { \|c\| ... }` 把连接传给块并返回 nil；通过抛出异常退出；嵌套调用加入外层事务，没有保存点（[事务](models.md#transactions)） |
| `has_many :through`、枚举、STI、多态关联 | 未实现；`has_many`、`has_one` 和 `belongs_to` 来自外键或一行声明，支持 `dependent:`、`counter_cache:` 和一层 `includes`（[关联](models.md#associations)） |
| `pluck(:a)`、`maximum(:a)`、`group(:a).sum(:b)`、`upsert`、`update_counters`、`where(created_at: t1..t2)` | 带类型的版本，因为 Spinel 的方法只有一种返回类型：`pluck_int` 及其同类方法、`maximum_int`、`sum_float_by`、`upsert`、`increment(:col, by: n)`；Time 的范围写作 `where_between`（[超出 `where` 的查询](models.md#querying-beyond-where)） |
| 任意列名；关联可以遮蔽 `errors` | 只允许 ASCII 标识符；与框架方法或 Ruby 关键字同名的列会以 `<column>_column` 的名字生成，名称冲突的关联则以后备名称生成（[列名](models.md#column-names)） |
| `namespace`、`scope`、格式与 `respond_to` | 相同（[路由](requests.md#routing)、[格式](requests.md#formats-and-respond_to)）；JSON 用 `render json:` 返回（没有 jbuilder 模板） |
| `constraints`、`mount`、glob 段 | 未实现 |
| 在运行时包含的 `ActiveSupport::Concern` | `app/controllers/concerns` 和 `app/models/concerns` 中的 concern 由 `spin run gen` 展开到包含它们的类中；`include` 指向 concern，`class_methods` 的方法不能与实例方法同名（[Concern](requests.md#concerns-and-helper_method)） |
| `rescue StandardError` 能捕获出错的 `JSON.parse` | 在 Spinel 下 `JSON::ParserError` 不是 `StandardError`：应用代码必须写 `rescue JSON::ParserError, StandardError`。服务器会作为最后手段捕获它并返回 500 |
| API 控制器中的 `skip_forgery_protection` | CSRF 在路由之前运行，所以 API 按路径豁免，`c.csrf_exempt_prefixes = ["/api/"]`，并自行验证调用方的身份（[配置](configuration.md#configuration-and-environment-variables)） |
| Rack 对 gzip 压缩的请求体保持原样 | 以 `Content-Encoding: gzip` 发送的请求体通过 `request.decoded_body` 获取，在 10 MiB 的上限内解压；损坏或过大的请求体返回 400；`request.body` 仍然是发送时的原样（[查询字符串与请求体](requests.md#query-strings-and-bodies)） |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` 只接受 `column [ASC\|DESC]` 列表；请求数据要先经过允许列表，原始 SQL 则通过 `order_sql`（[排序](models.md#ordering)）。格式错误或嵌套过深的参数返回 400（[查询字符串与请求体](requests.md#query-strings-and-bodies)） |
| 异常时的完整回溯 | 类名、消息、请求行、模板名和行号——Spinel 不提供回溯 |
| Rack、它的中间件，以及 `Gemfile` 中的任意 gem | 不兼容 Rack；一小组固定的中间件；Spinel 自己的 `spin-index`，仅限能在其 Ruby 子集下编译的内容 |
| minitest / RSpec | Rails 风格的测试类（`ActiveSupport::TestCase`、`ActionDispatch::IntegrationTest`、`ViewComponent::TestCase`）和夹具，`spin run gen` 把它们改写成一个程序，由 `cybertrain test` 编译并运行；基于反射的运行器无法在提前编译下工作（[测试应用](testing.md)） |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` 写出同样的结构，外加一个注册页面；密码使用 PBKDF2-HMAC-SHA256（bcrypt 需要 C 库，而 macOS 上的 `String#crypt` 不支持它）；密码重置、确认、锁定和保持登录也会像 Devise 所增加的那样一并生成（[认证](authentication.md)） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment` 写出五个 `cover_*` 列和模型方法；文件保存在本地磁盘的 `storage/uploads/` 下，由 `send_blob` 提供；每个字段一个文件，没有变体，也没有直接上传（[添加封面图片](tutorial.md#attachments)） |
| `skip_before_action :x` | 相同，适用于有名称的 before 回调（块形式的回调没有可供跳过的名称）；没有 `skip_after_action` |
| `resource :session` | 同样是指向 `SessionsController` 的六条路由；不能在其下嵌套 |
| 先 `get "/x"` 再 `post "/x"` | 两者都可以：第二条路由推导出的名称已被占用，所以它没有名称，与 Rails 相同；重复的 `as:` 仍然是错误 |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport 自带的时区数据 | `Cybertrain::TimeZone.find("Asia/Tokyo")` 读取系统的 TZif 文件（`/usr/share/zoneinfo`，或 `TZDIR`），并转换 Integer 类型的纪元秒数（`utc_offset_at`、`utc_to_local`、`local_to_utc`）；`c.time_zone` 为整个应用设置 `Time.zone`，`in_time_zone` 返回带墙上时间字段的小值对象，Time 仍是 UTC 瞬间（没有 TimeWithZone，`time.hour` 是 UTC）（[时区](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | 用于 webhook 和 API 的 `Cybertrain::HttpClient`：每次等待都有上限，默认拒绝非公网目标，只在要求时跟随重定向，支持流式和 gzip 响应，带有 Server-Sent Events 解析器，不保持连接（参见[出站 HTTP](external-services.md#outbound-http)）；Spinel 的 `Net::HTTP` 遇到停滞的对端会阻塞整个服务器 |
| Action Mailer（`deliver_later`、邮件程序类、视图） | `Cybertrain::Mailer.deliver(to:, subject:, body:, html:)` 通过 SMTP 发送纯文本，或带有从局部模板渲染的 HTML 部分（`Views.render_mail`）的 `multipart/alternative`（STARTTLS、隐式 TLS，或对环回地址使用明文；AUTH PLAIN；每次等待都有上限）；`Mailer.deliver_later` 从一个内置作业发送；邮件程序是 `app/mailers` 中的模块，其方法返回 `Cybertrain::MailMessage`（`deliver_later`、`deliver_now`），生成的 `PasswordsMailer` 就是如此；没有附件（参见[发送电子邮件](external-services.md#sending-e-mail)） |
| Active Job、`perform_later`、`solid_queue`、周期性任务、Mission Control | `app/jobs` 中的作业类（`< Cybertrain::Job::Base`，`perform(args)` 接收由 JSON 值组成的 Hash，`perform_later`、`retry_on`、`discard_on`、带键的 `limits_concurrency`），`Job.handle(kind)` 作为简短形式；带时区和保存在数据库中的时间表的 `Scheduler.every` 与 `Scheduler.cron`；作业页面（路由中的 `jobs_page`）和 `./<app> jobs`；每个进程 `job_threads` 个线程，在服务器或 `./<app> worker` 进程中运行，至少投递一次（[后台任务](background-and-operations.md#background-work)） |
| `Rails.cache.fetch(key, expires_in:, race_condition_ttl:)` | 应用 SQLite 数据库中的 `Cybertrain::Cache.fetch`，选项相同；值是 String，其他类型用 `fetch_hash`、`fetch_array` 和 `fetch_int`；没有内存或 Redis 存储（[缓存存储](background-and-operations.md#the-cache-store)） |
| ActionCable 客户端、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` 在服务器运行期间保持订阅连接（重连、ping、静默检测）；`WebSocket::Client` 用于单个同步连接；仅限出站（[订阅 WebSocket 数据流](external-services.md#consuming-websocket-feeds)） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` 是一个 String 数组，按子串不区分大小写地匹配（不支持正则表达式或 lambda）；它作用于请求日志和开发时的错误页面（[过滤的参数](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（指向控制器的路由） | `GET /up` 是内置的，在静态文件、会话和路由器之前就作出响应，所以不会运行任何 `before_action`；它检查数据库、后台工作线程和 WebSocket 数据订阅，返回 `200 ok` 或 `503`（[运维](background-and-operations.md#operations-backups-vacuum-health-check)） |
| 用于备份的 `bin/rails db:...` 任务（没有内置） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`，权限 0600，重命名到位）和 `./<app> db vacuum` |
| Action Cable、`turbo_stream_from`、`broadcast_append_to` | 相同的辅助方法名称，基于签名的流，从一张 SQLite 表通过 Server-Sent Events 或 WebSocket 投递；没有频道类（[实时](realtime.md)） |
| Propshaft、importmap-rails | 相同的目录布局（`app/assets`、`app/javascript`、`vendor/javascript`、`config/importmap.rb`），由 `spin run gen` 加上摘要写入 `public/assets/`；没有 `bin/importmap pin`，不内置 Turbo（[资源](assets.md)） |
| Rails 的 i18n、rails-i18n 的词典、`I18n.t`、`t(".title")` | 相同的 API 和键，捆绑英语和日语；`config/locales/*.yml` 由 `spin run gen` 从一个 YAML 子集（没有锚点、别名或标签）编译进程序，列表通过 `I18n.translate_list` 获取（[国际化](i18n.md)） |

<!-- table-foot: 并不详尽：`docs/design.md` §8（“What was deliberately left out”）是更完整的记录。 -->
