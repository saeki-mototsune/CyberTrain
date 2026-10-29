---
source_sha256: be6250416c64d3c07e705f9e3e4f04987365dbf6031cea8793a97c0452d9885f
---
# 仕組み

**ビルド時のコード生成。** `spin run gen`（`bin/gen.rb`）は、`db/schema.rb` の `create_table` DSL と `config/routes.rb` の `Routes.draw` DSL を実行してテーブルとルートの*データ*を得ます。それとは別に、`app/controllers/**/*.rb` と `app/models/**/*.rb` に対して**字句スキャン**（パーサーではなく正規表現。Spinel は実行時にパーサーを公開していません）を行い、`@ivar =` の代入、`before_action`/`after_action`/`rescue_from ... with:` の名前、引数なしの `def` を探します。そこから、素の読みやすい Ruby を `gen/` 以下に書き出します：`gen/models/<name>.rb`（アクセサー、型変換、ファインダー、外部キーから導いた関連付け）、`gen/routes.rb`（ルートテーブル、ディスパッチャー、`*_path`/`*_url` ヘルパー）、`gen/controllers.rb`（コントローラーごとの `view_assigns` と `run_callback`）、`gen/migrations.rb`、`gen/views.rb`（埋め込みビューのテーブル。デプロイ用のビルド以外では空）、`gen/app.rb`（`require_relative` のマニフェスト）。`gen/` は gitignore せずにコミットします — `spin build`/`spin test` には先に生成を行うフックがないため、チェックインされた出力がそのままコンパイルできるものでなければなりません。CI は `spin run gen` を再実行して差分があれば失敗するので、古い生成コードがマージされることはありません。

**ビューはコンパイルではなく解釈される。** `app/views/**/*.html.erb` のファイルは Rails の ERB のように見えますが、リクエスト時に AST へとパースされ、木を辿るインタープリターによって実行されます。ソースの出どころはモードによって異なります：開発環境（とテスト環境）ではエンジンが `app/views/` をディスクから読み、開発環境ではテンプレートが変更されると再パースするので、ビューの編集に再ビルドは不要です。`cybertrain build` は `spin run gen -- --embed-views` を実行し、すべてのテンプレートのソースを文字列テーブルとして `gen/views.rb` に書き込んでその 1 回の `spin
build` を行い、その後もう一度 `spin run gen` を実行して、コミットされる空のテーブルに戻します。本番用のバイナリはそのテーブルだけをレンダリングし（各テンプレートを一度だけパースします）、テーブルが空なら起動を拒否します（`error: views are not
embedded in this binary`）。Spinel には `eval` がないため、これは本物の Ruby ではなく閉じた文法です（リテラル、`@ivar`/ローカル変数の参照、型ごとに固定されたディスパッチテーブルを通じた呼び出し、`if`/`unless`、`each`/`each_with_index`/ヘルパーの 1 ブロック）。文法、ヘルパー、未対応のものの全体：[docs/guide/template-language.md](template-language.md)。

**HTTP サーバー。** `Cybertrain::Server` は素の Ruby による HTTP/1.1 です：`TCPServer#accept` と、接続ごとに 1 つの Spinel グリーンスレッド（M:N スケジューリング、GVL なし）、型付きの `Request`/`Response` からなり、Rack の層はありません。サーバーは `HttpHandler`（`call(request) -> Response`）を呼び出し、`ContextHandler` がそれをミドルウェアのスタックにつなぐので、HTTP の層（`cybertrain/http/` と `Params`、`Logger`）はフレームワークの残りの部分に依存しません。CI では `script/check-http-layer` がこれを強制します。TLS と HTTP/2 はリバースプロキシに任せます。`SPINEL_WORKERS` のデフォルトは `1` です — 検証の結果、同時接続 100 のこの I/O 律速の形では、そのほうが速く、詰まりもないことがわかりました。

