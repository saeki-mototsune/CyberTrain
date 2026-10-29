---
source_sha256: 86d3de9f2a69e668c822f68426aaf998fd7dfe3208df6d317b7a332ae7542ce5
---
# 工作原理

**构建时代码生成。** `spin run gen`（`bin/gen.rb`）执行 `db/schema.rb` 的 `create_table` DSL 和 `config/routes.rb` 的 `Routes.draw` DSL，以获得表和路由的*数据*；另外，它还对 `app/controllers/**/*.rb` 和 `app/models/**/*.rb` 进行**词法扫描**（用正则表达式，而不是解析器——Spinel 在运行时不提供解析器），查找 `@ivar =` 赋值、`before_action`/`after_action`/`rescue_from ... with:` 的名称以及无参数的 `def`。据此，它在 `gen/` 下写出朴素、易读的 Ruby 代码：`gen/models/<name>.rb`（访问器、类型转换、查找方法、由外键推导出的关联）、`gen/routes.rb`（路由表、分派器、`*_path`/`*_url` 辅助方法）、`gen/controllers.rb`（每个控制器的 `view_assigns` 和 `run_callback`）、`gen/migrations.rb`、`gen/views.rb`（内嵌视图表，除非为部署而构建，否则为空）以及 `gen/app.rb`（`require_relative` 清单）。`gen/` 要提交，而不是加入 gitignore——`spin build`/`spin test` 没有先运行生成的钩子，所以签入的输出必须已经是可以编译的代码。CI 会重新运行 `spin run gen`，出现差异就失败，因此过时的生成代码无法合并。

**视图是解释执行的，而不是编译的。** `app/views/**/*.html.erb` 文件看起来像 Rails 的 ERB，但在请求时被解析为 AST，然后由一个遍历树的解释器执行。源代码来自哪里取决于模式：在开发（和测试）模式下，引擎从磁盘读取 `app/views/`，并且在开发模式下，模板改动后会重新解析，所以修改视图无需重新构建。`cybertrain build` 会运行 `spin run gen -- --embed-views`，为那一次 `spin
build` 把每个模板的源代码作为字符串表写入 `gen/views.rb`，然后再次运行 `spin run gen`，恢复已提交的空表；生产环境的二进制文件只渲染这张表（每个模板解析一次），表为空时拒绝启动（`error: views are not
embedded in this binary`）。Spinel 没有 `eval`，所以这是一套封闭的语法（字面量、`@ivar`/局部变量查找、通过按类型固定的分派表进行的调用、`if`/`unless`、`each`/`each_with_index`/单个辅助方法块），而不是真正的 Ruby。完整的语法、辅助方法和缺失功能：[docs/guide/template-language.md](template-language.md)。

**HTTP 服务器。** `Cybertrain::Server` 是纯 Ruby 实现的 HTTP/1.1：`TCPServer#accept` 加上每个连接一个 Spinel 绿色线程（M:N 调度，没有 GVL），带类型的 `Request`/`Response`，没有 Rack 层。它调用一个 `HttpHandler`（`call(request) -> Response`）；`ContextHandler` 把它与中间件栈连接起来，所以 HTTP 层（`cybertrain/http/`，以及 `Params` 和 `Logger`）不依赖框架的其他部分；`script/check-http-layer` 在 CI 中强制保证这一点。TLS/HTTP/2 交给反向代理处理。`SPINEL_WORKERS` 默认为 `1`——实验发现，对于这种 I/O 密集型、100 个并发连接的场景，这样更快且不会卡顿。

**通过 FFI 使用 SQLite。** 模型直接通过 Spinel 的 `ffi_func`/`ffi_lib` 与 SQLite 通信——没有 C 扩展，也没有 gem。一个连接池（`SizedQueue`，默认 4 个连接）分发连接，这些连接启用了 WAL、约五秒的忙等待超时（一个每 100 µs 重试一次的忙处理器，而 SQLite 的 `busy_timeout` 每次会休眠一毫秒或更久）、最多 64 条缓存的预编译语句，并开启了外键；每个查询都使用绑定参数，从不做字符串插值。这是目前唯一的适配器（通过 `libpq` FFI 支持 PostgreSQL 被记为未来可能的工作）。

