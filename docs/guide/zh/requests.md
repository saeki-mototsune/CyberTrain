---
source_sha256: 5bf1d1e0eeab5c9b7faf3703795f14e54e91adaaeaf0e54a303f40ec3bb23a59
---
# 请求

控制器从请求中得到什么，以及框架在它运行之前检查什么：路由及其格式、`respond_to`、concern 与 `helper_method`、强参数、文件下载与 HTTP 缓存、cookie 与加密的会话、限流与代理背后的客户端地址、请求 ID、Content Security Policy、`force_ssl` 与主机检查、参数化的请求头，以及查询字符串和请求体如何被解析和限制。

## 路由

`config/routes.rb` 使用 Rails 的路由 DSL；`spin run gen` 执行它并写出 `gen/routes.rb`（路由表、分发器和 `*_path` / `*_url` 辅助方法）。顶层的调用不需要接收者；嵌套的块要写出传给它的接收者，因为 Spinel 只会在没有接收者的情况下执行 `Routes.draw` 的顶层：

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
end
```

`namespace :admin` 给路径加上 `/admin` 前缀，给辅助方法加上 `admin_` 前缀（`admin_articles_path`、`admin_article_path(article)`），它的控制器是 `app/controllers/admin/articles_controller.rb` 中的 `Admin::ArticlesController`，视图放在 `app/views/admin/articles/`。namespace 可以嵌套。命名空间中的控制器可以写成嵌套形式（`module Admin` / `class ArticlesController < ApplicationController`），也可以写成紧凑形式（在 `module Admin` 已存在时写 `class Admin::ArticlesController`）；扫描两种都能读。namespace 中的 `jobs_page` 会带上它的前缀。

`scope` 一次只改变一个部分，三者可以像 Rails 那样组合：

```ruby
scope "/dashboard" do |s|          # 只有路径前缀
  s.get "/stats", to: "stats#show"
end
scope module: "billing" do |s|     # 只有控制器模块：Billing::InvoicesController
  s.resources :invoices
end
scope "/v1", as: "v1" do |v|       # 路径和辅助方法前缀：v1_about_path
  v.get "/about", to: "pages#about"
end
```

`namespace` 和 `scope` 要在 `resources` 块之外使用（在块内使用时 gen 会拒绝）。

### 单数资源、`controller:` 与 `param:`

`resource`（单数）和 `resources` 一样，接受一个块和 `controller:`。块会添加成员路由和嵌套资源，路径和名称与 Rails 相同：

```ruby
resource :profile, controller: "pages", only: [:show] do |r|
  r.get :refresh, on: :member       # GET /profile/refresh，refresh_profile_path
end
resources :indicators, param: :key  # /indicators/:key，params[:key]
```

`on: :member` 和 `on: :collection` 把自定义路由放到 `member` 块和 `collection` 块所放的位置；单数资源没有集合。`param: :key` 为成员段命名（`params[:key]`），其下的嵌套资源使用 `:indicator_key`；`indicator_path(ind)` 仍然读取 `ind.to_param`，由模型重写它来返回键。自定义路由的 `:id` 和 `:x_id` 段保留原来的辅助方法参数名（`get "/users/:id"` 得到 `user_path(user)`）。

### 重定向与查询字符串

`get "/old", to: redirect("/new")` 以 301 响应（其他状态码用 `redirect("/new", status: 302)`）；目标中的 `%{name}` 是该段经过转义的值：`get "/old-posts/:id", to: redirect("/posts/%{id}")`。重定向路由除非写了 `as:`，否则没有辅助方法。不支持 `redirect` 的块形式；由控制器动作来计算目标。

路径辅助方法的关键字参数按给出的顺序、经过转义后进入查询字符串：`article_path(a, page: 2)` 是 `/articles/3?page=2`，值为 nil 时省略该键，Array 对每个元素给出 `key[]=v`，Hash 值会抛出 `ArgumentError`。`format: :json` 添加扩展名（`/articles/3.json`），`anchor: "c4"` 添加片段（`#c4`，放在最后）。关键字永远不会填充路径段：路径段是位置参数（`post_path(3)`，而不是 `post_path(id: 3)`）。`url_for("/x", format: :csv)` 会把同样的选项附加到 String 上。

## 格式与 `respond_to`

