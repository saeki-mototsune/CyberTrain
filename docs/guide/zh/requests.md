---
source_sha256: a33d978bb9bf00664107e2af05925eddc07a89d8bffdfb2ca94e7dddd8b441eb
---
# 请求

控制器从请求中得到什么，以及框架为它把了哪些关：限流和代理背后的客户端地址、参数化的请求头，以及查询字符串和请求体如何被解析并设定界限。

## 限流与客户端地址

控制器中的 `rate_limit` 限制一个客户端调用某些动作的频率，计数在动作运行之前进行：

```ruby
class SessionsController < ApplicationController
  # 次数用尽后，以 303 重定向回表单，并带上 flash[:alert]
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
end
```

每条声明针对每个客户端地址和控制器，在每 `within` 秒内最多计 `to` 个请求（一个从第一个请求开始的固定窗口），之后以 429 和 `Retry-After` 响应头作答；如果给出了 `redirect_to:`，则改为重定向。`within:` 以秒为单位，`only:`/`except:` 接收数组，没有 `with:` 块。计数保存在进程中，存放在一张最多容纳 10,000 个地址的表里（表满时，先清除已过期的窗口，再清除最旧的窗口来腾出空间），所以重启后计数会丢失，并且每个进程各自计数。对受限动作的每个请求都会获取一次锁：请用 `only:` 指明动作。在测试中，`Cybertrain::RateLimit.reset_all!` 会清除所有计数，`Cybertrain::RateLimit.current_time = n` 会固定时钟（`-1` 恢复）。

被计数的地址是 `request.client_ip`（`by: :remote_addr` 则改为对连接的对端计数）。它就是 `request.remote_addr`，除非开启了 `config.trusted_proxy`（`CYBERTRAIN_TRUSTED_PROXY=1`）**并且**连接来自环回地址，也就是来自同一主机上的反向代理（nginx、Caddy、kamal-proxy）；这时它是 `X-Forwarded-For` 中的最后一个地址，即代理追加的那个地址。更早的条目是客户端发送的任意内容，永远不会被使用；如果最后一个条目为空、长于 45 字节或不是可打印的 ASCII，则取 `remote_addr`。没有这个设置时，这样一个代理后面的所有访客共用代理的地址，十次错误密码就会把所有人锁在外面；有了它，从别处直接连接的客户端仍然无法自选地址。`request.loopback?` 判断连接是否来自本机（127.0.0.0/8、`::1`、`::ffff:127.x.x.x`），用于只有服务器上的运维人员才能访问的页面；在同一主机上的代理后面，每个请求都来自环回地址，所以这时还要检查 `client_ip`。设计说明：[docs/design.md](../design.md) D26。

通过网络而不是环回地址访问应用的代理，则按地址列出：`config.trusted_proxies` 取自 `CYBERTRAIN_TRUSTED_PROXIES`，接收以逗号分隔的 IPv4 或 IPv6 地址或 CIDR（`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`，或单个 `172.18.0.2`）。来自其中任一范围内的连接，会得到与上文环回连接相同的处理：取 `X-Forwarded-For` 的最后一个地址，并以同样的方式校验。IPv4 条目也匹配其地址的 IPv4 映射形式（`::ffff:172.18.0.2`），对端的 `%zone` 会被忽略。不是地址或 CIDR 的条目，或前缀超过 `/32`（IPv4）或 `/128`（IPv6）的条目，会让服务器在启动时停止。`CYBERTRAIN_TRUSTED_PROXY=1` 是 `127.0.0.0/8,::1` 的简写，两者可以叠加。

这正是 Kamal 的情形：kamal-proxy 运行在自己的 Docker 容器中，从它在 Docker 网络上的地址发起连接，所以 `cybertrain new` 写出的 `config/deploy.yml` 设置了 `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12`（Docker 的默认地址范围；如果你的网络使用其他范围，请修改它，参见 `docker network inspect kamal`）。不要设置 Kamal 的 `proxy.forward_headers`：在 `ssl: true` 时，kamal-proxy 会自己设置 `X-Forwarded-For`，而不是转发客户端发来的值。只列出客户端无法从中发起连接的网络：位于所列网络内的任何人，都能自选限流所计数的地址。

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
