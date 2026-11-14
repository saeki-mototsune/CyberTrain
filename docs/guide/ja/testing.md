---
source_sha256: 576be65a974bf2dc7726945227d1fc4a732de043c7fd59dc05f1ddd2b342cf17
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

`cybertrain test` は `SPIN_DEBUG=1 spin run gen` を実行します（CLI のどのコマンドとも同じく、gen は spin のデバッグモードでビルドされます）。これが `gen/tests.rb`（プログラム）と、`gen/test/` 以下に各テストクラスを書き換えたコピーを書き出します。どちらも `gen/` のほかの部分と一緒にコミットします。次に、いずれかの入力がバイナリより新しければ `gen/tests.rb` を `build/test/tests` にコンパイルし（リリースビルド）、実行します。`test/**/*_test.rb` のすべてと、`test/test_helper.rb` 以外の `test/*.rb` のすべてがこれに入ります。`test/support/`（ヘルパーが読み込む）と `test/fixtures/` にはテストはありません。プログラムは最初のテストの前に `storage/test.sqlite3` を削除し、新しいデータベースをマイグレートして、その上でアプリケーションを起動します（ジョブ、スケジューラー、フィードのスレッドはなし：ジョブはテストが自分で実行します）。`CYBERTRAIN_TEST_DATABASE` を設定すると代わりに別のファイルを使います。プログラムはテストに使うファイルを削除するので、自分が作るデータベースすべてに印を付け（`PRAGMA application_id`、専用の値）、既存のファイルを削除したり空にしたりするのは、その印があるとき、このアプリケーション自身の `storage/test.sqlite3`（パスの書き方は問いません）であるとき、空のファイルであるときだけです。それ以外は終了ステータス 2 で何も削除せずに拒否します：`cybertrain test refuses to delete <path>: not a database cybertrain test created; delete it yourself or name another file`。`development.sqlite3` や `production.sqlite3` という名前のファイル（大文字小文字は問いません）、または `storage/development.sqlite3` や `storage/production.sqlite3` と同じファイルは、`cybertrain test refuses to delete <path>: it is the development database`（または `production`）で拒否されます。名前はファイルのパスでなければなりません：`:memory:` と `file:` の URI は拒否されます（`cybertrain test refuses CYBERTRAIN_TEST_DATABASE ":memory:": name the test database by its file path (not :memory: or a file: URI)`）。アップグレードのあと、以前 `CYBERTRAIN_TEST_DATABASE` で指定していたファイルには印がないので一度拒否されます：そのファイルを（`-wal` と `-shm` も）削除すれば、`cybertrain test` が印の付いたものを作ります。既定の `storage/test.sqlite3` は何もしなくてかまいません。データベースを作っている間にシンボリックリンクに変わったパスは、終了ステータス 2 で拒否されます：`cybertrain test refuses <path>: it became a symlink while the test database was created (nothing was marked or migrated); remove it and run again`。各テストの前に空にするのはメインのデータベースのテーブルだけで、同じ名前の TEMP のテーブルや attach されたテーブルには触れません。既知の制限：印はテスト用データベースを `cp` しても残るので、テスト用データベースの名前を付けたコピー（またはテストが接続したもの）は空にされます。ファイルを作ってから印を付けるまでの間に止められた実行は、指定したパスに印のないファイルを残し、次は拒否されます（削除してください）。`storage/test.sqlite3` がディレクトリだと、プログラムが削除するときに例外になります。

プログラムは、`config/app.rb` が自分で同じことを設定していない限り、Rails と同じようにテスト環境を整えます：リクエスト偽造対策は無効、リクエストのログは出さず（レベル `:none`。エラーの行は出ます）、ログの行はテキスト（エクスポートされた `CYBERTRAIN_LOG_FORMAT` は読みません）、エラー報告は Sentry に送らず（エクスポートされた `CYBERTRAIN_SENTRY_DSN` は空にします）、メールは `Mailer.deliveries` に保持し（`:test`）、`force_ssl` は無効（テストでは変数 `CYBERTRAIN_MAIL_DELIVERY_METHOD` と `CYBERTRAIN_FORCE_SSL` は、不正な値でも読まれません）、アップロードは `tmp/test_uploads/` に書かれて実行のたびに空になり、ホストの検査は行いません（`CYBERTRAIN_HOSTS` を export しても有効になりません）。`*_url` ヘルパーのホストである `www.example.com` は常に許可されたホストです。

