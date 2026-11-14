---
source_sha256: 1ef9863a32c9cd418e4fc175c5dd157510bb5bf8b5f31cfb9c46e2399287edf9
description: "CyberTrain のアプリがどのようにビルドされ、実行されるか（ビルド時のコード生成、オプションのサブシステム、解釈されるビュー、HTTP サーバー、FFI による SQLite、開発ループ）と、Rails との違い。"
---
# 仕組み

このページでは、CyberTrain のアプリがどのようにビルドされ、実行されるかを説明します：ビルド時に生成されるコード、アプリが require するサブシステム、リクエスト時に解釈されるビュー、HTTP サーバー、FFI による SQLite、開発ループ、そして Rails との違いの表です。ホームページの[パフォーマンスのセクション](site:index.html#performance)では、その結果を、同じブログを Rails 8.1 で書いたものと比べています。計測方法、すべての数値、計測をもう一度実行する方法は [docs/benchmark.md](../benchmark.md) にあります。

## ビルド時のコード生成

`spin run gen`（`bin/gen.rb`）は、`db/schema.rb` の `create_table` DSL と `config/routes.rb` の `Routes.draw` DSL を実行してテーブルとルートの*データ*を得ます。それとは別に、`app/controllers/**/*.rb` と `app/models/**/*.rb` に対して**字句スキャン**（パーサーではなく正規表現。Spinel は実行時にパーサーを公開していません）を行い、`@ivar =` の代入、`before_action`/`after_action`/`rescue_from ... with:` の名前、`helper_method`・`layout`・`rate_limit` の行、コンサーンの `include`、引数なしの `def` を探します。`app/assets/`、`app/javascript/`、`vendor/javascript/` のファイルにダイジェストを付け、`config/importmap.rb` をテキストとして読み、`config/locales/` の辞書を独自の YAML リーダーで読みます。

そこから、素の読みやすい Ruby を `gen/` 以下に書き出します：

- `gen/models/<name>.rb`：アクセサー、型変換、ファインダー、外部キーから導いた関連付け
- `gen/routes.rb`：ルートテーブル、ディスパッチャー、`*_path`/`*_url` ヘルパー
- `gen/controllers.rb`：コントローラーごとの `view_assigns`、`run_callback`、`helper_method` の表、`controller_layout`
- `gen/concerns.rb` と `gen/concerns/**`：コンサーンの `included` ブロックを include する各クラスに差し込んだものと、そのブロックを空にしたコンサーンのモジュール（[コンサーン](requests.md#concerns-and-helper_method)）
- `gen/assets.rb`：ダイジェスト付きのアセットのパスとインポートマップ（[アセット](assets.md)）。ダイジェスト付きのファイルは `public/assets/` に置く
- `gen/locales.rb`：アプリケーションの辞書を 2 つの Hash にしたもの。`I18n.t` がこれを読む（[国際化](i18n.md#dictionaries)）
- `gen/migrations.rb`
- `gen/views.rb`：埋め込みビューのテーブル。デプロイ用のビルド以外では空
- `gen/app.rb`：`require_relative` のマニフェスト
- `gen/tests.rb` と `gen/test/**`：`test/` のすべてのテストを 1 つのプログラムにしたもの。各テストクラスはメソッドに書き換えられ、`gen/test/data.rb` にはテーブルとフィクスチャが入る（[アプリをテストする](testing.md#running-the-tests)）

`gen/` は gitignore せずにコミットします：`spin build` と `spin test` には先に生成を行うフックがないため、チェックインされた出力がそのままコンパイルできるものでなければなりません。CI は `spin run gen` を再実行して差分があれば失敗するので、古い生成コードがマージされることはありません。

## サブシステム

Spinel は、プログラムが require したすべてのファイルのすべてのメソッドを、呼ばれるかどうかにかかわらずコンパイルし、プログラム全体の解析がどのビルドでも大部分を占めます。そのため、アプリが使わないかもしれないフレームワークの部分は分かれていて、Rails の `config/application.rb` が railtie を並べるように、`bin/<app>.rb` が使うものを指定します：

| 行 | 読み込むもの |
| --- | --- |
| `require "cybertrain/core"` | HTTP、ルーティング、コントローラー、モデル、ビューとヘルパー（`turbo_frame_tag`、`dom_id`、`render turbo_stream:`、`format.turbo_stream` もここ）、アセット、セッション、CSRF、CSP、コンソール、`db` と `migrate` |
| `require "cybertrain/jobs"` | `Job` とジョブクラス、`Scheduler`（`every`、`cron`）、`worker` ロール、`jobs` コマンド、ジョブページ |
| `require "cybertrain/streams"` | `Stream.broadcast_*`、ストリームエンドポイント（SSE と WebSocket）、`Controller#turbo_stream`、ヘルパー `turbo_stream_from`、`turbo_stream`、`signed_stream_name`、`stream_source_path` |
| `require "cybertrain/feeds"` | `Background`、`feeds` ロールとそのヘルスチェック。`require "cybertrain/websocket"`（`WebSocket.subscribe`）がこれを読み込む |
| `require "cybertrain/mailer"` | `Mailer.deliver` |
| `require "cybertrain/mailer/later"` | `Mailer.deliver_later`。メーラーとジョブも読み込む |
| `require "cybertrain/cache"` | `Cache` |
| `require "cybertrain/rate_limit"` | コントローラーの `rate_limit`。キャッシュも読み込む |
| `require "cybertrain/error_reporter/sentry"` | Sentry の送信側：`CYBERTRAIN_SENTRY_DSN` で各エラー報告を Sentry か GlitchTip に送る（[エラー報告](background-and-operations.md#error-reporting)）。`HttpClient` と TLS を読み込む。`bin/<app>.rb` だけに書く |
| `require "cybertrain"` | 上のすべて |

どの行も `require "cybertrain/core"` の後に書きます（`cybertrain/jobs` と `cybertrain/feeds` は自分でコアを読み込みますが、ほかの行は読み込みません）。行の順序は関係ありません：フレームワークはサブシステムを自分の決まった順序で起動・停止します。スキャフォールドしたアプリでは、コアだけなら 2,767 ではなく 2,205 メソッドをコンパイルし、解析は 52 秒ではなく 38 秒です。フルビルドは 108 秒ではなく 83 秒、コントローラーの編集 1 回は約 65 秒ではなく約 47 秒です（[docs/performance-next.md](../performance-next.md)）。

`cybertrain new` は `bin/<app>.rb` と `bin/db.rb`（`config/app.rb` を読み込むので同じ行が必要）に `require "cybertrain/core"` を書きます。`cybertrain generate job` は両方に `require "cybertrain/jobs"` を、`generate authentication` はそのコードが使う 4 行（`cybertrain/jobs`、`cybertrain/mailer`、`cybertrain/mailer/later`、`cybertrain/rate_limit`：ジョブページ、`deliver_later` で送るメール、レート制限つきのサインイン）を追加します。それ以外の行は自分で追加します。分割より前に書かれたアプリには `require "cybertrain"` があり、これは今もすべてを読み込みます：以前と同じようにビルドされ動作します。この行をコアと使う行に置き換えると、ビルドが速くなります。

足りない行は、アプリが動く前に見つかります：

<!-- list: points -->
- 足りないサブシステムを名指しする Ruby コード（`ReportJob.perform_later`、`Cybertrain::Stream.broadcast_append_to`、`Cybertrain::Mailer.deliver`、`rate_limit to:`）はコンパイルできません。エラーは定数またはメソッドを名指しし、上の表がその行を示します。
- サブシステムのヘルパーを呼ぶビューは、`spin run gen`（と `spin run gen -- --check`）を終了ステータス 1 で止めます：`app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb`。それでもレンダリングされたテンプレートは `undefined helper 'turbo_stream_from'` を発生させます。
- `./<app> worker`、`./<app> jobs`、`./<app> feeds` は、たとえば `the worker role needs require "cybertrain/jobs" in bin/<app>.rb` と表示して 1 で終了します。
- `/up` は読み込まれたものについてだけ報告します：ジョブがなければワーカーの停滞を、フィードがなければフィードの停滞を見ません。
- Sentry の送信側の行がないまま DSN を設定すると、起動を拒みます：`error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`。エラーレポーター自体、そのサブスクライバー、ログのリクエスト ID はコアにあります。

gen は `bin/<app>.rb` をテキストとして読み、そこに書かれた `require "cybertrain"` と `require "cybertrain/..."` の行しか見ません。これらを `bin/<app>.rb` が `require_relative` で読み込む別のファイルに移すと、gen は動くはずのヘルパーを拒否します。`bin/<app>.rb` に置いたままにしてください。

ジョブがない場合、キャッシュは期限切れの行を自分で削除します：プロセスの最初の書き込みと、`cache_prune_interval` ごとの最初の書き込みが、最大 1000 行を削除します。ジョブがあれば、これまでどおりスケジュールされたタスク `"cybertrain cache prune"` が行います（[キャッシュストア](background-and-operations.md#the-cache-store)）。

gen が見つけないケースが 2 つあります：`cybertrain/jobs` なしで `config/routes.rb` に書いた `jobs_page` の行は、gen のメッセージではなく生成されたコントローラーのコンパイルエラーになります。また、`retry_on` や `discard_on` が `Cybertrain::Mailer` のエラーを名指しするジョブがあると、生成される `gen/app.rb` が自分で `cybertrain/mailer` を require します。

テストはこれらの行では削られません：`cybertrain test` がコンパイルするプログラム（`gen/tests.rb`）は、`bin/<app>.rb` が何を require していても `cybertrain`、つまりすべてのサブシステムと Sentry の送信側を require します。そのため `perform_enqueued_jobs`、`assert_emails`、`assert_broadcasts`、`Test::SentryReceiver` はどのアプリケーションでも使え、`cybertrain/core` のアプリケーションはすべてのサブシステムとともにテストをコンパイルし、行のないサブシステムを名指しするコードはテストを通って `spin build` で止まります（[アプリをテストする](testing.md)）。

## ビューは解釈される

`app/views/**/*.html.erb` のファイルは Rails の ERB のように見えますが、リクエスト時に AST へとパースされ、木を辿るインタープリターによって実行されます。Spinel には `eval` がないため、これは本物の Ruby ではなく閉じた文法です（リテラル、`@ivar`/ローカル変数の参照、型ごとに固定されたディスパッチテーブルを通じた呼び出し、`if`/`unless`、`each`/`each_with_index`/ヘルパーの 1 ブロック）。文法、ヘルパー、未対応のものの全体は[テンプレート言語リファレンス](template-language.md)にあります。

ソースの出どころはモードによって異なります：

- 開発環境（とテスト環境）ではエンジンが `app/views/` をディスクから読み、開発環境ではテンプレートが変更されると再パースするので、ビューの編集に再ビルドは不要です。
- `cybertrain build` は `SPIN_DEBUG=1 spin run gen -- --embed-views` を実行し、すべてのテンプレートのソースを文字列テーブルとして `gen/views.rb` に書き込んでその 1 回の `spin build` を行い、その後もう一度 `SPIN_DEBUG=1 spin run gen` を実行して、コミットされる空のテーブルに戻します。
- 本番用のバイナリはそのテーブルだけをレンダリングし（各テンプレートを一度だけパースします）、テーブルが空なら起動を拒否します（`error: views are not embedded in this binary`）。

## HTTP サーバー

`Cybertrain::Server` は素の Ruby による HTTP/1.1 です：`TCPServer#accept` と、接続ごとに 1 つの Spinel グリーンスレッド（M:N スケジューリング、GVL なし）、型付きの `Request`/`Response` からなり、Rack の層はありません。TLS と HTTP/2 はリバースプロキシに任せます。`SPINEL_WORKERS` のデフォルトは `1` です：検証の結果、同時接続 100 のこの I/O 律速の形では、そのほうが速く、詰まりもないことがわかりました。

サーバーは `HttpHandler`（`call(request) -> Response`）を呼び出し、`ContextHandler` がそれをミドルウェアのスタックにつなぐので、HTTP の層（`cybertrain/http/` と `Params`、`Logger`）はフレームワークの残りの部分に依存しません。CI では `script/check-http-layer` がこれを強制します。

## FFI による SQLite

モデルは Spinel の `ffi_func`/`ffi_lib` を通じて SQLite と直接やり取りします：C 拡張も gem もありません。すべてのクエリはバインドされ、文字列に埋め込まれることはありません。現在のアダプターはこれだけです（`libpq` FFI による PostgreSQL は将来の作業の候補として記録されています）。

プール（`SizedQueue`、デフォルトで 4 接続）は、次の設定で接続を貸し出します：

- WAL
- 約 5 秒のビジータイムアウト。待機はグリーンスレッドの `sleep`（最初は 100 µs、その後最大 1 ms）で行うので、ワーカーが 1 つでもロックを持つ接続は動き続けます。スキーマのスクリプトは SQLite の中で待ちます（SQLite 自身の `busy_timeout` は 1 ミリ秒以上スリープします）
- 最大 64 個のキャッシュされたプリペアドステートメント
- 外部キー有効

トランザクションがこうした接続のひとつをどう借り、その上で何が実行されるか：[トランザクション](models.md#transactions)。

## 開発ループ

`development`（`cybertrain build` で作ったバイナリ以外での `CYBERTRAIN_ENV` のデフォルト）の `cybertrain server` はスーパーバイザーです。`cybertrain` コマンドを動かしている Ruby、つまり CRuby の上で動き、待ち受けソケットを自分で持ち、その上で子プロセスを一度に一つだけ動かします：変更の直後は CRuby 上のアプリケーション、Spinel がバックグラウンドでビルドを終えたらコンパイル済みのバイナリです。Ruby の編集には CRuby のプレビューがすぐに応答し（examples/blog では 1 秒未満）、その後は何もしなくてもコンパイル済みのプログラムがポートを引き継ぎます。

起動するとスーパーバイザーは gen を CRuby で実行し（`ruby bin/gen.rb`。`spin run gen` と同じ `gen/` を書きます）、アプリケーションを CRuby で起動し（`ruby -r cybertrain/preview bin/NAME.rb`）、ビルドを始めます。どちらも `PATH` 上の `ruby`、つまり `cybertrain doctor` が `fiddle` を確認する Ruby で動きます。これは `cybertrain` コマンドを動かしている Ruby とは別の Ruby のこともあります。プレビューはフレームワークの FFI（SQLite、zlib）を Ruby の `fiddle` の上のシムで提供します。このシムはバイナリと同じ C を一度だけ `tmp/cybertrain-dev/ffi/` にコンパイルします。最初のビルドは `spin build NAME` なので、バイナリをビルドしてから変わっていないアプリケーションは何もコンパイルせず、バイナリが 1 秒以内に応答を始めます。バイナリより新しい Ruby ファイルがあるときの最初のビルドと、それ以降のすべてのビルドは `spin build NAME -- --incremental` です：Spinel のインクリメンタルビルドで、編集によって変わった C のユニットだけを再コンパイルします。`--incremental` のない Spinel のリリースはこのフラグを拒否し、その場合はフラグなしでビルドします。出力は `tmp/rebuild.log` に書かれます。

スーパーバイザーは `app/**/*.rb`、`config/**/*.rb`、`db/schema.rb`、`gen/**/*.rb` とアセットのルート（`app/assets/**`、`app/javascript/**`、`vendor/javascript/**`）を 1 秒に 10 回確認します。ビューは除外され（どちらのランタイムもディスクから読み直すためです）、開発環境では空の `gen/views.rb` も同様です。変更があると、実行中のビルドを取り消し、gen を CRuby で実行し、子プロセスを新しい CRuby の子プロセスに置き換えて、新しいビルドを始めます。ビルドが成功し、その間に何も変わっていなければ、スーパーバイザーは CRuby の子プロセスを止めて、同じソケットで `build/bin/NAME` を起動します：止めてから起動し、その間もソケットは開いたままなので、切り替えの最中に来たリクエストは少し待ってから応答されます。拒否されるリクエストはありません。

アプリケーションのすべてのレスポンスには `X-Cybertrain-Runtime: cruby` か `spinel` が付き、すべての HTML ページの右下隅には目立たない 1 行が表示されます：

- `CRuby preview · Spinel building…`：ビルドの実行中に CRuby がこのページを描画しました。
- `Spinel ready — reload`：いまはコンパイル済みのバイナリが応答しています。リロードするとそのページが見られます。
- `CRuby preview · Spinel build failed`：CRuby が応答を続け、ページにはコンパイラの出力がバナーとして表示されます。
- `CRuby preview · Spinel binary failed`：バイナリが起動しなかったか、終了しました。CRuby が再び応答し、バナーにはバイナリが報告した内容が表示され、次の変更でビルドしてもう一度試します。
- `Spinel`：コンパイル済みのバイナリがこのページを描画しました。
- `Source changed — reload`：ページの描画の後にファイルが変わりました。
- `CRuby preview`：CRuby がこのページを描画し、上のどれにも当てはまりません。

この行は自分で最新の状態に保たれます。アプリケーションのページが勝手にリロードすることはないので、入力途中のフォームが失われることはありません。gen が失敗したとき、またはアプリケーションが CRuby で起動できないとき（たとえば `SyntaxError`）は、スーパーバイザー自身がすべてのリクエストに 503 のページで応答し、エラーと何を待っているかを表示します。このスーパーバイザー自身のページは、子プロセスが応答できるようになるまで 2 秒ごとに自分でリロードし、エラーを直して保存すればアプリケーションが戻ってきます。`cybertrain build` が `tmp/cybertrain-build.lock` を保持している間は、再生成も再起動も行わず、ロックがなくなってから追いつきます。スーパーバイザーは自分のファイルを `tmp/cybertrain-dev/` に置き、アプリケーションごとに一つだけ動きます。Ctrl-C でビルド、子プロセス、サーバーが止まります。

プレビューでは分からないこと：

- コードがコンパイルできるかどうか。バックグラウンドのビルドが終わったときに分かります。
- [spikes/NOTES.md](../../spikes/NOTES.md) に記録されたランタイムの違い（例外の継承関係、ソケット上の String のエンコーディング、狭められた Float の `Float#round` など）。バイナリが応答するようになってから現れます。
- タイミングと並行性：CRuby には GVL と OS スレッドがあり、`SPINEL_WORKERS` は意味を持ちません。

バックグラウンドの処理（ジョブ、スケジューラー、ストリームのポーラー、WebSocket のフィード）は、応答している方の子プロセスで動きます。そのため一度の編集でこれらは CRuby へ、次にバイナリへと二度再起動し、Server-Sent Events と WebSocket のクライアントは二度再接続します。プレビューで動いたページは、バイナリでも動いて初めて完成です。数に入るのはコンパイルしたテスト（`spin test`）だけです。

`cybertrain server --spinel` は代わりにコンパイル版のループを実行します。直接入力した `spin run NAME` と、`spin install` がビルドするネイティブ CLI も同じです：`SPIN_DEBUG=1 spin run gen`、`build/bin/NAME` より新しい Ruby ファイルがあれば `spin build NAME -- --incremental`、次に `spin run NAME`。バイナリ自身が同じファイルを 0.5 秒ごとに確認し、変更があるとバックグラウンドで `SPIN_DEBUG=1 spin run gen && spin build NAME -- --incremental` を実行し、成功するとリスナーを止めて処理中のリクエストを捌き切り、同じポートと PID のまま新しいバイナリを `execv` します。ビルドに失敗した場合は古いバイナリで配信を続け、HTML レスポンスにコンパイラの出力をバナーとして表示します（ダウンロード（`Content-Disposition: attachment`）と、アプリケーションがエンコードした本文（`Content-Encoding`）には表示しません）。`cybertrain build` がロックを保持している間は再ビルドを行いません。CLI とこのループは gen を、CLI はさらに `bin/db.rb` を、spin のデバッグモード（`SPIN_DEBUG=1`、`-O0`）でビルドします：どちらも数ミリ秒しか動かず、gen は `-O2` のときのごく一部の時間でコンパイルできるためです。アプリケーションは常にリリースビルドです。プレビューを動かせないときは、`cybertrain server` は `preview unavailable:` で始まる 1 行を出力し、コンパイル版のループを実行します。それは、`CYBERTRAIN_ENV` に `development` 以外の環境が指定されているとき、アプリケーションのフレームワークがプレビューより古いとき（`cybertrain/preview.rb` か `cybertrain/dev/supervision.rb` がない）、`PATH` 上に `ruby` がないとき、またはその `ruby` が起動できないか、10 秒以内に応答しないか、`fiddle` を読み込めないとき（`cybertrain doctor` が確認します）です。本番環境ではこれらは一切読み込まれません。

## Rails との違い

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`、`rails dbconsole` | `./<app> console` はモデルに対してテンプレートの式言語を評価する（Spinel には `eval` がないので Ruby ではない）。`./<app> dbconsole` は `sqlite3` を開く（[コンソール](background-and-operations.md#the-console)） |
| `config/application.rb` がアプリの使う railtie を require する | `bin/<app>.rb` と `bin/db.rb` が `cybertrain/core` とアプリの使う[サブシステム](#subsystems)を require する。`require "cybertrain"` はそのすべて |
| `rails runner`、`lib/tasks/*.rake` | `bin/<app>.rb` に `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }`：`./<app> name ARGS` でデータベースに接続した状態で実行される |
| コードを編集すると、動いているアプリが取り込む | Ruby の変更は CRuby のプレビューからすぐに反映され、ビルドが終わるとコンパイル済みのバイナリがポートを引き継ぐ（`cybertrain server`） |
| ビューを編集しても再読み込みは不要 | 同じ — 開発環境ではビューはリクエストごとにディスクからパースされる |
| `def new` | `def new_action`（`new` は `Klass.new(ctx)` を覆い隠してしまう） |
| `before_action { do_thing }`（暗黙の `self`） | `before_action { \|c\| c.do_thing }` — 保存したブロックに対する `instance_exec` がないので、コールバックはコントローラーやレコードを明示的に受け取る |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — ネストしたブロックはマッパーを明示的に受け取る |
| ERB はメソッドにコンパイルされる。どんなオブジェクトの、どんなメソッドでも呼べる | 固定の文法とディスパッチテーブルに対して解釈される（[テンプレート言語](template-language.md)） |
| セッションはマーシャルされた任意のオブジェクトを保持する | セッションの値は String だけで、Rails の cookie store と同じく AES-256-GCM で暗号化した cookie に入る（[Cookie とセッション](requests.md#cookies-and-the-session)） |
| 多くのデータベースアダプター | FFI による SQLite のみ |
| `Article.transaction { ... }` はブロックの値を返す。`raise ActiveRecord::Rollback`。`requires_new: true` のセーブポイント | `Article.transaction { \|c\| ... }` は接続を渡して nil を返す。抜けるには例外を出す。ネストした呼び出しは外側のトランザクションに合流し、セーブポイントはない（[トランザクション](models.md#transactions)） |
| `has_many :through`、enum、STI、ポリモーフィック関連 | 実装されていない。`has_many`、`has_one`、`belongs_to` は外部キーか一行の宣言から作られ、`dependent:`、`counter_cache:`、一段の `includes` がある（[関連付け](models.md#associations)） |
| `pluck(:a)`、`maximum(:a)`、`group(:a).sum(:b)`、`upsert`、`update_counters`、`where(created_at: t1..t2)` | Spinel のメソッドは戻り値の型がひとつなので、型付きの版になる：`pluck_int` とその仲間、`maximum_int`、`sum_float_by`、`upsert`、`increment(:col, by: n)`。Time の範囲は `where_between`（[`where` を超えるクエリ](models.md#querying-beyond-where)） |
| 任意のカラム名。関連付けが `errors` を覆い隠せる | ASCII の識別子のみ。フレームワークのメソッドや Ruby のキーワードと同じ名前のカラムは `<column>_column` として生成され、衝突する関連付けは代わりの名前で生成される（[カラム名](models.md#column-names)） |
| `namespace`、`scope`、フォーマットと `respond_to` | 同じ（[ルーティング](requests.md#routing)、[フォーマット](requests.md#formats-and-respond_to)）。JSON は `render json:` で返す（jbuilder のテンプレートはない） |
| `constraints`、`mount`、glob セグメント | 実装されていない |
| 実行時に include される `ActiveSupport::Concern` | `app/controllers/concerns` と `app/models/concerns` のコンサーンを、`spin run gen` が include するクラスに展開する。`include` はコンサーンを指し、`class_methods` のメソッドはインスタンスメソッドと同じ名前にできない（[コンサーン](requests.md#concerns-and-helper_method)） |
| `rescue StandardError` が不正な `JSON.parse` を捕まえる | Spinel では `JSON::ParserError` は `StandardError` ではない：アプリのコードは `rescue JSON::ParserError, StandardError` と書く必要がある。サーバーは最後の手段としてこれを捕まえ、500 を返す |
| API コントローラーで `skip_forgery_protection` | CSRF はルーティングの前に実行されるので、API はパスで除外し（`c.csrf_exempt_prefixes = ["/api/"]`）、呼び出し元を自分で認証する（[設定](configuration.md#configuration-and-environment-variables)） |
| Rack は gzip されたリクエストボディをそのままにする | `Content-Encoding: gzip` のボディは `request.decoded_body` で、10 MiB の上限のもとで展開される。壊れたものや大きすぎるものは 400。`request.body` は送られたままのバイト列（[クエリ文字列とボディ](requests.md#query-strings-and-bodies)） |
| `order("lower(title)")`、`order("posts.title")`、`order(params[:sort])` | `order` は `column [ASC\|DESC]` のリストだけを受け取る。リクエストのデータは許可リストを通し、生の SQL は `order_sql` を通す（[並び順](models.md#ordering)）。形式の壊れたパラメーターや深くネストしたパラメーターは 400（[クエリ文字列とボディ](requests.md#query-strings-and-bodies)） |
| 例外時の完全なバックトレース | クラス、メッセージ、リクエスト行、テンプレート名と行 — Spinel はバックトレースを公開していない |
| Rack、そのミドルウェア、`Gemfile` の任意の gem | Rack 互換性はない。小さな固定のミドルウェア群。Spinel 自身の `spin-index` で、その Ruby サブセットでコンパイルできるものに限られる |
| minitest / RSpec | Rails 流のテストクラス（`ActiveSupport::TestCase`、`ActionDispatch::IntegrationTest`、`ViewComponent::TestCase`）とフィクスチャ。`spin run gen` がそれらを 1 つのプログラムに書き換え、`cybertrain test` がコンパイルして実行する。リフレクションに基づくランナーは AOT では動かない（[アプリをテストする](testing.md)） |
| `bin/rails generate authentication`、`has_secure_password` + bcrypt | `cybertrain generate authentication` は同じ形に加えてサインアップのページを書き出す。パスワードには PBKDF2-HMAC-SHA256 を使う（bcrypt は C ライブラリを必要とし、macOS の `String#crypt` には bcrypt がない）。パスワードリセット、確認、ロックアウト、ログインしたままにする機能も、Devise が加えるように生成される（[認証](authentication.md)） |
| Active Storage、`has_one_attached :cover` | `cybertrain generate attachment` は 5 つの `cover_*` カラムとモデルのメソッドを書き出す。ファイルはローカルディスクの `storage/uploads/` 以下に置かれ、`send_blob` で配信される。フィールドごとに 1 つで、バリアントやダイレクトアップロードはない（[カバー画像を追加する](tutorial.md#attachments)） |
| `skip_before_action :x` | 名前付きの before コールバックについては同じ（ブロックのコールバックにはスキップする名前がない）。`skip_after_action` はない |
| `resource :session` | `SessionsController` への同じ 6 つのルート。その下へのネストはない |
| `get "/x"` の後に `post "/x"` | どちらも問題ない：2 つ目のルートから導かれる名前は使用済みなので、Rails と同じく名前なしになる。`as:` の重複は引き続きエラー |
| `Time.zone = "Asia/Tokyo"`、`time.in_time_zone`、ActiveSupport に同梱のタイムゾーンデータ | `Cybertrain::TimeZone.find("Asia/Tokyo")` はシステムの TZif ファイル（`/usr/share/zoneinfo`、または `TZDIR`）を読み、Integer のエポック秒を変換する（`utc_offset_at`、`utc_to_local`、`local_to_utc`）。`c.time_zone` がアプリケーション全体の `Time.zone` を決め、`in_time_zone` は壁時計の値を持つ小さな値を返し、Time は UTC の瞬間のまま（TimeWithZone はなく、`time.hour` は UTC）（[タイムゾーン](configuration.md#time-zones)） |
| `Net::HTTP`、Faraday | Webhook や API には `Cybertrain::HttpClient`：すべての待ちに上限があり、公開されていない宛先はデフォルトで拒否され、リダイレクトは求められたときだけ、ストリーミングと gzip のレスポンス、Server-Sent Events のパーサーがあり、keep-alive はない（[外向きの HTTP](external-services.md#outbound-http) を参照）。Spinel の `Net::HTTP` は、相手が止まるとサーバー全体を止めてしまう |
| Action Mailer（`deliver_later`、メーラークラス、ビュー） | `Cybertrain::Mailer.deliver(to:, subject:, body:, html:)` はプレーンテキスト、またはパーシャルからレンダーした HTML の部分（`Views.render_mail`）を持つ `multipart/alternative` を SMTP で送る（STARTTLS、暗黙の TLS、またはループバックへの平文。AUTH PLAIN。すべての待ちに上限がある）。`Mailer.deliver_later` は組み込みのジョブから送る。メーラーは `app/mailers` のモジュールで、そのメソッドは `Cybertrain::MailMessage` を返す（`deliver_later`、`deliver_now`）。生成される `PasswordsMailer` がその例。添付ファイルはない（[メールを送る](external-services.md#sending-e-mail)を参照） |
| Active Job、`perform_later`、`solid_queue`、定期タスク、Mission Control | `app/jobs` のジョブクラス（`< Cybertrain::Job::Base`、JSON の値の Hash を受け取る `perform(args)`、`perform_later`、`retry_on`、`discard_on`、キー付きの `limits_concurrency`）、短い形の `Job.handle(kind)`。タイムゾーンとデータベースに保存される時刻表を持つ `Scheduler.every` と `Scheduler.cron`。ジョブページ（ルートの `jobs_page`）と `./<app> jobs`。サーバーか `./<app> worker` のプロセスで、プロセスあたり `job_threads` 本のスレッド。少なくとも 1 回の配信（[バックグラウンド処理](background-and-operations.md#background-work)） |
| `Rails.cache.fetch(key, expires_in:, race_condition_ttl:)` | アプリケーションの SQLite データベースの `Cybertrain::Cache.fetch`。オプションは同じ。値は String で、それ以外は `fetch_hash`、`fetch_array`、`fetch_int`。メモリや Redis のストアはない（[キャッシュストア](background-and-operations.md#the-cache-store)） |
| ActionCable クライアント、faye-websocket、websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` はサーバーの動作中、フィードを接続したまま保つ（再接続、ping、無音の検出）。同期的な 1 本の接続には `WebSocket::Client`。外向きのみ（[WebSocket フィードを購読する](external-services.md#consuming-websocket-feeds)） |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` は String の Array で、大文字小文字を区別せず部分文字列で照合される（Regexp やラムダは使えない）。リクエストログと開発環境のエラーページに適用される（[フィルターされるパラメーター](configuration.md#configuration-and-environment-variables)） |
| `get "up" => "rails/health#show"`（コントローラーへのルート） | `GET /up` は組み込みで、静的ファイル、セッション、ルーターより前に応答するので、`before_action` は実行されない。データベース、ワーカー、WebSocket のフィードを確認し、`200 ok` または `503` を返す（[運用](background-and-operations.md#operations-backups-vacuum-health-check)） |
| バックアップ用の `bin/rails db:...` タスク（組み込みはない） | `./<app> db backup PATH` / `db backup DIR/ --keep N`（`VACUUM INTO`、モード 0600、所定の場所にリネーム）と `./<app> db vacuum` |
| Action Cable、`turbo_stream_from`、`broadcast_append_to` | 同じヘルパー名で、1 つの SQLite テーブルから Server-Sent Events か WebSocket で配信される署名付きストリーム。チャンネルのクラスはない（[リアルタイム](realtime.md)） |
| Propshaft、importmap-rails | 同じ配置（`app/assets`、`app/javascript`、`vendor/javascript`、`config/importmap.rb`）で、`spin run gen` がダイジェストを付けて `public/assets/` に書く。`bin/importmap pin` はなく、Turbo は同梱しない（[アセット](assets.md)） |
| Rails の i18n、rails-i18n の辞書、`I18n.t`、`t(".title")` | 同じ API とキーで、英語と日本語を同梱。`config/locales/*.yml` は YAML のサブセット（アンカー、エイリアス、タグはなし）から `spin run gen` が組み込む。リストは `I18n.translate_list` で引く（[国際化](i18n.md)） |

<!-- table-foot: これですべてではありません：より詳しい記録は docs/design.md §8（「What was deliberately left out」）にあります。 -->
