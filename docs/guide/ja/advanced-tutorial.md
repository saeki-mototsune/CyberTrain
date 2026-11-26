---
source_sha256: a1bd7b8890459f79a2b34e6ee1a7243e28b482a3d52c59ff76ec795c361cd256
title: "発展編チュートリアル：ブログをさらに進める"
description: "Getting Started のブログを CyberTrain でさらに進めます：コンポーネントとヘルパー、Turbo Streams によるコメントのライブ更新、バックグラウンドジョブ、JSON、サインイン、アップロードしたカバー画像、cybertrain build によるデプロイ用ビルド。"
og_title: "発展編チュートリアル：CyberTrain のブログをさらに進める"
og_description: "CyberTrain の Getting Started のブログに、Turbo、バックグラウンドジョブ、JSON、サインイン、アップロード、デプロイ可能なビルドを加えます。"
og_image: tutorial.png
crumb: "発展編チュートリアル"
nav: tutorial
toc_title: "ステップ 13–19"
meta:
  - term: "必要なもの"
    text: '[チュートリアル](tutorial.md#test)のステップ 12 まで進めたブログ'
  - term: "出発点"
    text: "記事、コメント、テストのある `blog/`"
  - term: "完成物"
    text: "`dist/blog`"
---

# 発展編チュートリアル：ブログをさらに進める

[チュートリアル](tutorial.md)は、記事とコメントのあるブログで終わりました。このページでは同じアプリを先へ進めます：コメントをコンポーネントでレンダリングし、新しいコメントを Turbo で開いているすべてのページに届け、バックグラウンドジョブをキューに入れ、JSON で応答し、サインインを追加し、アップロードした画像を添付し、アプリをデプロイ可能な `dist/` フォルダーにビルドします。このアプリを発展させたものが [`examples/blog`](../../examples/blog) で、Linux と macOS の CI で検証されています。

<!-- step 13 #component stage: 自分で書く · `app/components/`, `app/helpers/` -->
## コンポーネントとヘルパー

> [!WHY]
> 次のステップから、コメントは 2 か所でレンダリングされます：ページの中と、背後にリクエストのないブロードキャストの中です。コンポーネント（テンプレートを横に置いたクラス）はどちらでも同じようにレンダリングされます。ヘルパーは、どのテンプレートからも呼べるメソッドです。

```shell ターミナル — blog/
cybertrain generate component comment comment   # 名前、続いて属性：ここでは 1 つで、これも comment
cybertrain generate helper comments
```

1 つ目は、属性ごとにキーワード引数を 1 つ持つ `app/components/comment_component.rb` とそのテンプレートを書き出し、2 つ目は空の `CommentsHelper` を書き出します。どちらもテストを 1 つ書き出しますが、これはこのステップの最後で扱います。クラスはすでに、このブログに必要な形になっています：

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

生成されたテンプレートをコメントのマークアップに置き換え、ヘルパーにメソッドを 1 つ書きます：

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # The commenter's name in a <strong>, escaped: <%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

そして、ページがパーシャルをレンダリングしていた箇所でコンポーネントをレンダリングし、`app/views/comments/_comment.html.erb` を削除します：