```text 出力 — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:14)
         Expected change of 1, got 0 (from 2 to 2)
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

ファイルごとに見出し、テストごとに 1 行、最後に合計を出し、所要時間は出しません。示される行はテストの `test "..."` の行です：コンパイル済みのプログラムにはバックトレースがないので、失敗したアサーションの行はわかりません。終了ステータスは、失敗したテストがあれば 1、なければ 0、受け付けない引数には 2 です。テスト対象のコードが自分で出力したもの（コマンドの出力行など）は、テストの行の間に出ます。テスト、setup、teardown、フックが `NotImplementedError`、ほかの `ScriptError`、`SystemStackError` を発生させても、ほかの例外と同じく `ERR` になり、実行は続きます。実行を終わらせるのは `Interrupt`、`SystemExit`、`NoMemoryError` だけです。Spinel では、本当のスタックオーバーフローは今もセグメンテーション違反でプロセスを終わらせます：ランナーに届くのは、コード自身が発生させた `SystemStackError` だけです。

引数：`-n NAME` はその名前またはメソッド名のテストを残し、`-n /TEXT/` は名前またはメソッド名に TEXT を素の文字列として含むテストを残します（`.`、`?`、`()` は文字そのものです）。`^ $ \ * + [ ] { } |` のどれかを含む TEXT は正規表現ではないので、終了ステータス 2 で拒否されます：`-n /^test_create/: the text between the slashes is a plain substring of the test name, not a regexp (^ would be looked for as itself); write the text to look for (-n /test_create/)`。ファイルやディレクトリはそのテストを残します。`FILE:LINE` は拒否され（`line filters are not supported; give the file, and -n for the name`）、`--` でオプションが終わります。どのテストも残らない絞り込みは、合計の前に `no test matched the filter` を出して 0 で終わります。`test/` 以下のファイルを加えたり消したりすると、プログラムはコンパイルし直されます。

**変更にかかる手間。** ファイルの引数と `-n` は、どのテストを実行するかを選ぶもので、何をコンパイルするかは変えません。プログラムは常にすべてのテストを含むので、絞り込みを変えてもバイナリはそのまま使われます。一方、どれか 1 つのテスト（あるいはプログラムを作るほかの何か）を編集すると、先に `bin/gen` をビルドし直したうえで、プログラム全体をコンパイルし直します。2026-11-12 と 2026-11-13 に、共有の 4 vCPU のクラウドマシンで測った値です（手元のマシンでは違います）：examples/blog の 21 ファイル 149 テストは、初回のコンパイルに約 527 秒かかり（初回の実行全体で 656 秒、バイナリは 10.2 MB）、そのあと何も変えずに `cybertrain test test/controllers` を実行すると、バイナリをそのまま使って約 1 秒で始まりました（ブログ自身の実行、2026-11-13）。ブログのアプリケーションに 3 つのテストファイル（8 テスト）を入れたものは、最大約 2.2 GB のメモリで 162〜233 秒かけてコンパイルされ、8.1 MB のバイナリになりました（2026-11-12）。テストはいくつか書いてからまとめて実行し、1 つのテストに取り組む間は、ビルドではなく実行のほうを絞り込んでください。

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
- フィクスチャは gen の実行時に検査されますが、そのエラーで止まるのはテストの実行だけです：`spin run gen` は先に進みます。スキャフォールドはマイグレーションより先にフィクスチャを書くので、`cybertrain db migrate`（先に gen を実行します）も止まりません。そして`cybertrain test` が `test/fixtures/<table>.yml:<行>: ...` を出して 1 で終わります。
- Rails と同じく、親を指すフィクスチャがあると、その親は削除できません：`comments.yml` に `article: one` があると、スキャフォールドの「should destroy article」は外部キーで失敗します。`has_many :comments, dependent: :destroy` を宣言するか、子のフィクスチャを別の行に向けるか（`article: two`）、何からも参照されていない行を削除してください。
- 提供しないもの：`fixtures :articles`（どのファイルも読み込まれます）、`articles(:one, :two)`、ポリモーフィックなラベル（`commentable: one (Article)`。`_id` と `_type` のカラムを書いてください）、`has_and_belongs_to_many` のラベル、アンカーとエイリアス。

## 統合テスト

`ActionDispatch::IntegrationTest` は起動したアプリケーションにプロセス内でリクエストを送ります。ソケットは使わず、cookie jar はテストごとに新しくなります：

- `get`、`post`、`patch`、`put`、`delete`、`head`（パス、`params: {}`、`headers: {}`）。書き方は Rails と同じです。どれも `Cybertrain::Response` を返し（Rails はステータスを返します）、それは `response` でもあります（`response.body`、`response.status`、`response.header(name)`）。
- `params:` は入れ子の Hash を受け取り、フォームと同じ形で送ります（`article[title]=New`）。値は String、Symbol、数値、`true` / `false`、nil、Date、Time にでき（カラムが読み戻すテキストとして送られます）、スキャフォールドのテストはレコードの値をそのまま送れます。Array は拒否されます。
- `post`、`patch`、`put` の `params:` に `fixture_file_upload("cover.png", "image/png")` を入れると、リクエストは multipart で送られます。ファイルは `test/fixtures/files/` から読まれます。
- `headers:` はヘッダーの名前か、Rails の `HTTP_ACCEPT` の形を取ります。
- `config/routes.rb` のパスヘルパーはコントローラーの中と同じく使えます。`*_url` ヘルパーは `http://www.example.com/...` を書きます。このホストの URL はパスでリクエストされ、`assert_redirected_to` はどちらの形でも比べます。ほかのホストの URL は拒否されます。
- `cookies` はテストの cookie jar で、`Cybertrain::Test::ClientCookies` です：`cookies[:user]` または `cookies["user"]`（生の、パーセントエンコードされたままの値）、`[]=`、`key?`、`delete`、`keys`、`size`、`empty?`、`to_h`。`Max-Age` や `Expires` が時計の上で過ぎた cookie は、その先へ `travel_to` した場合も含めて消えます（`Max-Age` が `Expires` より優先されます）。テストが `[]=` で書いた cookie は期限切れになりません。読めない `Max-Age`（`Max-Age=abc`）は無視され、負の値なら cookie は期限切れになります。Rails のものと違い、`each`、`length`、`include?`、`fetch`、`==` はありません：移植したテストではその代わりに `cookies.to_h` を読んでください。
- `follow_redirect!` は最後のレスポンスの `Location` を（`#fragment` を除いて）リクエストします。リダイレクトではないレスポンスのあとでは、テストを失敗させます：`follow_redirect!: the last response was 200, not a redirect (3xx with a Location)`。
- `assert_response(:success)`（どのステータスのシンボルでも、数値でも。`:error` はちょうど 500 を意味し、Rails はどの 5xx でも受け付けます）、`assert_redirected_to(path)`、`assert_select`、`assert_turbo_stream`。
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