**FFI による SQLite。** モデルは Spinel の `ffi_func`/`ffi_lib` を通じて SQLite と直接やり取りします — C 拡張も gem もありません。プール（`SizedQueue`、デフォルトで 4 接続）が接続を貸し出します。接続は WAL、約 5 秒のビジータイムアウト（100 µs ごとに再試行するビジーハンドラー。SQLite の `busy_timeout` は 1 ミリ秒以上スリープします）、最大 64 個のキャッシュされたプリペアドステートメント、外部キー有効の設定です。すべてのクエリはバインドされ、文字列に埋め込まれることはありません。現在のアダプターはこれだけです（`libpq` FFI による PostgreSQL は将来の作業の候補として記録されています）。

**トランザクション。** `Cybertrain::DB.transaction { |c| ... }`（または `Article.transaction`。Rails の名前で呼ぶ同じもの）は、接続を借りて `BEGIN` を実行し、接続をブロックに渡し、ブロックが戻れば `COMMIT` し、例外を出せばロールバックして例外を出し直します。`immediate: true` は `BEGIN IMMEDIATE` を実行し、最初に SQLite の書き込みロックを取ります：読んでから書くトランザクションに使ってください。そうすれば、同時に書き込む者がいても、最初の書き込みで「database is locked」で失敗するのではなく、`BEGIN` で待つことになります。ブロックの実行中、そのスレッドでプールを通るものすべて（`save`、`update`、`destroy`、Relation のクエリ、`DB.with`）はトランザクションの接続を使うので、トランザクションの一部になります：

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

ブロックの中でネストした `DB.transaction` は外側のものに合流します（コミットするのは最も外側だけ。どこで例外が出てもすべてロールバックされ、セーブポイントはありません）。`rescue` を普通のメソッドに置いておく必要があるコードは、ブロックを使わない形 `c.begin!(immediate: true)` ... `c.commit!` を使い、rescue で `c.rollback!` を呼びます。これはブロックの値ではなく nil を返します。また、`DB.with` のブロック（これはトランザクションではありません）の中で呼んだ `DB.transaction` は、2 つ目の接続を得ます。

**開発ループ。** `development`（`cybertrain build` で作ったバイナリ以外での `CYBERTRAIN_ENV` のデフォルト）で `cybertrain server`（`spin run gen`、次に `spin run NAME`）を実行すると、`app/**/*.rb`、`config/**/*.rb`、`db/schema.rb`、`gen/**/*.rb` も 0.5 秒ごとに確認します（ビューは除外されます — エンジンが自分で再読み込みするためです — 開発環境では空の `gen/views.rb` も同様です）。変更があるとバックグラウンドで `spin run gen && spin build NAME -- --incremental` を実行します（Spinel のインクリメンタルビルドで、編集によって変わった C のユニットだけを再コンパイルします。`--incremental` のない Spinel のリリースはこのフラグを拒否し、その場合ループはフラグなしでビルドします）。成功すると再起動を要求します（外部からの `kill -HUP` が立てるのと同じフラグです）：モニタースレッドがリスナーを止めて処理中のリクエストを捌き切り、その後メインスレッドが同じポートと PID のまま新しいバイナリを `execv` するので、セッションの途中のクライアントからは見えません。ビルドに失敗した場合は古いバイナリで配信を続け、すべての HTML レスポンスにコンパイラの出力をバナーとして表示します。本番環境ではこれらは一切読み込まれません。


## Rails との違い

