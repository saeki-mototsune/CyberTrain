---
source_sha256: 95aa532ab50c281cb5b22692324ab27171bb65213f7c46a6ea6c7903d5bb5d88
---
# ログとエラー報告

動いているアプリケーションがログに書くもの（行の形、レベル、JSON 行、リクエスト ID とタグ）と、リクエスト、ジョブ、定期タスク、フィードの例外がアプリケーションのサブスクライバーと Sentry に届くまでを説明します。ジョブ、プロセスの役割、ヘルスチェックは[バックグラウンド処理と運用](background-and-operations.md)にあります。

## ログ

フレームワークとアプリケーションは `Cybertrain.logger` を通してログを出します。1 つのメッセージが標準出力の 1 行になり、行ごとにフラッシュされます。Twelve-Factor のアプリケーションと同じで、systemd の journal、Kamal、Docker がそれを集めます：

```text 出力 — ./blog server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 127.0.0.1
2026-11-14T09:30:00.132Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-14T09:30:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: RuntimeError: smtp down; retrying in 60 s
2026-11-14T09:30:02.410Z WARN [feed:prices] WebSocket "prices" silent for 60s; reconnecting
```

1 行は、ミリ秒までの UTC の時刻（テストでは `travel_to` に従います）、大文字のレベル、角括弧に入ったタグ、メッセージです。`Cybertrain.logger` には `debug`、`info`、`warn`、`error`、`fatal` があり、どれも String を 1 つ取ります。複数のスレッドの行が混ざることはありません。各行は丸ごと組み立ててから、その書き込みの間だけ持つロックの下で 1 回の write で書きます。失敗した書き込み（閉じたパイプ）はその行を捨てます。ログ出力が呼び出し元に例外を投げることはありません。標準出力を読む側が読むのをやめると（パイプが満杯になると）、また読むまでログを出すスレッドがすべて止まるので、ログ収集を止めないでください。

**1 つのイベントが 1 行。** メッセージやタグの中の改行は 2 文字の `\n`、復帰は `\r` として書かれるので、複数行のメッセージや偽の行が、行を新しく始めることはできません。`Cybertrain.logger.info("ok\n2026-11-11T12:00:00.000Z ERROR fake")` は 1 行を書きます：

```text 出力 — 1 つのイベントが 1 行
2026-11-14T09:30:00.120Z INFO ok\n2026-11-11T12:00:00.000Z ERROR fake
```

メッセージの最後のちょうど 1 つの改行は行自身の終わりで、エスケープされません（`info("done\n")` は `done` と書きます）。2 つ目はエスケープされます。ほかには何もエスケープしません：バックスラッシュはバックスラッシュのまま、タブ、その他の制御バイト、正しくない UTF-8 はそのまま書かれます。JSON の行のエスケープは以前と同じです。

**レベル。** `config/app.rb` の `c.log_level`、または `CYBERTRAIN_LOG_LEVEL`（`debug`、`info`、`warn`、`error`、`fatal`、`none`。大文字小文字は問いません）が、書き出す最も低いレベルです。デフォルトは `:info` です。`:none` はリクエストログも止めますが、エラーの行は書きます。`config/app.rb` での代入が変数より優先されます。それ以外の値では起動が止まります：`error: log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)`。

**JSON の行。** `c.log_format = :json`（または `CYBERTRAIN_LOG_FORMAT=json`）にすると、ログ収集ツール向けに 1 行に 1 つの JSON オブジェクトを書きます：

