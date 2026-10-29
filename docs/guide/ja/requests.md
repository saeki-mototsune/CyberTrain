---
source_sha256: 2dc0901879541229f7d52f22c19e1446e8d9db24b90486a24024d2379a1605fe
---
# リクエスト：レート制限とヘッダー

## レート制限とクライアントのアドレス

コントローラーの `rate_limit` は、ひとつのクライアントがいくつかのアクションを呼び出せる頻度に上限を設けます。数えるのはアクションの実行前です：

```ruby
class SessionsController < ApplicationController
  # 使い切ると、flash[:alert] を付けてフォームへ 303 で戻す
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
end
```

各宣言は、クライアントのアドレスとコントローラーごとに、`within` 秒あたり最大 `to` 件のリクエストを数え（最初のリクエストで始まる固定のウィンドウ）、それを超えると `Retry-After` ヘッダー付きで 429 を返すか、`redirect_to:` が指定されていればリダイレクトします。`within:` は秒単位で、`only:`/`except:` は Array を受け取り、`with:` ブロックはありません。カウントはプロセス内の、最大 10,000 アドレスのテーブルにあり（満杯になると、期限切れのウィンドウ、次に最も古いものが場所を空けます）、そのため再起動すると失われ、プロセスはそれぞれ独自に数えます。制限されたアクションへのリクエストは、どれもロックを 1 回取ります：アクションは `only:` で指定してください。テストでは、`Cybertrain::RateLimit.reset_all!` がすべてのカウントを忘れ、`Cybertrain::RateLimit.current_time = n` が時計を固定します（`-1` で元に戻ります）。

数えられるアドレスは `request.client_ip` です（`by: :remote_addr` を指定すると、代わりに接続の相手を数えます）。これは `request.remote_addr` ですが、`config.trusted_proxy` が有効（`CYBERTRAIN_TRUSTED_PROXY=1`）で、**かつ**接続がループバック、つまり同じホスト上のリバースプロキシ（nginx、Caddy、kamal-proxy）から来ている場合は別です。そのときは `X-Forwarded-For` の最後のアドレス、つまりプロキシが追加したものになります。それより前のエントリーはクライアントが送ってきた何かであり、決して使われません。最後のエントリーが空、45 バイトより長い、または表示可能な ASCII でない場合は `remote_addr` になります。この設定がないと、そうしたプロキシの後ろにいる訪問者は全員がプロキシのアドレスを共有し、10 回のパスワード間違いで全員が締め出されます。設定があれば、別の場所から直接接続してくるクライアントは、それでも自分のアドレスを選べません。`request.loopback?` は、接続がこのマシン（127.0.0.0/8、`::1`、`::ffff:127.x.x.x`）から来ているかを返します。サーバー上の運用者だけが到達すべきページのためのものです。同じホスト上のプロキシの後ろではどのリクエストもループバックになるので、そこでは `client_ip` も確認してください。設計：[docs/design.md](../design.md) D26。

ループバックではなくネットワーク越しにアプリに到達するプロキシは、代わりにアドレスで列挙します：`config.trusted_proxies` は `CYBERTRAIN_TRUSTED_PROXIES` から読まれ、カンマ区切りの IPv4 または IPv6 のアドレスか CIDR を受け取ります（`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`、または単一の `172.18.0.2`）。そのいずれかの内側からの接続は、上のループバックの接続と同じ扱いを受けます：`X-Forwarded-For` の最後のアドレスを、同じ方法で検証して使います。IPv4 のエントリーは、そのアドレスの IPv4 射影形式（`::ffff:172.18.0.2`）にも一致し、相手の `%zone` は無視されます。アドレスでも CIDR でもないエントリーや、`/32`（IPv4）または `/128`（IPv6）を超えるプレフィックスを持つエントリーがあると、サーバーは起動時に停止します。`CYBERTRAIN_TRUSTED_PROXY=1` は `127.0.0.0/8,::1` の省略形で、両者は足し合わされます。これは Kamal の場合です：kamal-proxy は自身の Docker コンテナーで動き、Docker ネットワーク上の自分のアドレスから接続するので、`cybertrain new` が書き出す `config/deploy.yml` は `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` を設定します（Docker のデフォルトの範囲です。ネットワークが別の範囲を使っている場合は変更してください。`docker network inspect kamal`）。Kamal の `proxy.forward_headers` は設定しないでおきます：`ssl: true` のとき、kamal-proxy はクライアントのものを引き継ぐのではなく、`X-Forwarded-For` を自分で設定します。列挙するのは、クライアントが接続してこられないネットワークだけにしてください：列挙したネットワークの内側にいる人は誰でも、レート制限が数えるアドレスを選べてしまいます。

## パラメーター付きヘッダー

API クライアントは、`Scheme k1=v1, k2="v2"` 形式のヘッダー（`Authorization:
Digest ...`、ベンダー独自の `X-Example-Auth`）や `k1=v1;k2=v2, k3` 形式のリスト（`Forwarded`、`Prefer`）をよく送ってきます。`request.header_params(name)` はそれをパースして、小文字の名前から値への `Hash` にするので、API コントローラーが手で分割する必要はありません：

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

`,` と `;` はどちらもパラメーターを区切り、同じ名前が複数あれば最初のものが優先されます。引用符で囲まれた値は引用符が外され（`\"` と `\\` も元に戻されます）、囲まれていない値は前後の空白が取り除かれ、`=` のない名前は `""` に対応します。先頭のスキームの単語（`Digest`、`Bearer`）はパラメーターではありません：`request.header_scheme(name)` がそれを返します（ない場合は `""`）。ヘッダーがない、または 8 KiB より長い場合は `{}` になります。値は送られたままのバイト列で、パーセントデコードされることはなく、有効な UTF-8 でない場合もあります。`Bearer <token>` や `Basic <base64>` の資格情報はパラメーターではありません：スキームを確認してから、`request.header("authorization")` から資格情報を読んでください。設計：[docs/design.md](../design.md) D31。
