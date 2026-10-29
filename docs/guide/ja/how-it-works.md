---
source_sha256: e51e959017a031fc0c47aaef26b3c057773c2dc7b94c1fd7c634dd77767f06f2
description: "CyberTrain のアプリがどのようにビルドされ、実行されるか（ビルド時のコード生成、解釈されるビュー、HTTP サーバー、FFI による SQLite、開発ループ）と、Rails との違い。"
---
# 仕組み

このページでは、CyberTrain のアプリがどのようにビルドされ、実行されるかを説明します：ビルド時に生成されるコード、リクエスト時に解釈されるビュー、HTTP サーバー、FFI による SQLite、開発ループ、そして Rails との違いの表です。ホームページの[パフォーマンスのセクション](site:index.html#performance)では、その結果を、同じブログを Rails 8.1 で書いたものと比べています。計測方法、すべての数値、計測をもう一度実行する方法は [docs/benchmark.md](../benchmark.md) にあります。

## ビルド時のコード生成

`spin run gen`（`bin/gen.rb`）は、`db/schema.rb` の `create_table` DSL と `config/routes.rb` の `Routes.draw` DSL を実行してテーブルとルートの*データ*を得ます。それとは別に、`app/controllers/**/*.rb` と `app/models/**/*.rb` に対して**字句スキャン**（パーサーではなく正規表現。Spinel は実行時にパーサーを公開していません）を行い、`@ivar =` の代入、`before_action`/`after_action`/`rescue_from ... with:` の名前、引数なしの `def` を探します。

そこから、素の読みやすい Ruby を `gen/` 以下に書き出します：

- `gen/models/<name>.rb`：アクセサー、型変換、ファインダー、外部キーから導いた関連付け
- `gen/routes.rb`：ルートテーブル、ディスパッチャー、`*_path`/`*_url` ヘルパー
- `gen/controllers.rb`：コントローラーごとの `view_assigns` と `run_callback`
- `gen/migrations.rb`
- `gen/views.rb`：埋め込みビューのテーブル。デプロイ用のビルド以外では空
- `gen/app.rb`：`require_relative` のマニフェスト

`gen/` は gitignore せずにコミットします：`spin build` と `spin test` には先に生成を行うフックがないため、チェックインされた出力がそのままコンパイルできるものでなければなりません。CI は `spin run gen` を再実行して差分があれば失敗するので、古い生成コードがマージされることはありません。

## ビューは解釈される

`app/views/**/*.html.erb` のファイルは Rails の ERB のように見えますが、リクエスト時に AST へとパースされ、木を辿るインタープリターによって実行されます。Spinel には `eval` がないため、これは本物の Ruby ではなく閉じた文法です（リテラル、`@ivar`/ローカル変数の参照、型ごとに固定されたディスパッチテーブルを通じた呼び出し、`if`/`unless`、`each`/`each_with_index`/ヘルパーの 1 ブロック）。文法、ヘルパー、未対応のものの全体は[テンプレート言語リファレンス](template-language.md)にあります。

ソースの出どころはモードによって異なります：

- 開発環境（とテスト環境）ではエンジンが `app/views/` をディスクから読み、開発環境ではテンプレートが変更されると再パースするので、ビューの編集に再ビルドは不要です。
- `cybertrain build` は `spin run gen -- --embed-views` を実行し、すべてのテンプレートのソースを文字列テーブルとして `gen/views.rb` に書き込んでその 1 回の `spin build` を行い、その後もう一度 `spin run gen` を実行して、コミットされる空のテーブルに戻します。
- 本番用のバイナリはそのテーブルだけをレンダリングし（各テンプレートを一度だけパースします）、テーブルが空なら起動を拒否します（`error: views are not embedded in this binary`）。

## HTTP サーバー

`Cybertrain::Server` は素の Ruby による HTTP/1.1 です：`TCPServer#accept` と、接続ごとに 1 つの Spinel グリーンスレッド（M:N スケジューリング、GVL なし）、型付きの `Request`/`Response` からなり、Rack の層はありません。TLS と HTTP/2 はリバースプロキシに任せます。`SPINEL_WORKERS` のデフォルトは `1` です：検証の結果、同時接続 100 のこの I/O 律速の形では、そのほうが速く、詰まりもないことがわかりました。

サーバーは `HttpHandler`（`call(request) -> Response`）を呼び出し、`ContextHandler` がそれをミドルウェアのスタックにつなぐので、HTTP の層（`cybertrain/http/` と `Params`、`Logger`）はフレームワークの残りの部分に依存しません。CI では `script/check-http-layer` がこれを強制します。

## FFI による SQLite

モデルは Spinel の `ffi_func`/`ffi_lib` を通じて SQLite と直接やり取りします：C 拡張も gem もありません。すべてのクエリはバインドされ、文字列に埋め込まれることはありません。現在のアダプターはこれだけです（`libpq` FFI による PostgreSQL は将来の作業の候補として記録されています）。

プール（`SizedQueue`、デフォルトで 4 接続）は、次の設定で接続を貸し出します：

- WAL
- 約 5 秒のビジータイムアウト（100 µs ごとに再試行するビジーハンドラー。SQLite の `busy_timeout` は 1 ミリ秒以上スリープします）
- 最大 64 個のキャッシュされたプリペアドステートメント
- 外部キー有効

トランザクションがこうした接続のひとつをどう借り、その上で何が実行されるか：[トランザクション](models.md#transactions)。

## 開発ループ

`development`（`cybertrain build` で作ったバイナリ以外での `CYBERTRAIN_ENV` のデフォルト）で `cybertrain server`（`spin run gen`、次に `spin run NAME`）を実行すると、`app/**/*.rb`、`config/**/*.rb`、`db/schema.rb`、`gen/**/*.rb` も 0.5 秒ごとに確認します。ビューは除外され（エンジンが自分で再読み込みするためです）、開発環境では空の `gen/views.rb` も同様です。

変更があるとバックグラウンドで `spin run gen && spin build NAME -- --incremental` を実行します：Spinel のインクリメンタルビルドで、編集によって変わった C のユニットだけを再コンパイルします。`--incremental` のない Spinel のリリースはこのフラグを拒否し、その場合ループはフラグなしでビルドします。

成功すると再起動を要求します（外部からの `kill -HUP` が立てるのと同じフラグです）：モニタースレッドがリスナーを止めて処理中のリクエストを捌き切り、その後メインスレッドが同じポートと PID のまま新しいバイナリを `execv` するので、セッションの途中のクライアントからは見えません。ビルドに失敗した場合は古いバイナリで配信を続け、すべての HTML レスポンスにコンパイラの出力をバナーとして表示します。`cybertrain build` が `tmp/cybertrain-build.lock` を保持している間は、再ビルドを行いません。本番環境ではこれらは一切読み込まれません。

## Rails との違い

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console` | コンソールはない — Spinel には `eval` がない |
| `rails runner`、`lib/tasks/*.rake` | `bin/<app>.rb` に `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` でデータベースに接続した状態で実行される |
| コードを編集すると、動いているアプリが取り込む | Ruby の変更には再ビルドが必要。開発環境では `cybertrain server` が代わりに行う（再ビルド、停止、`execv`） |
| ビューを編集しても再読み込みは不要 | 同じ — 開発環境ではビューはリクエストごとにディスクからパースされる |
| `def new` | `def new_action`（`new` は `Klass.new(ctx)` を覆い隠してしまう） |
| `before_action { do_thing }`（暗黙の `self`） | `before_action { \|c\| c.do_thing }` — 保存したブロックに対する `instance_exec` がないので、コールバックはコントローラーやレコードを明示的に受け取る |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — ネストしたブロックはマッパーを明示的に受け取る |
| ERB はメソッドにコンパイルされる。どんなオブジェクトの、どんなメソッドでも呼べる | 固定の文法とディスパッチテーブルに対して解釈される（[テンプレート言語](template-language.md)） |
| セッションはマーシャルされた任意のオブジェクトを保持する | セッションの値は String だけで、HMAC 署名付きの cookie |
| 多くのデータベースアダプター | FFI による SQLite のみ |
| `Article.transaction { ... }` はブロックの値を返す。`raise ActiveRecord::Rollback`。`requires_new: true` のセーブポイント | `Article.transaction { \|c\| ... }` は接続を渡して nil を返す。抜けるには例外を出す。ネストした呼び出しは外側のトランザクションに合流し、セーブポイントはない（[トランザクション](models.md#transactions)） |
| `has_many :through`、`includes`、`dependent:`、enum、STI、ポリモーフィック関連 | 実装されていない。関連付けはスキーマの外部キーからのみ作られる |
| `pluck(:a)`、`sum(:a)`、`group(:a).count`、`upsert`、`update_counters`、`where("title LIKE ?", "%#{q}%")` | Spinel のメソッドは戻り値の型がひとつなので、型付きの版になる：`pluck_int` とその仲間、`sum_int`、`count_by`、`upsert`、`increment(:col, by: n)`、`where_like`（[`where` を超えるクエリ](models.md#querying-beyond-where)） |
| 任意のカラム名。関連付けが `errors` を覆い隠せる | ASCII の識別子のみ。フレームワークのメソッドや Ruby のキーワードと同じ名前のカラムは `<column>_column` として生成され、衝突する関連付けは代わりの名前で生成される（[カラム名](models.md#column-names)） |
| `namespace`、format/`respond_to`、`constraints`、`mount` | 実装されていない — 名前はフラットで、`render json:` のみ |
| `rescue StandardError` が不正な `JSON.parse` を捕まえる | Spinel では `JSON::ParserError` は `StandardError` ではない：アプリのコードは `rescue JSON::ParserError, StandardError` と書く必要がある。サーバーは最後の手段としてこれを捕まえ、500 を返す |
| API コントローラーで `skip_forgery_protection` | CSRF はルーティングの前に実行されるので、API はパスで除外し（`c.csrf_exempt_prefixes = ["/api/"]`）、呼び出し元を自分で認証する（[設定](configuration.md#configuration-and-environment-variables)） |
| Rack は gzip されたリクエストボディをそのままにする | `Content-Encoding: gzip` のボディは `request.decoded_body` で、10 MiB の上限のもとで展開される。壊れたものや大きすぎるものは 400。`request.body` は送られたままのバイト列（[クエリ文字列とボディ](requests.md#query-strings-and-bodies)） |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` は `column [ASC\|DESC]` のリストだけを受け取る。リクエストのデータは許可リストを通し、生の SQL は `order_sql` を通す（[並び順](models.md#ordering)）。形式の壊れたパラメーターや深くネストしたパラメーターは 400（[クエリ文字列とボディ](requests.md#query-strings-and-bodies)） |
| 例外時の完全なバックトレース | クラス、メッセージ、リクエスト行、テンプレート名と行 — Spinel はバックトレースを公開していない |
| Rack、そのミドルウェア、`Gemfile` の任意の gem | Rack 互換性はない。小さな固定のミドルウェア群。Spinel 自身の `spin-index` で、その Ruby サブセットでコンパイルできるものに限られる |
| minitest / RSpec | `Cybertrain::Test` — リフレクションに基づくランナーは AOT では動かない |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` は同じ形に加えてサインアップのページを書き出す。パスワードには PBKDF2-HMAC-SHA256 を使う（bcrypt は C ライブラリを必要とし、macOS の `String#crypt` には bcrypt がない）。パスワードのリセットはない（[サインインを追加する](tutorial.md#authentication)） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment` は 5 つの `cover_*` カラムとモデルのメソッドを書き出す。ファイルはローカルディスクの `storage/uploads/` 以下に置かれ、`send_blob` で配信される。フィールドごとに 1 つで、バリアントやダイレクトアップロードはない（[カバー画像を追加する](tutorial.md#attachments)） |
| `skip_before_action :x` | 名前付きの before コールバックについては同じ（ブロックのコールバックにはスキップする名前がない）。`skip_after_action` はない |
| `resource :session` | `SessionsController` への同じ 6 つのルート。その下へのネストはない |
| `get "/x"` の後に `post "/x"` | どちらも問題ない：2 つ目のルートから導かれる名前は使用済みなので、Rails と同じく名前なしになる。`as:` の重複は引き続きエラー |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport に同梱のタイムゾーンデータ | `Cybertrain::TimeZone.find("Asia/Tokyo")` はシステムの TZif ファイル（`/usr/share/zoneinfo`、または `TZDIR`）を読み、Integer のエポック秒を変換する（`utc_offset_at`、`utc_to_local`、`local_to_utc`）。リクエストごとの `Time.zone` や `l(time, zone:)` はまだない（[タイムゾーン](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | Webhook や API には `Cybertrain::HttpClient`：すべての待ちに上限があり、公開されていない宛先はデフォルトで拒否され、リダイレクトや keep-alive はない（[外向きの HTTP](external-services.md#outbound-http) を参照）。Spinel の `Net::HTTP` は、相手が止まるとサーバー全体を止めてしまう |
| Action Mailer（`deliver_later`、メーラークラス、ビュー） | `Cybertrain::Mailer.deliver(to:, subject:, body:)` はプレーンテキストを SMTP で送る（STARTTLS、暗黙の TLS、またはループバックへの平文。AUTH PLAIN。すべての待ちに上限がある）。テンプレート、HTML、添付ファイル、キューはない（[メールを送る](external-services.md#sending-e-mail)を参照） |
| Active Job、`perform_later`、`solid_queue`、定期タスク | `Cybertrain::Job.handle(kind)` と `Job.enqueue(kind, payload, run_at:)`（String のペイロードで、バックオフ付きで再試行される）、`Cybertrain::Scheduler.every(seconds, name)`。配信を行うプロセスで 1 スレッド（[バックグラウンド処理](background-and-operations.md#background-work)） |
| ActionCable クライアント、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` はサーバーの動作中、フィードを接続したまま保つ（再接続、ping、無音の検出）。同期的な 1 本の接続には `WebSocket::Client`。外向きのみ（[WebSocket フィードを購読する](external-services.md#consuming-websocket-feeds)） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` は String の Array で、大文字小文字を区別せず部分文字列で照合される（Regexp やラムダは使えない）。リクエストログと開発環境のエラーページに適用される（[フィルターされるパラメーター](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（コントローラーへのルート） | `GET /up` は組み込みで、静的ファイル、セッション、ルーターより前に応答するので、`before_action` は実行されない。データベースとワーカーを確認し、`200 ok` または `503` を返す（[運用](background-and-operations.md#operations-backups-vacuum-health-check)） |
| バックアップ用の `bin/rails db:...` タスク（組み込みはない） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`、モード 0600、所定の場所にリネーム）と `./<app> db vacuum` |
| ActionCable（サーバー）、アセットパイプライン、i18n | 作られていない（MVP の対象外。`docs/design.md` §2.3） |

<!-- table-foot: これですべてではありません：より詳しい記録は docs/design.md §8（「What was deliberately left out」）にあります。 -->