每条路由都在最后一段上匹配一个可选的扩展名：`/articles/3.json` 得到 `params[:id] == "3"` 和 `request.format == :json`。在接受格式的路由中，动态段从不捕获 `.`（Rails 的默认行为），所以 `/articles/3.json.bak` 是 404。某个段因为自身原因含有点号的路由要写 `format: false`（可用于 `get` 等动词、`resources`、`resource` 和 `root`）：

```ruby
get "/files/:name", to: "files#show", format: false   # /files/report.v2 的 name 是 "report.v2"
```

`request.format` 是一个 Symbol：有扩展名时取自 Rails 注册的类型（`:html`、`:json`、`:csv`、`:xml`、`:pdf`、`:turbo_stream` 等；`jpg` 是 `:jpeg`，`htm` 是 `:html`，`txt` 是 `:text`），其他扩展名为 `:unknown`。没有扩展名时它来自 `Accept`：列出 `text/vnd.turbo-stream.html` 时为 `:turbo_stream`，列出 `application/json` 且之前没有 `text/html` 时为 `:json`，否则为 `:html`（`q=0` 的类型不计）。

```ruby
def show
  @article = Article.find(params[:id])
  respond_to do |format|
    format.html
    format.json { render json: @article.as_json }
    format.turbo_stream
  end
end
```

收集器（`Cybertrain::FormatCollector`）有 `html`、`json`、`turbo_stream`、`csv`、`xml`、`text` 和 `any`。第一个匹配的声明会立即运行它的块，因此块能看到动作的实例变量；没有块的声明会渲染该格式的动作模板（`show.html.erb` 在布局中，`show.turbo_stream.erb` 不带布局）。一个都不匹配时，响应是 `406 Not Acceptable`。`any` 匹配除 `:unknown` 以外的任何格式。Turbo 提交表单时请求 `text/vnd.turbo-stream.html, text/html`：这样的请求格式是 `:turbo_stream`，没有 `format.turbo_stream` 的动作会像 Rails 那样通过它的 `format.html` 响应（`.turbo_stream` 扩展名只请求该格式）。同样的回退适用于任何在非 html 格式旁边列出 `text/html` 或 `*/*` 的 `Accept`：客户端向只有 html 模板的动作发送 `application/json, text/plain, */*`，得到的是 html，而不是 406。回退会为 html 把块再运行一次，所以块中 `format.` 行以外的语句会运行两次：块里只放 `format.` 行。带 `q=0` 的条目表示拒绝该类型：对 `application/json, text/html;q=0`，无论旁边有没有 `*/*`，都不会返回 html。

格式来自 `Accept` 的响应（没有扩展名、发送了 `Accept` 头）带有 `Vary: Accept`，并与动作已设置的 `Vary` 合并，这样浏览器或缓存不会把某个 URL 的 html 交给请求其 JSON 或 Turbo Stream 的请求；带扩展名的路径则没有。

没有 `respond_to` 时，动作在 `<action>.<format>.erb` 存在时渲染它（`create.turbo_stream.erb`，不带布局，使用该格式的内容类型），不存在时以 406 响应；html 和以前一样。JSON 没有模板：动作用 `render json:` 返回 JSON。在块中，`render :edit` 渲染该块所匹配格式的模板（`format.turbo_stream` 中是 `edit.turbo_stream.erb`）。

控制器用 `turbo_stream` 构建 Turbo Stream 响应（turbo-rails 的构建器：`replace`、`update`、`append`、`prepend`、`before`、`after` 各接受一个目标以及带 `locals:` 的 `partial:` 或 `html:` 之一，还有 `remove`）：

```ruby
render turbo_stream: [turbo_stream.remove(@comment), turbo_stream.update("count", html: @count.to_s)]
```

## Concern 与 `helper_method`

控制器的 concern 是 `app/controllers/concerns/` 中的模块，与 Rails 相同：

```ruby app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 20
  end
end
```

写了 `include AdminGate` 的控制器会得到 `included` 块所声明的内容（`before_action`、`skip_before_action`、`after_action`、`helper_method`、`rate_limit`、`rescue_from`、`layout`），位置就在 `include` 处，顺序与书写一致，并且在它的动作中可以使用 `self.class.per_page`。concern 可以包含 concern：gen 以深度优先展开它们，每个只展开一次，并点名拒绝循环（`concern cycle: A includes B includes A`）。`include A, B` 与 Ruby 一样先包含 B，所以 B 的 `included` 块和回调排在 A 之前。`around_action` 会被拒绝（没有 around 回调）。concern 方法中的 `@x =` 赋值属于控制器的视图变量。

