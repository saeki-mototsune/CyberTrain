---
source_sha256: 73e63b06a3c0e42694f5489b74b58f65464e506bfc88c1ba18759c91bd5771dd
---
# 配置

## 配置与环境变量

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

`Cybertrain::Config` 先读取环境变量；`config/app.rb` 中的设置会覆盖它们：

| 变量 | 属性 | 默认值 |
| --- | --- | --- |
| `CYBERTRAIN_ENV` | `env` | `"development"`；在 `cybertrain build` 构建的二进制文件中为 `"production"`（还有 `"test"`） |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | 生产环境中必需；开发和测试环境会自动生成一个，写入 `tmp/secret_key` |
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`；`0.0.0.0` 在所有网络接口上监听（容器） |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | 开发环境接受 `localhost`、`127.0.0.1`、`[::1]`；以逗号分隔的精确主机名会扩展这个列表（不带协议、端口或通配符）。其他主机会在静态文件、会话、路由或诊断之前得到 403。这与监听地址无关；生产和测试环境不应用这项开发时的防护 |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`；也可以是 `Strict` 或 `None`（`None` 总会加上 `Secure`）；其他任何值都会让服务器在启动时停止 |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`；`1` 或 `true` 会加上 `Partitioned`（以及 `Secure`） |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`；`1` 或 `true` 会让来自环回地址的连接的 `request.client_ip`（`rate_limit` 所计数的对象）取 `X-Forwarded-For` 中的最后一个地址，用于同一主机上的反向代理（参见[限流](requests.md#rate-limiting-and-the-client-address)）；是 `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` 的简写 |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`；以逗号分隔的 IPv4/IPv6 地址或 CIDR（`172.16.0.0/12,10.0.0.0/8`），来自这些地址的连接的 `request.client_ip` 取自 `X-Forwarded-For` 中的最后一个地址，用于通过网络访问的代理，例如运行在自己容器中的 kamal-proxy；无效的条目会让服务器在启动时停止 |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`：`params.page_number` 给出、`Relation#page` 接受的最大页码（参见[分页](models.md#pagination)）；不是最多 18 位的数字或小于 1 的值按默认值处理 |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`；以逗号分隔的名称会替换这个列表。名称中包含其中任一项的参数（按 ASCII 不区分大小写：`password` 也匹配 `user[password]`），其值在请求日志和开发时的错误页面上会写成 `[FILTERED]`；在 `config/app.rb` 中设为 `[]` 可关闭此功能 |
| `CYBERTRAIN_WORKER` | `worker` | `true`；`0` 或 `false` 会让这个进程不运行定时任务和作业（参见[后台任务](background-and-operations.md#background-work)）；`scheduler_interval`（1 秒）、`job_poll_interval`（5 秒）和 `job_max_attempts`（5）在 `config/app.rb` 中设置 |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`；内置健康检查的路径（参见[运维](background-and-operations.md#operations-backups-vacuum-health-check)）；空值会关闭它；不以 `/` 开头的值会让服务器在启动时停止。`health_worker_stale`（300 秒）在 `config/app.rb` 中设置 |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`；`1` 或 `true` 允许 `Cybertrain::HttpClient` 连接环回地址、私有地址和其他非公网地址（参见[出站 HTTP](external-services.md#outbound-http)） |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`；`Cybertrain::Mailer` 用来发送邮件的 SMTP 服务器（参见[发送电子邮件](external-services.md#sending-e-mail)） |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`：使用所选模式的端口，`starttls` 为 587，`tls` 为 465，`none` 为 25；1 到 65535 以外的任何值都视为 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`：不使用 AUTH；设置后，邮件程序使用 AUTH PLAIN 进行身份验证 |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`；属于机密，从不写入日志，也从不出现在启动横幅或错误消息中 |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`：未给出 `from:` 时 `Mailer.deliver` 使用的发件人 |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`；也可以是 `tls`（隐式 TLS）或 `none`（明文，凭据只发往环回地址）；两种 TLS 模式都需要 `require "cybertrain/net/tls"` |

只有在应用显示于另一个网站的框架内时，才使用 `None`（配合 `CYBERTRAIN_SESSION_PARTITIONED=1`）；浏览器必须通过 HTTPS 访问应用。

其他带有固定且可覆盖默认值的属性：`views_root`（`"app/views"`）、`public_root`（`"public"`）、`layout`（`"layouts/application"`）、`log_level`（`:info`）、`session_cookie_name`、`session_max_age`（两周）、`session_secure`（生产环境中为 `true`，会把会话 cookie 标记为 `Secure`；其他环境中为 `false`，不过 `SameSite=None` 和 `Partitioned` 无论如何都会加上 `Secure`）、`pool_size`（4）、`static_files`/`csrf`（`true`）、`csrf_exempt_prefixes`（`[]`：路径前缀，例如 `"/api/"`，其下的非 GET 请求跳过 CSRF 检查，用于由程序携带自己的凭据调用的端点；每个前缀都必须以 `/` 开头和结尾，且不能只是 `/`，否则启动失败；前缀与发送时的路径进行匹配，所以百分号编码的写法仍会被检查；任何其他路由都不得匹配该前缀下的路径，并且被豁免的控制器不得依赖会话进行身份验证，因为那里仍然会加载会话）、`max_body_bytes`（10 MiB：发送时长度超过此值的请求体，会在读取之前以 413 响应；需要上传大文件时请调高它；gzip 请求体解压后的大小由 `request.decoded_body(limit)` 另行限制）、`max_render_depth`（同时打开的渲染最多 12 层：页面及其局部模板；局部模板确实需要更深的递归时请调高它；它必须至少为 1，否则启动失败）。升级说明：渲染嵌套以前没有限制，现在默认上限为 12（页面是第 1 层，所以局部模板可以嵌套 11 层；布局在页面之后渲染，不算嵌套），树更深的应用（分层评论、分类菜单）在设置 `max_render_depth` 之前会得到模板错误。文件上传：`max_upload_bytes`（每个上传文件 5 MiB；不得超过 `max_body_bytes`）、`max_multipart_parts`（128 个部分，包括文本字段，最多 4096）、`upload_root`（`"storage/uploads"`，`Cybertrain::BlobStore` 写入的位置；在第一次上传时创建，而不是在启动时）。

**安全响应头**：服务器写出的每个响应（动作、静态文件中间件、错误页面和开发时的诊断页面、服务器自己的 400/411/413/500，以及 HEAD）都带有 `X-Content-Type-Options: nosniff` 和 `X-Frame-Options: SAMEORIGIN`，除非响应已经设置了同名的响应头（不区分大小写）：`Response#to_http` 在响应自己的响应头之后添加它们，并且只在缺失时添加，所以在动作中写 `response.set_header("X-Frame-Options", "DENY")` 会恰好发送一次你设置的值。刻意没有在全应用范围内关闭它们的 `Config` 开关；可嵌入的小部件在自己的响应上覆盖该响应头（在当前的浏览器中，`Content-Security-Policy: frame-ancestors ...` 响应头优先于 `X-Frame-Options`）。由于 `nosniff`，浏览器会按字面理解 `Content-Type`：静态文件中间件认识 `public/` 中常见的扩展名（html、css、js/mjs、包括 webp 和 avif 在内的图片、字体、wasm、pdf、音频和视频、json、csv、xml），其他任何文件都以 `application/octet-stream` 提供，即作为下载；如果应用需要内联显示其他类型，请把扩展名加入 `Cybertrain::Static::EXTENSIONS`。自己提供 `public/` 的反向代理会绕过这些响应头（参见 [docs/deploy.en.md](../deploy.en.md)）。`Cybertrain::Test::Client` 在进程内调用应用，从不序列化响应，所以看不到这两个默认响应头；请在 `response.to_http` 上断言它们。

**过滤的参数**：请求日志中的 `Started GET "/login?..."` 行和开发时的错误页面（其中的请求行，以及它转储的 params 和 JSON 请求体）会把 `config.filter_parameters` 中所列名称的每个参数的值显示为 `[FILTERED]`，与 Rails 的 `filter_parameters` 一样，所以 URL 中的 `?token=` 或提交到失败表单的密码不会出现在框架的请求日志或开发时的错误页面上。只替换值：查询字符串的其余部分按发送时的原样记录（控制字符会被转义）。该列表按子串、不区分大小写地匹配；可以在 `config/app.rb` 中扩展它（`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`），或用 `CYBERTRAIN_FILTER_PARAMETERS` 替换它。动作自己写入日志的值不会被过滤；在那里请调用 `Cybertrain::ParameterFilter.filter?(name)` 或 `ParameterFilter.filter_query(text)`。

**部署**：`cybertrain build` 生成 `dist/`：嵌入了视图的二进制文件 `dist/NAME`、`dist/public/`（静态资源，也可以交给反向代理提供），以及 `dist/storage/`（默认存放 SQLite 文件）和 `dist/tmp/`。在设置了 `CYBERTRAIN_SECRET_KEY_BASE` 的情况下从 `dist/` 运行它；除非 `CYBERTRAIN_ENV` 另有指定，它运行在生产环境中，`./NAME
migrate` 会执行编译进其中的迁移。二进制文件只支持纯 HTTP/1.1；请在前面放置 nginx/Caddy 来提供 TLS 和 HTTP/2（会话 cookie 在生产环境中为 `Secure`，所以要通过 HTTPS 提供服务）。在生产环境中，异常会以 500 响应，而简单的错误响应（路由器的纯文本 404、`head :not_found`、`render plain:`）在 `public/<status>.html` 文件存在时会被它替换；动作以 HTML 或 JSON 渲染的错误则原样通过。`SIGTERM` 会停止接受新连接，让已在处理中的请求完成（以 `Connection: close` 响应；空闲的 keep-alive 连接会立即关闭），并在它们完成后、或在服务器的 `drain_timeout`（10 秒）之后退出。监视和重新构建循环在生产环境中从不运行。[docs/deploy.en.md](../deploy.en.md)（日文版：[docs/deploy.md](../deploy.md)）从头到尾演示了整个过程：`cybertrain new`、Ubuntu 服务器、systemd、带 HTTPS 的 Caddy、重新部署、回滚和备份。

**Kamal**：`cybertrain new` 还会写出 [Kamal 2](https://kamal-deploy.org) 所需的内容：一个 `Dockerfile`，它在 Ubuntu 构建阶段运行 `cybertrain setup` 和 `cybertrain build`，并把 `dist/` 复制到同一发行版的精简阶段中（启动时执行迁移，然后在 `0.0.0.0:3000` 上提供服务）；一个 `.dockerignore`；`config/deploy.yml`（前面是带 Let's Encrypt 的 kamal-proxy，健康检查使用 `public/up.html`，SQLite 文件放在挂载于 `/app/storage` 的卷上）；以及 `.kamal/secrets`（从环境中读取 `KAMAL_REGISTRY_PASSWORD` 和 `CYBERTRAIN_SECRET_KEY_BASE`）。填写标有 `CHANGE ME` 的值，提交，然后运行 `kamal setup`；[docs/deploy-kamal.md](../deploy-kamal.md) 中有详细说明（部署教程的第 8 部分）。[examples/blog](../../examples/blog#deploying-with-kamal) 也带有同样的设置，基于本检出中的框架构建。

### 应用设置

应用自己的设置（公开的基础 URL、功能开关、时间间隔、SMTP 主机）在同一个 `Config` 上声明，带有类型、环境变量和默认值：

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
  c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
  c.setting_bool :worker, env: "MYAPP_WORKER", default: true
  c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
end

Cybertrain.config.string_setting(:base_url)
Cybertrain.config.bool_setting(:worker)
Cybertrain.config.int_setting(:prune_interval)
```

每个值只在启动时运行 `config/app.rb` 时读取一次。变量为空或未设置时取默认值。布尔值接受 `1`/`true` 或 `0`/`false`；整数接受 `min..max`（两者都可选）范围内的十进制数字（可带前导 `-`）。其他任何值都会退回默认值，并记录一行 `[WARN]` 加以说明。读取未声明的名称，或以其他类型声明的名称，会抛出 `ArgumentError`，重复声明同一名称也是如此。测试中可以用 `set_string_setting`、`set_int_setting` 和 `set_bool_setting` 修改值。`./NAME help` 会列出每个已声明的设置及其变量和默认值，启动横幅会打印当前值（`=> Settings: base_url="" worker=true ...`）；`secret: true` 的设置在这两处都只显示名称，值为 `[FILTERED]`。没有 `Cybertrain.config.base_url` 这样的访问器：Spinel 没有 `define_method`，所以读取方法是接收名称的带类型方法。

## 时区

Spinel 不带时区数据库，而通过设置 `ENV["TZ"]` 来转换时间会改变进程中每个线程的时区。`Cybertrain::TimeZone` 则读取系统的时区文件：`/usr/share/zoneinfo/<name>`，设置了 `TZDIR` 时为 `$TZDIR/<name>`（在精简的容器镜像中请安装 `tzdata` 包）。它解析 TZif 第 1 到第 4 版（RFC 8536），包括“精简”文件在最后一次转换之后所依赖的 POSIX TZ 规则，并在进程的整个生命期内缓存每个时区（写时复制，所以多个工作线程查找时无需加锁）。

一切都以 Integer 类型的纪元秒数表示。*本地纪元*是把挂钟读数当作 UTC 来计数的值，所以挂钟时间的运算就是简单的加法，`TimeZone.civil_to_epoch` / `TimeZone.epoch_to_civil` 则在它与 `[year, month, day, hour, minute, second]` 之间转换：

```ruby
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
tokyo.found?                         # 名称未知时为 false：此时该时区按 UTC 处理
tokyo.utc_offset_at(Time.now.to_i)   # => 32400
tokyo.abbreviation_at(Time.now.to_i) # => "JST"

# 东京的下一个 09:00：
now = Time.now.to_i
today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
```

在夏令时转换时，`local_to_utc` 的结果是确定的：被向前跳变跳过的挂钟时间（美国开始夏令时那天的 02:30）按跳变之前的偏移量解读，所以它落在跳变之后（03:30 EDT）；被向后跳变重复的挂钟时间则得到较早的那个时刻。`find` 只接受由 `A-Za-z0-9_+-./` 组成、不含空段、`.` 段或 `..` 段的相对名称，所以从用户资料中取得的时区名无法访问时区目录之外的文件；未知或格式错误的时区不会被缓存，`"UTC"` 不需要文件。供模板使用的格式化辅助方法（`l(time, zone:)`）尚未提供。