```json
{"time":"2026-11-14T09:30:00.132Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

`request_id` は、その行が ID を持ち（リクエストの中、またはリクエストがキューに入れたジョブの中）、`log_tags` がそれを表示するときだけ入ります。`tags` にはほかのタグが順に入ります。メッセージ（またはタグ）が UTF-8 として正しくないときは、その 0x80 以上のバイトがすべて、正しい文字のバイトも含めて、JSON ではエスケープ `\ufffd` として書かれます。正しくないバイトが 1 つあると、そのメッセージの ASCII 以外の文字がすべて置換文字になります。正しいメッセージはそのまま書かれ、テキストの行ではログに渡されたバイトのまま残ります。`:text` と `:json` 以外の形式では起動が止まります：`error: log_format must be :text or :json (got :xml)`。起動時の最初の行（テスト以外での `mail_delivery_method :test` の警告）は形式に従います。値が正しくないアプリケーション設定（`setting_int`、`setting_bool` がデフォルトに戻るとき）についての警告は、形式が決まる前の `config/app.rb` の実行中に出るので、常にテキストの行です。

レベルと形式は `./<app> server`、`worker`、`feeds` に加えて、登録したコマンド、`jobs`、`console` にも効きます。これらは未知の値を同じメッセージで拒み、データベースを開く前に終了ステータス 1 で終わります。`migrate`、`db`、`dbconsole` には効きません。これらの行は `info` レベルのテキストです。

### リクエスト ID

すべてのリクエストに ID（バージョン 4 の UUID）が付きます。アクションは `request.request_id` で読み、レスポンスは `X-Request-Id` で返します。ホスト確認の 403、`force_ssl` の https へのリダイレクト、エラーページ、開発用の診断ページ、サーバー自身の 500 にも付きます。サーバーが読めないリクエストに、アプリケーションに渡す前に返す 400 と 413 には付きません。リクエストの実行中に出たすべての行は、その ID をタグとして（デフォルトの `log_tags` では最初のタグとして）持ちます。アプリケーション自身の `Cybertrain.logger.info` の行も、ストリーミングのボディ（`stream do ... end`、Server-Sent Events）や、リクエストが開いた WebSocket の接続も、開いている間ずっと同じです。

```ruby
Cybertrain.logger.info("export #{report.id} for #{request.request_id}")
```

プロキシの ID は、アプリケーションが信頼するプロキシからのものだけを使います。接続が信頼するプロキシ（`CYBERTRAIN_TRUSTED_PROXY` または `CYBERTRAIN_TRUSTED_PROXIES`。`request.client_ip` と同じ確認です。[プロキシの背後のクライアントアドレス](requests.md#the-client-address-behind-a-proxy)）から来て、その `X-Request-Id` が 1〜255 文字の ASCII の英字、数字、ハイフンなら、リクエストはその ID を使うので、プロキシのログとアプリケーションのログが同じ ID を共有します。それ以外の `X-Request-Id`（2 回送られたヘッダーも含む）は捨てて新しい ID を作ります。値を書き換えることはありません。

`c.log_tags` はリクエストのタグとその順序を決めます。デフォルトは `[:request_id]`、`[:request_id, :remote_ip]` で `request.client_ip` を足します（アドレスは個人データなのでデフォルトでは付けません）、`[]` で何も付けません（ヘッダーは送ります）。それ以外では起動が止まります：`error: log_tags may hold :request_id and :remote_ip (got :user_agent)`。

### タグ

`Cybertrain.logger.tagged` は、ブロックの間にこのスレッドで出たすべての行に、リクエストのタグの後ろにタグを足し、ブロックが終わると（例外を投げたときも）外します。ブロックの値を返します。入れ子にできます。ブロックなしの形はありません。

```ruby
Cybertrain.logger.tagged("billing", "order #{order.id}") do
  Cybertrain.logger.info("charged 300")
  # 2026-11-14T09:30:00.140Z INFO [3f2a9c1e-...] [billing] [order 7] charged 300
