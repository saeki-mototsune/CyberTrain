---
source_sha256: 0a5a051dced3255b5cbc72eeeaa180f28cc8bf726dc0fce839c7885938c65379
---
# 外向きの HTTP、WebSocket フィード、メール

## 外向きの HTTP

別のサーバー（Webhook、Slack の Incoming Webhook、サードパーティの API）を呼び出すアプリケーションは `Cybertrain::HttpClient` を使います。これは `require "cybertrain"` には含まれていません。使う場所で require し、https の URL があれば TLS の層も require してください：

```ruby
require "json"
require "cybertrain/http_client"
require "cybertrain/net/tls"   # https:// のときだけ。システムの libssl をリンクする

client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15, max_body: 1 << 20)
begin
  res = client.post(ENV["SLACK_WEBHOOK_URL"], JSON.generate({ "text" => "Deployed" }),
                    content_type: "application/json")
  Cybertrain.logger.warn("slack answered #{res.status}") unless res.success?
rescue Cybertrain::HttpClient::Error => e
  Cybertrain.logger.warn("slack: #{e.message}")   # host:port は示すが、パスは決して含まない
end

res = client.get("https://api.example.com/v1/status", headers: { "Authorization" => "Bearer #{token}" })
res.status              # 200
res.header("ETag")      # 名前の大文字小文字は問わない。res.headers では小文字
res.body                # バイト列。チャンク形式は取り除かれている
```

これがある理由：Spinel の `Net::HTTP` は、TLS ハンドシェイクと最初のバイト以降のすべての読み取りを、ブロッキングする C の呼び出しとして行います。そのそれぞれが、止まったエンドポイントが望むだけ長く OS のワーカーを占有し、デフォルトの `SPINEL_WORKERS=1` ではそれが Web サーバー全体です。`HttpClient` がネットワークでワーカーをブロックすることは決してありません：

- **すべての待ちに上限がある。** 接続（ノンブロッキングの connect。Spinel の `TCPSocket.new` は `connect_timeout:` を無視します）、TLS ハンドシェイクの各手順、各読み取り、各書き込みは最大 `timeout` 秒（デフォルトは 5）待ち、リクエスト全体では最大 `deadline` 秒（デフォルトは 15）待ちます。どちらかを過ぎると `HttpClient::TimeoutError` です。読み取りは `read_nonblock` で満たされるバイトバッファーを通るので、すでに受け取ったバイトを待つことはありません。
- **名前解決はブロックする。** ランタイムには `getaddrinfo` のノンブロッキング版がありません：リクエストを行うスレッドは DNS を待ちます（通常は数ミリ秒ですが、リゾルバーが死んでいるとシステムのタイムアウト、1 回の試行につき約 5 秒かかることがあります）。デッドラインはその時間も数えますが、中断はできません。
- **公開されていない宛先は拒否される。** 何かを送る前に：ループバック（`127.0.0.0/8`、`::1`）、プライベート（`10/8`、`172.16/12`、`192.168/16`、`fc00::/7`）、リンクローカル（クラウドのメタデータサービスを含む `169.254/16`、`fe80::/10`）、未指定（`0.0.0.0/8`、`::`）、マルチキャスト、ブロードキャスト、CGNAT（`100.64/10`）、ドキュメント用とベンチマーク用の範囲、そしてそれらの IPv4 射影、NAT64、6to4 の形式です（`Cybertrain::Net::Address.blocked_reason`）。ホスト名は一度だけ解決され、解決されたアドレスがそのまま検査され、接続先になります（再び問い合わせることはありません）。そのため、プライベートなアドレスに解決される名前（`/etc/hosts` のエントリー、DNS リバインディング）も、リテラルと同じように拒否されます。TLS 証明書は引き続き名前に対して検証されます。検査はアドレスごとです：拒否されたアドレスはスキップされ、すべてのアドレスが拒否されたときにだけリクエストが失敗します。`HttpClient::BlockedAddressError` がその理由を伝えます。自分のネットワーク上のサービスや、テストでローカルのサーバーを呼び出すには、`config/app.rb` で `c.http_allow_private =
  true` を設定する（または `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`）か、`HttpClient.new` に `allow_private: true` を渡します。URL がユーザーから来る可能性があるときは、常に無効のままにしてください。