```erb app/views/articles/show.html.erb（抜粋）
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- テンプレートからは、コンポーネントのインスタンス変数がローカル変数として（`comment`）、引数のない public メソッドが名前で見えます。渡されるのはコメントだけで、ページの `@article` は渡されないので、ボタンのパスは `comment.article_id` から組み立てます。
- `dom_id(comment)` は、id が 7 のコメントなら `comment_7` です：次のステップのブロードキャストが狙う要素の id になります。
- コンポーネントは、パーシャルと同じように、`_component` を除いたスネークケースの名前で指定します：テンプレートは定数を名指しできません。
- `Cybertrain::Html.tag` は内容をエスケープして `SafeString` を返し、テンプレートはこれをそのまま出力します。ヘルパーが返した素の `String` はエスケープされます。

> [!RULE] Spinel のルール：ヘルパーとコンポーネントは生成されたディスパッチ
> ### ヘルパーとコンポーネントは生成されたディスパッチ
>
> テンプレートは `send` を使えないため、`spin run gen` が `app/helpers/` と `app/components/` をテキストとして読み、ディスパッチを `gen/helpers.rb` と `gen/components.rb` に書き出します。ヘルパーのパラメーターにはすべて名前が付き（`*rest` も `**opts` も使えません）、引数はテンプレートの値として届きます。`comment_author` が引数を `case ... when Comment` で絞り込んでいるのはそのためです。詳しくは[アプリケーションヘルパー](template-language.md#application-helpers)と[コンポーネント](template-language.md#components)にあります。

### コンポーネントのテスト

生成されたテストは、テンプレートがいまはコメントを期待しているところに String を渡して `CommentComponent` をレンダリングします。代わりにフィクスチャのコメントをレンダリングします：

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` はブロードキャストと同じく、リクエストなしでレンダリングし、`assert_select` はレンダリングされたものを読みます（[ストリームとコンポーネントのテスト](testing.md#testing-streams-and-components)）。ヘルパーのテストは生成されたままで通ります。[ステップ 12](tutorial.md#test) と同じく `cybertrain test` で実行します。

<!-- step 14 #turbo stage: 実行時 · Server-Sent Events 上の Turbo Streams -->
## Turbo でコメントをライブ更新する

> [!WHY]
> あるブラウザーで投稿されたコメントは、その記事を開いているすべてのページに、再読み込みなしで現れてほしいものです。Rails 8 のアプリと同じく、これは Turbo Streams で実現します。サーバーのほかにインストールするものも、起動するものもありません。

### Turbo を読み込む

`cybertrain new` はどちらの行もコメントアウトした状態で書き出しています。コメントを外してください：

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

レイアウトの `javascript_importmap_tags` がインポートマップと `import "application"` を書き出すので、これですべてのページで Turbo が動きます（[インポートマップ](assets.md#the-import-map)）。

Turbo Streams のサーバー側はサブシステムです：`bin/blog.rb` のコアの行の下にその行を追加し、`bin/db.rb` にも同じ行を追加します。これがないと、`spin run gen` は下の `turbo_stream_from` で止まり、必要な行を示します。

```ruby bin/blog.rb（抜粋）
require "cybertrain/core"
require "cybertrain/streams"
```

### ページを購読させる

一覧とフォームにそれぞれ id を付け、ページを記事のストリームに購読させます：

```erb app/views/articles/show.html.erb（抜粋）
<h2>Comments</h2>

<%= turbo_stream_from @article %>

<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render component: "comment", comment: comment %>
  <% end %>
</div>

<h2>Add a comment:</h2>

<div id="comment_form">
  <%= render "comments/form", comment: @comment %>
</div>
```

### ブロードキャストして応答する

`create` は保存したコメントをブロードキャストし、続いて投稿したブラウザーに応答します。`destroy` は、ほかのページにその要素を取り除くよう伝えます：

```ruby app/controllers/comments_controller.rb（抜粋）
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    @new_comment = Comment.new   # the empty form create.turbo_stream.erb puts back
    respond_to do |format|
      format.turbo_stream   # app/views/comments/create.turbo_stream.erb
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    target = Cybertrain::Html.dom_id(@comment)   # read before destroy clears the id
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end
```

```erb app/views/comments/create.turbo_stream.erb
<%= turbo_stream.append "comments", html: render(component: "comment", comment: @comment) %>
<%= turbo_stream.update "comment_form", partial: "comments/form", locals: { comment: @new_comment } %>
```

ひとつの記事を 2 つのウィンドウで開き、片方でコメントを投稿してみてください：コメントは両方に現れ、送信したフォームは空に戻ります。

### 何が起きているか

<!-- list: points -->
- `turbo_stream_from @article` は、ストリーム `articles:<id>` に対する `<turbo-stream-source>` 要素を、署名付きのトークンとともに書き出します。Turbo はこれを `/cybertrain/stream` への `EventSource` として開きます。このエンドポイントはサーバーが最初から提供しています。
- ブロードキャストは、フレームワークが自分で作るテーブル `cybertrain_messages` の 1 行です。各サーバープロセスがこのテーブルをポーリングし、自分が抱えているページにその行を、およそ 0.1 秒以内に渡します。
- Turbo はフォームを、Turbo Stream を求める形で送信するので、`format.turbo_stream` が `create.turbo_stream.erb` をレイアウトなしでレンダリングします。JavaScript を切った素のフォーム送信は `format.html` を通り、これまでどおりリダイレクトされます。
- 投稿したウィンドウはコメントを、応答とブロードキャストで 2 回受け取りますが、表示は 1 つです：Turbo は同じ id を持つ要素を置き換えます。

WebSocket や、自分の JavaScript から使うストリームなど、詳しくは[リアルタイム](realtime.md#turbo-streams)にあります。

> [!NOTE]
> ここでは Turbo を jsDelivr から取得しています。自分で配信するには、`turbo.es2017-esm.js` を `vendor/javascript/` にコピーし、`to: "turbo.es2017-esm.js"` でピン留めします。`config/app.rb` にコメントアウトされている Content Security Policy を有効にする場合は、その `script_src` で、Turbo を配信するオリジンを許可する必要があります（[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)）。

### Turbo Stream の応答をテストする

Turbo のフォーム送信と同じように Turbo Stream を求めるリクエストには、Turbo Stream で応答します。[ステップ 12](tutorial.md#test) のコメントのテストに、それを確かめるテストを加えます：

```ruby test/controllers/comments_controller_test.rb（抜粋）
  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end
```

<!-- step 15 #job stage: 自分で書く · `app/jobs/` -->
## バックグラウンドジョブ

> [!WHY]
> 通知のように、レスポンスを待たせるべきでない処理は、リクエストとは別に実行します。レスポンスを書く前に始まることも、後に始まることもあります。Solid Queue 上の Active Job と同じく、ジョブは `app/jobs/` のクラスであり、アプリケーション自身のデータベースの 1 行です：ほかのサービスは要りません。

```shell ターミナル — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

オプションで指定した `retry_on` の行と空の `perform` を持つ `app/jobs/notify_comment_job.rb` と、テストを書き出し、`bin/blog.rb` と `bin/db.rb` に `require "cybertrain/jobs"` を追加し、`config/deploy.yml` の `worker` ロールのコメントを外します（[ステップ 19](#ship)）。`perform` の中身を書いてください。ここではログを出すだけですが、実際のアプリケーションならメールを送るところです：

```ruby app/jobs/notify_comment_job.rb
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
```

コメントを保存した後、`create` からキューに入れます：

```ruby app/controllers/comments_controller.rb（抜粋）
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

コメントを投稿すると、サーバーのログにジョブの実行が出ます。ここではレスポンスの後に実行されていますが、ジョブのスレッドがレスポンスを書く前に行を取ることもあるので、行の順序は変わることがあります。ジョブの行には、ジョブのタグと、それをキューに入れたリクエストの ID が付きます：

```text 出力 — cybertrain server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started POST "/articles/1/comments" for 127.0.0.1
2026-11-14T09:30:00.122Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 2ms
2026-11-14T09:30:00.950Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] new comment 1 on article 1
2026-11-14T09:30:00.951Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` は `perform_later` に渡した Hash で、JSON として保存され、String のキーで読み戻されます：レコードではなく id を渡し、値は `Cybertrain::Cast` で絞り込んでください。`perform_in(seconds, args)` と `perform_at(time, args)` は、後で実行するようにキューに入れます。
- ジョブは `cybertrain_jobs` の行で、サーバーのプロセスの 3 本のジョブスレッドが実行します。`./blog worker` で起動した別のプロセスに実行させることもできます（[プロセスの役割](background-and-operations.md#process-roles)）。
- `retry_on StandardError, wait: 30, attempts: 3` は、失敗した実行を 30 秒後にもう一度キューに入れ、試行は全部で 3 回です。それでも失敗した行は `failed` になり、残されます（[再試行と破棄](background-and-operations.md#retries-and-discards)）。
- ジョブは 2 回以上実行されることがあります（実行の途中でプロセスが落ちると、そのジョブはもう一度実行されます）。`perform` は繰り返しても安全なように書いてください。
- 失敗したジョブの一覧・再試行・破棄は、`./blog jobs` か、`/admin/jobs` のジョブページで行います。`config/routes.rb` にコメントアウトされている `jobs_page` の行は `require_admin` を指定していますが、このメソッドは[ステップ 17](#authentication) のジェネレーターが書き出すもので、ページのマウントもそのジェネレーターが行います（[ジョブページ](background-and-operations.md#the-jobs-page-and-the-jobs-command)）。

> [!RULE] Spinel のルール：ジョブのポリシーはテキストとして読まれる
> ### ジョブのポリシーはテキストとして読まれる
>
> `spin run gen` は `app/jobs/` の各クラスを読み、そのもう半分を `gen/jobs.rb` に書き出します：`perform_later` と、`rescue` 節としての各 `retry_on` です。そのため、`retry_on`、`discard_on`、`limits_concurrency` はそれぞれ 1 行で、リテラルの値を取ります：`wait: 30` と書き、`wait: 30.seconds` やラムダは書けません。

> [!EXAMPLE] 終わったジョブを毎晩削除する
> ### 終わったジョブを毎晩削除する
>
> コメントのたびに `done` の行が 1 つ残ります。`config/app.rb` の末尾には、1 週間たった行を削除する定期タスクがコメントアウトされた状態で入っています。コメントを外してください：
>
> ```ruby config/app.rb（抜粋）
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> cron 式は `CYBERTRAIN_SCHEDULER_TZ`（デフォルトはアプリケーションの `time_zone`、設定しなければ UTC）のタイムゾーンで読まれ、スケジュールを実行するのは一度に 1 つのプロセスだけです（[定期タスク](background-and-operations.md#scheduled-tasks)）。

### コメントがジョブをキューに入れることをテストする

ジェネレーターが書いたジョブのテストは、そのままで通ります。コメントのテストに、`create` がジョブをキューに入れることを確かめ、そのジョブを実行するテストを加えます：

```ruby test/controllers/comments_controller_test.rb（抜粋）
  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end
```

テストはジョブのスレッドを動かさないので、キューに入ったジョブはテストが実行するまで待ちます（`perform_enqueued_jobs`）。ほかのジョブのアサーションは[ジョブのテスト](testing.md#testing-jobs)にあります。

<!-- step 16 #json stage: 自分で書く · `app/controllers/` -->
## JSON で応答する

> [!WHY]
> ひとつのアクションで、ページと API の両方に応えられます：Rails と同じ `respond_to` です。

```ruby app/controllers/articles_controller.rb（抜粋）
  def index
    @articles = Article.all.to_a
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:as_json) }
    end
  end

  def show
    @comment = Comment.new
    respond_to do |format|
      format.html
      format.json { render json: @article.as_json }
    end
  end
```

```console ターミナル — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- フォーマットは拡張子（`/articles.json`）から、拡張子がなければ `Accept` ヘッダーから決まります。`/articles.xml` のように、アクションが挙げていないフォーマットには `406 Not Acceptable` が返ります。
- ブロックのない `format.html` は、これまでどおりアクションのテンプレートをレンダリングします。
- `as_json` はレコードのカラムで、時刻は ISO 8601 の UTC です。JSON にテンプレートはありません：アクションは `render json:` で応答します。
- ブロックには `format.` の行だけを書いてください：リクエストが html にフォールバックすると、ブロックはもう一度実行されます。

`/articles/1.json` は記事 1 件で、`show` の同じブロックが返します。フォーマットのすべては[フォーマットと `respond_to`](requests.md#formats-and-respond_to) にあります。

<!-- step 17 #authentication stage: 自分で書く · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## サインインを追加する

> [!WHY]
> ここまでは誰でも記事を編集・削除できます。Rails 8 の `bin/rails generate authentication` と同じく、ひとつのコマンドでメールアドレスとパスワードによるサインインを追加します。エンジンとして組み込むのではなく、アプリが所有するコードとして書き出します。

```shell ターミナル — blog/
cybertrain generate authentication
cybertrain db migrate    # users と sessions のテーブルを作る
```

`users` と `sessions` のマイグレーションとモデル、`ApplicationController` にインクルードする `Authentication` コンサーン、サインイン・サインアップ・パスワードリセット・アカウントページのコントローラーとビュー、メーラー、`./blog user` コマンド、そしてテストを書き出します。さらにルート（管理者向けの `/admin/jobs` のジョブページもその 1 つです）、レイアウトの先頭の `sessions/_nav` パーシャル、メール中のリンクの始まりになる `config/app.rb` の `base_url` 設定を加えます。最後に、そのコードが使うサブシステムの行を `bin/blog.rb` と `bin/db.rb` に加えます：`cybertrain/jobs`（ジョブページとメールを送るスレッド）、`cybertrain/mailer`、`cybertrain/mailer/later`（メールは `deliver_later` で送られます）、`cybertrain/rate_limit`（サインインの試行にはレート制限がかかります。後述）。すべてのファイルは [認証](authentication.md#generating-it) に一覧があります。

```ruby app/controllers/concerns/authentication.rb（抜粋）
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
```

これ以降、すべてのアクションはサインイン済みのユーザーを必要とし、訪問者は `/session/new` にリダイレクトされます。Rails のガイドと同じように、誰でも読めるページを開放し直します：

```ruby app/controllers/articles_controller.rb（抜粋）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

これらのページでも `resume_session` は実行されるので、テンプレートから `@current_user` を読めます。訪問者が使えないものは隠します：

```erb app/views/articles/show.html.erb（抜粋）
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>

  <div id="comment_form">
    <%= render "comments/form", comment: @comment %>
  </div>
<% end %>
```

コメントのコンポーネントの「Destroy comment」ボタンは、誰に対しても表示されたままです：ブロードキャストはコンポーネントを、すべての閲覧者に向けて一度だけ、リクエストなしで、つまり現在のユーザーなしでレンダリングするからです。訪問者がこのボタンを押すと、サインイン画面に送られます。`CommentsController` はどのアクションも開放していないためです。新しいコメントは訪問者のページにも届きます。ストリームはコントローラーのアクションではないからです。

サーバーを起動して `http://127.0.0.1:3000/sign_up` を開き、最初のユーザーを作成します。Rails のジェネレーターにはサインアップ画面がなく、最初のユーザーはコンソールで作りますが、CyberTrain は `RegistrationsController` を書き出すので、最初のユーザーはブラウザーでサインアップします。招待制のアプリでは、代わりに `--invite-only` 付きでジェネレーターを実行してください：サインアップ画面はなく、最初のユーザーは `./blog user EMAIL` か、サーバー自身のマシンからしか開けない `/setup` ページで作ります（[サインアップか、招待制か](authentication.md#sign-up-or-invite-only)）。

サインインページはメールによるパスワードリセットにも、nav はアカウントページにもリンクしています。[認証](authentication.md) のガイドが、ロックアウト、「ログインしたままにする」、`--confirmable`、管理者ユーザーとあわせて説明しています。リセットのメールには SMTP の設定と、本番では `BLOG_BASE_URL` が必要です（[メール中のリンク](authentication.md#links-in-mails)）。

> [!RULE] has_secure_password は書き下される
> ### `has_secure_password` は書き下される
>
> CyberTrain に `has_secure_password` マクロはありません。ジェネレーターは、それが定義するはずのもの、つまり `password=`、`authenticate`、`User.authenticate_by(email_address:, password:)` を、アプリケーションが所有するコードとして `User` モデルに書き出します。パスワードは `Cybertrain::Password` でハッシュ化されます。Ruby で書かれた PBKDF2-HMAC-SHA256 で、既定は 10 万回反復（コンパイル後で約 0.2 秒）です。bcrypt を使うと、バイナリが C ライブラリをリンクする必要があるためです。コストは `config/app.rb` に `Cybertrain::Password.iterations = 600_000` と書いて引き上げられ、`User#authenticate` が各ユーザーのサインイン時にハッシュを作り直します。

### テストを更新する

[ステップ 12](tutorial.md#test) のテストのうち、フォームを開くもの、フォームを送信するもの、`index` と `show` 以外のアクションに届くものは、いまはサインインのページに行き当たります。ジェネレーターは `test/fixtures/users.yml`（`one` と `two`。パスワードは `"password"`）と `test/support/session_test_helper.rb` を書き出しており、`test/test_helper.rb` がその `sign_in_as` をいまはすべての統合テストに与えます。記事のテストの `setup` には、ジェネレーターがサインインをすでに加えています（`insert test/controllers/articles_controller_test.rb (sign_in_as users(:one))` と表示されます）。次のようになっているはずです：

```ruby test/controllers/articles_controller_test.rb（抜粋）
  setup do
    sign_in_as users(:one)
    @article = articles(:one)
  end
```

コメントのテストにはジェネレーターが書き足せる `setup` がありません。`CommentsController` のすべてのアクション（create と destroy）がいまはサインインしたユーザーを必要とするので、4 つのテストのどれもが同じです。`setup` を加えます：

```ruby test/controllers/comments_controller_test.rb（抜粋）
class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end
```

これから生成するスキャフォールドは自分でサインインします。

> [!NOTE]
> ジェネレーター自身のテスト（`test/controllers/sessions_controller_test.rb`、`registrations_controller_test.rb`、`passwords_controller_test.rb`、`accounts_controller_test.rb`、`test/integration/remember_me_test.rb`、`lockout_test.rb`、`admin_test.rb`。[テスト](authentication.md#testing)）は `cybertrain test` でほかのテストと一緒に実行され、`travel_to` で時計を動かして 15 日目と 30 日目を確かめます。サインインの試行は Rails のジェネレーターと同じく、クライアントのアドレスごとに 3 分間に 10 回までに制限され、アプリのデータベースで数えるので、すべてのプロセスがまとめて数えます。リバースプロキシの後ろでは[信頼するプロキシ](requests.md#rate-limiting-and-the-client-address)を設定してください。`examples/blog` はこのステップを `--invite-only` で行い、`/admin` のページを管理者だけのものにしています。

<!-- step 18 #attachments stage: 自分で書く · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## カバー画像を追加する

> [!WHY]
> 記事に画像を添えられるようにします。サインインと同じ役割分担です。フレームワークが `multipart/form-data` を解析してバイト列を保存し、残りはひとつのコマンドが、Active Storage の `has_one_attached` の代わりに、アプリが所有するコードとして書き出します。

画像は記事のページに表示されます。このページはステップ 17 から訪問者も読めるので、画像のダウンロードも訪問者に開いておく必要があります。ジェネレーターを実行する前に、ステップ 17 で書いたリストに `:cover` を加えます。また、ダウンロードは `def show` の中のコードを実行しません。この `show` にはコードがある（フォーム用の空のコメントを用意し、フォーマットを選ぶ）ので、そのコードが誰も制限しないことを `--show-checks-nothing` で示さない限り、ジェネレーターは止まります。このコードは誰も制限しません：

```ruby app/controllers/articles_controller.rb（抜粋）
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell ターミナル — blog/
cybertrain generate attachment article cover --show-checks-nothing   # 新しいモデルなら: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                                                # articles に cover_* のカラムを追加する
```

`articles` に 5 つのカラム（`cover_key`、`cover_filename`、`cover_content_type`、`cover_byte_size`、`cover_checksum`。ファイルそのものは SQLite には入りません）を追加するマイグレーションと、`Article` に `cover_file=`、`cover_attached?`、`cover_url`、バリデーション、保存時と削除時のコールバックを持つブロックを書き出します。`ArticlesController` には、`before_action :set_article` の対象となる `cover` アクションと、`create` と `update` にそれぞれ 1 行を追加します：

```ruby app/controllers/articles_controller.rb （抜粋）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 17 wrote [:index, :show]; you added :cover
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show (and authentication applies).
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end
  # ...
  def create
    @article = Article.new(article_params)
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
  # ...
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.update(article_params)
```

ダウンロードは `show` と同じく `set_article` を通して記事を見つけるので、`set_article` がユーザーに見せる記事を制限しているなら、その制限はダウンロードにも及びます。この `show` には独自のコードがあるので、ジェネレーターは出力の中でそれでも警告を表示します：

```text 出力 — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

ここでは、そのコードはコメントを用意してフォーマットを選ぶだけで、誰の閲覧も拒みません。したがって `cover` に写すものはありません。もし誰かを拒むコード（`head 404 if @article.draft?`）だったなら、そのチェックの置き場所は `:show` と `:cover` の両方を挙げる `before_action` です。ジェネレーターはそれを読み取れるので、フラグは要りません。

ジェネレーターは、`config/routes.rb` に `get "/articles/:id/cover"` を、フォームに `multipart: true` と、送信ボタンの上のファイル入力を、表示ページの `<h1>` の直後に画像を、それぞれ追加します：

```erb app/views/articles/_form.html.erb （抜粋）
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb （抜粋）
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!NOTE]
> ジェネレーターは `show` のアクセスルールをダウンロードに写しますが、写すのは読み取れるもの、つまりコールバックだけです。`set_article` 以外の `before_action` が、新しいアクションを含まずに `:show` を挙げていると、`cannot preserve show's authorization for :cover` と表示して止まり、何も書き出しません。`def show` の中のコードは、何を確かめているのかを読み取れません。そのため `--show-checks-nothing` で保証しない限り同じように止まり、保証すれば警告を表示します。`show` が空なら、`:show` が挙がっている `allow_unauthenticated_access` にジェネレーターが自分で `:cover` を加えます。`show` にコードがあるとその行には手を付けず、そこに `:cover` がなければ画像にはサインインが必要になります。

> [!RULE] has_one_attached は書き下される
> ### `has_one_attached` は書き下される
>
> `has_one_attached` も、共有の添付テーブルもありません。許可する種類、サイズ、誰がダウンロードできるかはアプリケーションごとに違うので、ジェネレーターはフィールド名にちなんだメソッドを `Article` に書き下し、メタデータは `articles` の 5 つのカラムに入れます。これらは `NOT NULL` で、`""` と `0` が「添付なし」を表します。NULL を許すカラムでは Spinel の型推論が効かなくなるためです。SQLite に入るのはメタデータだけ（テキスト値は NUL バイトで途切れます）で、バイト列はファイルとして保存されます。

### ファイルの配信方法

<!-- list: points -->
- **種類。**既定では 2 MB までの PNG、JPEG、GIF、WebP だけを受け付けます（モデルの `COVER_TYPES` と `COVER_MAX_BYTES`。`--any` を付けるとどの種類も受け付けます）。種類はファイルの先頭バイトから判定し、ブラウザーが送ってきた値は使いません。
- **保存。**バイト列は `storage/uploads/<2 hex>/<32 hex key>` に書き込まれます（`Cybertrain::BlobStore`、パーミッション 0600）。ファイルを差し替えると古いファイルは削除され、記事を削除するとそのファイルも削除されます。`storage/uploads/` は SQLite のファイルと一緒にバックアップしてください。
- **配信。**ファイルはコントローラーの `send_blob` 経由で返し、`public/` からは返しません。4 種類の画像はそのまま表示され、それ以外はダウンロードになります（`application/octet-stream`）。すべてのレスポンスに `X-Content-Type-Options: nosniff` と `Content-Security-Policy: default-src 'none'; sandbox` が付きます。
- **パラメーター。**`params.nested(:article).upload(:cover)` は `Cybertrain::UploadedFile` を返し、ファイルが選ばれていなければ nil です。`permit` はファイルを返さないので、ファイルはこの明示的な 1 行を通ってしか入ってきません。CSRF トークンは、通常のフォームと同じように multipart のボディからも読み取られます。壊れたボディやサイズ超過のボディは 400 になります。上限は `config/app.rb` の `max_upload_bytes` と `max_multipart_parts` で、保存先のディレクトリは `upload_root` で設定します。

サーバーを起動し、記事を編集して画像を選びます。ジェネレーターは `test/integration/article_cover_attachment_test.rb` と画像 `test/fixtures/files/cover.png` も書き出しています。このテストは一連の流れ全体を確かめ、アプリに `User` があるので最初にサインインします。ここでは `:cover` が公開されているので、訪問者がカバー画像をダウンロードできることを確かめます。本文には、[ステップ 05](tutorial.md#validations) の最小 10 文字に合わせて伸ばした `"A article."` を入れます。

> [!NOTE]
> [ステップ 12](tutorial.md#test) と同じく `cybertrain test` で実行します（2026-11-13 に測ったところ、チュートリアルのブログはこの時点で 83 テスト、870 アサーションです）。`examples/blog` にもこのステップが入っており、その JSON は `cover_*` のカラムを含みません（`Article#public_json`）。未対応のもの：1 つのフィールドに複数のファイル、S3 などのリモートストレージ、画像のバリアント、大きなボディをディスクへストリーミングすること（ボディ全体がメモリに読み込まれます。上限は `max_body_bytes`）。

<!-- step 19 #ship stage: 実行時 · `dist/blog` -->
## デプロイ用にビルドする

> [!WHY]
> ひとつのコマンドで、すべてのビューを埋め込んだ、デプロイ可能な `dist/` フォルダーにアプリをビルドします。

```shell ターミナル — blog/
cybertrain build
```

これは `dist/` を書き出します：すべてのビューを埋め込んだアプリのバイナリと、その横に置かれる、バイナリが使うファイルです。`SPIN_DEBUG=1 spin run gen -- --embed-views`、`spin build blog`、`SPIN_DEBUG=1 spin run gen`（失敗や Ctrl-C の後でも、コミット済みの空の `gen/views.rb` を元に戻します）を実行してから、次のものを組み立てます：

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>コンパイルされたフレームワーク、コントローラー、モデル、テンプレートインタプリタ。すべてのビューを埋め込み済み</span></li>
  <li><code>dist/public/</code><span>静的アセットとエラーページ。リバースプロキシに配信させてもよい</span></li>
  <li><code>dist/storage/</code><span>空の状態で作成。デフォルトでは SQLite のファイルを置く（再ビルドで空にされることはない）</span></li>
  <li><code>dist/tmp/</code><span>空の状態で作成（再ビルドで空にされることはない）</span></li>
</ul>

`dist/` を同じ OS と CPU のマシンにコピーし（バイナリはシステムの SQLite にリンクします）、そこで実行します。ビルドしたバイナリはデフォルトで本番環境として動きます（`CYBERTRAIN_ENV` で上書きできます）。`CYBERTRAIN_SECRET_KEY_BASE` を設定してください（`cybertrain secret` でも生成できます）。例：

```shell ターミナル — 本番ホスト
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` はバイナリに組み込まれたマイグレーションを適用し、`./blog db status` はその状態を表示します。ポートは `PORT` で設定します。シークレットは再起動をまたいで同じ値に保ってください：変更するとすべてのセッションが終了します。`./blog help` は、`worker`、`jobs`、`console`、`db backup` など、バイナリのほかのコマンドを一覧します。

`Cybertrain::Config` はまず環境変数を読み、`config/app.rb` がそれを上書きします。最初のデプロイで出会う変数は次のとおりです（すべての変数は[設定](configuration.md#configuration-and-environment-variables)にあります）：

<div class="table-scroll" role="region" aria-label="環境変数" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">変数</th><th scope="col">属性</th><th scope="col">デフォルト</th></tr></thead>
  <tbody>
    <tr><td data-label="変数"><code>CYBERTRAIN_ENV</code></td><td data-label="属性"><code>env</code></td><td data-label="デフォルト"><code>"development"</code>。<code>cybertrain build</code> で作ったバイナリでは <code>"production"</code>（ほかに <code>"test"</code>）</td></tr>
    <tr><td data-label="変数"><code>PORT</code></td><td data-label="属性"><code>port</code></td><td data-label="デフォルト"><code>3000</code></td></tr>
    <tr><td data-label="変数"><code>CYBERTRAIN_DATABASE</code></td><td data-label="属性"><code>database_path</code></td><td data-label="デフォルト"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="変数"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="属性"><code>secret_key_base</code></td><td data-label="デフォルト">本番環境では必須。dev/test では <code>tmp/secret_key</code> に自動生成される</td></tr>
    <tr><td data-label="変数"><code>SPINEL_WORKERS</code></td><td data-label="属性"><code>workers</code></td><td data-label="デフォルト"><code>1</code></td></tr>
    <tr><td data-label="変数"><code>CYBERTRAIN_HOST</code></td><td data-label="属性"><code>host</code></td><td data-label="デフォルト"><code>"127.0.0.1"</code>。<code>0.0.0.0</code> にするとすべてのインターフェースで待ち受ける（コンテナ向け）</td></tr>
    <tr><td data-label="変数"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="属性"><code>session_same_site</code></td><td data-label="デフォルト"><code>"Lax"</code>。<code>Strict</code> または <code>None</code> も可（<code>None</code> は常に <code>Secure</code> を付ける）。それ以外の値では起動時にサーバーが停止する</td></tr>
    <tr><td data-label="変数"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="属性"><code>session_partitioned</code></td><td data-label="デフォルト"><code>false</code>。<code>1</code> または <code>true</code> で <code>Partitioned</code>（と <code>Secure</code>）を付ける</td></tr>
  </tbody>
</table>
</div>

```ruby config/app.rb
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

<!-- list: points -->
- サーバーが話すのは素の HTTP/1.1 です：TLS と HTTP/2 には前段に nginx か Caddy を置いてください。本番環境ではセッション cookie が `Secure` になるので、HTTPS で配信してください（本番環境が本当に素の http である場合に限り、`c.session_secure = false` を `config/app.rb` で設定します）。そうしたプロキシの後ろでは、`CYBERTRAIN_FORCE_SSL=1` で http を https にリダイレクトし、`CYBERTRAIN_HOSTS` でアプリが応答するホスト名を指定します（[ホストと `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)）。
- サーバーのプロセスは、ステップ 14 と 15 のジョブ、定期タスク、ストリームのポーラーも実行します：プロセス 1 つでデプロイ全体が成り立ちます。`./blog worker` を使うと、ジョブを専用のプロセスに移せます（[プロセスの役割](background-and-operations.md#process-roles)）。
- 本番環境では、`CYBERTRAIN_SECRET_KEY_BASE` がないと起動を拒否します。
- 本番環境では例外に対して 500 を返し、素のエラーレスポンス（ルーターのプレーンテキストの 404、`head :not_found`、`render plain:`）は、`public/<status>.html` が存在すればそれに置き換えられます。`cybertrain new` は `404.html` と `500.html` を書き出します。
- `SIGTERM` を受けると新たな受け付けを止め、処理中のリクエストを完了させ、それらが終わった時点か、サーバーの `drain_timeout`（10 秒）が過ぎた時点で終了します。
- ファイル監視、CRuby プレビュー、再ビルドのループが本番環境で動くことはありません。実行中の `cybertrain server` は、`cybertrain build` が `tmp/cybertrain-build.lock` を保持している間、再生成も再起動も行いません。

`cybertrain new` は [Kamal 2](https://kamal-deploy.org) 用の設定も書き出します。`Dockerfile` は Ubuntu のビルドステージで `cybertrain setup` と `cybertrain build` を実行し、`dist/` を同じリリースの軽量なステージにコピーします。このイメージは起動時にマイグレーションを流してから `0.0.0.0:3000` で待ち受けます。ほかに `.dockerignore`、`config/deploy.yml`（前段に Let&rsquo;s Encrypt 付きの kamal-proxy、ヘルスチェックは `public/up.html`、SQLite のファイルは `/app/storage` のボリューム、そしてステップ 15 でコメントを外した `worker` ロール：同じイメージで `./blog worker` を実行する 2 つ目のコンテナです。`CYBERTRAIN_WORKER` が 0 でなければ web ロールもジョブを実行します）、`KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE` を環境変数から読む `.kamal/secrets` が作られます。`config/deploy.yml` の `CHANGE ME` の値を書き換えてコミットし、次を実行します：

```shell ターミナル — blog/
kamal setup    # 初回：サーバーに Docker と kamal-proxy を入れ、ビルド・push・起動する
kamal deploy   # 以降のデプロイ
```

バイナリはイメージの中でコンパイルされるので、OS は常にイメージと一致します。`config/deploy.yml` の `builder.arch` はサーバーの CPU に合わせてください。デプロイ先はサーバー 1 台です：データベースはそのサーバーのボリュームにある SQLite のファイルです。手順はバックアップも含めて [`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) の第 8 部にあります（英語版は [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)）。

完成版のアプリ [`examples/blog`](../../examples/blog#deploying-with-kamal) にも同じ設定が入っています。違いは 1 つだけです：リポジトリのフレームワークに対してビルドする（`spin.toml` の `path = "../.."`）ので、その `Dockerfile` は gem を入れずにチェックアウトから `cybertrain setup` と `cybertrain build` を実行し、ビルドコンテキストはリポジトリのルートです（`builder.context: ../..`。送る中身は `Dockerfile.dockerignore` でフレームワークとアプリだけに絞ります）。CI（[`blog-image.yml`](../../.github/workflows/blog-image.yml)）はリリースのたびにこのイメージをビルドし、ヘルスチェック、フォームからの記事の作成、正常な停止、ボリュームに残るデータベースを確かめ、`config/deploy.yml` を Kamal で読み込みます。

> [!NOTE]
> 各部品の組み合わせ方と、Kamal と Caddy の後ろのサーバーとの比較は、[デプロイのページ](site:deploy.html)にあります。

<!-- step + #things-to-know -->
## 知っておくこと

> [!WHY]
> 思わぬところでつまずく前に知っておきたい、制限とクセ。

<!-- list: points know -->
- セッションに保持できるのは String のみで、暗号化した cookie に入ります。
- データベースは SQLite のみで、Spinel の FFI を経由します。
- バックトレースはありません：エラーにはクラス、メッセージ、リクエスト行、テンプレート名と行番号が表示されます。
- ビュー内で属性名を書き間違えると例外になります（`undefined method 'titel' for Article`）。`nil` が入っているカラムは空としてレンダリングされます。
- 関連付けは外部キーか一行の宣言から作られます。`has_many :through`、入れ子の `includes`、enum、STI、ポリモーフィック関連付けはありません。
- `constraints` と `mount` はありません。JSON は `render json:` で返します（JSON のテンプレートはありません）。
- スキャフォールドで生成したモデルでは、最初の string フィールドにだけデフォルトで presence バリデーションが付きます。
- ジェネレーターは `app/controllers`、`app/models`、`app/helpers`、`app/components`、`app/jobs` に対して、パーサーではなく字句スキャン（正規表現）を使います。
- ジョブは少なくとも 1 回実行されます。ブロードキャストが届くのは、送信の時点で開いているページか、1 分以内に再接続したページだけです。
- ビューはビルド時に埋め込まれます：ビューだけの変更でも、本番環境に反映するには `cybertrain build` と再起動が必要です。
- `dist/` は、実行するマシンと同じ OS と CPU でビルドしてください：バイナリはシステムの SQLite にリンクします。
- `SPINEL_WORKERS` のデフォルトは `1` です。
- テスト済みなのは固定された Spinel のリリース（`Cybertrain::SPINEL_TAG`）だけです。
- Rails とのその他の違いは一つの表にまとめてあります：[Rails との違い](how-it-works.md#differences-from-rails)。

<!-- step → #where-next -->
## 次に読むもの

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — このチュートリアルを発展させたアプリとそのテスト。
- [**デプロイ**](site:deploy.html) — ビルドしたアプリが本番でどう動くか：Kamal、または Caddy の後ろの systemd。
- [**認証**](authentication.md) — パスワードリセット、確認、ロックアウト、ログインしたままにする、アカウントページ、管理者ユーザー。
- [**国際化**](i18n.md) — 辞書、`t` と `l`、リクエストごとのロケール。
- [**ガイド**](index.md) — トピックごとに 1 ページ：モデル、リクエスト、テンプレート、リアルタイム、バックグラウンド処理、テスト。
- [**GitHub の CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — ソースコード、README、リリース。
- [**API リファレンス**](site:api/index.html) — アプリが使うすべてのクラスとメソッドを、例とともに。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — スパイク（技術検証）と、そこで見つかったコンパイラの制約。
- [**Spinel**](https://github.com/matz/spinel) — matz による Ruby の AOT コンパイラ。
- [**CyberTrain ホーム**](site:index.html) — 概要、機能、仕組み。