ブロックの中では、フォームにはテストがリクエストしたページの `authenticity_token` が必要です。ブロックが終わると、中のアサーションが失敗した場合でも、すべて元に戻ります。テスト自身が設定したもの（アップロードのルート、ゾーン、ロケール、ログレベル）はそのまま残ります。

**サインイン。** `cybertrain generate authentication` は `test/support/session_test_helper.rb` を書き出し、これはどの統合テストにも include されます：`sign_in_as users(:one)`（フィクスチャのユーザーのパスワードは `"password"`。`remember: true` で「ログインしたままにする」にチェックが入ります）、`sign_out`、`authenticity_token_in(response.body)`（ページの最初のフォームのトークン。`with_forgery_protection` の中のリクエスト用）、そして自分のクッキーを持つ 2 つ目のブラウザーである `open_session`（`phone = open_session` のあと、`phone.sign_in_as users(:two)` や `phone.get ...`）。リクエストはどれも `127.0.0.1` から来ます。別のクライアントアドレスが必要なテストは、自分で `client = Cybertrain::Test::Client.new(Cybertrain::Test.app)` を作って `client.peer_address = "203.0.113.7"` を設定します（クライアント自身のメソッドは `client.get(path, headers)` と `client.post(path, fields, headers)` です）。

## アサーション

