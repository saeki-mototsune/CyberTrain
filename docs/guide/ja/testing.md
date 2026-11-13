---
source_sha256: 635312e7f45c6813a305b32c77a30beb91a7fe05c4b4c3d139920dc3e510ae0f
---
# アプリをテストする

アプリケーションのテストは `test/` 以下にある Rails 流のクラスで、`cybertrain test` がそれらすべてを 1 つのコンパイル済みプログラムとして実行します。Minitest や RSpec はリフレクションでテストメソッドを見つけますが、事前（AOT）コンパイラーにはそれができません。そこで `spin run gen` が各テストクラスを素のメソッドに書き換え、すべてのテストを振り分ける表を 1 つ書き出します。

## テストを書く

`cybertrain new` が `test/test_helper.rb` を書き出します。Rails と同じく、どのテストファイルも最初にこれを読み込みます：

```ruby test/test_helper.rb
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # すべてのテストで使うヘルパーメソッドはここに書く。
end
```

```ruby test/models/article_test.rb
require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "title must be present" do
    article = Article.new(body: "a body long enough to pass length")
    assert_not article.save
    assert_includes article.errors.full_messages, "Title can't be blank"
  end
end
```

```ruby test/controllers/articles_controller_test.rb
require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", text: @article.title
  end

  test "creates an article" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough" } }
    end
    assert_redirected_to article_path(Article.last)
  end
end
```