**事务。** `Cybertrain::DB.transaction { |c| ... }`（或 `Article.transaction`，同一个东西换成 Rails 的名字）会取出一个连接，运行 `BEGIN`，把连接传给块，块返回时 `COMMIT`，块抛出异常时回滚并重新抛出。`immediate: true` 运行 `BEGIN IMMEDIATE`，它在开始时就获取 SQLite 的写锁：先读后写的事务应使用它，这样并发的写入者会让它在 `BEGIN` 处等待，而不是在第一次写入时以 “database is locked” 失败。块运行期间，该线程上所有经过连接池的操作（`save`、`update`、`destroy`、Relation 查询、`DB.with`）都使用事务的连接，因此都属于这个事务：

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

嵌套在块中的 `DB.transaction` 会加入外层事务（只有最外层提交；任何地方抛出异常都会回滚全部内容；没有保存点）。必须把 `rescue` 写在普通方法中的代码可以使用不带块的形式：`c.begin!(immediate: true)` ... `c.commit!`，并在 rescue 中调用 `c.rollback!`。它返回 nil 而不是块的值；在 `DB.with` 块（它不是事务）中调用的 `DB.transaction` 会取出第二个连接：在只有一个连接的连接池上（包括 `:memory:`），它会因此永远等待下去。请先开启事务，再在其中完成工作。

**开发循环。** 在 `development` 模式下（默认的 `CYBERTRAIN_ENV`，`cybertrain build` 构建的二进制文件除外），`cybertrain server`（先 `spin run gen`，再 `spin run NAME`）还会每半秒轮询一次 `app/**/*.rb`、`config/**/*.rb`、`db/schema.rb` 和 `gen/**/*.rb`（视图被排除在外——引擎会自己重新加载它们——`gen/views.rb` 也被排除，它在开发模式下为空）。发生改动时，会在后台运行 `spin run gen && spin build NAME -- --incremental`（Spinel 的增量构建，只重新编译这次编辑改动了的 C 单元；不支持 `--incremental` 的 Spinel 版本会拒绝这个参数，此时循环会不带它进行构建）；构建成功后会请求重启（与外部 `kill -HUP` 设置的是同一个标志）：一个监视线程停止监听并等待进行中的请求完成，然后主线程在同一端口和 PID 上 `execv` 新的二进制文件，会话进行中的客户端察觉不到。构建失败时继续用旧的二进制文件提供服务，并在每个 HTML 响应上以横幅显示编译器输出。这些在生产环境中都不会加载。


## 与 Rails 的差异