`assert`、`assert_not`（`refute`）、`assert_equal`、`assert_not_equal`、`assert_nil`、`assert_not_nil`、`assert_includes`、`assert_not_includes`、`assert_empty`、`assert_not_empty`、`assert_match` / `assert_no_match`（Regexp か、部分文字列としての String）、`assert_in_delta(expected, actual, delta = 0.001)`、`assert_nothing_raised { }`、`flunk` が Minitest と同じくあります。`assert_equal` は Minitest のテキスト（2 行の `Expected: 1` と `  Actual: 0`）で失敗し、新しく加わったアサーションも同様です。`assert_includes`、`assert_nil`、`flunk` はそれぞれ独自の短いテキストのままです。`assert` と `refute` は 2 つ目の引数にメッセージを取ります。ブロックの形はラムダを位置引数で取ります：

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
- 提供しないもの：`assert_predicate`（計算された `send` が要ります：`assert article.valid?` と書いてください）、`assert_difference` の String の式（`eval` が要ります）、式の Array や Hash、ほかのアサーションのメッセージの引数。Minitest の `refute_*` の名前のうちあるのは `refute` だけです：`assert_not_equal`、`assert_not_nil` などの `assert_not_*` の形を書いてください。`refute_equal` を呼ぶと、定義しているものがないので、テストプログラムのビルドが止まります。

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

`travel_to(time)`、`travel(seconds)`、`freeze_time`、`travel_back` は Rails のヘルパーです：どれも時計を止め、1 秒未満の部分を落とします。ブロックを渡すと、ブロックが終わったとき（例外が起きたときも）元の時刻に戻り、渡さなければ `travel_back` かテストの終わりまで移動したままです。フレームワークが時刻を記録するものはすべてこれに従います：`Time.current`、テストプログラムの中の `Time.now`、レコードのタイムスタンプ、キャッシュの有効期限、レート制限、セッションの寿命、ジョブの `run_at`、トークンの有効期限、スケジューラー。待ちとタイムアウト（ストリームの読み取り、受信者）は実時間のままなので、時計を止めても待ちが止まったままになることはありません。本番では `Time.now` はシステムの時計です：移動に従うべきコードは、Rails が勧めるとおり `Time.current` を読みます。`Time.now` は組み込みのものと同じくプロセスの `TZ` での現地時刻を返し、`Time.current` は UTC です。`travel_to` が取るのは Time で、Date は取りません。`Time.zone.local` もありません：瞬間は `Time.utc(...)` で書いてください。スケジューラーは覚えていること（最後の回復、次の実行時刻）をタイムトラベルの間も持ち続けます。スケジューラーやワーカーのスレッドが動いている間にタイムトラベルするテストはサポートしていません。

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

- セレクター：タグ、`.class`、`#id`、`[attr]`、`[attr="v"]`、それらの組み合わせ（`a.btn[href="/x"]`）、子孫と子（`>`）の結合子、リスト（`h1, h2`）。疑似クラス、`+` と `~`、ほかの属性演算子、バックスラッシュ（`assert_select: CSS escapes (\) are not supported`）、入れ子のブロックの形は `assert_select: <feature> is not supported` で失敗します。
- `text:` は各要素のテキストと比べる String か、そのテキストに当てる Regexp です。テキストは、空白の連続を 1 つのスペースにし、両端を取り除いたものです（Rails は両端を取り除くだけです）。2 つ目の引数は Rails の位置引数の形にでき、テキスト（String か Regexp）、件数（Integer）、`true` / `false` を取ります。件数には `2..3` のような Range も使えます。そこで件数を渡しつつ `count:`、`minimum:`、`maximum:` も渡すと拒否され、負の Range、逆向きの Range、両端のない Range も拒否されます（`assert_select: a Range count needs both ends (got 2..)`）。
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