- **解決されたすべてのアドレスを試す。** リゾルバーが返した順に、IPv6 も IPv4 も同じように試します：あるアドレスが拒否する、到達できない、リセットする、`timeout` 以内に応答しない場合は次のアドレスに接続し、そのすべてを `deadline` 以内に行います。すべてが失敗すると、最後のアドレスのエラーを出します。これによって macOS の `localhost` が動きます。macOS では `localhost` はまず `::1` に解決され、`127.0.0.1` で待ち受けているサーバーはそれを拒否するからです。`Cybertrain::Mailer` も同じ方法で接続します。
- **TLS** は openssl パッケージのものです：オペレーティングシステムの信頼ストアに対する `VERIFY_PEER`（`SSL_CERT_FILE` / `SSL_CERT_DIR` で別の場所を指せます。パッケージにはカスタムのストアのための `X509::Store` がありません）、ホスト名の検査、SNI、TLS 1.2 以降。https の URL にはホスト名が必要です：IP アドレスは証明書の名前に一致しません。`require
  "cybertrain/net/tls"` がないと、https のリクエストはその旨を伝える `HttpClient::TLSError` を出します。`cybertrain/http_client` だけでは libssl をリンクすることはありません。
- **ブラウザーではなく、通知用のクライアント：** `Connection:
  close` 付きの HTTP/1.1 で、リクエストごとに接続は 1 つ、keep-alive なし、リダイレクトなし（3xx はそのまま返されます）、プロキシなし、cookie なし、圧縮なしです。レスポンスは `Content-Length`、チャンク形式、または接続が閉じるまでの読み取りのいずれでもかまいません。ヘッダーは 64 KiB かつ 100 行、ボディは `max_body`（デフォルトは 1 MiB）が上限で、それを超えると `HttpClient::TooLargeError` です。HTTP/1.x でない、または途中で終わるレスポンスは `HttpClient::BadResponseError`、拒否された・リセットされた接続や、解決できない名前は `HttpClient::RefusedError` です。TLS ハンドシェイク中にリセットされた・閉じられた接続（TLS を話さないサーバー）は、OpenSSL が拒否したハンドシェイクと同じく、どのプラットフォームでも `HttpClient::TLSError`（「TLS handshake failed」）です。これらはすべて `HttpClient::Error` です。
- **エラーにパスやクエリが含まれることはない。** Webhook の URL はそこに秘密を持っているからです：メッセージが示すのはホストとポートだけです。形式の壊れた URL や CR/LF を含むヘッダーは `ArgumentError` で、これもその内容を繰り返しません。`Host`、`Connection`、`Content-Length`、`Transfer-Encoding` はクライアントが管理し、`User-Agent` のデフォルトは `cybertrain/<version>` です。

リクエストは呼び出したスレッドで実行されます。これは配信中のリクエストと同じくグリーンスレッドなので、待っている間も他の接続は配信され続けます。ソケットの層（`cybertrain/net/socket.rb`：上限付きの connect、バッファー付きの読み取り、上限付きの書き込み）は HTTP の層から分かれているので、他のプロトコルからも使えます。設計：[docs/design.md](../design.md) D24。

## WebSocket フィードを購読する

サーバーの動作中に外部のフィード（市場のティック、デバイスのテレメトリー、イベントストリーム）を受信するアプリケーションは、`Cybertrain::WebSocket.subscribe` でそれを購読します。HTTP クライアントと同じく `require "cybertrain"` には含まれていません。購読を書く場所で require し、`wss://` には TLS の層も require してください：

```ruby
# config/app.rb（または bin/<app>.rb が Cybertrain::Main.run の前に require するファイル）
require "json"
require "cybertrain/websocket"
require "cybertrain/net/tls"   # wss:// のときだけ。システムの libssl をリンクする

Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"],
    headers: { "Authorization" => "Bearer #{ENV["FEED_TOKEN"]}" },
    stale_after: 30)
  .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe", "channel" => "trades" })) }
  .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
```

`cybertrain/websocket` を require すると、フィードが `Cybertrain::Background` に登録されます。`Application#serve` がスケジューラーの後にこれを開始し、シャットダウン時に停止するので、呼び出すものは何もありません。購読ごとに 1 本のスレッドが付きます。スレッドは接続し、`on_open` を実行し（購読のメッセージはここで送ってください：再接続のたびに再び実行されます）、その後、各メッセージを `Connection`（`send_text`、`send_binary`、`close`、そして `:text` か `:binary` の `last_opcode`）とともに `on_message` に渡します。ブロックは引数を受け取り、`self` は使えません（Spinel には `instance_eval` がありません）。

