---
description: CyberTrain 应用如何构建和运行（构建时代码生成、解释执行的视图、HTTP 服务器、通过 FFI 使用 SQLite、开发循环），以及与 Rails 的差异。
source_sha256: e51e959017a031fc0c47aaef26b3c057773c2dc7b94c1fd7c634dd77767f06f2
---
# 工作原理

本页说明 CyberTrain 应用如何构建和运行：构建时生成的代码、请求时解释执行的视图、HTTP 服务器、通过 FFI 使用 SQLite 以及开发循环，然后是一张与 Rails 的差异表。首页的[性能一节](site:index.html#performance)把结果与用 Rails 8.1 编写的同一个博客作了对比。测量方法、全部数字以及如何重新测量，见 [docs/benchmark.md](../benchmark.md)。

## 构建时代码生成

`spin run gen`（`bin/gen.rb`）执行 `db/schema.rb` 的 `create_table` DSL 和 `config/routes.rb` 的 `Routes.draw` DSL，以获得表和路由的*数据*。另外，它还对 `app/controllers/**/*.rb` 和 `app/models/**/*.rb` 进行**词法扫描**（用正则表达式，而不是解析器——Spinel 在运行时不提供解析器），查找 `@ivar =` 赋值、`before_action`/`after_action`/`rescue_from ... with:` 的名称以及无参数的 `def`。

据此，它在 `gen/` 下写出朴素、易读的 Ruby 代码：

- `gen/models/<name>.rb`：访问器、类型转换、查找方法、由外键推导出的关联；
- `gen/routes.rb`：路由表、分派器、`*_path`/`*_url` 辅助方法；
- `gen/controllers.rb`：每个控制器的 `view_assigns` 和 `run_callback`；
- `gen/migrations.rb`；
- `gen/views.rb`：内嵌视图表，除非为部署而构建，否则为空；
- `gen/app.rb`：`require_relative` 清单。

`gen/` 要提交，而不是加入 gitignore：`spin build`/`spin test` 没有先运行生成的钩子，所以签入的输出必须已经是可以编译的代码。CI 会重新运行 `spin run gen`，出现差异就失败，因此过时的生成代码无法合并。

## 视图是解释执行的

`app/views/**/*.html.erb` 文件看起来像 Rails 的 ERB，但在请求时被解析为 AST，然后由一个遍历树的解释器执行。Spinel 没有 `eval`，所以这是一套封闭的语法（字面量、`@ivar`/局部变量查找、通过按类型固定的分派表进行的调用、`if`/`unless`、`each`/`each_with_index`/单个辅助方法块），而不是真正的 Ruby。完整的语法、辅助方法和缺失功能见[模板语言参考](template-language.md)。

源代码来自哪里取决于模式：

- 在开发（和测试）模式下，引擎从磁盘读取 `app/views/`，并且在开发模式下，模板改动后会重新解析，所以修改视图无需重新构建。
- `cybertrain build` 会运行 `spin run gen -- --embed-views`，为那一次 `spin build` 把每个模板的源代码作为字符串表写入 `gen/views.rb`，然后再次运行 `spin run gen`，恢复已提交的空表。
- 生产环境的二进制文件只渲染这张表（每个模板解析一次），表为空时拒绝启动（`error: views are not embedded in this binary`）。

## HTTP 服务器

`Cybertrain::Server` 是纯 Ruby 实现的 HTTP/1.1：`TCPServer#accept` 加上每个连接一个 Spinel 绿色线程（M:N 调度，没有 GVL），带类型的 `Request`/`Response`，没有 Rack 层。TLS/HTTP/2 交给反向代理处理。`SPINEL_WORKERS` 默认为 `1`——实验发现，对于这种 I/O 密集型、100 个并发连接的场景，这样更快且不会卡顿。

服务器调用一个 `HttpHandler`（`call(request) -> Response`）；`ContextHandler` 把它与中间件栈连接起来，所以 HTTP 层（`cybertrain/http/`，以及 `Params` 和 `Logger`）不依赖框架的其他部分；`script/check-http-layer` 在 CI 中强制保证这一点。

## 通过 FFI 使用 SQLite

模型直接通过 Spinel 的 `ffi_func`/`ffi_lib` 与 SQLite 通信——没有 C 扩展，也没有 gem。每个查询都使用绑定参数，从不做字符串插值。这是目前唯一的适配器（通过 `libpq` FFI 支持 PostgreSQL 被记为未来可能的工作）。

一个连接池（`SizedQueue`，默认 4 个连接）分发连接，这些连接带有：

- WAL；
- 约五秒的忙等待超时（一个每 100 µs 重试一次的忙处理器，而 SQLite 的 `busy_timeout` 每次会休眠一毫秒或更久）；
- 最多 64 条缓存的预编译语句；
- 开启的外键。

事务如何取出其中一个连接，以及在它上面运行什么：[事务](models.md#transactions)。

## 开发循环

在 `development` 模式下（默认的 `CYBERTRAIN_ENV`，`cybertrain build` 构建的二进制文件除外），`cybertrain server`（先 `spin run gen`，再 `spin run NAME`）还会每半秒轮询一次 `app/**/*.rb`、`config/**/*.rb`、`db/schema.rb` 和 `gen/**/*.rb`。视图被排除在外（引擎会自己重新加载它们），`gen/views.rb` 也被排除，它在开发模式下为空。

发生改动时，会在后台运行 `spin run gen && spin build NAME -- --incremental`：Spinel 的增量构建，只重新编译这次编辑改动了的 C 单元。不支持 `--incremental` 的 Spinel 版本会拒绝这个参数，此时循环会不带它进行构建。

构建成功后会请求重启（与外部 `kill -HUP` 设置的是同一个标志）：一个监视线程停止监听并等待进行中的请求完成，然后主线程在同一端口和 PID 上 `execv` 新的二进制文件，会话进行中的客户端察觉不到。构建失败时继续用旧的二进制文件提供服务，并在每个 HTML 响应上以横幅显示编译器输出。`cybertrain build` 持有 `tmp/cybertrain-build.lock` 期间会跳过重新构建。这些在生产环境中都不会加载。

## 与 Rails 的差异

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console` | 没有控制台——Spinel 没有 `eval` |
| `rails runner`、`lib/tasks/*.rake` | 在 `bin/<app>.rb` 中写 `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` 会在连接好数据库的情况下运行它 |
| 修改代码，正在运行的应用会自动采用 | Ruby 需要重新构建；开发时 `cybertrain server` 会替你完成（重新构建、停止、`execv`） |
| 修改视图，无需重新加载 | 相同——开发时视图在每次请求时从磁盘解析 |
| `def new` | `def new_action`（`new` 会遮蔽 `Klass.new(ctx)`） |
| `before_action { do_thing }`（隐式的 `self`） | `before_action { \|c\| c.do_thing }`——无法对存储的块使用 `instance_exec`，所以回调显式接收控制器或记录 |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end`——嵌套块显式接收 mapper |
| ERB 编译为方法；任意对象、任意方法 | 按固定的语法和分派表解释执行（[模板语言](template-language.md)） |
| 会话可以保存任何序列化的对象 | 会话的值只能是 String，存放在 HMAC 签名的 cookie 中 |
| 多种数据库适配器 | 只有 SQLite，通过 FFI |
| `Article.transaction { ... }` 返回块的值；`raise ActiveRecord::Rollback`；`requires_new: true` 保存点 | `Article.transaction { \|c\| ... }` 把连接传给块并返回 nil；通过抛出异常退出；嵌套调用加入外层事务，没有保存点（[事务](models.md#transactions)） |
| `has_many :through`、`includes`、`dependent:`、枚举、STI、多态关联 | 未实现；关联只来自 schema 中的外键 |
| `pluck(:a)`、`sum(:a)`、`group(:a).count`、`upsert`、`update_counters`、`where("title LIKE ?", "%#{q}%")` | 带类型的版本，因为 Spinel 的方法只有一种返回类型：`pluck_int` 及其同类方法、`sum_int`、`count_by`、`upsert`、`increment(:col, by: n)`、`where_like`（[`where` 之外的查询](models.md#querying-beyond-where)） |
| 任意列名；关联可以遮蔽 `errors` | 只允许 ASCII 标识符；与框架方法或 Ruby 关键字同名的列会以 `<column>_column` 的名字生成，名称冲突的关联则以后备名称生成（[列名](models.md#column-names)） |
| `namespace`、format/`respond_to`、`constraints`、`mount` | 未实现——扁平的名称，只有 `render json:` |
| `rescue StandardError` 能捕获出错的 `JSON.parse` | 在 Spinel 下 `JSON::ParserError` 不是 `StandardError`：应用代码必须写 `rescue JSON::ParserError, StandardError`。服务器会作为最后手段捕获它并返回 500 |
| API 控制器中的 `skip_forgery_protection` | CSRF 在路由之前运行，所以 API 按路径豁免，`c.csrf_exempt_prefixes = ["/api/"]`，并自行验证调用方的身份（[配置](configuration.md#configuration-and-environment-variables)） |
| Rack 对 gzip 压缩的请求体保持原样 | 以 `Content-Encoding: gzip` 发送的请求体通过 `request.decoded_body` 获取，在 10 MiB 的上限内解压；损坏或过大的请求体返回 400；`request.body` 仍然是发送时的原样（[查询字符串与请求体](requests.md#query-strings-and-bodies)） |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` 只接受 `column [ASC\|DESC]` 列表；请求数据要先经过允许列表，原始 SQL 则通过 `order_sql`（[排序](models.md#ordering)）。格式错误或嵌套过深的参数返回 400（[查询字符串与请求体](requests.md#query-strings-and-bodies)） |
| 异常时的完整回溯 | 类名、消息、请求行、模板名和行号——Spinel 不提供回溯 |
| Rack、它的中间件，以及 `Gemfile` 中的任意 gem | 不兼容 Rack；一小组固定的中间件；Spinel 自己的 `spin-index`，仅限能在其 Ruby 子集下编译的内容 |
| minitest / RSpec | `Cybertrain::Test`——基于反射的运行器无法在提前编译下工作 |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` 写出同样的结构，外加一个注册页面；密码使用 PBKDF2-HMAC-SHA256（bcrypt 需要 C 库，而 macOS 上的 `String#crypt` 不支持它）；没有密码重置（[添加登录](tutorial.md#authentication)） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment` 写出五个 `cover_*` 列和模型方法；文件保存在本地磁盘的 `storage/uploads/` 下，由 `send_blob` 提供；每个字段一个文件，没有变体，也没有直接上传（[添加封面图片](tutorial.md#attachments)） |
| `skip_before_action :x` | 相同，适用于有名称的 before 回调（块形式的回调没有可供跳过的名称）；没有 `skip_after_action` |
| `resource :session` | 同样是指向 `SessionsController` 的六条路由；不能在其下嵌套 |
| 先 `get "/x"` 再 `post "/x"` | 两者都可以：第二条路由推导出的名称已被占用，所以它没有名称，与 Rails 相同；重复的 `as:` 仍然是错误 |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport 自带的时区数据 | `Cybertrain::TimeZone.find("Asia/Tokyo")` 读取系统的 TZif 文件（`/usr/share/zoneinfo`，或 `TZDIR`），并转换 Integer 类型的纪元秒数（`utc_offset_at`、`utc_to_local`、`local_to_utc`）；暂时没有按请求设置的 `Time.zone`，也没有 `l(time, zone:)`（[时区](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | 用于 webhook 和 API 的 `Cybertrain::HttpClient`：每次等待都有上限，默认拒绝非公网目标，不跟随重定向，也不保持连接（参见[出站 HTTP](external-services.md#outbound-http)）；Spinel 的 `Net::HTTP` 遇到停滞的对端会阻塞整个服务器 |
| Action Mailer（`deliver_later`、邮件程序类、视图） | `Cybertrain::Mailer.deliver(to:, subject:, body:)` 通过 SMTP 发送纯文本（STARTTLS、隐式 TLS，或对环回地址使用明文；AUTH PLAIN；每次等待都有上限）；没有模板、HTML、附件或队列（参见[发送电子邮件](external-services.md#sending-e-mail)） |
| Active Job、`perform_later`、`solid_queue`、周期性任务 | `Cybertrain::Job.handle(kind)` 和 `Job.enqueue(kind, payload, run_at:)`（String 类型的负载，按退避策略重试），`Cybertrain::Scheduler.every(seconds, name)`；在提供服务的进程中运行一个线程（[后台任务](background-and-operations.md#background-work)） |
| ActionCable 客户端、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` 在服务器运行期间保持订阅连接（重连、ping、静默检测）；`WebSocket::Client` 用于单个同步连接；仅限出站（[订阅 WebSocket 数据流](external-services.md#consuming-websocket-feeds)） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` 是一个 String 数组，按子串不区分大小写地匹配（不支持正则表达式或 lambda）；它作用于请求日志和开发时的错误页面（[过滤的参数](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（指向控制器的路由） | `GET /up` 是内置的，在静态文件、会话和路由器之前就作出响应，所以不会运行任何 `before_action`；它检查数据库和后台工作线程，返回 `200 ok` 或 `503`（[运维](background-and-operations.md#operations-backups-vacuum-health-check)） |
| 用于备份的 `bin/rails db:...` 任务（没有内置） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`，权限 0600，重命名到位）和 `./<app> db vacuum` |
| ActionCable（服务器端）、资源管道、i18n | 未构建（不在 MVP 范围内，`docs/design.md` §2.3） |

<!-- table-foot: 并不详尽：`docs/design.md` §8（“What was deliberately left out”）是更完整的记录。 -->
