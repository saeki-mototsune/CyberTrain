---
source_sha256: 45ac335f704c27617c7aee80f74f3ae736c480c04faacc7088eb90a6cd497fbe
---
# アプリをテストする

アプリのテストは、フレームワーク自身のものと同じく、`test/` 以下の素の Spinel プログラムです：

```ruby
require_relative "support/blog_test"   # アプリ、BLOG、Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

アサーション：`assert`、`refute`、`assert_equal`、`assert_nil`、`assert_includes`、`assert_raises("Class") { }`、`flunk`。コントローラーや HTTP の一連の流れには、`Cybertrain::Test::Client` が cookie jar を持ってアプリをプロセス内で（ソケットなしで）動かすので、セッションと CSRF はブラウザー越しと同じように振る舞います：

```ruby
require_relative "support/blog_test"   # アプリ、BLOG、Cybertrain::Test

test "POST /articles creates an article and redirects to it" do
  client = Cybertrain::Test::Client.new(BLOG)
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, BlogTest.article_path(Article.last)
  assert_response res, :see_other
end
```

どちらのスニペットも、サンプルのヘルパー [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb) から始まります：これをアプリの `test/support/` にコピーしてください。このディレクトリのファイルは実行されず、require されるだけです。このファイルは新しい `storage/test.sqlite3` にマイグレーションを適用し、アプリを `BLOG` として起動し、`Cybertrain::Test` とそのクライアントを読み込み、最後にレンダリングされたフォームから CSRF トークンを読み取ります（`BlogTest.form_token`）。各テストファイルの最後には `Cybertrain::Test.run!` を書きます。`examples/blog/test/articles.rb` と `comments.rb` に、このパターンの全体があります。

テストクライアントが送るリクエストは、すべて `127.0.0.1` から来ます（`request.remote_addr`。そのため `request.loopback?` は true です）。別のマシンにいる訪問者に対してページが何をするかを確かめるには、リクエストの前に `client.peer_address = "203.0.113.7"` を設定します。

実行は `cybertrain spin test` で行います：各 `test/*.rb` をそれぞれ独立したプログラムにコンパイルし、その出力（stdout と stderr をまとめたもの）を `test/<name>.rb.expected` と比較します。`cybertrain spin test --regen
test/<name>.rb` で再生成します。FFI やデータベースのテストは CRuby では実行できないため、そのスナップショットは代わりにコンパイル済みバイナリから作ります：`rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1`（スナップショットが古い間は `cybertrain spin test` が 0 以外で終了するため、後続は `;` でつなぎ、`&&` は使いません。`[ -x ]` のチェックにより、コンパイルに失敗したときは出力の取り込みをスキップするので、古いスナップショットが残ります。フレームワークのチェックアウトでは、`script/regen-snapshot test/<name>.rb` がちょうどこれを行い、差分の統計を表示します）。

## 外向きの呼び出しをテストする

テスト対象のコードが Webhook（[外向きの HTTP](external-services.md#outbound-http)）やメール（[メールを送る](external-services.md#sending-e-mail)）を送る場合、テストはそれをプロセス内で受け取ります：`Cybertrain::Test::HttpReceiver` と `Cybertrain::Test::SmtpReceiver` は `127.0.0.1` で待ち受け、届いたものを記録して、決まった応答を返します。ファイルは上と同じヘルパー `support/blog_test` から始めます。`require "cybertrain"` がメーラーを読み込むので、下の明示的な require は害になりません。

```ruby
require_relative "support/blog_test"   # アプリ、BLOG、Cybertrain::Test
require "cybertrain/mailer"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

test "a sign-up posts a webhook" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  hook.start                                   # 空いているポートをバインドし、それを返す
  Cybertrain.config.http_allow_private = true  # そうしないと HttpClient はループバックを拒否する
  SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # アプリのコード
  req = hook.received_request                  # 最大 5 秒待つ。何も来なければ nil
  hook.stop
  assert_equal "POST", req.http_method
  assert_equal "/hooks/signup", req.http_target
  assert_equal "application/json", req.http_header("Content-Type")
  assert_includes req.http_body, "ann@example.com"
end

test "a refused recipient is reported" do
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
  port = smtp.start
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
  assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
  mail = smtp.received_message
  smtp.stop
  assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
               mail.transcript.first(3)
  refute mail.delivered?
end

Cybertrain::Test.run!
```

`HttpReceiver.new` は決まった応答の `status:`、`headers:`、`body:`、`chunked:` を受け取ります（`respond_with` でリクエストの間に変更できます）。リクエストは `ReceivedRequest` として返ってきます（`http_method`、`http_target`、`http_path`、名前を小文字にした `http_headers`、`http_header(name)`、チャンク形式のボディをデコードした `http_body`）。`SmtpReceiver` は 220、EHLO（`eight_bit_mime: false` でなければ 8BITMIME 付き、`auth: true` なら AUTH PLAIN 付き）、MAIL、RCPT、DATA、QUIT を演じます。`reject:` は `:greeting`、`:ehlo`、`:mail`、`:rcpt`、`:data`、`:message` のいずれかを、指定した応答で失敗させます。`ReceivedMessage` には、`envelope_from`、`envelope_recipients`、`message_data`（ドットスタッフィングは元に戻されています）、`message_header(name)`、`message_body`、そしてコマンドの `transcript` があります。HTML のメッセージなら、`message_parts` がそれを `"subject"`、`"text"`、`"html"` にデコードします。どちらも、`max:` でそれ以上を指定しない限り、接続を 1 つだけ受け付けます（`received_requests` / `received_messages` がそのすべてを返します）。すべての待ちに上限があります：レシーバーは接続がないまま `accept_window:`（10 秒）たつと諦め、黙っているクライアントは `read_timeout:`（5 秒）で諦めます。`stop`（二度呼んでも安全）はレシーバーのスレッドを終わらせて join し、ポートを閉じるので、レシーバーが後のテストの接続を横取りすることはありません。必要なのは Ruby の socket ライブラリだけで、openssl は不要です。

フィードも同じ方法で、`127.0.0.1` 上のスクリプト化された WebSocket サーバーである `Cybertrain::Test::WebSocketReceiver` を使ってテストします：各接続は `Cybertrain::Test::WsStep` のリスト（`"accept"`、`"send_text"`、`"expect"`、`"silent"`、`"close"`、`"drop"`、`"echo_until_close"` など）を演じ、クライアントが送ったフレームはマスクを外して `ws_received` から返ってきます。

```ruby
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # 定数にする：ブロックからはローカル変数が見えない

# ブロックはテストのブロックの中ではなく、パラメーターが使われる
# メソッドの中に書く。
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

test "a trade message is stored" do
  rx = Cybertrain::Test::WebSocketReceiver.new
  rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
  rx.start
  subscribe_trades(rx.url("/trades"))
  Cybertrain::WebSocket.start!               # Test::Client はフィードを決して開始しない
  # ... 最大数秒間 TICKS をポーリングする ...
  Cybertrain::WebSocket.stop!
  assert_equal ["tick"], TICKS
  assert_equal "subscribe", rx.ws_received[0].rec_data
  rx.stop
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` にすると、再試行の遅延が正確な値になります。このリポジトリの `test/websocket_integration.rb` に、完全なテストがあります。

## ジョブのテスト

`require "cybertrain/test/jobs"` は、テスト用データベースのジョブキューについての 5 つのヘルパーを足します。`cybertrain generate authentication` が書くサポートファイル（`test/support/app_test.rb`）はこれを require します。それがないアプリケーションは、examples/blog のサポートファイルのように、自分のサポートファイルにこの行を足してください。

```ruby
require_relative "support/blog_test"
require "cybertrain/test/jobs"

test "a notification is enqueued, then runs" do
  clear_enqueued_jobs
  NotifyCommentJob.perform_later("comment_id" => 7, "article_id" => 1)
  assert_enqueued_jobs 1, "NotifyCommentJob"
  assert_enqueued_with "NotifyCommentJob", { "comment_id" => 7 }
  assert_equal 1, perform_enqueued_jobs
  assert_no_enqueued_jobs
end

test "the job itself" do
  assert_nil NotifyCommentJob.perform_now("comment_id" => 1, "article_id" => 1)
end
```

<!-- list: points -->
- `assert_enqueued_jobs(count, kind = "")` は `queued` の行を数えます（種類を与えればその種類だけ）。`assert_no_enqueued_jobs(kind = "")` は 1 つもないことを求めます。
- `assert_enqueued_with(kind, args)` は、その種類のキューにある行で、与えたすべてのキーを等しい値で持つものを求めます。両側は `Cast.str` で比べるので、`"comment_id" => 7` は JSON の `7` に一致します。Symbol のキーはその名前として読まれるので、`assert_enqueued_with "NotifyCommentJob", comment_id: 7` とも書けます。
- `perform_enqueued_jobs(now = Time.now)` は、期限の来たジョブを呼び出したスレッドで 1 つずつ（`Job.work_one`）、期限の来たものがなくなるまで実行し、実行した数を返します。後に予定された再試行はキューに残ります。実行するには後の `now` を渡してください。すぐに期限の来る形で自分をもう一度キューに入れるジョブは、これを実行し続けさせてしまうので、10,000 個のジョブの後でテストを失敗させます。
- `clear_enqueued_jobs` は `queued` の行をすべて消します。`failed` と `discarded` の行は残るので、それを作るテストは自分で消してください。
- `WelcomeJob.perform_now(args)` は、キューも rescue もなしにジョブを 1 つ直接実行します。例外はテストに届きます。
- `deliver_later` で送るメールは `"cybertrain mail"` のジョブです。`perform_enqueued_jobs` はそれを `SmtpReceiver` に送ります（`smtp_host` と `smtp_port` をそこに向けておきます）。
- 定期タスクは `Cybertrain::Scheduler.run_due(now)` で 1 ティックずつ実行され、`Cybertrain::Cache.prune(now)` は選んだ時刻でキャッシュを掃除します。

## ストリームとコンポーネントのテスト

`require "cybertrain/test/views"` は、リクエストを必要としない 2 つのレンダラーを加えます。パーシャルや[コンポーネント](template-language.md#components)の HTML を検証するためのものです：

```ruby
require_relative "support/blog_test"
require "cybertrain/test/views"

test "the comment component names its author" do
  html = Cybertrain::Test.render_component(CommentComponent.new(comment: Comment.first))
  assert_includes html, "<strong>"
end

test "the article partial links to the article" do
  article = Article.create(title: "Hello", body: "Rendered for the test")
  html = Cybertrain::Test.render_partial("articles/article", article: article)
  assert_includes html, BlogTest.article_path(article)
end
```

`Test.render_component(component, content: "")` は `content:` をブロックの HTML として渡します。どちらもブロードキャストと同じようにレンダリングするので、リクエストを必要とするヘルパーはここでも `Cybertrain::Views::OutsideRequest` を出します。

[ストリーム](realtime.md)はエンドポイントを通してテストします。`client.get_stream(path, events: n, timeout: 2, headers: {})` は、`n` 個のイベントが書かれる（ping は数えません）かタイムアウトするまで、ストリーミングのレスポンスをメモリー上で実行し、書かれたものをボディとしてそれを返します。エンドポイントはストリームのポーラーが動くまで 503 を返し、テストクライアントはポーラーを始めないので、ファイルの中で一度始めてください：

```ruby
Cybertrain::Stream::Poller.start!

test "a new comment is broadcast to the article's stream" do
  article = Article.create(title: "Live comments", body: "Posted for the test")
  Cybertrain::Stream.broadcast_append_to(article, target: "comments", html: "hi")
  token = Cybertrain::Stream.sign([Cybertrain::Stream.name_for(article)])
  client = Cybertrain::Test::Client.new(BLOG)
  res = client.get_stream("/cybertrain/stream?s=#{token}", events: 1, headers: { "last-event-id" => "0" })
  assert_includes res.body, '<turbo-stream action="append" target="comments">'
end
```

新しい接続が受け取るのは、接続した後にブロードキャストされたものだけです。`last-event-id` を `0` にすると、すでにテーブルにあるものが再送されるので、テストは先にブロードキャストして後から読めます。アクションがブロードキャストしたことだけを確かめるなら、テーブルを読みます：`Cybertrain::DB.with { |c| c.execute("SELECT stream, payload FROM cybertrain_messages ORDER BY id DESC LIMIT 1") }`。

## 継続的インテグレーション

`cybertrain new` はアプリのために `.github/workflows/ci.yml` を書き出します。これはこのリポジトリの `setup-cybertrain` アクション（[.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)）を、CLI のリリースタグに固定して呼び出します。このアクションは SQLite、zlib、OpenSSL のヘッダーと Ruby をインストールし、アプリが固定しているフレームワークのコミットを `spin.lock` から読み、そのコミットのフレームワークを取得して、その `cybertrain
doctor` と `cybertrain setup` を実行します（`~/.cybertrain/spinel` は Spinel のリリースとランナーのイメージごとにキャッシュされます）。その後ワークフローは、`spin.lock` が最新であること（`spin lock && git diff --exit-code spin.lock`）と `gen/` が新しいこと（`spin run gen -- --check`）を確認し、`test/` にテストプログラムがあれば `spin test` を実行します。ツールチェーンの手順が変わったときに変わるのはアクションで、各アプリのコピーではありません。コミットは `spin.lock` から読まれるので、ワークフローはデフォルトの git 依存を前提とします。`--path` で作ったアプリは、フレームワークのチェックアウトを `framework-path` としてアクションに渡します。