- **いつ実行されるか。** フィードは、スケジューラーと同じく、バイナリが配信を行うときに始まります（[バックグラウンド処理](background-and-operations.md#background-work)）。`migrate`、`db ...`、`Main.command` のコマンドと `Cybertrain::Test::Client` では決して始まりません。`CYBERTRAIN_WORKER=0`（`config.worker = false`）では、そのプロセスでは動きません（単に始まらないだけです。唯一の知らせはスケジューラーの「run elsewhere」の行で、`WebSocket.start!` を直接呼んだ場合は自分でログを出します）：複数のプロセスが配信する場合は、1 つを除いてすべてで無効にしてください。そうしないと、それぞれがフィード全体を受信します。`subscribe` はサーバーが始まる前に呼ぶ必要があります。動作中にフィードを追加したり削除したりすることはできません。名前は一意で（`ArgumentError`）、`on_message` のないフィードは、ポートをバインドする前に起動を失敗させます（`error: WebSocket subscription "trades" has no on_message`、終了コード 1）。
- **オプション。** `headers:`（ハンドシェイクに追加するヘッダー）、`timeout:`（接続中の各待ちと各書き込みに 5 秒）、`max_message:`（1 MiB。それより大きいメッセージは 1009 で接続を閉じます）、`ping_interval:`（15）と `stale_after:`（45）、そして `allow_private:`（下記の `HttpClient` と同じ）。
- **待機と再接続。** 失敗のたびに、スレッドは `min(60, 2 ** (attempt - 1))` 秒、前後 20 % のジッター付きで待ちます：1、2、4、... 60。60 秒続いた接続は、再び 1 から始まります。すべての待ちに上限があります。`WebSocket.stop!` は、サーバーが何をしても約 2 秒以内に戻ります：すべてのスレッドを合わせて最大 2 秒待ち、接続中のフィードはクローズ（1000）を送ってサーバーの応答を最大 1 秒待ち、戻った時点ですべてのフィードの `connected?` は false です（まだ閉じている途中のスレッドは自分で終わります）。
- **無音。** フィードは接続を閉じないまま静かになることがあるので、スレッドはフレームが何もないまま `ping_interval` 秒たつと ping を送り（その後は間隔ごとに 1 回）、pong も含めてフレームが `stale_after` 秒まったく届かなければ、接続を閉じて再接続します。`stale_after` は `ping_interval` より大きくなければならず、`ping_interval` は 1 以上でなければなりません（`subscribe` からの `ArgumentError`）。
- **ブロック内のエラー。** `on_message` での例外はログに記録され、接続はそのままです。`on_open` での例外はログに記録され、接続は閉じられて再試行されます。購読していないフィードは役に立たないためです。
- **ログに出るもの。**

  | いつ | レベル | 行 |
  | --- | --- | --- |
  | 開始 | INFO | `WebSocket started: trades (wss://feed.example.com:443)` |
  | 接続 | INFO | `WebSocket "trades" connected to feed.example.com:443` |
  | 切断 | WARN | `WebSocket "trades" disconnected: Cybertrain::WebSocket::ClosedError: feed.example.com:443: closed by the server (1001) (retry in 2s)` |
  | 無音 | WARN | `WebSocket "trades" silent for 45s; reconnecting` |
  | ブロックが例外を出した | ERROR | `WebSocket "trades" on_message failed: KeyError: ...`（または `on_open`） |

  パスとクエリがログやエラーメッセージに出ることは決してありません：トークンを含んでいることが多いからです。
- **エラー。** すべて `Cybertrain::WebSocket::Error` で、メッセージにはホストとポートだけが含まれます。ハンドシェイクが済んだ後は、失われた接続やサーバーによるクローズは `ClosedError`（`close_code`、`close_reason`。リセットやクローズフレームなしの終了は 1006）です。タイムアウトした書き込みや TLS で失敗した書き込みは、引き続き `TimeoutError` や `TLSError` です。接続中は `RefusedError`、`TimeoutError`、`TLSError`、`BlockedAddressError`（公開されていないアドレスで、[外向きの HTTP](#outbound-http) とまったく同じくデフォルトで拒否され、同じ `allow_private:` と `http_allow_private` の設定を持ちます）、または `HandshakeError`（101 でない、`Sec-WebSocket-Accept` が誤っている、またはサーバーが拡張やサブプロトコルで応答した）です。`ProtocolError`（サーバーがフレーミングを壊した。クライアントは 1002 を送ります）と `TooLargeError` はいつでも起こりえます。
- **ヘルス。** `Cybertrain::WebSocket.feed_status("trades")` は `Status` を返します：`connected?`、`last_message_at`（エポック秒。最初のメッセージの前は 0）、`reconnects`。これは `GET /up` には含まれません。自前のチェックで使ってください。3 つは 1 つのスナップショットとしてではなく順に読まれ、`connected?` は接続ができた時点、`on_open` の実行前に true になります。
- **`on_message` は短く保つ。** スレッドは `wait_readable` か `sleep` で待つので、止まったフィードが待っている間 OS のワーカーを占有することはありません。占有するものは 2 つあります：各接続の試行はブロッキングする `getaddrinfo` でホスト名を解決します（[外向きの
  HTTP](#outbound-http) の「名前解決はブロックする」を参照。`SPINEL_WORKERS=1` では、死んだリゾルバーがフィードごと・試行ごとに 1 回、リゾルバーのタイムアウトの間すべてのリクエストを止めます。URL に IP アドレスを書けば問い合わせを避けられます）。そして `on_message` の中の SQLite の呼び出しは、定期タスクと同じく戻るまで占有します（[バックグラウンド
  処理](background-and-operations.md#background-work)）：`SPINEL_WORKERS=1` では、長い書き込みがすべてのリクエストを止めます。忙しいフィードでは小さな行を 1 つ挿入するか、メッセージをメモリーに集めて `Scheduler.every` のタスクからまとめて書き込んでください。
- **作られていないもの。** 拡張（`permessage-deflate`）とサブプロトコルはネゴシエートされません。プロキシ、リダイレクト、cookie のサポートも、メッセージの自動保存も、WebSocket サーバー（ActionCable）もありません。テキストフレームが有効な UTF-8 かは検査されません（RFC 6455 の 8.1 節からの逸脱）：バイト列は届いたまま渡されます。`Connection` が有効なのはコールバックの間だけです。リクエストやタスクから送信することはサポートされていません。

再接続のループなしの 1 本の接続（スクリプト、1 回だけの読み取り）には、同期的なクライアントを使います：

```ruby
require "cybertrain/websocket"
require "cybertrain/net/tls"   # wss:// のときだけ

client = Cybertrain::WebSocket::Client.connect("wss://feed.example.com/v1", timeout: 5)
client.send_text("hello")
msg = client.receive(10)      # 最大 10 秒待つ。何も来なければ nil
msg.ws_opcode                 # :text または :binary
msg.ws_data                   # バイト列
client.close
```

設計：[docs/design.md](../design.md) D33。

## メールを送る

`Cybertrain::Mailer` は、SMTP サーバー（プロバイダーのサブミッションサーバー、またはローカルのリレー）を通じてプレーンテキストのメールを送ります。HTTP クライアントと同じく `require "cybertrain"` には含まれておらず、TLS は別に require します：

```ruby
require "cybertrain/mailer"
require "cybertrain/net/tls"   # starttls（デフォルト）と tls のため。システムの libssl をリンクする

# 設定は CYBERTRAIN_SMTP_HOST、_PORT、_USER、_PASSWORD、_FROM、_TLS から：
begin
  Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello #{user.name},\n...")
rescue Cybertrain::Mailer::Error => e
  Cybertrain.logger.warn("mail: #{e.message}")   # パスワードは決して含まない
end

# または、Config を経由せず明示的に設定する：
mailer = Cybertrain::Mailer.new(host: "smtp.example.com", port: 587, tls: "starttls",
                                user: "app", password: ENV["SMTP_PASSWORD"].to_s,
                                from: "noreply@example.com", timeout: 10, deadline: 60)
mailer.deliver(to: "a@example.com, b@example.com", subject: "Report", body: report)
```

| 変数 | 属性 | デフォルト |
| --- | --- | --- |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`（設定されるまで `Mailer.new` は `ArgumentError` を出す） |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`：`starttls` なら 587、`tls` なら 465、`none` なら 25 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`：AUTH なし |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`（秘密の値） |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`。`tls` または `none` |

- **TLS のモード。** `starttls` は平文で接続し、サーバーが STARTTLS を提供することを求め（なければ `Mailer::TLSError`）、他に何かを話す前にアップグレードします。サーバーが STARTTLS の応答の後に送ってきたバイトは拒否されます。`tls` は最初のバイトから TLS を話します（ポート 465）。どちらも HTTP クライアントと同じく証明書を `host` に対して検証し（IP アドレスではなくホスト名を指定してください）、どちらにも `require "cybertrain/net/tls"` が必要です：それがないと、`deliver` は接続する前に、その旨を伝える `Mailer::TLSError` を出します。`none` は平文で、同じマシン上のリレーやテストサーバー向けです：ユーザーが設定されている場合、ホストがループバックアドレスに解決されない限り拒否し（接続する前に `Mailer::InsecureError`）、解決される場合はそのループバックアドレスにだけ接続します。
- **パスワードがログに出たり表示されたりすることはない。** 起動バナー、`help`、ログ、どのエラーメッセージにも含まれず、送られるのは TLS 越しに（またはループバックへ）AUTH PLAIN コマンドの中だけです。パスワードを保持している `Mailer` や `Config` を `p` や `inspect` しないでください。
- **すべての待ちに上限がある。** [外向きの HTTP](#outbound-http) と同じく：接続、TLS の各手順、各応答は最大 `timeout` 秒（デフォルトは 10）待ち、配信全体では最大 `deadline` 秒（デフォルトは 60）待ちます。それを超えると `Mailer::TimeoutError` です。名前解決は呼び出したスレッドをブロックします。
- **やり取り：** 220 の挨拶、`EHLO`（名前は `helo:`。デフォルトは `localhost`）、`STARTTLS` と再度の `EHLO`、ユーザーが設定されていれば `AUTH PLAIN`（サーバーが PLAIN を提供する必要があります）、`MAIL FROM`、受信者ごとに 1 つの `RCPT TO`、`DATA`、`QUIT`。それ以外のコードの応答は `Mailer::RejectedError` で、その `smtp_code` はサーバーのもの（421、535、550 など）、メッセージには手順とサーバーのテキストが含まれます。戻り値は、メッセージに対するサーバーの応答です（`"250 2.0.0 Ok: queued
  as ..."`）。
- **メッセージ：** `Date`、`From`、`To`、`Subject`、`MIME-Version: 1.0`、`Content-Type: text/plain; charset=UTF-8`。ASCII 以外を含む件名は RFC 2047 でエンコードされます（`=?UTF-8?B?...?=`。文字の境界で分割されます）。本文の改行は CRLF になり、`.` で始まる行はドットスタッフィングされます。`Content-Transfer-Encoding` は、ASCII なら `7bit`、UTF-8 でサーバーが 8BITMIME を広告していれば `8bit`（`MAIL FROM
  ... BODY=8BITMIME` 付き）、それ以外や 998 バイトより長い行がある場合は `base64` です。`Message-ID` は追加しません（サブミッションサーバーが追加します）。
- **拒否されるもの。** 接続する前に `ArgumentError` で：素の ASCII の `local@domain` でないアドレス（表示名、`<>`、空白、カンマ、引用符、CR、LF は不可。最大 254 バイト）、CR、LF、NUL を含む（ヘッダーインジェクション）または 998 バイトを超える件名、有効な UTF-8 でない、または NUL を含む本文、100 を超える受信者。`to:` は 1 つのアドレス、またはカンマで区切った複数のアドレスを受け取ります。
- **まだないもの：** HTML とマルチパートのメッセージ、添付ファイル、テンプレート、表示名、`Cc`/`Bcc` ヘッダー（代わりに複数の受信者に送ってください）、AUTH LOGIN/CRAM-MD5、SMTPUTF8 のアドレス、パイプライン、配信キュー（配信は呼び出したスレッド、つまりリクエストと同じくグリーンスレッドで実行されます）。`cybertrain generate authentication` は今もパスワードのリセットを書き出しません。

設計：[docs/design.md](../design.md) D27。