end
```

タグはスレッドのものです。自分で起こしたスレッドは、起こしたスレッドが何を持っていてもタグなしで始まります。フレームワークも自分の仕事に同じようにタグを付けます：

- **ジョブ。** 各試行の行は `[<JobClass> <id>]`（`Job.handle` のブロックのジョブならその種類）を持ち、続けてキューに入れたリクエストの ID を持ちます：`INFO [WelcomeJob 7] [3f2a9c1e-...] welcome 1`。ID は `log_tags` にかかわらずジョブの行（`cybertrain_jobs.request_id`）に記録され、`log_tags` に `:request_id` があるときに表示されます。ジョブがキューに入れたジョブは親の ID を記録し、定期タスク、フィード、コマンドがキューに入れたジョブは何も記録しません。
- **定期タスク。** タスクの実行中は `[schedule:<name>]`。失敗の行も含みます。
- **フィード。** フィードのスレッドが出すすべての行（コールバックの行も含む）に `[feed:<name>]`。スーパーバイザー自身のスレッドで出る再起動とあきらめの行にはタグがありません。

## エラー報告

`Cybertrain.error` は、リクエスト、ジョブの試行、定期タスク、フィードを終わらせた例外と、アプリケーションが自分で報告する例外を集め、アプリケーションが追加したサブスクライバーに渡し、DSN が設定されていれば Sentry（または GlitchTip）にも送ります。これはコアにあります。Sentry への送信はそれだけの 1 行で、`require "cybertrain"` が読み込み、`cybertrain/core` のアプリケーションは `bin/<app>.rb` に足します（`bin/db.rb` には足しません。[サブシステム](how-it-works.md#subsystems)）。`cybertrain new` は、この節の行をコメントにして書きます：`.env.example` の変数、`config/app.rb` のサブスクライバー、`config/deploy.yml` と `.kamal/secrets` の DSN、そして `bin/<app>.rb` のコメントのこの行です：

```ruby
require "cybertrain/error_reporter/sentry"   # bin/<app>.rb の require "cybertrain/core" の後
```

```ruby
# アプリケーションが rescue したものを、わかっていることと一緒に：
begin
  charge(order)
rescue PaymentError => e
  Cybertrain.error.report(e, context: { "order_id" => order.id })
end

