---
source_sha256: 31cef0c4fd1f43cff188d2552a04cd69056b049d8bc2dcc24fb09e6bc6ef3dae
---
# 設定

## 設定と環境変数

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

`Cybertrain::Config` はまず環境変数を読み、`config/app.rb` がそれを上書きします：

| 変数 | 属性 | デフォルト |
| --- | --- | --- |
| `CYBERTRAIN_ENV` | `env` | `"development"`。`cybertrain build` で作ったバイナリでは `"production"`（`"test"` もある）。`c.env` ではなく変数で設定してください：`database_path`、`session_secure`、`mail_delivery_method` のデフォルトは、`config/app.rb` が実行される前にこの値から決まります |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `DATABASE_URL` | `database_url` | `""`。MySQL だけ：`cybertrain/mysql` でビルドしたアプリケーションが接続するデータベース、`mysql://USER:PASSWORD@HOST:3306/NAME`（[MySQL](#mysql)を参照）。空か形式が正しくないと起動に失敗する |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | 本番環境では必須。開発環境とテスト環境では `tmp/secret_key` に自動生成される |
| `CYBERTRAIN_ENCRYPTION_KEY` | `encryption_key` | `""`。64 文字の 16 進数（`cybertrain secret --hex`）で、モデルが `encrypts` で暗号化するカラムの鍵。形式が正しくないとき、またはモデルが `encrypts` を宣言しているのに空のとき、起動は失敗する（[暗号化されたカラム](models.md#encrypted-columns)を参照） |
| `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` | `encryption_keys_previous` | `[]`。カンマ区切りの以前の鍵で、復号にだけ試される。レコードを保存し直せば鍵を入れ替えられる。形式の正しくない項目があると起動は止まる |
| `SPINEL_WORKERS` | `workers` | `1`。開発サーバーはこの値を無視して常に 1 ワーカーで動きます（[理由](template-language.md#file-resolution-enginerb)） |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`。`0.0.0.0` はすべてのインターフェースで待ち受ける（コンテナー向け） |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | 開発環境は `localhost`、`127.0.0.1`、`[::1]` を受け付ける。カンマ区切りの完全なホスト名でこのリストを拡張できる（スキーム、ポート、ワイルドカードは不可）。その他のホストには、静的ファイル、セッション、ルーティング、診断の前に 403 を返す。これは待ち受けアドレスとは別のもので、本番環境とテスト環境がこのリストを使うのは、`CYBERTRAIN_HOSTS` が確認を有効にしたときだけ |
| `CYBERTRAIN_HOSTS` | `hosts_from_env`（`allowed_hosts` に追加） | `[]`。カンマ区切りの完全なホスト名（IPv6 アドレスは角かっこで囲む。スキーム、パス、ポート、ワイルドカードは不可で、あれば起動に失敗する）で、どの環境でもループバックの名前の後に追加される。設定すると本番とテストでもホストを確認し、ほかの `Host` には 403 `Blocked host` を返してログに残す。ヘルスチェックのパスへの GET と HEAD は Host にかかわらず通る（[ホスト](requests.md#content-security-policy-force_ssl-and-hosts)を参照） |
| `CYBERTRAIN_FORCE_SSL` | `force_ssl` | `false`。`1` か `true` で http を https にリダイレクトし（GET と HEAD は 301、それ以外は 307。プロキシの後ろでは `X-Forwarded-Proto` で判断）、`Strict-Transport-Security: max-age=63072000; includeSubDomains` を送り、すべての Cookie を `Secure` で書く。ヘルスチェックのパスはリダイレクトしない。`1`、`true`、`0`、`false`、空以外の値なら起動が止まる。プロキシの後ろでは `CYBERTRAIN_TRUSTED_PROXY` か `CYBERTRAIN_TRUSTED_PROXIES` も設定する。しないと、アプリが組み立てる URL は http のまま |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`。`Strict` や `None` も可（`None` は常に `Secure` を追加する）。それ以外の値ではサーバーが起動時に停止する |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`。`1` または `true` で `Partitioned`（と `Secure`）を追加する |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`。`1` または `true` にすると、同じホスト上のリバースプロキシのために、ループバックからの接続の `request.client_ip`（`rate_limit` が数えるもの）を `X-Forwarded-For` の最後のアドレスにする（[レート制限](requests.md#rate-limiting-and-the-client-address)を参照）。`CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` の省略形 |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`。カンマ区切りの IPv4/IPv6 アドレスまたは CIDR（`172.16.0.0/12,10.0.0.0/8`）で、そこからの接続では `request.client_ip` を `X-Forwarded-For` の最後のアドレスから取る。コンテナー内の kamal-proxy のように、ネットワーク越しに到達するプロキシ向け。不正なエントリーがあるとサーバーは起動時に停止する |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`：`params.page_number` が返し、`Relation#page` が受け付ける最大のページ（[ページネーション](models.md#pagination)を参照）。最大 18 桁の数値でない値や、1 未満の値はデフォルトになる |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`。カンマ区切りの名前でリストを置き換える。名前にこれらのいずれかを含むパラメーター（ASCII の大文字小文字を区別しない：`password` は `user[password]` にも一致する）は、リクエストログと開発環境のエラーページで値が `[FILTERED]` と書かれる。`config/app.rb` で `[]` にすると無効になる |
| `CYBERTRAIN_LOG_LEVEL` | `log_level` | `:info`：書き出す最も低いレベル。`debug`、`info`、`warn`、`error`、`fatal`、`none`（大文字小文字は問わない。`none` はリクエストログを止め、エラーの行は書く）。それ以外では起動が止まる（[ログ](logs-and-errors.md#logs)を参照）。`cybertrain test` は、`config/app.rb` が設定しない限り `:none` を使う |
| `CYBERTRAIN_LOG_FORMAT` | `log_format` | `:text`。`json` はログ収集ツール向けに 1 行 1 つの JSON オブジェクトを書く。それ以外では起動が止まる。`cybertrain test` は、変数にかかわらず、`config/app.rb` が設定しない限りテキストの行のまま |
| `CYBERTRAIN_SENTRY_DSN` | `sentry_dsn` | `""`：何も送らない。Sentry か GlitchTip の DSN にすると、各エラー報告をそこに送る（[エラー報告](logs-and-errors.md#error-reporting)を参照）。`bin/<app>.rb` に `require "cybertrain/error_reporter/sentry"`（または `require "cybertrain"`）が必要で、ないと起動を拒む。読めないものでは起動が止まり、どの部分かを示すがキーは示さない。`cybertrain test` は、`config/app.rb` が代入しない限り空にする |
| `CYBERTRAIN_ERROR_SAMPLE_RATE` | `error_sample_rate` | `1.0`：Sentry に送るエラー報告の割合。0.0〜1.0 を、数字に任意の `.数字` が続く形で書く。サブスクライバーはすべての報告を受け取る。それ以外では起動が止まる |
| `CYBERTRAIN_RELEASE` | `release` | `""`：各エラー報告と一緒に送るバージョンかコミット |
| `CYBERTRAIN_WORKER` | `worker` | `true`。`0` または `false` にすると、`server` プロセスは定期タスク、ジョブ、WebSocket のフィードを実行しない（[プロセスの役割](background-and-operations.md#process-roles)を参照）。`./<app> worker` と `feeds` はこれを無視する |
| `CYBERTRAIN_JOB_THREADS` | `job_threads` | `3`：1 つのプロセスが同時に実行するジョブの数（[バックグラウンド処理](background-and-operations.md#background-work)を参照）。1 以上 |
| `CYBERTRAIN_TIME_ZONE` | `time_zone` | `"UTC"`：アプリケーションのゾーン。`Asia/Tokyo` のような IANA の名前で、`Time.zone`、日と月の境界、`Date.current`、`l` と `time_tag` に使う（[タイムゾーン](#time-zones)を参照）。システムの zoneinfo にないゾーンでは起動が止まる |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | 設定しなければ `time_zone`：`tz:` のない `Scheduler.cron` のタスクを読むゾーン。IANA の名前（[タイムゾーン](#time-zones)を参照）。システムの zoneinfo にないゾーンでは起動が止まる |
| `CYBERTRAIN_JOBS_PAGE_PER_PAGE` | `jobs_page_per_page` | `50`：[ジョブページ](background-and-operations.md#the-jobs-page-and-the-jobs-command)のリストごとの行数。1 以上 |
| `CYBERTRAIN_CACHE_PRUNE_INTERVAL` | `cache_prune_interval` | `300`：[キャッシュ](background-and-operations.md#the-cache-store)の期限切れの行を掃除する間隔の秒数。1 以上。`cybertrain/jobs` があるときは、定期的な掃除のタスクが登録されるときに一度だけ読まれる。これは両方が require される時点で、`config/app.rb` の実行より前なので、変数で設定する。ジョブがないときはキャッシュへの書き込みのたびに読まれるので、`c.cache_prune_interval` も効く |
| `CYBERTRAIN_FEED_STATUS_INTERVAL` | `feed_status_interval` | `10`：各 WebSocket フィードの状態の行を書く間隔の秒数（[フィードのヘルス](realtime.md#feed-health)を参照）。1 以上 |
| `CYBERTRAIN_FEED_RESTART_LIMIT` | `feed_restart_limit` | `10`：期間内のフィードのスレッドの再起動の回数。これを超えてまた死ぬと、`feeds` のプロセスは終了ステータス 1 で終わる（[WebSocket フィードを購読する](external-services.md#consuming-websocket-feeds)を参照）。1 以上 |
| `CYBERTRAIN_FEED_RESTART_WINDOW` | `feed_restart_window` | `600`：その期間の秒数。1 以上 |
| `CYBERTRAIN_STREAM_PATH` | `stream_path` | `"/cybertrain/stream"`：リアルタイムのエンドポイント（[リアルタイム](realtime.md#limits-and-settings)を参照）。空の値でストリームが無効になる。`/` で始まり、`health_path` と異なっていなければならない |
| `CYBERTRAIN_REUSE_PORT` | `reuse_port` | `false`。`1` または `true` にすると `SO_REUSEPORT` で bind し、複数のプロセスが 1 つのポートで listen でき、Linux ではカーネルが接続を振り分ける（開発環境では無視される。[Running several processes](../deploy.en.md#running-several-processes)を参照）。1 つを除くすべてのプロセスで `CYBERTRAIN_WORKER=0` にする |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`。組み込みのヘルスチェックのパス（[運用](background-and-operations.md#operations-backups-vacuum-health-check)を参照）。空の値で無効になり、先頭に `/` のない値ではサーバーが起動時に停止する。`health_worker_stale`（300 秒）は `config/app.rb` で設定する |
| `CYBERTRAIN_HEALTH_FEEDS` | `health_feeds` | `true`：ヘルスチェックは、状態を報告しなくなった、または黙った WebSocket フィードについても `503 feed stale` を返す（[フィードのヘルス](realtime.md#feed-health)を参照）。`0` か `false` でこの部分が無効になる |
| `CYBERTRAIN_HEALTH_FEED_STALE` | `health_feed_stale` | `180`：`503 feed stale` になるまでの、フィードが黙っている、またはそのプロセスが状態を書かない秒数。1 以上で、`health_feeds` が有効な間は `feed_status_interval` より大きいこと（そうでなければ起動時に拒否されます） |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`。`1` または `true` にすると、`Cybertrain::HttpClient` がループバック、プライベート、その他の公開されていないアドレスに接続できる（[外向きの HTTP](external-services.md#outbound-http) を参照） |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`。`Cybertrain::Mailer` が送信に使う SMTP サーバー（[メールを送る](external-services.md#sending-e-mail)を参照） |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`：モードのポート。`starttls` なら 587、`tls` なら 465、`none` なら 25。1〜65535 以外は 0 になる |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`：AUTH なし。設定するとメーラーは AUTH PLAIN で認証する |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`。秘密の値で、ログにも起動バナーにもエラーメッセージにも出ない |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`：`from:` が与えられないときに `Mailer.deliver` が使う送信者 |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`。`tls`（暗黙の TLS）や `none`（平文。資格情報はループバックへのみ）も可。どちらの TLS モードにも `bin/<app>.rb` に `require "cybertrain/net/tls"` が必要：`require "cybertrain"` は読み込むが、`cybertrain/core` と `cybertrain/mailer` は読み込まない（[サブシステム](how-it-works.md#subsystems)） |
| `CYBERTRAIN_MAIL_DELIVERY_METHOD` | `mail_delivery_method` | テスト環境では `:test`、それ以外では `:smtp`：`:test` は各メールを送らずに `Cybertrain::Mailer.deliveries` に保持する（[メールのテスト](testing.md#testing-mail)）。テスト環境の外では警告を出して起動し、何も送らない。それ以外の値では起動が止まる。`cybertrain test` は、変数が何であっても、`config/app.rb` が設定しない限り `:test` を使う |
| `CYBERTRAIN_TEST_DATABASE` | — | `""`：`storage/test.sqlite3` の代わりに、`cybertrain test` が削除し、マイグレートし、テストを実行するファイル。ファイルのパス（`:memory:` や `file:` の URI は不可）。既存のファイルを削除するのは、`cybertrain test` が作ったもの（作るデータベースに印を付ける）、このアプリケーション自身の `storage/test.sqlite3`、空のファイルのときだけ。それ以外と、開発用や本番用のデータベースは終了ステータス 2 で拒否され、何も削除されない（[テストを実行する](testing.md#running-the-tests)） |
| `CYBERTRAIN_I18N_DEFAULT_LOCALE` | `i18n_default_locale` | `:en`：すべてのリクエストが始まるロケール。`ja` や `pt-BR` のような名前（[ロケール](#locales) を参照）。それ以外は起動を止める |
| `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS` | `auth_lockout_attempts` | `10`：アカウントがロックされるまでの間違ったパスワードの回数。`0` でロックアウトを無効にする（[認証の設定](#authentication-settings) を参照） |
| `CYBERTRAIN_AUTH_LOCKOUT_PERIOD` | `auth_lockout_period` | `3600`：ロックアウトが続く秒数。1 以上 |
| `CYBERTRAIN_AUTH_REMEMBER_FOR` | `auth_remember_for` | `2592000`（30 日）：「ログインしたままにする」サインインが続く秒数。1 以上 |
| `CYBERTRAIN_AUTH_IDLE_TIMEOUT` | `auth_idle_timeout` | `604800`（7 日）：リクエストがないままサインインが終わるまでの秒数。`0` で無効 |

`cybertrain test` は、`config/app.rb` が代入しない限り、このうちのいくつかにテスト用の独自の値を与えます。その旨を書いた 4 つの行のほかに、`force_ssl` は無効になり、`CYBERTRAIN_HOSTS` は空になります（どちらも変数が何であっても）。`csrf` は無効、`upload_root` は `tmp/test_uploads` になり、`smtp_from` は `CYBERTRAIN_SMTP_FROM` が設定されていなければ `"from@example.com"` になります（[テストを実行する](testing.md#running-the-tests)）。

`None` を（`CYBERTRAIN_SESSION_PARTITIONED=1` とともに）使うのは、別のサイトのフレーム内に表示されるアプリだけにしてください。ブラウザーは HTTPS でアプリに到達する必要があります。

そのほかの属性には変数がなく、`config/app.rb` で設定します：

| 属性 | デフォルト | 意味 |
| --- | --- | --- |
| `views_root` | `"app/views"` | 開発環境とテスト環境でテンプレートを読む場所。ビルドしたバイナリは埋め込まれたテンプレートを使う |
| `public_root` | `"public"` | 静的ファイルのディレクトリ。エラーページ `public/<status>.html` もここから探す |
| `layout` | `"layouts/application"` | すべてのページがレンダリングされるレイアウト。ファイルがなければ無視される |
| `secret_key_path` | `"tmp/secret_key"` | 開発環境とテスト環境が、生成した秘密の値を保存する場所 |
| `log_tags` | `[:request_id]` | 各ログ行に付くリクエストのタグ：`:remote_ip` でクライアントのアドレスを足し、`[]` で何も付けず、それ以外では起動が止まる（[リクエスト ID](logs-and-errors.md#request-ids)） |
| `session_cookie_name` | `"_cybertrain_session"` | セッションの cookie の名前 |
| `session_max_age` | `1209600`（2 週間） | セッションの cookie の `Max-Age`（秒）。セッションが変わるたびに数え直す |
| `session_absolute_max_age` | `1209600`（2 週間） | どれだけ使われていても、セッションが続く最長の秒数：これより古い cookie は空のセッションとして読み込まれる。`0` で制限なし |
| `session_secure` | 本番環境では `true`、それ以外では `false` | セッションの cookie に `Secure` を付ける。`SameSite=None` と `Partitioned` はいずれにしても `Secure` を追加する |
| `pool_size` | `4` | プール内の SQLite 接続の数 |
| `static_files` | `true` | `public/` を配信するかどうか。リバースプロキシが配信するなら無効にする |
| `csrf` | `true` | GET 以外のリクエストに CSRF トークンを要求するかどうか（なければ 403） |
| `csrf_exempt_prefixes` | `[]` | その下の GET 以外のリクエストが CSRF のチェックを飛ばす、パスのプレフィックス（下記） |
| `max_body_bytes` | `10485760`（10 MiB） | 送られたままのサイズでこれより長いリクエストボディには、読む前に 413 を返す。大きなアップロードには引き上げる。gzip されたボディの展開後のサイズは、別に `request.decoded_body(limit)` で制限される |
| `body_timeout` | `120` | ヘッダの終わりから数えて、リクエストボディ全体が届くまでに許す秒数。超えると、クライアントが少しずつ送り続けていても（slowloris）408 を返して接続を閉じる。遅い回線で大きなアップロードを受けるなら引き上げる |
| `max_connections` | `1024` | 同時に開いておく接続の数（ストリーム接続も含む）。それを超えた接続には 503 を返して閉じる。接続ごとにファイルディスクリプタを 1 つ使うので、プロセスの上限（`ulimit -n`）より十分小さくし、リスナー、ログ、データベースなど他に開くファイルの分を残しておく。上限に達すると、503 を返すための接続さえ受け付けられない |
| `max_render_depth` | `12` | 同時に開いているレンダリングの数（ページとそのパーシャル）：ページが深さ 1 なので、パーシャルは 11 階層までネストできる（レイアウトはページの後にレンダリングされ、ネストしない）。それより深いとテンプレートエラー。1 以上でなければ起動に失敗する |
| `max_upload_bytes` | `5242880`（5 MiB） | アップロードされるファイル 1 つの最大サイズ。`max_body_bytes` を超えてはならない |
| `max_multipart_parts` | `128` | 1 つのマルチパートボディのパートの最大数（テキストフィールドを含む）。最大 4096 |
| `upload_root` | `"storage/uploads"` | `Cybertrain::BlobStore` が書き込む場所。起動時ではなく最初のアップロードで作られる |

**CSRF を除外するプレフィックス：** `csrf_exempt_prefixes` は、`"/api/"` のように、プログラムが独自の資格情報で呼び出すエンドポイントのためのものです。各プレフィックスは `/` で始まって `/` で終わり、`/` だけであってはならず、そうでなければ起動に失敗します。プレフィックスは送られたままのパスに対して照合されるので、パーセントエンコードした綴りも引き続きチェックされます。他のルートがプレフィックス以下のパスに一致してはならず、除外されたコントローラーは認証をセッションに頼ってはなりません。そこでもセッションは読み込まれるためです。

**ジョブとストリーム：** 上の変数のほかに、`config/app.rb` では `scheduler_interval`（1 秒、スケジューラーのティック）、`job_poll_interval`（1 秒、手の空いたジョブスレッドが待つ時間）、`job_max_attempts`（5）、`job_heartbeat_interval`（30 秒）、`job_heartbeat_stale`（300 秒、間隔より長く）、`job_drain_timeout`（10 秒、`SIGTERM` が実行中のジョブを待つ時間）、`scheduler_lease_ttl`（30 秒、`scheduler_interval` の 2 倍以上）と、ストリームの設定 `stream_poll_ms`、`stream_retention`、`stream_ping_interval`、`stream_max_connections`、`stream_max_message`、`stream_max_backlog`（[上限と設定](realtime.md#limits-and-settings)）を設定します。範囲外の値なら、起動はその名前を示すメッセージを出して止まります。

**セキュリティヘッダー：** サーバーが書き出すすべてのレスポンス（アクション、静的ファイルのミドルウェア、エラーページと開発環境の診断ページ、サーバー自身の 400/411/413/500、そして HEAD）は、`X-Content-Type-Options: nosniff`、`X-Frame-Options: SAMEORIGIN`、`Permissions-Policy: camera=(), microphone=(), geolocation=()` を持ちます。ただし、レスポンスがすでにその名前のヘッダー（大文字小文字は問わない）を設定している場合は別です：`Response#to_http` はレスポンス自身のヘッダーの後に、ないときだけこれらを追加するので、アクションで `response.set_header("X-Frame-Options", "DENY")` とすれば、指定した値がちょうど 1 回送られます。`c.permissions_policy` は三つ目の値を置き換え（`"camera=(), microphone=(), geolocation=(self)"`）、`""` なら送らず、CR や LF を含むと起動が止まります。アプリ全体で最初の二つを無効にする `Config` のスイッチは意図的に用意していません。埋め込み可能なウィジェットは、自身のレスポンスでヘッダーを上書きします（現在のブラウザーでは、`Content-Security-Policy: frame-ancestors ...` ヘッダーが `X-Frame-Options` より優先されます）。`nosniff` があるため、ブラウザーは `Content-Type` を文字どおりに受け取ります：静的ファイルのミドルウェアは `public/` によくある拡張子（html、css、js/mjs、webp と avif を含む画像、フォント、wasm、pdf、音声と動画、json、csv、xml）を知っており、それ以外は `application/octet-stream`、つまりダウンロードとして配信されます。アプリが別の拡張子をインラインで必要とする場合は、`Cybertrain::Static::EXTENSIONS` に追加してください。`public/` を自分で配信するリバースプロキシは、これらのヘッダーを経由しません（[docs/deploy.en.md](../deploy.en.md) を参照）。`Cybertrain::Test::Client` はアプリをプロセス内で呼び出し、レスポンスをシリアライズしないので、これらのデフォルトは見えません。`response.to_http` に対してアサートしてください。

**Content Security Policy：** Rails と同じく既定では無効で、`cybertrain new` は下のブロックをコメントアウトして `config/app.rb` に書きます。`c.content_security_policy do |p| ... end` がポリシーを宣言し（ディレクティブごとのメソッドで `p.script_src :self, "https://cdn.jsdelivr.net"`。二度目の呼び出しは同じポリシーに足します）、`c.content_security_policy_nonce_directives`（`[]`）がリクエストの nonce を付けるディレクティブを挙げ（ディレクティブでない名前なら起動が止まります）、`c.content_security_policy_report_only`（`false`）はヘッダーを `Content-Security-Policy-Report-Only` として送ります。コントローラーは `content_security_policy do |p|` で自分のコピーを宣言します。[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)を参照してください。

**フィルターされるパラメーター：** リクエストログの `Started GET "/login?..."` の行と開発環境のエラーページ（そのリクエスト行と、params や JSON ボディのダンプ）は、Rails の `filter_parameters` と同じく、`config.filter_parameters` に名前のあるすべてのパラメーターの値を `[FILTERED]` と表示します。そのため、URL 内の `?token=` や、失敗したフォームに送信されたパスワードが、フレームワークのリクエストログや開発環境のエラーページに現れることはありません。置き換えられるのは値だけです：クエリ文字列の残りは送られたままログに記録されます（制御文字はエスケープされます）。リストは大文字小文字を区別せず、部分文字列で照合します。`config/app.rb` で拡張する（`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`）か、`CYBERTRAIN_FILTER_PARAMETERS` で置き換えてください。アクションが自分でログに出す値はフィルターされません。そこでは `Cybertrain::ParameterFilter.filter?(name)` や `ParameterFilter.filter_query(text)` に問い合わせてください。

**フィルターされるパス：** パスそのものに含まれる秘密（`/results/<token>` のような共有リンクのトークン）には、フィルターの手がかりになるパラメーター名がありません。そこで、その直前のプレフィックスを列挙します：`c.filter_path_prefixes = ["/results/"]` とすると、フレームワークがリクエストのパスを書き出すすべての場所（リクエストログの `Started` の行、`Blocked host` の行、エラーレポートのリクエスト、開発環境のエラーページ）で、`/results/` の次のセグメント全体が `[FILTERED]` と書かれます。プレフィックスは送られたままのパスと先頭のバイトから照合され、`/` で始まって `/` で終わり、`/` だけであってはなりません。そうでなければ起動に失敗します。リストはデフォルトでは空です。フレームワーク自身の署名付きトークン（パスワード再設定リンクのもの）は、これがなくてもその形で伏せられます。前段のリバースプロキシは独自のログを残します。そちらでもパスを伏せてください。

**デプロイ：** `cybertrain build` は `dist/` を作ります：ビューを埋め込んだバイナリ `dist/NAME`、`dist/public/`（静的アセット。リバースプロキシに配信させてもかまいません）、`dist/storage/`（デフォルトでは SQLite のファイル）、`dist/tmp/` です。`CYBERTRAIN_SECRET_KEY_BASE` を設定して `dist/` から実行します。`CYBERTRAIN_ENV` で指定しない限り本番環境で、`./NAME
migrate` はバイナリに組み込まれたマイグレーションを適用します。バイナリが話すのは素の HTTP/1.1 だけです。TLS と HTTP/2 には nginx や Caddy を前に置いてください（本番環境ではセッションの cookie が `Secure` なので、HTTPS で配信してください）。本番環境では、例外には 500 を返し、飾りのないエラーレスポンス（ルーターのプレーンテキストの 404、`head :not_found`、`render plain:`）は、`public/<status>.html` があればそれに置き換えられます。アクションが HTML や JSON としてレンダリングしたエラーはそのまま通ります。`SIGTERM` を受けると、新たな受け付けを止め、処理中のリクエストを完了させ（`Connection: close` で応答します。アイドル状態の keep-alive 接続はすぐに閉じます）、それらが終わるか、サーバーの `drain_timeout`（10 秒）が過ぎると終了します。監視と再ビルドのループは本番環境では決して動きません。[docs/deploy.en.md](../deploy.en.md)（日本語版：[docs/deploy.md](../deploy.md)）では、`cybertrain new`、Ubuntu のサーバー、systemd、HTTPS 付きの Caddy、再デプロイ、ロールバック、バックアップまで、全体を通して説明しています。

**Kamal：** `cybertrain new` は [Kamal 2](https://kamal-deploy.org) が必要とするものも書き出します：Ubuntu のビルドステージで `cybertrain setup` と `cybertrain build` を実行し、同じリリースのスリムなステージに `dist/` をコピーする（起動時にマイグレーションし、その後 `0.0.0.0:3000` で配信する。`SPINEL_GC_FULL_INTERVAL=8` も設定する。これは Spinel のガベージコレクターの変数で、[docs/deploy.en.md](../deploy.en.md) が説明しており、systemd でも設定している）`Dockerfile`、`.dockerignore`、`config/deploy.yml`（前段に Let's Encrypt 付きの kamal-proxy、`public/up.html` でのヘルスチェック、`/app/storage` のボリューム上の SQLite ファイル）、`.kamal/secrets`（環境変数からの `KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE`）です。`CHANGE ME` と書かれた値を埋めてコミットし、`kamal setup` を実行します。詳しくは [docs/deploy-kamal.md](../deploy-kamal.md)（デプロイのチュートリアルのパート 8）にあります。[examples/blog](../../examples/blog#deploying-with-kamal) にも、このチェックアウトのフレームワークに対してビルドされる同じ設定があります。

### アプリケーションの設定

アプリケーション独自の設定（公開するベース URL、機能のスイッチ、間隔、SMTP ホストなど）は、同じ `Config` に、型、環境変数、デフォルト値とともに宣言します：

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

各値は、起動時に `config/app.rb` が実行されるときに一度だけ読まれます。空の変数や設定されていない変数はデフォルトを意味します。真偽値は `1`/`true` または `0`/`false` を、整数は `min..max`（どちらも省略可能）の範囲の 10 進数の数字（先頭に省略可能な `-`）を受け取ります。それ以外の値はデフォルトに戻り、その旨を `WARN` の行でログに出します（`config/app.rb` の実行中なので、`log_format` にかかわらずテキストの行です）。宣言されていない名前や、別の型で宣言された名前を読むと `ArgumentError` を出し、同じ名前を二度宣言した場合も同様です。テストでは `set_string_setting`、`set_int_setting`、`set_bool_setting` で値を変更します。`./NAME help` は宣言されたすべての設定を変数とデフォルト値とともに一覧し、起動バナーは現在の値を表示します（`=> Settings: base_url="" worker=true ...`）。`secret: true` の設定は、どちらでも名前だけが `[FILTERED]` として表示されます。`Cybertrain.config.base_url` のようなアクセサーはありません：設定は config オブジェクトへの呼び出しで宣言されますが、Spinel はクラス本体の `define_method` はコンパイルするものの、インスタンスメソッドから呼ぶものは拒否するので、リーダーは名前を受け取る型付きのメソッドになっています。

### ロケール

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.i18n_default_locale = :en               # または CYBERTRAIN_I18N_DEFAULT_LOCALE
  c.i18n_available_locales = [:en, :ja]
  c.i18n_raise_on_missing = true if c.test?
end
```

`i18n_available_locales`（`[]`、デフォルトのロケールだけ）は、`I18n.locale=` と `I18n.locale_available?` が受け付けるロケールを並べます。起動時に、ロケール名でない要素と、空でないリストにないデフォルトは拒否されます。`i18n_raise_on_missing`（`false`）は、見つからない翻訳で目印（開発とテスト）や人が読める形のキー（本番）を返す代わりに `I18n::MissingTranslationData` を発生させます。辞書とリクエストごとのロケールは [国際化](i18n.md) にあります。

### 認証の設定

`cybertrain generate authentication` が書き出すコードは 4 つの設定を読みます（変数は上の表にあります）：[ロックアウト](authentication.md#lockout) の `auth_lockout_attempts`（10）と `auth_lockout_period`（3600 秒）、「ログインしたままにする」サインインの `auth_remember_for`（30 日）、使われないサインインの `auth_idle_timeout`（7 日）です（[ログインしたままにする](authentication.md#remember-me-and-session-limits)）。チェックなしのサインインは `session_absolute_max_age`（2 週間）続きます。範囲外の値は起動を止めます。ジェネレーターはアプリケーションの設定 `base_url` も宣言します。`<APP>_BASE_URL` から読み、メール中のリンクはここから始まります。アプリケーションを提供するすべての場所で、https で設定してください（[メール中のリンク](authentication.md#links-in-mails)）。

## MySQL

アプリケーションは 1 つのデータベース向けにビルドされます。既定の SQLite か、MySQL 8.0 以降です（`docs/design.md` の D96）。どちらになるかは、`bin/<app>.rb` と `bin/db.rb` の最初の `require` で、アプリケーションをビルドするときに決まります。実行時に切り替えるものはありません：

```ruby bin/<app>.rb (excerpt)
require "cybertrain/mysql"   # すべてのサブシステム。"cybertrain/core/mysql" はコアだけ
```

`cybertrain new NAME --database=mysql` はこの行を書き、`config/app.rb` と `.env.example` で `DATABASE_URL` を説明し、`config/deploy.yml` と `.kamal/secrets` でそれをシークレットとして渡し、テストを MySQL のサービスに対して実行する CI のワークフローを書きます。SQLite 向けに作ったアプリケーションは、2 つのファイルのこの行を変えれば移れます（データは SQLite のファイルに残ります）。モデル、マイグレーション、テストはどちらでも同じです。MySQL で答えが変わるところは[モデルとデータベース](models.md#mysql)にまとめてあります。

データベースは `DATABASE_URL` が指すものです（`database_url`。`config/app.rb` が実行される前に読まれます）：

```shell
export DATABASE_URL='mysql://app:PASSWORD@db.internal:3306/shop_production'
```

- `USER`、`PASSWORD`、データベース名はパーセントデコードされます（`%40` は `@`）。`?` の後のパラメータは `ssl_mode`、`connect_timeout`（既定は 5 秒）、`read_timeout` と `write_timeout`（それぞれ 30 秒。クエリ全体ではなく、サーバーを 1 回待つ時間）です。それ以外の名前があると起動が止まります。パスワードは、どのメッセージ、ログの行、`inspect` にも出ません。
- パスワードは環境変数かデプロイのシークレット（`.kamal/secrets`）に置き、`config/app.rb` やリポジトリには書かないでください。バイナリはパスワードを持ちません。
- 既定の `ssl_mode=verify` は TLS で接続し、サーバーの証明書とホスト名を確かめます。`ssl_mode=disabled` は TLS なしで接続し、URL に書かれた `localhost`、ループバックアドレス、プライベートアドレス（10/8、172.16/12、192.168/16）、ユニークローカルの IPv6 アドレスにだけ使えます。ほかのホストは拒否されます。暗号化だけして証明書を確かめないモードはありません。
- TLS なしでは、MySQL 8.0 の既定の `caching_sha2_password` は、サーバーがまだキャッシュしていないパスワードを確かめられず、接続はその旨のメッセージで拒否されます。TLS を使うか、開発用のユーザーを `mysql_native_password` にしてください。
- 証明書は、システムの CA ストア、または設定されていれば `SSL_CERT_FILE`（バンドル）か `SSL_CERT_DIR` に対して確かめます。フレームワークのすべての TLS 接続と同じです。マネージドなサーバーの CA はそこに置きます。Amazon RDS や Aurora MySQL では、グローバルバンドルをダウンロードして指定します（`SSL_CERT_FILE` は、HTTP クライアントやメールを含むプロセスのすべての TLS 接続で、システムのバンドルファイルの代わりになります。アプリケーションがほかのサービスも呼ぶなら、2 つをつなげてください）：

```shell
curl -fsSLo /etc/ssl/certs/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
cat /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/rds-global-bundle.pem > /etc/ssl/certs/app-ca.pem
export SSL_CERT_FILE=/etc/ssl/certs/app-ca.pem
export DATABASE_URL='mysql://app:PASSWORD@shop.abc123.ap-northeast-1.rds.amazonaws.com:3306/shop_production'
```

`db` コマンドも同じデータベースを使います。`db create` と `db drop` はそれを作り、削除します（`utf8mb4`、照合順序 `utf8mb4_0900_bin`）。`migrate`、`rollback`、`status`、`schema`、`schema:dump` は SQLite と同じように動きます。`dbconsole` は `mysql` クライアントを TCP で、同じ TLS モードと CA で開き、パスワードはクライアントの環境変数で渡します。`db backup`、`vacuum`、`normalize` は SQLite のもので、ステータス 2 で終わります。`mysqldump` かプロバイダーのスナップショットを使ってください。

`cybertrain test` はテストの前に `DATABASE_URL` が指すデータベースを空にしてマイグレーションし直します。そのため、名前が `_test` で終わらないデータベース、`test` 以外の環境、テーブルはあるのに目印のテーブル `cybertrain_test_marker` がないデータベースは拒否します（目印は空のデータベースに作ります）。データベースを作ったり削除したりはしません。`NAME_test` を一度作り（その URL で `db create`、またはプロバイダーのコンソール）、テストの実行時にその URL を export してください。テストの合間にテーブルを空にしてフィクスチャを入れ直します。MySQL では、空にする処理がフィクスチャを入れる前にコミットされる（id のリセットが DDL だから）ので、読み込みに失敗したフィクスチャはテーブルを空のまま残します。

フレームワークのテーブル（ジョブ、ストリーム、キャッシュ、リース、スケジューラの時刻表、フィードの状態）は `db/schema.rb` になく、`db migrate` も作りません。SQLite と同じく、それぞれの機能を最初に使ったときに作られます。MySQL ではトランザクションの中の CREATE TABLE がトランザクションを途中でコミットしてしまうので、`DB.transaction` の中での最初の使用（そのテーブルがまだないデータベースでの、トランザクション内の `Job.enqueue` や `broadcast_*`）は、代わりに `Cybertrain::DB::Error` を投げ、何もコミットしません。ジョブを実行するプロセスは起動時に `cybertrain_jobs` を作ります。ほかのテーブル（またはそのプロセスが初めて起動する前に登録されるジョブ）のために、最初の `migrate` の後、トランザクションの外で一度テーブルを作ってください。たとえば運用コマンドで：

```ruby bin/<app>.rb (excerpt)
Cybertrain::Main.command("install_tables", "create the framework's tables") do |argv|
  Cybertrain::Job.install!
  Cybertrain::Stream.install!
  Cybertrain::Cache.install!
  0
end
```

> [!NOTE]
> 当面は 1 プロセスです。MySQL では、ジョブ、ストリーム、リース、スケジュールされたタスクは 1 プロセスの中で保証されます（SQLite と同じに答えます）が、同じデータベースを共有する複数のプロセスやホストでは、まだ保証されません。ジョブの取り出し、ストリームの順序、リースの時計は、ロードマップの次の段階です。リリースがそうでないと言うまで、コンテナは 1 つ、web のロールだけで動かしてください。

## タイムゾーン

Spinel には tz データベースが同梱されておらず、時刻を変換するために `ENV["TZ"]` を設定すると、プロセスのすべてのスレッドで変わってしまいます。`Cybertrain::TimeZone` は代わりにシステムのゾーンファイルを読みます：`/usr/share/zoneinfo/<name>`、または `TZDIR` が設定されていれば `$TZDIR/<name>` です（スリムなコンテナーイメージには `tzdata` パッケージをインストールしてください）。TZif のバージョン 1〜4（RFC 8536 を置き換えた RFC 9636）をパースし、「slim」なファイルが最後の遷移の後に頼る POSIX の TZ ルールにも対応します。各ゾーンはプロセスの存続期間中キャッシュされます（コピーオンライトなので、複数のワーカーからの参照でもロックを取りません）。

すべては Integer のエポック秒です。*ローカルエポック*とは、壁時計の読みを UTC であるかのように数えたもので、壁時計の計算は単純な足し算になります。`TimeZone.civil_to_epoch` / `TimeZone.epoch_to_civil` は、それと `[year, month, day, hour, minute, second]` の間を変換します：

```ruby
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
tokyo.found?                         # 未知の名前なら false：そのときゾーンは UTC として振る舞う
tokyo.utc_offset_at(Time.now.to_i)   # => 32400
tokyo.abbreviation_at(Time.now.to_i) # => "JST"

# 東京で次の 09:00：
now = Time.now.to_i
today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
```

夏時間の切り替わりでも `local_to_utc` は決定的です：前方へのジャンプで飛ばされる壁時計の時刻（米国で時計を進める日の 02:30）はジャンプ前のオフセットで読まれるので、ジャンプの後（03:30 EDT）になります。後方へのジャンプで繰り返される壁時計の時刻は、早いほうの瞬間になります。`find` は、空、`.`、`..` のセグメントを含まない、`A-Za-z0-9_+-./` からなる相対的な名前だけを受け付けるので、ユーザーのプロフィールから取ったゾーン名がゾーンディレクトリ外のファイルに到達することはありません。未知のゾーンや形式の壊れたゾーンはキャッシュされず、`"UTC"` にはファイルは不要です。

### アプリケーションのゾーン

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.time_zone = "Asia/Tokyo"   # または CYBERTRAIN_TIME_ZONE。既定は "UTC"
end
```

`c.time_zone` は IANA の名前を取り（「Tokyo」のような Rails 独自の名前は読みません）、システムにないゾーンでは起動が止まります。値は UTC の瞬間のままです：カラム、`Time.current`、カレンダーのメソッドは UTC の `Time` を返し、`time.hour` は UTC の時です。ゾーンが決めるのはカレンダー（`beginning_of_day` などや `Date.current`。[時刻とタイムゾーン](models.md#times-and-the-time-zone)）と表示です：`l(time)` と `time_tag(time)` は Time をそのゾーンで表示し（`%z` と `%Z` も含む）、`time_tag` の `datetime` はゾーンのオフセット付きの ISO 8601 です（`2026-11-12T05:00:00+09:00`）。`l(time, zone: "America/New_York")` と `time_tag(time, zone: "...")` は 1 つの値を別のゾーンで表示します。オフセット 0 の Time、つまりフレームワークが渡すすべての Time はそのゾーンで表示されます。自分自身の別のオフセットを持つ Time（`time.getlocal("+05:30")`）は、`zone:` を渡さない限りそのオフセットのままです。Date はそのまま表示されます。`tz:` のない cron のタスクも、`scheduler_tz` を設定しない限りこのゾーンに従います。登録されたコマンド（`Main.command`）、`./<app> jobs`、`./<app> console` も実行の前にゾーンを設定し、未知のゾーンは起動と同じく `error: time_zone "Mars/Base" is not a known time zone` を出して、データベースを開く前に終了ステータス 1 で拒否します。`cybertrain test` では、各テストは設定したゾーンで始まります。（`l` の書式は[日付と時刻](i18n.md#dates-and-times)にあります。）

## アップグレード

リリースが変える設定とデフォルトは、[アップグレード](upgrading.md#notes-by-version) にバージョンごとに載っています。