`cybertrain test` では、`config/app.rb` が設定していない限り `Cybertrain.config.mail_delivery_method` は `:test` です：`deliver_now`、`Mailer.deliver`、`deliver_later` のジョブはメッセージを検査し、接続する代わりに `Cybertrain::Mailer.deliveries` に保持します。このリストは各テストの前に空になります。アプリケーションが送信者を設定していなければ、テストプログラムはメールの送信者を `from@example.com` にします。

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
- 定期タスクは `Cybertrain::Scheduler.run_due(Time.current.to_i)` （エポック秒） で 1 回ずつ実行します。

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

## ログとエラー報告のテスト

レスポンスの `X-Request-Id` がリクエストの ID です。ログの行を読むには、テストが見たい処理の間だけ `Cybertrain.logger` に `StringIO` を渡し、後でロガーを戻します。これは専用のメソッドの中で行います（`yield` を囲む `rescue` や `ensure` は、Spinel では素のメソッドに置きます）：

```ruby test/integration/logging_test.rb
require "test_helper"
require "stringio"

class LoggingTest < ActionDispatch::IntegrationTest
  test "a comment's job logs the request's id" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Ann", body: "Hi" } }
    rid = response.header("X-Request-Id").to_s
    log = StringIO.new
    perform_jobs_logging_to(log)
    assert_includes log.string, "] [#{rid}] new comment "
  end

  private

  def perform_jobs_logging_to(io)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end
end
```

行頭の時刻は実行のたびに変わるので（比べるなら `freeze_time` で止めます）、その後ろ、つまりレベル、タグ、メッセージを比べます。アプリケーションのリクエストログはテストでは出ませんが（`log_level :none`）、失敗したジョブの `ERROR` の行はそれでも書かれます。失敗するジョブを実行するテストは上のようにロガーを捕まえます。そうしないと、その行がテストの行の間に出ます。

エラー報告は `Cybertrain::Test::SentryReceiver` に届きます。これは `cybertrain/test_help` が読み込む `127.0.0.1` 上の Sentry です。`cybertrain test` はエクスポートされた DSN を無視するので、テストが DSN を代入し、後で戻します：

```ruby test/integration/error_reporting_test.rb
require "test_helper"

class ErrorReportingTest < ActionDispatch::IntegrationTest
  setup do
    @sentry = Cybertrain::Test::SentryReceiver.new
    @sentry.start
    @saved_dsn = Cybertrain.config.sentry_dsn
    @saved_private = Cybertrain.config.http_allow_private
    Cybertrain.config.sentry_dsn = @sentry.dsn                # http://public@127.0.0.1:<port>/1
    Cybertrain.config.http_allow_private = true               # そうしないと HttpClient はループバックを拒否する
  end

  teardown do
    Cybertrain.config.sentry_dsn = @saved_dsn
    Cybertrain.config.http_allow_private = @saved_private
  end

  test "a job whose comment is gone is discarded and reported" do
    NotifyCommentJob.perform_later("comment_id" => 999_999, "article_id" => articles(:one).id)
    perform_enqueued_jobs                                       # 破棄でテストは失敗しない
    event = @sentry.received_events(1)[0]                      # 最大 5 秒待つ
    assert_equal "NotifyCommentJob", event.sentry_field("transaction")
    assert_equal "NotifyCommentJob::CommentGone", event.sentry_field("exception.values.0.type")
  end
end
```

`SentryReceiver.new(status: 200, max: 50, accept_window: 10.0)` は各エンベロープに Sentry と同じように応答します（429 など別の `status:` で、拒否する Sentry を演じます）。`dsn(project = "1", prefix = "")` はそこに送る DSN で、`received_events(count, wait = 5.0)` は届いたものを返します。それぞれは `Cybertrain::Test::SentryEnvelope` で、`sentry_path`、`sentry_auth`（`X-Sentry-Auth`）、`sentry_content_type`、`sentry_body`（3 行の JSON）、イベントのフィールドを読む `sentry_field("a.b.0.c")`（ないときは `""`）、エンベロープのヘッダーを読む `sentry_header_field(name)` を持ちます。`extra` のキーにドットを含むもの（`job.attempt`）は、ドットで区切る `sentry_field` では読めません。`sentry_body` から読んでください。テストの中で起動したレシーバーは、ほかのレシーバーと同じくテストの後に止まります。