# ブロックを実行し、投げたものを報告して、nil で続ける：
price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)
end
```

`report(e, handled: true, context: {})` はすぐに nil を返します。報告はレポーター自身のスレッドで届けられます。コンテキストのキーと値は String になり、フレームワークが足すコンテキスト（ジョブの ID と試行回数）の上に重なります。`handle(context: {}) { }` はブロックの値を返します。ブロックが `StandardError`（または `JSON::ParserError`、`JSON::NestingError`）を投げたときは、それを報告して nil を返します。ブロックの中の `break v` で `handle` は `v` を返し、`return` は周りのメソッドから戻ります。それ以外のクラスの例外が `handle` のブロックで投げられると、呼び出し元に届きます。報告すること自体は呼び出し元に例外を投げません。報告が失敗したときは、error レベルで `error report failed: <Class>: <message>` とログに出ます。

**サブスクライバー。** サブスクライバーはアプリケーションのクラスで、`report(event)` を定義した `Cybertrain::ErrorSubscriber` のサブクラスです：

```ruby
# config/app.rb の、それを登録する行より上（bin/<app>.rb は app/ より前に
# config/app を読み込むので、ここでは app/ の下のクラスはまだ読み込まれていない）
class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message} at #{event.error_where}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)
```

各サブスクライバーはすべての報告を、失敗したリクエストやジョブの中ではなく、レポーターのスレッドで受け取ります。例外を投げたサブスクライバーは error レベルで `error subscriber AuditSubscriber failed: <Class>: <message>` とログに出し、それ自体は報告しません。ほかのサブスクライバーはそのままイベントを受け取ります。イベントは String でできた値です：

| リーダー | 内容 |
| --- | --- |
| `error_class` | 例外のクラス名。名前空間付き（`"Cybertrain::DB::Error"`） |
| `error_message` | そのメッセージ |
| `error_where` | `"ArticlesController#create"`、`"request"`（アクションが動かなかった）、ジョブのクラスか種類、`"cybertrain mail"`、`"job thread"`、`"schedule:<name>"`、`"feed:<name>"`、または `""` |
| `error_request_id`、`error_request_method`、`error_request_path` | リクエストのもの。パスはクエリを除き、リクエストログと同じようにフィルタされます。ジョブの中では、キューに入れたリクエストの ID。リクエストの外では `""` |
| `error_environment`、`error_release` | `Cybertrain.config.env` と `c.release` |
| `error_handled` | `report` と `handle` では true、フレームワークが報告したものでは false |
| `error_context` | `Hash{String => String}`。アプリケーションのコンテキストと、ジョブの中では `job.id`、`job.attempt`、`job.max_attempts` |
| `error_backtrace` | `Array<String>`。`cybertrain build` のバイナリでは空（後述） |
| `error_occurred_at` | `Time`。クロックから |

**自分で何も書かなくても報告されるもの：**

- 500 で終わったリクエスト。1 回だけです（その後エラーページを返す処理が新しい例外を投げたとき、たとえば `public/500.html` が読めないときは、それも報告され、報告は 2 件になります。どちらも本当の失敗です）。`Cybertrain::ClientError.status_for` が 500 以上に対応させる例外です。4xx（不正なパラメーター、CSRF の失敗、404）と、`rescue_from` が処理したものは報告しません。
- ジョブの失敗した試行（`where` はそのクラスか種類。コンテキストに `job.attempt` と `job.max_attempts`）。デフォルトのポリシー、`retry_on`、`discard_on` のどれでも報告されます。ジョブの中では重複除去のキーにジョブの ID も入ります（[配送](#error-reporting)、後述）。同じ種類の 2 つのジョブが同じように失敗すれば 2 件の報告になり、1 つのジョブの試行が、1 分以内に報告された自身の試行と同じクラスとメッセージで失敗したときは、ログに出ますがもう一度は報告されません（デフォルトのポリシーでは最初の再試行まで 1 分待つので各試行が報告されますが、`retry_on ..., wait: 30` では報告された試行の 30 秒後の試行は報告されません）。破棄は 1 回報告されます。`job.max_attempts` は、デフォルトのポリシーでは `job_max_attempts`、`retry_on` ではポリシーの `attempts:`、`discard_on` では破棄されたときの試行回数です。失敗した `deliver_later` のメールは `cybertrain mail` ジョブのものです。ジョブのスレッドのループから漏れた例外や、そこでのデータベースのエラーは `where` が `job thread` です。
- ブロックが例外を投げた定期タスク、または 5 年以内に次の実行がない `cron` タスク（`schedule:<name>`）。
- 例外を投げたフィードの `on_open`、`on_message`、`on_tick`、死んだフィードのスレッド、フィードをあきらめたスーパーバイザー（`Cybertrain::Background::FeedFailed`。裏にクラスのない名前だけで、メッセージは `feed <name> restarted <n> times in <w> s; exiting`）。どれも `feed:<name>` です。

ストリーミングのボディ（`stream do ... end`、Server-Sent Events）やアップグレードした WebSocket の接続を書いている間に投げられた例外は、サーバーの `stream error: <Class>: <message>` の行の後に 1 回報告されます。リクエストの ID、メソッド、パスを持ち、`where` は `ArticlesController#index (stream)`（アクションが動かなかったときは `request (stream)`）です。去ったクライアント（ライターから出た `EOFError`、`IOError`、`Errno::ECONNRESET`、`Errno::EPIPE`）はその行でログに出ますが、報告されません。報告しないもの：ハンドラーのない種類のジョブ、そして開発中に、すでに報告された例外を表示している診断ページ自身が投げた例外。フレームワークが以前から出していたログの行はそのままで、報告はそれに加えて行われます。