| Rails | cybertrain |
| --- | --- |
| `rails console` | 没有控制台——Spinel 没有 `eval` |
| `rails runner`、`lib/tasks/*.rake` | 在 `bin/<app>.rb` 中写 `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` 会在连接好数据库的情况下运行它 |
| 修改代码，正在运行的应用会自动采用 | Ruby 需要重新构建；开发时 `cybertrain server` 会替你完成（重新构建、停止、`execv`） |
| 修改视图，无需重新加载 | 相同——开发时视图在每次请求时从磁盘解析 |
| `def new` | `def new_action`（`new` 会遮蔽 `Klass.new(ctx)`） |
| `before_action { do_thing }`（隐式的 `self`） | `before_action { \|c\| c.do_thing }`——无法对存储的块使用 `instance_exec`，所以回调显式接收控制器或记录 |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end`——嵌套块显式接收 mapper |
| ERB 编译为方法；任意对象、任意方法 | 按固定的语法和分派表解释执行——[docs/guide/template-language.md](template-language.md) |
| 会话可以保存任何序列化的对象 | 会话的值只能是 String，存放在 HMAC 签名的 cookie 中 |
| 多种数据库适配器 | 只有 SQLite，通过 FFI |
| `Article.transaction { ... }` 返回块的值；`raise ActiveRecord::Rollback`；`requires_new: true` 保存点 | `Article.transaction { \|c\| ... }`（= `Cybertrain::DB.transaction`）把连接传给块并返回 nil；通过抛出异常退出（回滚后会重新抛出）；嵌套调用加入外层事务，没有保存点。`immediate: true` 对应 SQLite 的 `BEGIN IMMEDIATE`。在 Spinel 下不能对传入的 `c` 调用 `c.transaction { }`：请嵌套 `DB.transaction`，或使用 `c.begin!` / `c.commit!` / `c.rollback!` |
| `has_many :through`、`includes`、`dependent:`、枚举、STI、多态关联 | 未实现；关联只来自 schema 中的外键 |
| `pluck(:a)`、`sum(:a)`、`group(:a).count`、`upsert`、`update_counters`、`where("title LIKE ?", "%#{q}%")` | 带类型的单列版本，因为 Spinel 的方法只有一种返回类型：`pluck_str` / `pluck_int` / `pluck_float`（仅限一列）、`sum_int` / `sum_float`、`count_by(:a)`（一个 `Hash{String => Integer}`），表达式则用 `count_by_sql(expr)`；`Model.upsert(attrs, conflict:, update:)` 以 SQL 文本形式接收 `DO UPDATE SET` 表达式，不运行验证、回调，也不设置时间戳；`relation.increment(:col, by: n)`；`where_like(:col, text)` 会替你转义 `\`、`%` 和 `_`。参见[`where` 之外的查询](models.md#querying-beyond-where) |
| 任意列名；关联可以遮蔽 `errors` | 列名必须是 ASCII 标识符（`[A-Za-z_][A-Za-z0-9_]*`）：带有非 ASCII 列名（`名前`、`prénom`）的 schema 在 PR #10 之前可以在 CRuby 下生成，现在 `spin run gen` 会拒绝它，所以升级时请重命名该列（像 `first-name` 这样的名字从来都不是合法的方法名）。如果列名与生成的类或框架在记录上调用的方法同名（`errors`、`save`、`attributes`、`hash`、`to_s`、`to_ary`、`raise` 等），或与 Ruby 关键字同名（`end`、`class`、`begin`），就会以 `<column>_column` 的名字生成（`hash_column` 的读方法、写方法和实例变量），并在生成的文件中附上说明；它的 SQL 名称在 `read_attribute`、params 和 `attributes["hash"]` 中仍然有效，模板可以用任一名称访问它（`post.hash`、`post.hash_column`），但 `errors` 和 `to_param` 除外，模板会把它们解析为模型方法，所以在模板中要用 `post.errors_column`；查询 API（`where`、`order`、`find_by`）始终使用 SQL 列名（`Post.where(hash: 1)`），Ruby 名称只用于读写方法和模板。与 Object 的其他方法同名的列（`display`、`tap`、`methods`）以原名生成，并附上说明。`cybertrain generate scaffold` 会拒绝关键字和保留名称（否则它就得调用改过名的读方法），对会遮蔽方法的名称则接受并附上说明，与生成器一致。如果某个关联的普通名称已被某列、另一个关联或 `Model` 的方法占用，就会以后备名称生成，并在生成的文件中附上注释：`has_many` 用 `<table>_as_<column stem>`（`comments_as_article`），`belongs_to` 用 `<stem>_as_<column>`（`author_as_author_id`） |
| `namespace`、format/`respond_to`、`constraints`、`mount` | 未实现——扁平的名称，只有 `render json:` |
| `rescue StandardError` 能捕获出错的 `JSON.parse` | 在 Spinel 下 `JSON::ParserError` 不是 `StandardError`：应用代码必须写 `rescue JSON::ParserError, StandardError`。服务器会作为最后手段捕获它并返回 500 |
| API 控制器中的 `skip_forgery_protection` | CSRF 是在路由之前运行的中间件，所以 API 按路径豁免：在 `config/app.rb` 中写 `c.csrf_exempt_prefixes = ["/api/"]`。这样一来，控制器必须自己验证调用方的身份（请求头中的 API 密钥），并且任何使用会话验证身份的路由都不得落在该前缀之下 |
| Rack 对 gzip 压缩的请求体保持原样 | 以 `Content-Encoding: gzip` 发送的请求体（超过几 KB 的 SDK 或 API 客户端会这样做）通过 `request.decoded_body` 获取，它通过系统的 zlib 解压一次，输出有上限（默认 10 MiB；需要更多的端点传入自己的上限，`request.decoded_body(limit)`）：损坏的请求体或 gzip/identity 以外的编码会引发 `Cybertrain::BodyUndecodable`，解压后会超过上限的请求体会引发 `Cybertrain::BodyTooLarge`，两者都是 `QueryInvalid`，以 400 响应；`request.body` 仍然是发送时的原始字节 |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` 只接受 `column [ASC\|DESC]` 列表（每个列名都会加引号），遇到其他内容会抛出 `ArgumentError`（返回 500：这个字符串是开发者写的）；请求数据必须先经过允许列表，例如 `SORTS = { "title" => "title", "newest" => "created_at DESC" }` 和 `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`，因为格式正确的项仍可能指向不存在的列（SQLite 返回 500），或客户端不应据以排序的列；原始的 ORDER BY 文本要通过 `order_sql`（`Post.order_sql("lower(title)")`，relation 上也有），它绝不能接触请求数据。`delete_all` 上的 `limit`/`offset` 会被遵守（通过子查询），请求参数最多嵌套 32 层、4096 对（超过则返回 400）。遇到格式错误的百分号转义时，`Query.parse`、`Query.value_of`、`Query.decode` 以及 `request.form_value` / `query_value` 会在两种运行时上都抛出 `Cybertrain::QueryMalformed`（`Cybertrain::QueryInvalid` 之下的一个 `StandardError`，而不是 `ArgumentError`）（`Cookies.parse` 仍然保留原始值）。遇到无效的 UTF-8 字节序列时，无论是原始字节（不管 String 带什么编码标记）还是百分号编码的，它们也会抛出这个异常（Rails 同样会对参数编码无效的请求返回 400）；只有加上转义才能补全的原始字节（`a=\xC3%A9`）也是如此；`Cookies.parse` 会原样保留这样的值，带有无效序列的路径（原始的，或某个路径段经百分号解码后出现的）同样返回 400（`request.path_segments`；路径中格式错误的转义保持原样，因匹配不到而返回 404）。原先在它们外面 rescue `ArgumentError` 的应用代码应改为 rescue `Cybertrain::QueryInvalid`（升级说明）。请求本身不保存参数树（路由器构建 `params`，中间件只读取一个键）；需要完整参数树的应用自己解析，`Query.parse(request.utf8_query_string)`，并自行管理结果 |
| 异常时的完整回溯 | 类名、消息、请求行、模板名和行号——Spinel 不提供回溯 |
| Rack、它的中间件，以及 `Gemfile` 中的任意 gem | 不兼容 Rack；一小组固定的中间件；Spinel 自己的 `spin-index`，仅限能在其 Ruby 子集下编译的内容 |
| minitest / RSpec | `Cybertrain::Test`——基于反射的运行器无法在提前编译下工作 |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` 写出同样的结构（User、Session、SessionsController、before_action），外加一个注册页面，因为没有可以用来创建用户的控制台；`has_secure_password` 被写成 User 模型上基于 `Cybertrain::Password` 的方法（用 Ruby 实现的 PBKDF2-HMAC-SHA256：bcrypt 需要让二进制链接一个 C 库，而 macOS 上的 `String#crypt` 不支持 bcrypt）。没有密码重置（其邮件需要应用为 `Cybertrain::Mailer` 提供的 SMTP 设置，参见[发送电子邮件](external-services.md#sending-e-mail)）；登录尝试由 `rate_limit` 限制（按进程计数；参见[限流](requests.md#rate-limiting-and-the-client-address)） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment post cover` 在所属表上写出五个 `cover_*` 列，并把模型方法（`cover_file=`、`cover_url` 等）写进应用；文件存放在磁盘上的 `storage/uploads/` 下，由一个生成的动作通过 `send_blob` 提供。每个字段一个文件，仅限本地磁盘，没有变体，也没有直接上传 |
| `skip_before_action :x` | 相同，适用于有名称的 before 回调（块形式的回调没有可供跳过的名称）；没有 `skip_after_action` |
| `resource :session` | 同样是指向 `SessionsController` 的六条路由；不能在其下嵌套 |
| 先 `get "/x"` 再 `post "/x"` | 两者都可以：第二条路由推导出的名称已被占用，所以它没有名称，与 Rails 相同；重复的 `as:` 仍然是错误 |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport 自带的时区数据 | `Cybertrain::TimeZone.find("Asia/Tokyo")` 读取系统的 TZif 文件（`/usr/share/zoneinfo`，或 `TZDIR`），并转换 Integer 类型的纪元秒数（`utc_offset_at`、`utc_to_local`、`local_to_utc`）；暂时没有按请求设置的 `Time.zone`，也没有 `l(time, zone:)`（[时区](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | 用于 webhook 和 API 的 `Cybertrain::HttpClient`：每次等待都有上限，默认拒绝非公网目标，不跟随重定向，也不保持连接（参见[出站 HTTP](external-services.md#outbound-http)）；Spinel 的 `Net::HTTP` 遇到停滞的对端会阻塞整个服务器 |
| Action Mailer（`deliver_later`、邮件程序类、视图） | `Cybertrain::Mailer.deliver(to:, subject:, body:)` 通过 SMTP 发送纯文本（STARTTLS、隐式 TLS，或对环回地址使用明文；AUTH PLAIN；每次等待都有上限）；没有模板、HTML、附件或队列（参见[发送电子邮件](external-services.md#sending-e-mail)） |
| Active Job、`perform_later`、`solid_queue`、周期性任务 | `Cybertrain::Job.handle(kind) { \|payload\| ... }` 和 `Job.enqueue(kind, payload, run_at:)`（String 类型的负载存放在 `cybertrain_jobs` 表中，按退避策略重试，之后标记为 `failed`），`Cybertrain::Scheduler.every(seconds, name) { ... }`；在提供服务的进程中运行一个线程，其他地方用 `CYBERTRAIN_WORKER=0`（[后台任务](background-and-operations.md#background-work)） |
| ActionCable 客户端、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url).on_message { \|conn, data\| ... }` 在服务器运行期间保持订阅连接（重连、ping、静默检测），`Cybertrain::WebSocket::Client` 用于单个同步连接；仅限出站，每次等待都有上限（参见[订阅 WebSocket 数据流](external-services.md#consuming-websocket-feeds)） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` 是一个 String 数组，按子串不区分大小写地匹配（不支持正则表达式或 lambda）；它作用于请求日志和开发时的错误页面（[过滤的参数](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（指向控制器的路由） | `GET /up` 是内置的，在静态文件、会话和路由器之前就作出响应，所以不会运行任何 `before_action`；它查询数据库和后台工作线程的最后一次心跳，返回 `200 ok` 或 `503`（[运维](background-and-operations.md#operations-backups-vacuum-health-check)） |
| 用于备份的 `bin/rails db:...` 任务（没有内置） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`，权限 0600，重命名到位）和 `./<app> db vacuum` |
| ActionCable（服务器端）、资源管道、i18n | 未构建（不在 MVP 范围内，`docs/design.md` §2.3） |

以上并不详尽——`docs/design.md` §8（“What was deliberately left out”）是更完整的记录。

## 性能

[docs/benchmark.md](../benchmark.md) 把 examples/blog 与用 Rails 8.1 编写的同一个博客 [bench/rails_blog](../../bench/rails_blog)（相同的视图、路由、模型和 schema）进行对比，两者都在生产模式下运行，每个服务器都固定在同一台 4 vCPU 云虚拟机的相同 CPU 核心上，并由另外两台机器上的 wrk 施加负载。三次 10 秒运行的中位数，记录于 2026-10-09：

| 1 个 CPU 核心，16 个连接 | CyberTrain 0.2.1 | Rails 8.1.4（YJIT、Puma） | |
| --- | --: | --: | --: |
| `GET /articles`（30 篇文章） | 2,641 req/s | 468 req/s | 5.6x |
| `GET /articles/1`（10 条评论、12 个表单） | 2,450 req/s | 201 req/s | 12.2x |
| `POST /articles/2/comments` | 1,507 req/s | 390 req/s | 3.9x |
| `GET /style.css` | 13,300 req/s | 5,127 req/s | 2.6x |
| 负载后的内存（RSS） | 10.6 MB | 126 MB | |
| 从启动到第一个响应 | 0.02 s | 1.3 s | |
| 服务器需要的东西 | 2.5 MB（一个二进制文件） | 109 MB（Ruby、69 个 gem、应用） | |

两者都使用 jemalloc 时（spin.toml 中的 `allocator = "jemalloc"`；Rails 的生产镜像会预加载它），倍数为 2.8 到 14.6。在两个核心上，领先幅度缩小到 2.0 到 5.5：第二个 Puma 工作进程让 Rails 的吞吐翻倍，而 `SPINEL_WORKERS=2` 让 CyberTrain 提升 9% 到 58%（在多核服务器上请把它设为核心数；默认为 1）。二进制文件也需要构建（在那台机器上 `cybertrain build` 大约用了三分钟）。docs/benchmark.md 包含延迟、每种配置、测量方法，以及为达到这一结果做了哪些优化；`bench/run` 会重复这次测量，`bench/report` 会打印其中的表格。