| Rails | cybertrain |
| --- | --- |
| `rails console` | コンソールはない — Spinel には `eval` がない |
| `rails runner`、`lib/tasks/*.rake` | `bin/<app>.rb` に `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` でデータベースに接続した状態で実行される |
| コードを編集すると、動いているアプリが取り込む | Ruby の変更には再ビルドが必要。開発環境では `cybertrain server` が代わりに行う（再ビルド、停止、`execv`） |
| ビューを編集しても再読み込みは不要 | 同じ — 開発環境ではビューはリクエストごとにディスクからパースされる |
| `def new` | `def new_action`（`new` は `Klass.new(ctx)` を覆い隠してしまう） |
| `before_action { do_thing }`（暗黙の `self`） | `before_action { \|c\| c.do_thing }` — 保存したブロックに対する `instance_exec` がないので、コールバックはコントローラーやレコードを明示的に受け取る |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — ネストしたブロックはマッパーを明示的に受け取る |
| ERB はメソッドにコンパイルされる。どんなオブジェクトの、どんなメソッドでも呼べる | 固定の文法とディスパッチテーブルに対して解釈される — [docs/guide/template-language.md](template-language.md) |
| セッションはマーシャルされた任意のオブジェクトを保持する | セッションの値は String だけで、HMAC 署名付きの cookie |
| 多くのデータベースアダプター | FFI による SQLite のみ |
| `Article.transaction { ... }` はブロックの値を返す。`raise ActiveRecord::Rollback`。`requires_new: true` のセーブポイント | `Article.transaction { \|c\| ... }`（= `Cybertrain::DB.transaction`）は接続を渡して nil を返す。抜けるには例外を出す（ロールバックの後に出し直される）。ネストした呼び出しは外側のトランザクションに合流し、セーブポイントはない。SQLite の `BEGIN IMMEDIATE` には `immediate: true`。Spinel では、渡された `c` に対して `c.transaction { }` は呼べない：`DB.transaction` をネストするか、`c.begin!` / `c.commit!` / `c.rollback!` を使う |
| `has_many :through`、`includes`、`dependent:`、enum、STI、ポリモーフィック関連 | 実装されていない。関連付けはスキーマの外部キーからのみ作られる |
| `pluck(:a)`、`sum(:a)`、`group(:a).count`、`upsert`、`update_counters`、`where("title LIKE ?", "%#{q}%")` | Spinel のメソッドは戻り値の型がひとつなので、型付きの 1 カラム版になる：`pluck_str` / `pluck_int` / `pluck_float`（1 カラムのみ）、`sum_int` / `sum_float`、`count_by(:a)`（`Hash{String => Integer}`）、式には `count_by_sql(expr)`。`Model.upsert(attrs, conflict:, update:)` は `DO UPDATE SET` の式を SQL テキストで受け取り、バリデーション、コールバック、タイムスタンプは実行しない。`relation.increment(:col, by: n)`。`where_like(:col, text)` は `\`、`%`、`_` をエスケープしてくれる。[`where` を超えるクエリ](models.md#querying-beyond-where)を参照 |
| 任意のカラム名。関連付けが `errors` を覆い隠せる | カラム名は ASCII の識別子（`[A-Za-z_][A-Za-z0-9_]*`）でなければならない：ASCII 以外のカラム名（`名前`、`prénom`）を持つスキーマは PR #10 以前は CRuby の下で生成できたが、今は `spin run gen` が拒否するので、アップグレード時にカラム名を変える（`first-name` のような名前は、もともとメソッド名になれなかった）。生成されたクラスやフレームワークがレコードに対して呼ぶメソッド（`errors`、`save`、`attributes`、`hash`、`to_s`、`to_ary`、`raise` など）や Ruby のキーワード（`end`、`class`、`begin`）と同じ名前のカラムは、`<column>_column`（`hash_column`。リーダー、ライター、インスタンス変数）として生成され、生成ファイルに注記が付く。SQL の名前は `read_attribute`、params、`attributes["hash"]` で引き続き使え、テンプレートからはどちらの名前でも参照できる（`post.hash`、`post.hash_column`）。ただし `errors` と `to_param` はテンプレートがモデルのメソッドとして解決するので、そこでは `post.errors_column` を使う。クエリ API（`where`、`order`、`find_by`）は常に SQL のカラム名を受け取り（`Post.where(hash: 1)`）、Ruby の名前はリーダーとライター、テンプレートの名前としてだけ使われる。その他の Object のメソッド（`display`、`tap`、`methods`）と同じ名前のカラムは、注記付きでその名前のまま生成される。`cybertrain generate scaffold` はキーワードと予約名を拒否し（名前を変えたリーダーを呼ばなければならなくなるため）、覆い隠す名前はジェネレーターと同じく注記付きで受け付ける。素の名前がすでにカラム、別の関連付け、`Model` のメソッドに使われている関連付けは、生成ファイルにコメントを付けて代わりの名前で出力される：`has_many` なら `<table>_as_<column stem>`（`comments_as_article`）、`belongs_to` なら `<stem>_as_<column>`（`author_as_author_id`） |
| `namespace`、format/`respond_to`、`constraints`、`mount` | 実装されていない — 名前はフラットで、`render json:` のみ |
| `rescue StandardError` が不正な `JSON.parse` を捕まえる | Spinel では `JSON::ParserError` は `StandardError` ではない：アプリのコードは `rescue JSON::ParserError, StandardError` と書く必要がある。サーバーは最後の手段としてこれを捕まえ、500 を返す |
| API コントローラーで `skip_forgery_protection` | CSRF はルーティングの前に実行されるミドルウェアなので、API はパスで除外する：`config/app.rb` に `c.csrf_exempt_prefixes = ["/api/"]`。その場合コントローラーは呼び出し元を自分で認証しなければならず（ヘッダーの API キーなど）、セッションで認証するルートがそのプレフィックスに一致してはならない |
| Rack は gzip されたリクエストボディをそのままにする | `Content-Encoding: gzip` で送られたボディ（数キロバイトを超える SDK や API クライアント）は `request.decoded_body` で、出力の上限（デフォルトで 10 MiB。それ以上を期待するエンドポイントは自分の上限を渡す：`request.decoded_body(limit)`）のもとでシステムの zlib を通じて一度だけ展開される：壊れたボディや gzip/identity 以外のエンコーディングは `Cybertrain::BodyUndecodable`、上限を超えて展開されそうなものは `Cybertrain::BodyTooLarge` で、どちらも 400 を返す `QueryInvalid`。`request.body` は送られたままのバイト列 |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` は `column [ASC\|DESC]` のリスト（各カラムはクォートされる）だけを受け取り、それ以外には `ArgumentError`（文字列は開発者のものなので 500）を出す。リクエストのデータはまず許可リストを通す必要がある。例えば `SORTS = { "title" => "title", "newest" => "created_at DESC" }` と `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`。形式の正しい項目でも、存在しないカラム（SQLite からの 500）や、クライアントに並べ替えさせてはならないカラムを指しうるためである。ORDER BY の生のテキストは `order_sql`（`Post.order_sql("lower(title)")`。relation にもある）を通すが、これにリクエストのデータを渡してはならない。`delete_all` の `limit`/`offset` は尊重され（サブセレクト）、リクエストパラメーターのネストは最大 32 階層 / 4096 ペア（それを超えると 400）。`Query.parse`、`Query.value_of`、`Query.decode`、`request.form_value` / `query_value` は、形式の壊れたパーセントエスケープに対して、どちらのランタイムでも `Cybertrain::QueryMalformed`（`Cybertrain::QueryInvalid` 配下の `StandardError` で、`ArgumentError` ではない）を出す（`Cookies.parse` は引き続き生の値を保持する）。不正な UTF-8 のバイト列に対しても、生のもの（String のタグにかかわらず）でもパーセントエンコードされたものでも同じ例外を出し（Rails も不正なパラメーターのエンコーディングには 400 を返す）、エスケープによってしか完成しない生のバイト（`a=\xC3%A9`）も同様。`Cookies.parse` はそうした値を生のまま保持し、不正なバイト列を含むパス（生のもの、またはセグメント内でパーセントデコードされたもの）も 400 になる（`request.path_segments`。パス内の形式の壊れたエスケープは文字どおりに扱われ、一致しないので 404）。これらを `ArgumentError` で rescue していたアプリのコードは、代わりに `Cybertrain::QueryInvalid` を rescue すること（アップグレードの注意点）。リクエストは自前のパラメーターツリーを持たない（`params` は Router が組み立て、ミドルウェアはキーをひとつ読む）。ツリー全体が欲しいアプリは自分でパースし（`Query.parse(request.utf8_query_string)`）、結果を自分で管理する |
| 例外時の完全なバックトレース | クラス、メッセージ、リクエスト行、テンプレート名と行 — Spinel はバックトレースを公開していない |
| Rack、そのミドルウェア、`Gemfile` の任意の gem | Rack 互換性はない。小さな固定のミドルウェア群。Spinel 自身の `spin-index` で、その Ruby サブセットでコンパイルできるものに限られる |
| minitest / RSpec | `Cybertrain::Test` — リフレクションに基づくランナーは AOT では動かない |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` は同じ形（User、Session、SessionsController、before_action）に加えて、ユーザーを作るコンソールがないのでサインアップのページも書き出す。`has_secure_password` は、`Cybertrain::Password`（Ruby による PBKDF2-HMAC-SHA256。bcrypt はバイナリがリンクする C ライブラリを必要とし、macOS の `String#crypt` には bcrypt がない）の上に User モデルのメソッドとして書き下される。パスワードのリセットはない（メーラーがない）。サインインの試行は `rate_limit` で制限される（プロセスごとに数える。[レート制限](requests.md#rate-limiting-and-the-client-address)を参照） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment post cover` は、所有者のテーブルに 5 つの `cover_*` カラムを、アプリにモデルのメソッド（`cover_file=`、`cover_url` など）を書き出す。ファイルはディスクの `storage/uploads/` 以下に置かれ、生成されたアクションが `send_blob` で配信する。フィールドごとにファイル 1 つ、ローカルディスクのみで、バリアントやダイレクトアップロードはない |
| `skip_before_action :x` | 名前付きの before コールバックについては同じ（ブロックのコールバックにはスキップする名前がない）。`skip_after_action` はない |
| `resource :session` | `SessionsController` への同じ 6 つのルート。その下へのネストはない |
| `get "/x"` の後に `post "/x"` | どちらも問題ない：2 つ目のルートから導かれる名前は使用済みなので、Rails と同じく名前なしになる。`as:` の重複は引き続きエラー |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport に同梱のタイムゾーンデータ | `Cybertrain::TimeZone.find("Asia/Tokyo")` はシステムの TZif ファイル（`/usr/share/zoneinfo`、または `TZDIR`）を読み、Integer のエポック秒を変換する（`utc_offset_at`、`utc_to_local`、`local_to_utc`）。リクエストごとの `Time.zone` や `l(time, zone:)` はまだない（[タイムゾーン](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | Webhook や API には `Cybertrain::HttpClient`：すべての待ちに上限があり、公開されていない宛先はデフォルトで拒否され、リダイレクトや keep-alive はない（[外向きの HTTP](external-services.md#outbound-http) を参照）。Spinel の `Net::HTTP` は、相手が止まるとサーバー全体を止めてしまう |
| Action Mailer（`deliver_later`、メーラークラス、ビュー） | `Cybertrain::Mailer.deliver(to:, subject:, body:)` はプレーンテキストを SMTP で送る（STARTTLS、暗黙の TLS、またはループバックへの平文。AUTH PLAIN。すべての待ちに上限がある）。テンプレート、HTML、添付ファイル、キューはない（[メールを送る](external-services.md#sending-e-mail)を参照） |
| Active Job、`perform_later`、`solid_queue`、定期タスク | `Cybertrain::Job.handle(kind) { \|payload\| ... }` と `Job.enqueue(kind, payload, run_at:)`（`cybertrain_jobs` テーブルに置かれる String のペイロードで、バックオフ付きで再試行され、その後 `failed` になる）、`Cybertrain::Scheduler.every(seconds, name) { ... }`。配信を行うプロセスで 1 スレッド、それ以外では `CYBERTRAIN_WORKER=0`（[バックグラウンド処理](background-and-operations.md#background-work)） |
| ActionCable クライアント、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url).on_message { \|conn, data\| ... }` はサーバーの動作中、フィードを接続したまま保つ（再接続、ping、無音の検出）。同期的な 1 本の接続には `Cybertrain::WebSocket::Client`。外向きのみで、すべての待ちに上限がある（[WebSocket フィードを購読する](external-services.md#consuming-websocket-feeds)を参照） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` は String の Array で、大文字小文字を区別せず部分文字列で照合される（Regexp やラムダは使えない）。リクエストログと開発環境のエラーページに適用される（[フィルターされるパラメーター](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（コントローラーへのルート） | `GET /up` は組み込みで、静的ファイル、セッション、ルーターより前に応答するので、`before_action` は実行されない。データベースとバックグラウンドワーカーの最後のティックを確認し、`200 ok` または `503` を返す（[運用](background-and-operations.md#operations-backups-vacuum-health-check)） |
| バックアップ用の `bin/rails db:...` タスク（組み込みはない） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`、モード 0600、所定の場所にリネーム）と `./<app> db vacuum` |
| ActionCable（サーバー）、アセットパイプライン、i18n | 作られていない（MVP の対象外。`docs/design.md` §2.3） |

これですべてではありません — より詳しい記録は `docs/design.md` §8（「What was deliberately left out」）にあります。

## パフォーマンス

[docs/benchmark.md](../benchmark.md) は、examples/blog と、同じブログを Rails 8.1 で書いた [bench/rails_blog](../../bench/rails_blog)（ビュー、ルート、モデル、スキーマは同じ）を、どちらも本番モードで計測しています。各サーバーは 4 vCPU のクラウド VM 1 台の同じ CPU コアに固定し、別の 2 台から wrk で負荷をかけました。10 秒の実行 3 回の中央値で、2026-10-09 に記録したものです：

| CPU 1 コア、16 接続 | CyberTrain 0.2.1 | Rails 8.1.4（YJIT、Puma） | |
| --- | --: | --: | --: |
| `GET /articles`（記事 30 件） | 2,641 req/s | 468 req/s | 5.6x |
| `GET /articles/1`（コメント 10 件、フォーム 12 個） | 2,450 req/s | 201 req/s | 12.2x |
| `POST /articles/2/comments` | 1,507 req/s | 390 req/s | 3.9x |
| `GET /style.css` | 13,300 req/s | 5,127 req/s | 2.6x |
| 負荷後のメモリ（RSS） | 10.6 MB | 126 MB | |
| 起動から最初のレスポンスまで | 0.02 s | 1.3 s | |
| サーバーに必要なもの | 2.5 MB（バイナリ 1 つ） | 109 MB（Ruby、gem 69 個、アプリ） | |

両方で jemalloc を使うと（spin.toml に `allocator = "jemalloc"`。Rails の本番用イメージはこれをプリロードします）、比は 2.8〜14.6 になります。2 コアでは差は 2.0〜5.5 に縮まります：Puma のワーカーを 2 つにすると Rails は倍になりますが、`SPINEL_WORKERS=2` で CyberTrain が伸びるのは 9〜58% です（マルチコアのサーバーではコア数に設定してください。デフォルトは 1 です）。また、バイナリはビルドする必要があります（そこでは `cybertrain build` に約 3 分かかりました）。docs/benchmark.md には、レイテンシー、すべての構成、計測方法、ここに至るまでに何を最適化したかが載っています。`bench/run` は計測を繰り返し、`bench/report` はその表を出力します。