**送らないもの。** パラメーター、ヘッダー、Cookie、セッション、クライアントのアドレス、クエリ文字列はイベントに入りません。リクエストのパスはリクエストログと同じようにフィルタされます。足されるのはアプリケーションが `context:` に入れたものだけです。例外のメッセージは、フィルターが変えない限りそのまま送られます。個人データを含むメッセージ（宛先を書いた SMTP サーバーの拒否）にはフィルターが要ります。

**フィルター。** フィルターは `filter_event(event)` を定義した `Cybertrain::ErrorReporter::Filter` のサブクラスで、イベントを残すなら true、捨てるなら false を返します。メッセージ（`event.error_message =`）とコンテキスト（`event.set_error_context(key, value)`、`event.delete_error_context(key)`）を変えられます。次の 1 つは引用符のない単純な ASCII のメールアドレスを隠し、もう 1 つはアプリケーションが報告したくないクラスを捨てます：

```ruby
# config/app.rb
class MaskAddresses < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_message = event.error_message.gsub(/[\w.+-]+@[\w-]+(\.[\w-]+)+/, "[email]")
    event.delete_error_context("email")
    true
  end
end

class DropDeclinedCards < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_class != "PaymentGateway::Declined"
  end
end

Cybertrain.error.add_filter(MaskAddresses.new)
Cybertrain.error.add_filter(DropDeclinedCards.new)
```

`MaskAddresses` のパターンが見逃すアドレスは 2 種類あります。1 つは `alice@例え.テスト` のように ASCII 以外の文字を含むものです。Ruby の `\w` は、Unicode のプロパティを求めない限り ASCII の英字、数字、`_` にしか一致しません。もう 1 つは `"alice smith"@example.com` のように局所部が引用符で囲まれたものです。パターンは `@` の直前に英字、数字、`.`、`+`、`-`、`_` のどれかを必要としますが、閉じる引用符の後にはそれがなく、この中の何にも一致しないので、アドレス全体がメッセージに残ります。想定するアドレスに合うパターンを書くか、イベントを捨ててください。

フィルターはレポーターのスレッドで、追加した順に、サブスクライバーと送信側より前に動きます。次のフィルター、サブスクライバー、Sentry は、フィルターが変えた内容を見ます。1 つがイベントを捨てると、後のフィルターは動かず、誰もそのイベントを受け取りません（キューの破棄としては数えません）。例外を投げたフィルターはイベントを捨て（フィルターは何かが外に出ないようにするためにあるからです）、error レベルで `error filter failed: <Filter class>: <Class>: <message>` とログに出します。これは報告されません。重複除去はフィルターより前に、フィルター前のクラス、メッセージ、`where` で決まります。フィルターが書き換えても、どの報告がまとめられるかは変わらず、フィルターが捨てたイベントもその 1 分の枠を占めます。フレームワーク自身の `ERROR` のログ行はイベントができる前に書かれ、フィルタされません。フィルターだけでは報告はキューに入りません（サブスクライバーか DSN が要ります）。`config/app.rb` で追加したフィルターはすべてのテストで残り、テストで追加したものは次のテストの前に外れます。

**配送。** 報告は 100 件のキューに入り、1 つのスレッドが届けます。同じクラス、メッセージ、`where`（ジョブの中ではジョブの ID も）の報告は 1 分に 1 回までしかキューに入らないので、訪問者全員に同じメッセージで失敗するページでも報告は 1 分に 1 件です（ID を含むメッセージ、`Couldn't find Article with id=5` なら、メッセージごとに 1 件です）。キューが満杯のときは報告を捨てて数え、`error reports dropped: <n>` を warn レベルで 1 分に 1 回まで出します。サブスクライバーも DSN もない間は、何もキューに入らず、スレッドも起動しません。失敗した配送は `error delivery failed: <Class>: <message>` とログに出し、前のスレッドが終わっていれば次の報告が新しいスレッドを起動します。サーバー、ワーカー、feeds プロセスは止まるとき、サービスを止めた後、キューの報告を最大 2 秒待ちます。残ったものは失われます。開発中の再ビルドも待ちます。登録したコマンド、`./<app> jobs`、`./<app> console` も、データベースを閉じて終了する前に待ちます。