Spinel 会编译从不运行的 `included` 和 `class_methods` 块，所以由 gen 自己来展开：它把每个 concern 写到 `gen/concerns/<app/ 下的路径>`，并把这两个块清空（应用的文件加载这些副本），`gen/concerns.rb` 重新打开每个包含它的类，写入插入的声明以及每个 `class_methods` 方法的转发方法。由此产生两条规则。`class_methods` 的方法不能与 concern、包含它的类或其祖先的实例方法同名（Spinel 会把两者都定义为实例方法，spikes/NOTES.md 规则 93）；gen 会拒绝它并指出两个位置（实例方法所在的 `文件:行`）。另外，`include` 一个不是 concern 的模块（`include Comparable`，或在 `app/*/concerns` 下没有对应文件的名字）会原样留给 Ruby，所以 concern 名字拼错时，是应用加载时的 `NameError`，而不是 gen 的提示。gen 像 Ruby 一样查找名字，先查类自己所在的模块，所以 `module Admin` 里的 `include Gate` 会引入 `Admin::Gate`。一个名字如果找不到任何 concern，但最后一段与某个 concern 的名字相同（只有 `Admin::Gate` 时写 `include Gate`），gen 会停止：Ruby 会 include 别的模块或抛出异常，而这个 concern 的 `included` 块就会丢失。

模型的 concern 放在 `app/models/concerns/`，工作方式相同：它们的 `included` 块可以包含模型的任何类级声明（`validates`、`validate`、`scope`、`belongs_to`、`has_many`、`has_one`、`encrypts`、回调、`normalizes`），视同在 `include` 处写在模型中。concern 的回调在模型自己的同类回调之后运行，模型 concern 的 `included` 块中的 `include` 会把那个 concern 引入。模型 concern 的 `class_methods` 方法名不能是该模型的 scope，也不能是每个模型都有的类方法（与 `scope :recent` 并列的 `recent`，或 `where`）；gen 会拒绝。

在控制器或 concern 的 `included` 块中写 `helper_method :current_user, :admin?`，就可以在该控制器的模板以及它们渲染的组件和局部模板中，带参数调用这些控制器方法。gen 会拒绝以下名称：框架辅助方法的名称、以 `_path` 或 `_url` 结尾的名称、由 `app/helpers` 中的模块定义的名称、在控制器及其父类或 concern 中没有 `def` 的名称，以及模板无法传入其参数（`*rest`、`**opts`、`...`）的名称。

## 参数：`params.expect` 与嵌套的 `permit`

```ruby
def article_params
  params.expect(article: [:title, :body, tags: [], meta: [:source]])
end
# => {"title" => "Hi", "body" => "...", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
```

`permit` 接受同样的形式：一个键允许一个 String，`key: []` 允许 String 的列表，`key: [...]` 允许一层嵌套。不是 Array 的过滤器（`permit(meta: :source)`、`expect(article: :title)`）或含有 Array 的过滤器（`[[:title]]`）会抛出 `ArgumentError`：这是代码里的错误，不是错误的请求，所以不是 400。类型不对的值、未列出的键和上传的文件都会被丢弃。`expect` 返回其唯一键之下的那一层，当该键不存在、类型不对或什么都不允许时，抛出 `Params::ParameterMissing`（以 400 响应）。`params.expect(:id)` 读取一个 String 并返回 `{"id" => "3"}`；`params.expect(tags: [])` 同样返回一个非空列表。两者都返回 `Hash{String => Object}`：值是 String、String 的 Array 或嵌套的 Hash，所以在对值调用 String 方法之前，先用 `Cybertrain::Cast.str`（或 `.to_s`）收窄它。

## 下载、HTTP 缓存与状态码

`send_data(bytes, filename: "report.csv", type: "text/csv", disposition: "attachment")` 用这些字节响应，并在 `Content-Disposition` 中同时以带引号的形式和 RFC 5987 的 `filename*` 写出文件名，因此重音符号和引号都能保留；`disposition: "inline"` 让浏览器直接显示它。字节按给定的 `type` 发送，所以它用于应用自己生成的数据；用户上传的文件请用 `send_blob` 返回，它从不让浏览器执行文件。

