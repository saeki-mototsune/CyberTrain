---
source_sha256: 73e63b06a3c0e42694f5489b74b58f65464e506bfc88c1ba18759c91bd5771dd
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
| `CYBERTRAIN_ENV` | `env` | `"development"`。`cybertrain build` で作ったバイナリでは `"production"`（`"test"` もある） |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | 本番環境では必須。開発環境とテスト環境では `tmp/secret_key` に自動生成される |
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`。`0.0.0.0` はすべてのインターフェースで待ち受ける（コンテナー向け） |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | 開発環境は `localhost`、`127.0.0.1`、`[::1]` を受け付ける。カンマ区切りの完全なホスト名でこのリストを拡張できる（スキーム、ポート、ワイルドカードは不可）。その他のホストには、静的ファイル、セッション、ルーティング、診断の前に 403 を返す。これは待ち受けアドレスとは別のもので、本番環境とテスト環境はこの開発用のガードを適用しない |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`。`Strict` や `None` も可（`None` は常に `Secure` を追加する）。それ以外の値ではサーバーが起動時に停止する |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`。`1` または `true` で `Partitioned`（と `Secure`）を追加する |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`。`1` または `true` にすると、同じホスト上のリバースプロキシのために、ループバックからの接続の `request.client_ip`（`rate_limit` が数えるもの）を `X-Forwarded-For` の最後のアドレスにする（[レート制限](requests.md#rate-limiting-and-the-client-address)を参照）。`CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` の省略形 |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`。カンマ区切りの IPv4/IPv6 アドレスまたは CIDR（`172.16.0.0/12,10.0.0.0/8`）で、そこからの接続では `request.client_ip` を `X-Forwarded-For` の最後のアドレスから取る。コンテナー内の kamal-proxy のように、ネットワーク越しに到達するプロキシ向け。不正なエントリーがあるとサーバーは起動時に停止する |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`：`params.page_number` が返し、`Relation#page` が受け付ける最大のページ（[ページネーション](models.md#pagination)を参照）。最大 18 桁の数値でない値や、1 未満の値はデフォルトになる |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`。カンマ区切りの名前でリストを置き換える。名前にこれらのいずれかを含むパラメーター（ASCII の大文字小文字を区別しない：`password` は `user[password]` にも一致する）は、リクエストログと開発環境のエラーページで値が `[FILTERED]` と書かれる。`config/app.rb` で `[]` にすると無効になる |
| `CYBERTRAIN_WORKER` | `worker` | `true`。`0` または `false` にすると、このプロセスは定期タスクとジョブを実行しない（[バックグラウンド処理](background-and-operations.md#background-work)を参照）。`scheduler_interval`（1 秒）、`job_poll_interval`（5 秒）、`job_max_attempts`（5）は `config/app.rb` で設定する |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`。組み込みのヘルスチェックのパス（[運用](background-and-operations.md#operations-backups-vacuum-health-check)を参照）。空の値で無効になり、先頭に `/` のない値ではサーバーが起動時に停止する。`health_worker_stale`（300 秒）は `config/app.rb` で設定する |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`。`1` または `true` にすると、`Cybertrain::HttpClient` がループバック、プライベート、その他の公開されていないアドレスに接続できる（[外向きの HTTP](external-services.md#outbound-http) を参照） |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`。`Cybertrain::Mailer` が送信に使う SMTP サーバー（[メールを送る](external-services.md#sending-e-mail)を参照） |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`：モードのポート。`starttls` なら 587、`tls` なら 465、`none` なら 25。1〜65535 以外は 0 になる |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`：AUTH なし。設定するとメーラーは AUTH PLAIN で認証する |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`。秘密の値で、ログにも起動バナーにもエラーメッセージにも出ない |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`：`from:` が与えられないときに `Mailer.deliver` が使う送信者 |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`。`tls`（暗黙の TLS）や `none`（平文。資格情報はループバックへのみ）も可。どちらの TLS モードにも `require "cybertrain/net/tls"` が必要 |

`None` を（`CYBERTRAIN_SESSION_PARTITIONED=1` とともに）使うのは、別のサイトのフレーム内に表示されるアプリだけにしてください。ブラウザーは HTTPS でアプリに到達する必要があります。

固定の、上書き可能なデフォルトを持つその他の属性：`views_root`（`"app/views"`）、`public_root`（`"public"`）、`layout`（`"layouts/application"`）、`log_level`（`:info`）、`session_cookie_name`、`session_max_age`（2 週間）、`session_secure`（本番環境では `true` で、セッションの cookie に `Secure` を付けます。それ以外では `false` ですが、`SameSite=None` と `Partitioned` はいずれにしても `Secure` を追加します）、`pool_size`（4）、`static_files`/`csrf`（`true`）、`csrf_exempt_prefixes`（`[]`：`"/api/"` のようなパスのプレフィックスで、その下の GET 以外のリクエストは CSRF のチェックを飛ばします。プログラムが独自の資格情報で呼び出すエンドポイント向けです。それぞれ `/` で始まって `/` で終わり、`/` だけであってはならず、そうでなければ起動に失敗します。プレフィックスは送られたままのパスに対して照合されるので、パーセントエンコードした綴りも引き続きチェックされます。他のルートがプレフィックス以下のパスに一致してはならず、除外されたコントローラーは認証をセッションに頼ってはなりません。そこでもセッションは読み込まれるためです）、`max_body_bytes`（10 MiB：送られたままのサイズでこれより長いリクエストボディには、読む前に 413 を返します。大きなアップロードには引き上げてください。gzip されたボディの展開後のサイズは、別に `request.decoded_body(limit)` で制限されます）、`max_render_depth`（同時に開いているレンダリングは 12 まで：ページとそのパーシャル。正当により深く再帰するパーシャルには引き上げてください。1 以上でなければならず、そうでなければ起動に失敗します）。アップグレードの注意点：以前は無制限だったレンダリングのネストが、デフォルトで 12 までになりました（ページが深さ 1 なので、パーシャルは 11 階層までネストできます。レイアウトはページの後にレンダリングされ、ネストしません）。より深いツリー（スレッド形式のコメント、カテゴリーメニュー）を持つアプリは、`max_render_depth` を設定するまでテンプレートエラーになります。ファイルアップロード：`max_upload_bytes`（アップロードされたファイル 1 つあたり 5 MiB。`max_body_bytes` を超えてはなりません）、`max_multipart_parts`（テキストフィールドを含めて 128 パート、最大 4096）、`upload_root`（`"storage/uploads"`。`Cybertrain::BlobStore` が書き込む場所で、起動時ではなく最初のアップロードで作られます）。

**セキュリティヘッダー：** サーバーが書き出すすべてのレスポンス（アクション、静的ファイルのミドルウェア、エラーページと開発環境の診断ページ、サーバー自身の 400/411/413/500、そして HEAD）は、`X-Content-Type-Options: nosniff` と `X-Frame-Options: SAMEORIGIN` を持ちます。ただし、レスポンスがすでにその名前のヘッダー（大文字小文字は問わない）を設定している場合は別です：`Response#to_http` はレスポンス自身のヘッダーの後に、ないときだけこれらを追加するので、アクションで `response.set_header("X-Frame-Options", "DENY")` とすれば、指定した値がちょうど 1 回送られます。アプリ全体でこれらを無効にする `Config` のスイッチは意図的に用意していません。埋め込み可能なウィジェットは、自身のレスポンスでヘッダーを上書きします（現在のブラウザーでは、`Content-Security-Policy: frame-ancestors ...` ヘッダーが `X-Frame-Options` より優先されます）。`nosniff` があるため、ブラウザーは `Content-Type` を文字どおりに受け取ります：静的ファイルのミドルウェアは `public/` によくある拡張子（html、css、js/mjs、webp と avif を含む画像、フォント、wasm、pdf、音声と動画、json、csv、xml）を知っており、それ以外は `application/octet-stream`、つまりダウンロードとして配信されます。アプリが別の拡張子をインラインで必要とする場合は、`Cybertrain::Static::EXTENSIONS` に追加してください。`public/` を自分で配信するリバースプロキシは、これらのヘッダーを経由しません（[docs/deploy.en.md](../deploy.en.md) を参照）。`Cybertrain::Test::Client` はアプリをプロセス内で呼び出し、レスポンスをシリアライズしないので、この 2 つのデフォルトは見えません。`response.to_http` に対してアサートしてください。

**フィルターされるパラメーター：** リクエストログの `Started GET "/login?..."` の行と開発環境のエラーページ（そのリクエスト行と、params や JSON ボディのダンプ）は、Rails の `filter_parameters` と同じく、`config.filter_parameters` に名前のあるすべてのパラメーターの値を `[FILTERED]` と表示します。そのため、URL 内の `?token=` や、失敗したフォームに送信されたパスワードが、フレームワークのリクエストログや開発環境のエラーページに現れることはありません。置き換えられるのは値だけです：クエリ文字列の残りは送られたままログに記録されます（制御文字はエスケープされます）。リストは大文字小文字を区別せず、部分文字列で照合します。`config/app.rb` で拡張する（`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`）か、`CYBERTRAIN_FILTER_PARAMETERS` で置き換えてください。アクションが自分でログに出す値はフィルターされません。そこでは `Cybertrain::ParameterFilter.filter?(name)` や `ParameterFilter.filter_query(text)` に問い合わせてください。

**デプロイ：** `cybertrain build` は `dist/` を作ります：ビューを埋め込んだバイナリ `dist/NAME`、`dist/public/`（静的アセット。リバースプロキシに配信させてもかまいません）、`dist/storage/`（デフォルトでは SQLite のファイル）、`dist/tmp/` です。`CYBERTRAIN_SECRET_KEY_BASE` を設定して `dist/` から実行します。`CYBERTRAIN_ENV` で指定しない限り本番環境で、`./NAME
migrate` はバイナリに組み込まれたマイグレーションを適用します。バイナリが話すのは素の HTTP/1.1 だけです。TLS と HTTP/2 には nginx や Caddy を前に置いてください（本番環境ではセッションの cookie が `Secure` なので、HTTPS で配信してください）。本番環境では、例外には 500 を返し、飾りのないエラーレスポンス（ルーターのプレーンテキストの 404、`head :not_found`、`render plain:`）は、`public/<status>.html` があればそれに置き換えられます。アクションが HTML や JSON としてレンダリングしたエラーはそのまま通ります。`SIGTERM` を受けると、新たな受け付けを止め、処理中のリクエストを完了させ（`Connection: close` で応答します。アイドル状態の keep-alive 接続はすぐに閉じます）、それらが終わるか、サーバーの `drain_timeout`（10 秒）が過ぎると終了します。監視と再ビルドのループは本番環境では決して動きません。[docs/deploy.en.md](../deploy.en.md)（日本語版：[docs/deploy.md](../deploy.md)）では、`cybertrain new`、Ubuntu のサーバー、systemd、HTTPS 付きの Caddy、再デプロイ、ロールバック、バックアップまで、全体を通して説明しています。

**Kamal：** `cybertrain new` は [Kamal 2](https://kamal-deploy.org) が必要とするものも書き出します：Ubuntu のビルドステージで `cybertrain setup` と `cybertrain build` を実行し、同じリリースのスリムなステージに `dist/` をコピーする（起動時にマイグレーションし、その後 `0.0.0.0:3000` で配信する）`Dockerfile`、`.dockerignore`、`config/deploy.yml`（前段に Let's Encrypt 付きの kamal-proxy、`public/up.html` でのヘルスチェック、`/app/storage` のボリューム上の SQLite ファイル）、`.kamal/secrets`（環境変数からの `KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE`）です。`CHANGE ME` と書かれた値を埋めてコミットし、`kamal setup` を実行します。詳しくは [docs/deploy-kamal.md](../deploy-kamal.md)（デプロイのチュートリアルのパート 8）にあります。[examples/blog](../../examples/blog#deploying-with-kamal) にも、このチェックアウトのフレームワークに対してビルドされる同じ設定があります。

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

各値は、起動時に `config/app.rb` が実行されるときに一度だけ読まれます。空の変数や設定されていない変数はデフォルトを意味します。真偽値は `1`/`true` または `0`/`false` を、整数は `min..max`（どちらも省略可能）の範囲の 10 進数の数字（先頭に省略可能な `-`）を受け取ります。それ以外の値はデフォルトに戻り、その旨を `[WARN]` の行でログに出します。宣言されていない名前や、別の型で宣言された名前を読むと `ArgumentError` を出し、同じ名前を二度宣言した場合も同様です。テストでは `set_string_setting`、`set_int_setting`、`set_bool_setting` で値を変更します。`./NAME help` は宣言されたすべての設定を変数とデフォルト値とともに一覧し、起動バナーは現在の値を表示します（`=> Settings: base_url="" worker=true ...`）。`secret: true` の設定は、どちらでも名前だけが `[FILTERED]` として表示されます。`Cybertrain.config.base_url` のようなアクセサーはありません：Spinel には `define_method` がないので、リーダーは名前を受け取る型付きのメソッドになっています。

## タイムゾーン

Spinel には tz データベースが同梱されておらず、時刻を変換するために `ENV["TZ"]` を設定すると、プロセスのすべてのスレッドで変わってしまいます。`Cybertrain::TimeZone` は代わりにシステムのゾーンファイルを読みます：`/usr/share/zoneinfo/<name>`、または `TZDIR` が設定されていれば `$TZDIR/<name>` です（スリムなコンテナーイメージには `tzdata` パッケージをインストールしてください）。TZif のバージョン 1〜4（RFC 8536）をパースし、「slim」なファイルが最後の遷移の後に頼る POSIX の TZ ルールにも対応します。各ゾーンはプロセスの存続期間中キャッシュされます（コピーオンライトなので、複数のワーカーからの参照でもロックを取りません）。

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

夏時間の切り替わりでも `local_to_utc` は決定的です：前方へのジャンプで飛ばされる壁時計の時刻（米国で時計を進める日の 02:30）はジャンプ前のオフセットで読まれるので、ジャンプの後（03:30 EDT）になります。後方へのジャンプで繰り返される壁時計の時刻は、早いほうの瞬間になります。`find` は、空、`.`、`..` のセグメントを含まない、`A-Za-z0-9_+-./` からなる相対的な名前だけを受け付けるので、ユーザーのプロフィールから取ったゾーン名がゾーンディレクトリ外のファイルに到達することはありません。未知のゾーンや形式の壊れたゾーンはキャッシュされず、`"UTC"` にはファイルは不要です。テンプレート向けの書式化ヘルパー（`l(time, zone:)`）はまだありません。