**Sentry または GlitchTip に送る。** `bin/<app>.rb` にその行があれば、`CYBERTRAIN_SENTRY_DSN`（または `c.sentry_dsn`）をプロジェクトの DSN にすると、各報告を Sentry のイベントとして送ります：

```sh
export CYBERTRAIN_SENTRY_DSN=https://PUBLIC_KEY@o1.ingest.sentry.io/42
export CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # 任意：イベントの release として送られる
export CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # 任意：4 分の 1 を送る
```

- DSN は `http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>` の形です（secret、Sentry の古い後半部分は無視します）。イベントは `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/` に送られ、Sentry と GlitchTip のどちらも受け付けます。キーを含むので、コミットするファイルではなくデプロイのシークレットに置いてください。読めない DSN では起動が止まり、どの部分かを示しますがキーは示しません：`error: sentry_dsn must look like https://<public key>@<host>/<project id>: the project id must be digits`。
- 送信側をリンクしていないプログラムで DSN を設定すると、起動が止まり、登録したコマンド、`jobs`、`console` もデータベースを開く前に拒否されます（終了ステータス 1）：`error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`。自分で作った送信側のクラス（`Cybertrain::ErrorReporter::Sender` のサブクラス）は、空でない名前を返す `sender_name` を定義します。そうしないと同じ拒否に当たります。
- `CYBERTRAIN_ERROR_SAMPLE_RATE`（`c.error_sample_rate`、1.0）は送る報告の割合で、0.0〜1.0 です。サブスクライバーはすべての報告を受け取ります。変数は数字に任意の `.数字` が続く形でなければならず、そうでなければ起動が止まります：`error: error_sample_rate must be a number from 0.0 to 1.0 (got "x")`。
- `CYBERTRAIN_RELEASE`（`c.release`。デフォルトは空）はバージョンかコミットを示します。検査はしません。
- 1 回の送信は、ホスト名を解決した後は最大 5 秒待ち（名前解決は配送スレッドを止め、締め切りでは打ち切れないので、止まったリゾルバーは送信をそれ以上待たせることがあります）、再試行はしません。拒否は warn レベルで `error report not sent: Sentry answered 429` とログに出し、接続の失敗も `error report not sent: <Class>: <message>` と出します。
- イベントには、クラスとメッセージ、トランザクションとしての `where`、環境、release、タグとしてのリクエスト ID、リクエストのメソッドとパス、`extra` としてのコンテキスト、そしてバックトレースがあればフレームが入ります。
- 呼び出しは `Cybertrain::HttpClient` と、そのプライベートアドレスへの防御を通ります（[外向きの HTTP](external-services.md#outbound-http)）。プライベートネットワークや同じマシンの GlitchTip には `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1` が要り、これはアプリケーションのすべての外向きの呼び出しで防御を外します。

**バックトレース。** `cybertrain build` のバイナリは Spinel のリリースビルドで、その例外はバックトレースを持ちません。報告にはクラス、メッセージ、`where` が入ります。`--debug` ビルドと CRuby では、フレームが付きます。

`cybertrain test` は Sentry に何も送りません。`config/app.rb` が代入していない限り、エクスポートされた `CYBERTRAIN_SENTRY_DSN` を空にします。テストは代わりに DSN を `Test::SentryReceiver` に向けます（[ログとエラー報告のテスト](testing.md#testing-logs-and-error-reports)）。設計：[docs/design.md](../design.md) の D86 と D88。

### ログとエラー報告のアップグレード

ログとエラー報告についてリリースが変えることは、[アップグレード](upgrading.md#notes-by-version) にバージョンごとに載っています。