```ruby
def show
  @post = Post.find(params[:id])
  fresh_when etag: @post, last_modified: @post.updated_at
end

def feed
  @posts = Post.order(created_at: :desc).limit(20).to_a
  return unless stale?(etag: @posts.first)
  expires_in 300, public: true
end
```

`fresh_when` 设置弱 `ETag`（来自 String，或来自记录的表名、`to_param` 和 `updated_at`）和 `Last-Modified`，当请求的 `If-None-Match`（没有它时为 `If-Modified-Since`）表明客户端已有当前版本时，以 `304 Not Modified` 响应；`stale?` 做同样的事并返回动作是否应当渲染。只有 GET 和 HEAD 会得到 304。`Cache-Control` 为 `max-age=0, private, must-revalidate`（`public: true` 时为 `public`），除非 `expires_in seconds` 先设置了 `max-age=<seconds>`。其他响应不会自动带 ETag。`If-None-Match: *` 与动作设置的任何验证器匹配，无论是 `ETag` 还是只有 `Last-Modified`。

ETag 由你给的键、请求的格式和构建摘要（资源摘要和 import map，在 `cybertrain build` 的二进制中还有视图）组成，所以同一 URL 的 html 和 JSON 永远不会共用一个 ETag，改动资源或视图的部署会让所有客户端重新验证。由此有两点。在开发中，不带 `--embed-views` 时模板是从磁盘读取的，不在摘要里：编辑视图后仍可能得到 `304`，直到记录改变或页面在不带缓存副本的情况下重新加载。还有，键表示页面显示什么，而不是谁在看：因用户而异的内容需要把用户放进键里（`etag: "posts/#{@post.id}-#{@post.updated_at.to_i}-#{current_user.id}"`），否则会展示给错误的人。不要把带有 CSP nonce 的页面设为 `public`（带 nonce 的 `content_security_policy`、`javascript_importmap_tags`）：共享缓存会把同一个页面，也就是同一个 nonce，交给每位访客，nonce 也就起不到任何保护作用。

`status:` 和 `head` 接受所有 Rack 符号（`:unauthorized`、`:payment_required`、`:unprocessable_content`、`:too_many_requests` 等，旧的 `:unprocessable_entity` 和 `:payload_too_large` 作为别名保留），原因短语采用 RFC 9110 的写法（413 "Content Too Large"、422 "Unprocessable Content"）。

## Cookie 与会话

```ruby
cookies[:theme] = "dark"
cookies[:theme] = { value: "dark", expires: Time.now + 86_400, same_site: "Strict" }
cookies.permanent[:locale] = "ja"
cookies.signed[:user_id] = "5"     # 客户端可以读，但不能改
cookies.encrypted[:card] = "4242"  # 既不能读也不能改
cookies.signed[:user_id]           # => "5"，被改过则为 nil
cookies.delete(:theme)
```

写入接受一个 String，或一个带 `value:`、`expires:`（Time）、`max_age:`、`path:`、`httponly:`、`secure:` 和 `same_site:` 的 Hash。cookie 写入时带 `Path=/`、`HttpOnly` 和 `SameSite=Lax`，会话 cookie 带 `Secure` 时（生产环境中，或开启 `force_ssl` 时）也带 `Secure`，除非写入时另有指定。`permanent` 写入 20 年的 `Max-Age`。签名的值是用从 `secret_key_base` 派生的密钥计算的 HMAC-SHA256；加密的值是用另一个密钥的 AES-256-GCM；两者都绑定到各自 cookie 的名称，因此换一个名称既无法验证也无法解密，被改过的值读出来是 nil。同一请求中写入后再读取，得到的是写入的值。在 jar 之下，`Cybertrain::Cookies.serialize(name, value, expires: time)` 构造一个 `Set-Cookie` 值；省略 `expires:`（它的默认值是 `Cybertrain::Cookies::NO_EXPIRES` 而不是 nil，这是出于 Spinel 的原因：见 spikes/NOTES.md 第 109 条规则）或传入 nil 都不会写出 `Expires`。