テストで追加したサブスクライバーは次のテストの前に外れます（`config/app.rb` が追加したものは残ります）。各テストの前に、レポーターはまだキューにあるものを届け、重複除去の時間枠を忘れるので、2 つのテストで同じ失敗が起きればどちらでも報告されます。サブスクライバーが受け取ったものを読むテストのために、`Cybertrain.error.drain_reports` がキューの報告を（最大 2 秒）待ちます：

```ruby
# テストファイルの先頭に：
REPORTS_SEEN = Array.new(0) { "" }
class SeenReports < Cybertrain::ErrorSubscriber
  def report(event)
    REPORTS_SEEN << event.error_class
    nil
  end
end

# テストの中で：
Cybertrain.error.subscribe(SeenReports.new)
get "/articles/999999"
Cybertrain.error.drain_reports
assert_equal 0, REPORTS_SEEN.size             # 404 は報告されない
```

## テストクラスで gen が拒否するもの

gen はテストクラスをメソッドに書き換えます：`test "shows it" do` は `def test_shows_it` になり（`[A-Za-z0-9_]` 以外の ASCII の文字は `_` に、それ以外の文字は `_u<hex>_`（小文字のコードポイントを `_` で閉じたもの）になるので、`"ログ"` は `test__u30ed__u30b0_`、`"café x"` は `test_caf_ue9__x` です。`-n` にはメソッド名も書いたとおりの名前も渡せます）、`setup do` と `teardown do` のブロックは `super` を呼ぶ `setup` と `teardown` のメソッドになります。書き換えで正確に移せないものがあると、そのファイルは拒否されます。黙って誤ったコピーを作ったり、テストを失ったりはしません：

- 素の文字列リテラルではないテスト名（式展開）や、gen が読まないエスケープ（`\u`、`\x`、`\c`、`\C`、`\M`、8 進数）を含むテスト名（文字そのものを書いてください。`\n`、`\t`、`\"` は読まれます）。
- 1 つのクラスの中でメソッド名が同じになる 2 つのテスト（`def test_x` も含む）。
- 1 つのクラスの中の `setup do` と `def setup` の両方（`teardown` も同じ）、そして親がアプリケーションの基底クラスであるクラスの中の、`super` のない `def setup` や `def teardown`（基底クラスの `setup do` ブロックが実行されなくなります）。
- パラメーターを取る `def test_x`、または `private` や `protected` のあとの `def test_x`（Minitest は public なテストメソッドしか実行しません）。
- `setup { }` と `setup :name`（`setup do ... end` と書いてください）、`test`、`setup`、`teardown` のブロックパラメーター。
- テスト、setup、teardown の本体の中の `next`、`break`、`redo`（本体の中の `if`、`unless`、`case`、`begin` の中にあっても。`return` を使ってください）、`return <value>`（どれも nil を返します）。
- 別のクラスやモジュールの中に入れ子にしたテストクラス、2 回開いたテストクラス、開き直した `ActiveSupport::TestCase` の中の `setup do`（`setup do` を持つアプリケーションの基底クラスを書いて継承してください）。
- gen がクラス本体の中に置けない `test`、`setup`、`teardown` の行（条件、ループ、文字列、ヒアドキュメントの中）、`end` で終わらない 1 行の形、あとにコードが続く `end`、タブとスペースが混じったインデント。
- 引数が文字列リテラルではない `require_relative`。

拒否されたファイルがあっても `spin run gen` は止まらないので、開発サーバー、`cybertrain db migrate`、`cybertrain build` は動き続けます：gen は理由を出すだけの `gen/tests.rb` を書き、`cybertrain test` はコンパイルせずに `<path>:<line>: <reason>` を出して 1 で終わります。示された行を直してください。`test "name" do` は `test"name"` やタブを挟んだ形でも書けます。`private` のあとに書いた `test "x" do` は拒否されませんが、コピーの中で private なメソッドになり、実行すると失敗します（Rails では実行されます）：テストは `private` より上に書いてください。ほかの既知の制限：`_u3042_` という文字列を含む名前は、そこを `"あ"` にした名前と同じメソッド名になります（1 つのクラスの中では gen がその組を拒否します）。モジュールの中の `def setup` は `super` の検査を受けません。アプリケーションの基底クラスから 2 段下のクラスは、その基底クラスが `setup` を定義していなくても `super` を求められます。テストファイルが拒否されている間、`spin run gen -- --check` は `gen/test/` の古いコピーを比べません（CI は `cybertrain test` で失敗します）。