基底クラスは Rails と同じ 3 つです：`ActiveSupport::TestCase`（モデル、ジョブ、メーラーなど、リクエストを伴わないもの）、`ActionDispatch::IntegrationTest`（リクエスト。[統合テスト](#integration-tests)）、`ViewComponent::TestCase`（`render_inline`。[ストリームとコンポーネントのテスト](#testing-streams-and-components)）。アプリケーションは自分の基底クラスを `test/test_helper.rb` か `test/support/` に置き、それを継承できます。ヘルパーメソッド、定数、`private` は Rails と同じくクラス本体に書きます。各テストは新しいインスタンスの上で動くので、`setup` で設定したインスタンス変数はそのテストのものです。`fixtures :all` と `require "test_helper"` は受け付けられますが、それ自体は何もしません：フィクスチャはどのテストにもすべて読み込まれます。

各テストは次の順序で動きます：

1. すべてのテーブルが空になり（ジョブ、キャッシュ、Turbo のメッセージ、スケジュール、フィード、リースといったフレームワークのテーブルも含む）、id は 1 から振り直されます。
2. フィクスチャが挿入されます（[フィクスチャ](#fixtures)）。
3. `Mailer.deliveries`、レート制限のカウンター、`I18n.locale` がリセットされ、タイムゾーンは `config/app.rb` で設定したものに戻ります。
4. `setup`（スーパークラスのものが先。複数の `setup do` ブロックは順番に）。
5. テストの本体。それまでに何も失敗していなければ。
6. `teardown`。必ず実行されます：アサーションの失敗、例外、setup の失敗のあとでも（複数の `teardown do` ブロックは逆順に、そのあとスーパークラスのもの）。
7. 時計が実時間に戻り、テストが起動した受信者はすべて止められます。

Rails は代わりに各テストをトランザクションでロールバックします。ここではそれが合いません：このフレームワークの SQLite にはセーブポイントがないので、テスト自身の `transaction` が外側のトランザクションを終わらせてしまいます。また、ジョブのスレッドは別の接続を使うので、テストの行が見えません。

## テストを実行する

```sh
cybertrain test                                         # すべてのテスト
cybertrain test test/controllers                        # あるディレクトリ以下のファイル
cybertrain test test/models/article_test.rb             # 1 つのファイル
cybertrain test -n "creates an article"                 # 名前で 1 つのテスト
cybertrain test -n test_creates_an_article              # またはメソッド名で
cybertrain test -n /article/                            # 名前に "article" を含むテスト
```

`cybertrain test` は `SPIN_DEBUG=1 spin run gen` を実行します（CLI のどのコマンドとも同じく、gen は spin のデバッグモードでビルドされます）。これが `gen/tests.rb`（プログラム）と、`gen/test/` 以下に各テストクラスを書き換えたコピーを書き出します。どちらも `gen/` のほかの部分と一緒にコミットします。次に、いずれかの入力がバイナリより新しければ `gen/tests.rb` を `build/test/tests` にコンパイルし（リリースビルド）、実行します。`test/**/*_test.rb` のすべてと、`test/test_helper.rb` 以外の `test/*.rb` のすべてがこれに入ります。`test/support/`（ヘルパーが読み込む）と `test/fixtures/` にはテストはありません。プログラムは最初のテストの前に `storage/test.sqlite3` を削除し、新しいデータベースをマイグレートして、その上でアプリケーションを起動します（ジョブ、スケジューラー、フィードのスレッドはなし：ジョブはテストが自分で実行します）。`CYBERTRAIN_TEST_DATABASE` を設定すると代わりに別のファイルを使います。指定されたファイルは何であっても削除されるので、使い捨てのファイルだけを指定してください。

```text 出力 — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:13)
         Expected: 1
           Actual: 0
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

ファイルごとに見出し、テストごとに 1 行、最後に合計を出し、所要時間は出しません。示される行はテストの `test "..."` の行です：コンパイル済みのプログラムにはバックトレースがないので、失敗したアサーションの行はわかりません。終了ステータスは、失敗したテストがあれば 1、なければ 0、受け付けない引数には 2 です。

**変更にかかる手間。** ファイルの引数と `-n` は、どのテストを実行するかを選ぶもので、何をコンパイルするかは変えません：プログラムは常にすべてのテストを含むので、絞り込みを変えてもバイナリはそのまま使われ、どれか 1 つのテスト（あるいはプログラムを作るほかの何か）を編集すると、先に `bin/gen` をビルドし直したうえで、プログラム全体をコンパイルし直します。2026-11-12 と 2026-11-13 に、共有の 4 vCPU のクラウドマシンで測った値です（手元のマシンでは違います）：examples/blog の 21 ファイル 149 テストは、初回のコンパイルに約 527 秒かかり（初回の実行全体で 656 秒、バイナリは 10.2 MB）、何も変えずにもう一度実行すると約 1 秒で始まりました。テストファイルが数個の小さなアプリケーションは、約 2.2 GB のメモリで約 3 分かけてコンパイルされ、8 MB のバイナリになりました。テストはいくつか書いてからまとめて実行し、1 つのテストに取り組む間は、ビルドではなく実行のほうを絞り込んでください。

2 つのテストファイルやサポートファイルが同じトップレベルのメソッドや定数を定義していると（1 つのプログラムの中では 1 つになってしまいます：共有するヘルパーは `test/support/` か、クラスの中に移してください）、`gen/tests.rb` は拒否され、`cybertrain test` はコンパイルせずに理由を出して 1 で終わります。[テストクラスで gen が拒否するもの](#what-gen-refuses-in-a-test-class)のほかの場合も同じです。

## フィクスチャ

```yaml test/fixtures/users.yml
alice:
  email_address: alice@example.com
  admin: true
```

```yaml test/fixtures/articles.yml
one:
  title: First post
  body: A body long enough to pass the length check.
  author: alice
  created_at: 2026-11-01 09:00:00

two:
  id: 42
  title: Second post
  body: Another body long enough.
  author: alice
```

`test/fixtures/<table>.yml` は Rails と同じ形です：ラベル、その下にカラム。gen は実行時にファイルを[辞書](i18n.md#dictionaries)と同じ YAML のサブセットで読み、次のものを `ファイル:行` を付けて拒否します：`db/schema.rb` のテーブルではないファイル、カラムでもモデルの `belongs_to` でもないキー、ERB（どこかに `<%` があること：`eval` はありません。現在時刻からの相対的な時刻は `setup` か `travel_to` で設定してください）、カラムの型に合わない値（存在しない日付、64 ビットに収まらない整数、真偽値の `yes`）、同じ id の 2 つのラベル、親のファイルのどの行も指さない `belongs_to` のラベル。`DEFAULTS` は Rails と同じく行ではありません。

- `id:` のない行には、ラベルに対する Rails の id が付きます（`ActiveRecord::FixtureSet.identify`）。そのため、ラベルの id は Rails のアプリケーションと同じです。`author: alice` は `author_id` を alice の id にします。
- 日時は UTC です。行が省いた `created_at` と `updated_at` は、各テストの前にその行を挿入した時点の時計の時刻になります。
- `articles(:one)` はその行の `Article.find` を返します。未知のラベルは `Cybertrain::Test::FixtureNotFound` を発生させます。1 回の呼び出しで 1 つのラベルです。
- フィクスチャは gen の実行時に検査されますが、そのエラーで止まるのはテストの実行だけです：`spin run gen`（したがって、スキャフォールドのフィクスチャのほうが先にできる `cybertrain db migrate` も）は先に進み、`cybertrain test` が `test/fixtures/<table>.yml:<行>: ...` を出して 1 で終わります。
- Rails と同じく、親を指すフィクスチャがあると、その親は削除できません：`comments.yml` に `article: one` があると、スキャフォールドの「should destroy article」は外部キーで失敗します。`has_many :comments, dependent: :destroy` を宣言するか、子のフィクスチャを別の行に向けるか（`article: two`）、何からも参照されていない行を削除してください。
- 提供しないもの：`fixtures :articles`（どのファイルも読み込まれます）、`articles(:one, :two)`、ポリモーフィックなラベル（`commentable: one (Article)`。`_id` と `_type` のカラムを書いてください）、`has_and_belongs_to_many` のラベル、アンカーとエイリアス。

## 統合テスト

`ActionDispatch::IntegrationTest` は起動したアプリケーションにプロセス内でリクエストを送ります。ソケットは使わず、クッキーの入れ物はテストごとに新しくなります：

- `get`、`post`、`patch`、`put`、`delete`、`head`（パス、`params: {}`、`headers: {}`）。書き方は Rails と同じです。どれも `Cybertrain::Response` を返し（Rails はステータスを返します）、それは `response` でもあります（`response.body`、`response.status`、`response.header(name)`）。
- `params:` は入れ子の Hash を受け取り、フォームと同じ形で送ります（`article[title]=New`）。値は String、Symbol、数値、`true` / `false`、nil、Date、Time にでき（カラムが読み戻すテキストとして送られます）、スキャフォールドのテストはレコードの値をそのまま送れます。Array は拒否されます。
- `post`、`patch`、`put` の `params:` に `fixture_file_upload("cover.png", "image/png")` を入れると、リクエストは multipart で送られます。ファイルは `test/fixtures/files/` から読まれます。
- `headers:` はヘッダーの名前か、Rails の `HTTP_ACCEPT` の形を取ります。
- `config/routes.rb` のパスヘルパーはコントローラーの中と同じく使えます。`*_url` ヘルパーは `http://www.example.com/...` を書きます。このホストの URL はパスでリクエストされ、`assert_redirected_to` はどちらの形でも比べます。ほかのホストの URL は拒否されます。
- `follow_redirect!`、`cookies`、`assert_response(:success)`（どのステータスのシンボルでも、数値でも。`:error` はちょうど 500 を意味し、Rails はどの 5xx でも受け付けます）、`assert_redirected_to(path)`、`assert_select`、`assert_turbo_stream`。
- ないもの：`session`、`flash`、`assigns`、`request`、`host!`、`as:`。代わりにページを検証してください（`assert_select`、`response.body`）。

**リクエスト偽造対策**は、Rails のテスト環境と同じく、`config/app.rb` が `csrf` を設定しない限りテストでは無効です。そのため `post` にトークンは要りません。この検査そのもののテストは、いくつかのリクエストだけ有効にします：

```ruby
test "a form without the token is refused" do
  with_forgery_protection do
    post articles_path, params: { article: { title: "x" } }
    assert_response :forbidden
  end
end
```

ブロックの中では、フォームにはテストがリクエストしたページの `authenticity_token` が必要です。ブロックが終わると、中のアサーションが失敗した場合でも、すべて元に戻ります。

**サインイン。** `cybertrain generate authentication` は `test/support/session_test_helper.rb` を書き出し、これはどの統合テストにも include されます：`sign_in_as users(:one)`（フィクスチャのユーザーのパスワードは `"password"`。`remember: true` で「ログインしたままにする」にチェックが入ります）、`sign_out`、そして自分のクッキーを持つ 2 つ目のブラウザーである `open_session`（`phone = open_session` のあと、`phone.sign_in_as users(:two)` や `phone.get ...`）。リクエストはどれも `127.0.0.1` から来ます。別のクライアントアドレスが必要なテストは、自分で `client = Cybertrain::Test::Client.new(Cybertrain::Test.app)` を作って `client.peer_address = "203.0.113.7"` を設定します（クライアント自身のメソッドは `client.get(path, headers)` と `client.post(path, fields, headers)` です）。

## アサーション

`assert`、`assert_not`（`refute`）、`assert_equal`、`assert_not_equal`、`assert_nil`、`assert_not_nil`、`assert_includes`、`assert_not_includes`、`assert_empty`、`assert_not_empty`、`assert_match` / `assert_no_match`（Regexp か、部分文字列としての String）、`assert_in_delta(expected, actual, delta = 0.001)`、`assert_nothing_raised { }`、`flunk` が Minitest と同じくあり、失敗時のテキストも Minitest のもの（2 行の `Expected: 1` と `  Actual: 0`）です。ブロックの形はラムダを位置引数で取ります：

```ruby
assert_difference -> { Article.count }, 1 do
  post articles_path, params: { article: { title: "New", body: "A body long enough" } }
end
assert_no_difference(-> { Article.count }) { post articles_path, params: { article: { title: "" } } }
assert_changes(-> { article.reload.title }, from: "Old", to: "New") { article.update(title: "New") }

message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
assert_includes message, "999"
```

- `assert_raises` はクラス（Minitest と同じくサブクラスも一致します）、String としてのクラス名の一部（`assert_raises("RecordNotFound")`）、または何も取らず（どの StandardError でも）、例外ではなく例外の**メッセージ**を返します：Rails で `error = assert_raises(X) { }` と書いて `error.message` を使うところでは、返ってくる String を使ってください。Spinel ではメソッドは 1 つの型しか返せず、テストが読むのはメッセージだからです。
- ブロックのアサーションはブロックの値ではなく nil を返します。
- 提供しないもの：`assert_predicate`（計算された `send` が要ります：`assert article.valid?` と書いてください）、`assert_difference` の String の式（`eval` が要ります）、式の Array や Hash、メッセージの引数。

## タイムトラベル

```ruby
test "a remembered session survives day 15" do
  sign_in_as users(:one), remember: true
  travel_to 15.days.from_now do
    get root_path
    assert_response :success
  end
end

test "the cache entry expires" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 5.minutes)
  travel 6.minutes
  assert_nil Cybertrain::Cache.read("k")
end
```

`travel_to(time)`、`travel(seconds)`、`freeze_time`、`travel_back` は Rails のヘルパーです：どれも時計を止め、1 秒未満の部分を落とします。ブロックを渡すと、ブロックが終わったとき（例外が起きたときも）元の時刻に戻り、渡さなければ `travel_back` かテストの終わりまで移動したままです。フレームワークが時刻を記録するものはすべてこれに従います：`Time.current`、テストプログラムの中の `Time.now`、レコードのタイムスタンプ、キャッシュの有効期限、レート制限、セッションの寿命、ジョブの `run_at`、トークンの有効期限、スケジューラー。待ちとタイムアウト（ストリームの読み取り、受信者）は実時間のままなので、時計を止めても待ちが止まったままになることはありません。本番では `Time.now` はシステムの時計です：移動に従うべきコードは、Rails が勧めるとおり `Time.current` を読みます。

期間は Integer の秒です：`5.minutes` は `300` で、`2.weeks.ago` と `3.days.from_now` は時計の上の Time を返します。`1.month` はありません（1 か月には秒での長さがありません）：実行されたときに `NoMethodError` になります。Time のカレンダーのメソッドを使ってください：`Time.current.months_ago(1)`、`advance(months: 1)`、`beginning_of_day`、`end_of_month`、`yesterday`（[時刻とタイムゾーン](models.md#times-and-the-time-zone)）。`advance` は時、分、秒をカレンダーの部分のあとに経過時間として足し、Integer を取ります。実時間の時計はマイクロ秒を保ちます。

## ストリームとコンポーネントのテスト

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "Alice"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
```

`render_inline(component, content: "")` と `render_inline(partial:, locals: {})` はリクエストの外でレンダリングし、HTML を返して（Rails は Nokogiri のフラグメントを返し、内容をブロックで受け取ります）、`assert_select` のために保持します。リクエストを必要とするヘルパーは `Cybertrain::Views::OutsideRequest` を発生させます。

`assert_select(selector, equality = nil, count:, minimum:, maximum:, text:)` は、このテストの最後の `render_inline` かレスポンスを検査し（どちらもなければ「No response yet」で失敗します）、一致した要素を返します：

- セレクター：タグ、`.class`、`#id`、`[attr]`、`[attr="v"]`、それらの組み合わせ（`a.btn[href="/x"]`）、子孫と子（`>`）の結合子、リスト（`h1, h2`）。疑似クラス、`+` と `~`、ほかの属性演算子、入れ子のブロックの形は `assert_select: <feature> is not supported` で失敗します。
- `text:` は各要素のテキストと比べる String か、そのテキストに当てる Regexp です。テキストは、空白の連続を 1 つのスペースにし、両端を取り除いたものです（Rails は両端を取り除くだけです）。2 つ目の引数は Rails の位置引数の形にでき、テキスト（String か Regexp）、件数（Integer）、`true` / `false` を取ります。Range は拒否されます（`minimum:` と `maximum:` を書いてください）。
- HTML は書かれたとおりに読まれ、ブラウザー（と、Rails の `assert_select` の裏にある Nokogiri）のように修復はされません：`<tbody>` なしで書かれた表には `table > tr` が一致し、`<p><div>` には `p > div` が一致し、省略された終了タグ（`<li>a<li>b`、`<p>a<p>b`）や自己終了の `<div/>` は、その位置を示してアサーションを失敗させます。フレームワーク自身のテンプレートはすべて読めます。

ブロードキャストは `cybertrain_messages` の行なので、ストリームのアサーションはポーラーもソケットも使わずにテーブルを読みます：

```ruby
test "a new comment is broadcast and answered with a Turbo Stream" do
  article = articles(:one)
  payloads = assert_broadcasts(article, 1) do
    post article_comments_path(article), params: { comment: { commenter: "Dave", body: "Hi" } },
                                         headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end
  assert_includes payloads[0], 'target="comments"'
  assert_turbo_stream action: "append", target: "comments"
end
```

`assert_broadcasts(stream, count) { }` は、ブロックの間に（ブロックがなければテストの始まりから）ストリーム（名前かレコード）へブロードキャストされたものを数え、その内容を返します。`assert_no_broadcasts(stream)` は 1 つもないことを求めます。`assert_turbo_stream(action:, target:, count: 1)` は最後のレスポンス（`text/vnd.turbo-stream.html` でなければなりません）か、最後の `render_inline` を読みます。ブラウザーのようにライブのストリームを読むには、`Cybertrain::Test::Client` の `client.get_stream(path, events: n)` がストリーミングのレスポンスをメモリ上で動かします（[リアルタイム](realtime.md)）。

## メールのテスト

テスト環境では `Cybertrain.config.mail_delivery_method` が `:test` です：`deliver_now`、`Mailer.deliver`、`deliver_later` のジョブはメッセージを検査し、接続する代わりに `Cybertrain::Mailer.deliveries` に保持します。このリストは各テストの前に空になります。アプリケーションが送信者を設定していなければ、テストプログラムはメールの送信者を `from@example.com` にします。

```ruby
test "a reset mails a link" do
  assert_emails 1 do
    post passwords_path, params: { email_address: users(:one).email_address }
  end
  mail = Cybertrain::Mailer.deliveries.last
  assert_equal "Reset your password", mail.mail_subject
  assert_includes mail.mail_body, "/passwords/"
end
```

`assert_emails(count) { }` はブロックが送ったメールを数えます。ブロックの中で `deliver_later` でキューに入れたメールは先に送られ、失敗したメールのジョブはそのエラーでアサーションを失敗させます。`assert_no_emails { }` は 1 通もないことを求めます。メッセージの読み取りメソッドは `mail_to`、`mail_from`、`mail_subject`、`mail_body`、`mail_html` です。SMTP の経路そのもののテストは `Cybertrain.config.mail_delivery_method = :smtp` を設定し、`teardown` で `:test` に戻します（この設定はテストの間でリセットされません）。[外向きの呼び出しをテストする](#testing-outbound-calls)と同じです。テスト環境の外では `:test` は警告を出して起動し、メールは送られません。

## ジョブのテスト

```ruby test/jobs/notify_comment_job_test.rb
require "test_helper"

class NotifyCommentJobTest < ActiveSupport::TestCase
  test "a comment queues its notification, which runs" do
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    assert_enqueued_jobs 1, "NotifyCommentJob"
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id }
    assert_equal 1, perform_enqueued_jobs
    assert_no_enqueued_jobs
  end

  test "the jobs a block queues run at once" do
    performed = perform_enqueued_jobs { ReminderJob.perform_in(3600, { "id" => 1 }) }
    assert_equal 1, performed
  end
end
```

- `assert_enqueued_jobs(count, kind = "")` はキューにあるジョブを数えます（種類を指定すればその種類だけ）。`assert_no_enqueued_jobs(kind = "")` は 1 つもないことを求めます。
- `assert_enqueued_with(kind, args)` は、その種類のジョブで、引数が指定したキーをすべて同じ値で持つものがキューにあることを求めます（`"comment_id" => 7` は JSON の `7` に一致します。`comment_id: 7` でも動きます）。
- `perform_enqueued_jobs { }` は Rails のインラインの形で、ブロックを実行し、そのあとブロックの間にキューに入ったジョブと、それらがキューに入れたジョブを、`run_at` にかかわらずすべて実行し、実行した数を返します。例外を出したジョブはそのクラスとエラーでテストを失敗させ、再試行されません。アプリケーションが破棄したジョブ（`discard_on`）は実行済みと数えます。
- ブロックのない `perform_enqueued_jobs(now = Time.current)` は、`now` の時点で期限の来たジョブを 1 つずつ、なくなるまで実行します。あとに予定された再試行はキューに残ります：その時刻を過ぎるまで `travel` するか、もっと遅い `now` を渡してください。どちらの形も、10,000 件のジョブのあとテストを失敗させます（自分自身を再びキューに入れるジョブ）。
- `clear_enqueued_jobs` はキューにあるジョブを削除します。`WelcomeJob.perform_now(args)` はジョブを 1 つ直接実行し、例外はテストまで届きます。
- 定期タスクは `Cybertrain::Scheduler.run_due(Time.current)` で 1 回ずつ実行します。

## 外向きの呼び出しをテストする

テスト対象のコードが Webhook（[外向きの HTTP](external-services.md#outbound-http)）や SMTP でのメール（[メールを送る](external-services.md#sending-e-mail)）を送るとき、テストはそれをプロセス内で受け取ります：`Cybertrain::Test::HttpReceiver` と `Cybertrain::Test::SmtpReceiver` は `127.0.0.1` で待ち受け、届いたものを記録し、用意した返事で答えます。テストの中で起動した受信者は、テストが失敗した場合でも、そのテストのあとに止められます。

```ruby test/integration/signup_hook_test.rb
require "test_helper"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

class SignupHookTest < ActiveSupport::TestCase
  setup do
    Cybertrain.config.http_allow_private = true   # そうしないと HttpClient はループバックを拒否する
  end

  teardown do
    Cybertrain.config.http_allow_private = false
    Cybertrain.config.mail_delivery_method = :test
  end

  test "a sign-up posts a webhook" do
    hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    hook.start                                   # 空いているポートにバインドし、それを返す
    SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # アプリのコード
    req = hook.received_request                  # 最大 5 秒待つ。何も来なければ nil
    assert_equal "POST", req.http_method
    assert_equal "/hooks/signup", req.http_target
    assert_equal "application/json", req.http_header("Content-Type")
    assert_includes req.http_body, "ann@example.com"
  end

  test "a refused recipient is reported" do
    Cybertrain.config.mail_delivery_method = :smtp
    smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
    port = smtp.start
    mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
    assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
    mail = smtp.received_message
    assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
                 mail.transcript.first(3)
    assert_not mail.delivered?
  end
end
```

`HttpReceiver.new` は用意する `status:`、`headers:`、`body:`、`chunked:` を取ります（`respond_with` でリクエストの間に変えられます）。リクエストは `ReceivedRequest` として返ります（`http_method`、`http_target`、`http_path`、小文字の名前の `http_headers`、`http_header(name)`、chunked の本文をデコードした `http_body`）。`SmtpReceiver` は 220、EHLO（`eight_bit_mime: false` でなければ 8BITMIME 付き、`auth: true` で AUTH PLAIN 付き）、MAIL、RCPT、DATA、QUIT を演じます。`reject:` は `:greeting`、`:ehlo`、`:mail`、`:rcpt`、`:data`、`:message` のどれでも、指定した返事で失敗させます。`ReceivedMessage` には `envelope_from`、`envelope_recipients`、`message_data`（ドットスタッフィングを戻したもの）、`message_header(name)`、`message_body`、コマンドの `transcript` があり、HTML のメッセージなら `message_parts` が `"subject"`、`"text"`、`"html"` にデコードします。どちらも `max:` で増やさない限り 1 つの接続を受け付けます（`received_requests` / `received_messages` がすべてを返します）。待ちにはすべて上限があります：受信者は接続がないまま `accept_window:`（10 秒）が過ぎるとあきらめ、黙ったクライアントは `read_timeout:`（5 秒）で切り、`stop`（2 回呼んでも安全）はスレッドを終わらせてポートを閉じるので、受信者があとのテストの接続を取ることはありません。テストの外で（ファイルの先頭で）起動した受信者は、自動では止められません。

フィードも同じように、`127.0.0.1` 上の台本どおりに動く WebSocket サーバー `Cybertrain::Test::WebSocketReceiver` でテストします：各接続は `Cybertrain::Test::WsStep` のリスト（`"accept"`、`"send_text"`、`"expect"`、`"silent"`、`"close"`、`"drop"`、`"echo_until_close"` など）を演じ、クライアントが送ったフレームはマスクを外して `ws_received` から返ります。

```ruby test/integration/trades_feed_test.rb
require "test_helper"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # 定数：ブロックからはローカル変数が見えない

# ブロックは、そのパラメーターが使われるメソッドの中に書く。
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

class TradesFeedTest < ActiveSupport::TestCase
  test "a trade message is stored" do
    rx = Cybertrain::Test::WebSocketReceiver.new
    rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                  Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
    rx.start
    subscribe_trades(rx.url("/trades"))
    Cybertrain::WebSocket.start!               # テストプログラムはフィードを起動しない
    # ... 最大で数秒、TICKS をポーリングする ...
    Cybertrain::WebSocket.stop!
    assert_equal ["tick"], TICKS
    assert_equal "subscribe", rx.ws_received[0].rec_data
  end
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` で再試行の間隔が正確になります。このリポジトリの `test/websocket_integration.rb` に完全なテストがあります。

## テストクラスで gen が拒否するもの

gen はテストクラスをメソッドに書き換えます：`test "shows it" do` は `def test_shows_it` になり（`[A-Za-z0-9_]` 以外の文字はどれも `_` になります。Rails と同じで、`-n` にもこの名前を渡せます）、`setup do` と `teardown do` のブロックは `super` を呼ぶ `setup` と `teardown` のメソッドになります。正確に移せないものがあると、`spin run gen` は `パス:行:` と理由を出して止まります。黙って誤ったコピーを作ったり、テストを失ったりはしません：

- 素の文字列リテラルではないテスト名（式展開、`\n` のようなエスケープ：文字そのものを書いてください）。
- 1 つのクラスの中でメソッド名が同じになる 2 つのテスト（`def test_x` も含む）。
- 1 つのクラスの中の `setup do` と `def setup` の両方（`teardown` も同じ）。
- `setup { }` と `setup :name`（`setup do ... end` と書いてください）、`test`、`setup`、`teardown` のブロックパラメーター。
- テスト、setup、teardown の本体の中の `next`、`break`、`redo`（`return` を使ってください）、`return <value>`（どれも nil を返します）。
- 別のクラスやモジュールの中に入れ子にしたテストクラス、2 回開いたテストクラス、開き直した `ActiveSupport::TestCase` の中の `setup do`（`setup do` を持つアプリケーションの基底クラスを書いて継承してください）。
- gen がクラス本体の中に置けない `test`、`setup`、`teardown` の行（条件、ループ、文字列、ヒアドキュメントの中）、`end` で終わらない 1 行の形、あとにコードが続く `end`、タブとスペースが混じったインデント。
- 引数が文字列リテラルではない `require_relative`。

`cybertrain test` はさらに（`spin run gen` は先に進みつつ）次のものを拒否します：`test/test_helper.rb` や `test/support/` の中のトップレベルの `test`、`setup`、`teardown`（実行されることがありません）、トップレベルの `def render_inline`（フレームワークのものを置き換えてしまいます）、`assert_select ... do` と `render_inline ... do`、そして[テストを実行する](#running-the-tests)で述べた重複するトップレベルのヘルパー。クラスの形のファイルは `cybertrain test` でしか実行できません：`spin test` では、そのクラス本体が「class-form tests run with `cybertrain test FILE`」を発生させます。

## トップレベルの形

以前の形、つまりファイルのトップレベルに書いた `test` ブロックはそのまま動きます。`cybertrain test`（ここでのように、プログラムのアプリケーションとフィクスチャを使って）でも、`cybertrain spin test` でも動きます：

```ruby test/legacy.rb
require "test_helper"

setup do
  Cybertrain.config.http_allow_private = true
end

teardown do
  Cybertrain.config.http_allow_private = false
end

test "shows an article" do
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  res = client.get("/articles/#{articles(:one).id}")
  assert_response res, :success
  assert_includes res.body, articles(:one).title
end

Cybertrain::Test.run!
```

トップレベルの `setup do` と `teardown do` は、そのファイルの各テストの前後に実行されます。`cybertrain spin test` は各 `test/*.rb` を別々のプログラムにコンパイルし、出力を `test/<name>.rb.expected` と比べます。そこではテーブルを空にすることもフィクスチャもなく（どちらも gen のテーブルの一覧が要ります）、`Cybertrain::Test.run!` がファイルのテストを実行します。`cybertrain test` では、ファイルのテストはテーブルを空にしてフィクスチャを入れたあとにほかのテストと一緒に実行され、`run!` は何もしません。`spin test` ではそのファイルのためにアプリケーションを起動するものがないので、そのようなファイルは 0.4 のサポートファイル（`AppTest.boot`、`BlogTest.boot`）がしていたように自分で起動し、フィクスチャは使いません。`Cybertrain::Test::Client` はクッキーの入れ物を持ち、CSRF も含めてアプリケーションを操作します（`client.get`、`client.post(path, fields, headers)`、`client.follow_redirect!`、`client.response`、引数 2 つの `assert_response res, :ok` と `assert_redirected_to res, path`）。SQLite に触れるテストのスナップショットはコンパイル済みのバイナリから取ります：フレームワークのチェックアウトでは `script/regen-snapshot test/<name>.rb`、または `rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`。

## 0.4 からのアップグレード

- 上のとおりに `test/test_helper.rb` を加え、サポートファイルが読み込み時にしていたこと（`AppTest.boot`、`BlogTest.boot`、データベースのマイグレート）をそこから外してください：テストプログラムは最初のテストの前に新しいデータベースで起動し、2 回目の起動は時間がかかるだけです。
- CI のステップを `spin test` から `cybertrain test` に変えてください。
- 同じトップレベルのヘルパーや定数を定義する 2 つのファイル（0.4 のジェネレーターが書いたように、それぞれにある `new_client`）は一緒に拒否されます：ヘルパーを `test/support/` に移すか、どちらかの名前を変えてください。
- 各テストの前にすべてのテーブルが空になるので、あとのテストが前のテストの作った行に頼ることはもうできません：そのようなデータはフィクスチャか `setup` に移してください。
- 時計の差し込み口はなくなりました：`Cybertrain::Cache.clock=`、`Cache.system_clock`、`RateLimit.current_time=`、`SessionStore#fixed_now=`、`Application.status_now=`、`Background.supervisor_clock=`。`travel_to`、`travel`、`freeze_time` を使ってください。ブロックの形なら、自分で `ensure` を書かなくても時刻が戻ります。
- テストのメールは `Cybertrain::Mailer.deliveries` に保持されます。`Test::SmtpReceiver` でメールを読むテストは、先に `Cybertrain.config.mail_delivery_method = :smtp` を設定します。
- 0.4 の `generate helper` が書いたヘルパーのテストはトップレベルの `render_inline(source)` を定義しており、これはフレームワークのものとぶつかります：そのファイルの中で、呼び出しも含めて `render_helper_template` に名前を変えてください。
- `1.month.ago` は `Time.current.months_ago(1)` と書きます。
- `assert_equal` は Minitest の 2 行のテキストで失敗します。通るテストのスナップショットは変わりません。
- `cybertrain generate authentication` をもう一度実行すると、クラスの形のテストを書き出し、それらが置き換える古いファイル（`test/authentication.rb`、`test/support/app_test.rb` など）をそれぞれ示します。`--force` でそれらを削除します。

## 継続的インテグレーション

`cybertrain new` はアプリ用に `.github/workflows/ci.yml` を書き出します。これはこのリポジトリの `setup-cybertrain` アクション（[.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)）を CLI のリリースタグに固定して呼び出します。アクションは SQLite、zlib、OpenSSL のヘッダーと Ruby をインストールし、アプリが固定しているフレームワークのコミットを `spin.lock` から読み、そのコミットのフレームワークを取得して、その `cybertrain doctor` と `cybertrain setup` を実行します（`~/.cybertrain/spinel` は Spinel のリリースとランナーのイメージごとにキャッシュされます）。そのあとワークフローは `spin.lock` が最新であること（`spin lock && git diff --exit-code spin.lock`）と `gen/` が新しいこと（`SPIN_DEBUG=1 spin run gen -- --check`）を確かめ、`cybertrain test` を実行します。ツールチェーンの手順が変わるときは、各アプリのコピーではなくアクションが変わります。コミットは `spin.lock` から読むので、ワークフローは既定の git 依存を前提にしています。`--path` で作ったアプリは、フレームワークのチェックアウトを `framework-path` としてアクションに渡します。