会话 cookie 与 Rails 的 cookie store 一样，用 AES-256-GCM 加密并认证，使用从 `secret_key_base` 派生的专用密钥：客户端既不能读取也不能修改它。无法解密的 cookie（被改过的、来自别处的或旧的签名 cookie）会作为空会话加载，超过 4096 字节的 cookie 也是如此；cookie 会超过 4096 字节的会话，或 `name=value` 超过 4096 字节的 jar cookie，在写入时抛出 `Session::CookieOverflow`。值仍然是 String。和以前一样，更换 `secret_key_base` 会让所有人退出登录。

## 限流与客户端地址

控制器中的 `rate_limit` 限制一个客户端调用某些动作的频率，在动作运行之前计数。它需要在 `bin/<app>.rb` 和 `bin/db.rb` 中写 `require "cybertrain/rate_limit"`（它会同时加载缓存）；`cybertrain generate authentication` 会添加它：

```ruby
class SessionsController < ApplicationController
  # 用尽后，带着 flash[:alert] 以 303 返回表单
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
  rate_limit to: 5, within: 60, only: [:create], by: :account_key, with: :slow_down, name: "account"
end
```

每条声明针对每个客户端和控制器，在每个 `within` 秒的窗口内最多计 `to` 个请求，之后以 429 和 `Retry-After` 响应头（窗口剩余的秒数）作答；如果给出了 `redirect_to:`，则改为重定向。其他选项指向控制器方法：`by:` 是键（默认 `:client_ip`，`:remote_addr` 表示连接的对端，或者像 `account_key` 这样的方法，它返回 nil 或 `""` 时会抛出异常，而不是把所有客户端算在一起），`with:` 是改为返回的响应（它什么都没渲染时，随后仍返回 429），`if:` / `unless:` 决定限制何时生效（被跳过的请求不计数）。有两个限制的控制器要为每个限制取不同的 `name:`（gen 会拒绝同一控制器中（包括其父类的）同名的第二个限制，以及含有 `:` 的名称）。`within:` 以秒为单位，`only:`/`except:` 接收数组。