`cybertrain test` はさらに、同じやり方で次のものを拒否します：`test/test_helper.rb` や `test/support/` の中のトップレベルの `test`、`setup`、`teardown`（実行されることがありません）、トップレベルの `def render_inline`（フレームワークのものを置き換えてしまいます）、`assert_select ... do` と `render_inline ... do`、そして[テストを実行する](#running-the-tests)で述べた重複するトップレベルのヘルパー。クラスの形のファイルは `cybertrain test` でしか実行できません：`spin test` では、そのクラス本体が「class-form tests run with `cybertrain test FILE`」を発生させます。

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

トップレベルの `setup do` と `teardown do` は、そのファイルの各テストの前後に実行されます。`cybertrain spin test` は各 `test/*.rb` を別々のプログラムにコンパイルし、出力を `test/<name>.rb.expected` と比べます。そこではテーブルを空にすることもフィクスチャもなく（どちらも gen のテーブルの一覧が要ります）、`Cybertrain::Test.run!` がファイルのテストを実行します。`cybertrain test` では、ファイルのテストはテーブルを空にしてフィクスチャを入れたあとにほかのテストと一緒に実行され、`run!` は何もしません。`spin test` ではそのファイルのためにアプリケーションを起動するものがないので、そのようなファイルは 0.4 のサポートファイル（`AppTest.boot`、`BlogTest.boot`）がしていたように自分で起動し、フィクスチャは使いません。`Cybertrain::Test::Client` は cookie jar を持ち、CSRF も含めてアプリケーションを操作します（`client.get`、`client.post(path, fields, headers)`、`client.follow_redirect!`、`client.response`、引数 2 つの `assert_response res, :ok` と `assert_redirected_to res, path`）。SQLite に触れるテストのスナップショットはコンパイル済みのバイナリから取ります：フレームワークのチェックアウトでは `script/regen-snapshot test/<name>.rb`、または `rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`。

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
- 角括弧のレベルで始まるログの行を丸ごと探していたテストは、レベルとメッセージを別々に探します（`" ERROR "` と `"password reset mail not sent: "`）。行はいまは時刻で始まり、リクエストの ID を持つことがあります（[ログ](background-and-operations.md#logs)）。
- エクスポートされた `CYBERTRAIN_LOG_FORMAT` や `CYBERTRAIN_SENTRY_DSN` はテストに届かなくなりました。それらでテストするには、`config/app.rb` で設定するか、テストで DSN を代入します。

## 継続的インテグレーション

`cybertrain new` はアプリ用に `.github/workflows/ci.yml` を書き出します。これはこのリポジトリの `setup-cybertrain` アクション（[.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)）を CLI のリリースタグに固定して呼び出します。アクションは SQLite、zlib、OpenSSL のヘッダーと Ruby をインストールし、アプリが固定しているフレームワークのコミットを `spin.lock` から読み、そのコミットのフレームワークを取得して、その `cybertrain doctor` と `cybertrain setup` を実行します（`~/.cybertrain/spinel` は Spinel のリリースとランナーのイメージごとにキャッシュされます）。そのあとワークフローは `spin.lock` が最新であること（`spin lock && git diff --exit-code spin.lock`）と `gen/` が新しいこと（`SPIN_DEBUG=1 spin run gen -- --check`）を確かめ、`cybertrain test` を実行します。ツールチェーンの手順が変わるときは、各アプリのコピーではなくアクションが変わります。コミットは `spin.lock` から読むので、ワークフローは既定の git 依存を前提にしています。`--path` で作ったアプリは、フレームワークのチェックアウトを `framework-path` としてアクションに渡します。