计数保存在应用数据库中的 `Cybertrain::Cache` 里，所以服务该应用的所有进程一起计数，重启后计数仍然保留；窗口是固定的，并与时钟对齐（`now / within`）。`store: :memory` 保留原来的按进程计数：每个进程各自计数，存放在一张最多容纳 10,000 个键的表里（表满时，先清除已过期的窗口，再清除最旧的窗口来腾出空间），重启后丢失，窗口从某个键的第一个请求开始，并且对受限动作的每个请求都会获取一次锁（请用 `only:` 指明动作）。在测试中，`Cybertrain::RateLimit.reset_all!` 会清除所有计数（内存中的表和缓存中的限流行；`cybertrain test` 在每个测试之前都会这样做），两种存储都读取框架的时钟，所以 `travel 1.minute` 或 `travel_to` 可以让测试越过一个窗口（[时间旅行](testing.md#time-travel)）。

### 代理背后的客户端地址

被计数的地址是 `request.client_ip`（`by: :remote_addr` 则改为对连接的对端计数）。它就是 `request.remote_addr`，除非开启了 `config.trusted_proxy`（`CYBERTRAIN_TRUSTED_PROXY=1`）**并且**连接来自环回地址，也就是来自同一主机上的反向代理（nginx、Caddy、kamal-proxy）；这时它是 `X-Forwarded-For` 中的最后一个地址，即代理追加的那个地址。更早的条目是客户端发送的任意内容，永远不会被使用；如果最后一个条目为空、长于 45 字节或不是可打印的 ASCII，则取 `remote_addr`。没有这个设置时，这样一个代理后面的所有访客共用代理的地址，十次错误密码就会把所有人锁在外面；有了它，从别处直接连接的客户端仍然无法自选地址。`request.loopback?` 判断连接是否来自本机（127.0.0.0/8、`::1`、`::ffff:127.x.x.x`），用于只有服务器上的运维人员才能访问的页面；在同一主机上的代理后面，每个请求都来自环回地址，所以这时还要检查 `client_ip`。设计说明：[docs/design.md](../design.md) D26。

通过网络而不是环回地址访问应用的代理，则按地址列出：`config.trusted_proxies` 取自 `CYBERTRAIN_TRUSTED_PROXIES`，接收以逗号分隔的 IPv4 或 IPv6 地址或 CIDR（`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`，或单个 `172.18.0.2`）。来自其中任一范围内的连接，会得到与上文环回连接相同的处理：取 `X-Forwarded-For` 的最后一个地址，并以同样的方式校验。IPv4 条目也匹配其地址的 IPv4 映射形式（`::ffff:172.18.0.2`），对端的 `%zone` 会被忽略。不是地址或 CIDR 的条目，或前缀超过 `/32`（IPv4）或 `/128`（IPv6）的条目，会让服务器在启动时停止。`CYBERTRAIN_TRUSTED_PROXY=1` 是 `127.0.0.0/8,::1` 的简写，两者可以叠加。

这正是 Kamal 的情形：kamal-proxy 运行在自己的 Docker 容器中，从它在 Docker 网络上的地址发起连接，所以 `cybertrain new` 写出的 `config/deploy.yml` 设置了 `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12`（Docker 的默认地址范围；如果你的网络使用其他范围，请修改它，参见 `docker network inspect kamal`）。不要设置 Kamal 的 `proxy.forward_headers`：在 `ssl: true` 时，kamal-proxy 会自己设置 `X-Forwarded-For`，而不是转发客户端发来的值。只列出客户端无法从中发起连接的网络：位于所列网络内的任何人，都能自选限流所计数的地址。

## 请求 ID

每个请求都有一个 ID，`request.request_id`：框架生成的版本 4 UUID，或受信任的代理发来的 `X-Request-Id`（满足上面的信任条件，且为 1 到 255 个 ASCII 字母、数字和连字符；其他值会被丢弃，从不改写）。响应在 `X-Request-Id` 中把它返回（错误页面和主机检查的 403 也一样），请求运行期间记录的每一行都把它作为标签：

```ruby
def export
  ExportJob.perform_later("user_id" => current_user.id)   # 作业的行也带这个 ID
  Cybertrain.logger.info("export queued for #{request.request_id}")
  head :accepted
end
```

`c.log_tags` 选择每一行显示什么；作业的行和错误报告带有把它加入队列的请求的 ID（[请求 ID](background-and-operations.md#request-ids)）。

## Content Security Policy、`force_ssl` 与主机

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

与 Rails 一样，在 `config/app.rb` 声明之前策略是关闭的。声明之后，每个响应都带有 `Content-Security-Policy`（`c.content_security_policy_report_only = true` 时为 `Content-Security-Policy-Report-Only`），并在带 nonce 的指令中放入每个请求新生成的 nonce；304 不带策略，因此缓存的页面保留其脚本写入时的 nonce。`csp_meta_tag`、`javascript_tag(nonce: true)`、`javascript_importmap_tags` 和 `stylesheet_link_tag(nonce: true)` 会写出这个 nonce（[模板语言](template-language.md#helpers-and-the-form-builder)）。Symbol 是关键字和协议（`:self` 是 `'self'`，`:data` 是 `data:`）；含有空格、`;`、`,` 或控制字符的 String 来源在声明时就会被拒绝。控制器可以为自己的动作调整一份副本，子类会继承它：

```ruby
class EmbedController < ApplicationController
  content_security_policy do |p|
    p.frame_ancestors "https://partner.example"
  end
end
```

每个响应还带有 `Permissions-Policy: camera=(), microphone=(), geolocation=()`，除非它设置了自己的；`c.permissions_policy` 替换该值，`""` 则不发送。

`CYBERTRAIN_FORCE_SSL=1`（`config.force_ssl`）把 http 重定向到 https，GET 和 HEAD 用 301，其余用 307，并给 https 响应加上 `Strict-Transport-Security: max-age=63072000; includeSubDomains`。在终止 TLS 的代理之后，请求带有 `X-Forwarded-Proto: https` 时即为 https；无论 `trusted_proxy` 如何设置都会读取这个头（伪造它的客户端只会跳过自己的重定向）。`request.base_url` 只相信来自受信任代理的这个头，所以还要设置 `CYBERTRAIN_TRUSTED_PROXY` 或 `CYBERTRAIN_TRUSTED_PROXIES`，否则应用生成的 URL 仍是 http。重定向从格式正确的 `Host` 中取主机（格式不对时为 400），对健康检查路径的 http GET 或 HEAD 请求从不重定向。开启 `force_ssl` 后，会话和 cookie jar 写入带 `Secure` 的 cookie。

主机检查扩展了开发环境中的防护：`CYBERTRAIN_HOSTS`（逗号分隔的主机名，不带协议、端口或通配符）在所有环境中都会追加到 `allowed_hosts`，排在回环名称之后。开发环境照旧检查；生产和测试环境只在设置了 `CYBERTRAIN_HOSTS` 时检查。被拒绝的 `Host` 得到 403 `Blocked host` 并记入日志；对健康检查路径的 GET 或 HEAD 请求无论 Host 为何都会通过，所以按地址探测的负载均衡器仍能到达健康检查。

## 参数化的请求头

API 客户端经常发送 `Scheme k1=v1, k2="v2"` 形式的请求头（`Authorization:
Digest ...`、厂商自定义的 `X-Example-Auth`），或 `k1=v1;k2=v2, k3` 形式的列表（`Forwarded`、`Prefer`）。`request.header_params(name)` 把这样的请求头解析为一个从小写名称映射到值的 `Hash`，这样 API 控制器就不必手动拆分它：

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

`,` 和 `;` 都用于分隔参数，同名参数以第一次出现的为准；带引号的值会去掉引号（还原 `\"` 和 `\\`），不带引号的值会去掉两侧的空格，没有 `=` 的名称映射为 `""`。开头的方案词（`Digest`、`Bearer`）不是参数：`request.header_scheme(name)` 返回它（没有时返回 `""`）。缺失或长于 8 KiB 的请求头得到 `{}`。值是发送时的原始字节，从不进行百分号解码，也可能不是有效的 UTF-8。`Bearer <token>` 或 `Basic <base64>` 凭据不是参数：先检查方案，再从 `request.header("authorization")` 读取凭据。设计说明：[docs/design.md](../design.md) D31。

## 查询字符串与请求体

`Query.parse`、`Query.value_of`、`Query.decode` 以及 `request.form_value` / `query_value` 会抛出 `Cybertrain::QueryMalformed`（`Cybertrain::QueryInvalid` 之下的一个 `StandardError`，而不是 `ArgumentError`），以 400 响应，情形如下：

- 格式错误的百分号转义，在两种运行时上都是如此；
- 无效的 UTF-8 字节序列，无论是原始字节（不管 String 带什么编码标记）还是百分号编码的（Rails 同样会对参数编码无效的请求返回 400）；
- 只有加上转义才能补全的原始字节（`a=\xC3%A9`）。

`Cookies.parse` 则会原样保留这样的值。带有无效序列的路径（原始的，或某个路径段经百分号解码后出现的）同样返回 400（`request.path_segments`）；路径中格式错误的转义保持原样，因匹配不到而返回 404。请求参数最多嵌套 32 层、4096 对，超过则返回 400。升级说明：原先在这些调用外面 rescue `ArgumentError` 的应用代码，应改为 rescue `Cybertrain::QueryInvalid`。

请求本身不保存参数树（路由器构建 `params`，中间件只读取一个键）；需要完整参数树的应用自己解析，`Query.parse(request.utf8_query_string)`，并自行管理结果。

Rack 对 gzip 压缩的请求体保持原样。这里，以 `Content-Encoding: gzip` 发送的请求体（超过几 KB 的 SDK 或 API 客户端会这样做）通过 `request.decoded_body` 获取，它通过系统的 zlib 解压一次，输出有上限：默认 10 MiB，需要更多的端点传入自己的上限，`request.decoded_body(limit)`。损坏的请求体或 gzip/identity 以外的编码会引发 `Cybertrain::BodyUndecodable`，解压后会超过上限的请求体会引发 `Cybertrain::BodyTooLarge`，两者都是 `QueryInvalid`，以 400 响应。`request.body` 仍然是发送时的原始字节。

## 升级为 0.4 编写的应用

为 0.4 编写的应用需要注意的变化（完整列表见[设计文档](../superpowers/specs/2026-11-10-phase4-web-layer-design.md)第 14 节）：

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
- `allow_unauthenticated_access` 现在是框架的方法；0.4 的生成器写进 `ApplicationController` 的那个仍然有效并优先。再次运行 `cybertrain generate authentication` 会加入密码重置、锁定、保持登录、账户页面和管理员用户，并为 0.4 写的文件打印差异（[从 0.4 升级](authentication.md#upgrading-from-04)）。
- 每个响应都带 `X-Request-Id`，代理的 `X-Request-Id` 只有在代理受信任时才会采用；每一行日志的形状都变了（[从 0.4 升级日志与错误报告](background-and-operations.md#upgrading-logs-and-error-reports-from-04)）。
