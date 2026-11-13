---
source_sha256: f3145c830eda9a57eec157b51d12cc95ae3bf37dfc06b4b2e4d7866e7f6b02c5
path: tutorial.html
title: "はじめよう：ブログを作る"
description: "Rails の Getting Started のブログ（コメント付きの記事）を CyberTrain で作ります：スキャフォールド、マイグレーション、ルーティングのネスト、Turbo によるコメントのライブ更新、ジョブ、Cybertrain::Test によるテスト、cybertrain build によるデプロイ用ビルド。"
og_title: "CyberTrain をはじめよう：ブログを作る"
og_description: "Rails 公式の Getting Started に沿った内容です：記事とコメントのあるブログを、Spinel 上の CyberTrain で作ります。"
og_image: tutorial.png
crumb: "チュートリアル"
nav: tutorial
toc_title: "ステップ 00–19"
meta:
  - term: "必要なもの"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3・zlib・OpenSSL のヘッダー（Spinel は自動でインストールされます） <a class="meta-link" href="#requirements">ステップ 00</a>'
  - term: "出発点"
    text: "`gem install cybertrain`"
  - term: "完成物"
    text: "`dist/blog`"
---

# はじめよう：ブログを作る

Rails 公式の [Getting Started](https://guides.rubyonrails.org/getting_started.html) に沿って、記事とコメントのあるブログを作ります。記事をスキャフォールドし、バリデーションを追加し、記事の下にコメントをネストし、新しいコメントを Turbo で開いているすべてのページに届け、バックグラウンドジョブをキューに入れ、JSON で応答し、アプリをプロセス内で動かすテストを書き、サインインを追加し、アップロードした画像を添付し、最後にアプリをデプロイ可能な `dist/` フォルダーにビルドします。このアプリを発展させたものが [`examples/blog`](../../examples/blog) で、Linux と macOS の CI で検証されています。


<!-- step 00 #requirements stage: 準備 · Ruby、`cc`、SQLite -->
## 必要なもの

> [!WHY]
> CyberTrain は Spinel を通じて C にコンパイルされるため、C ツールチェーンと SQLite のヘッダーが必要です。`cybertrain` コマンドは gem なので、Ruby が必要です。

<!-- list: checklist -->
- Ruby 3.2+ と RubyGems。`cybertrain` コマンドと、開発サーバーの CRuby プレビュー（Ruby の `fiddle` が必要です）に必要です。デプロイしたアプリケーションが CRuby 上で動くことはありません。Ruby 3.2 では `gem install prism` も実行します。
- Spinel の、CyberTrain が固定しているリリース（`cybertrain doctor` が表示します）。CyberTrain が必要とする修正を本家より先に取り込んだフォーク [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) のリリースです。他のバージョンでは未テストです。手動でインストールする必要はありません：Spinel を必要とする最初のコマンドが、そのリリースを `~/.cybertrain` にビルドします（数分、初回のみ）。ただし、そのリリースの `spinel` がすでに `PATH` 上にある場合は除きます。
- C ツールチェーン（`cc`、または `CC` で指定したコンパイラ）と `make`、さらに `git` と `curl`。すべてのプログラムを C にコンパイルする Spinel をビルドするために使います。
- SQLite 3、zlib、OpenSSL のヘッダーとライブラリ：Debian/Ubuntu では `libsqlite3-dev`、`zlib1g-dev`、`libssl-dev`。macOS では、SQLite と zlib は Xcode のコマンドラインツールに含まれ、OpenSSL は Homebrew から入れます（`brew install openssl@3` を実行し、[必要なもの](install.md#requirements)にある 2 つのパスを設定します）。

`cybertrain doctor` がこれらすべてを確認し、足りないものにはインストール用のコマンドを表示します。完全な一覧と、どれが任意か：[必要なもの](install.md#requirements)。Spinel がどこに置かれるか、別のインストールを使う方法：[Spinel のインストールの仕組み](install.md#how-spinel-is-installed)。

> [!NOTE]
> インストールできるマシンがない場合は、[プレイグラウンド](site:playground.html)を使えば、ステップ 02、03、04、07 を済ませたこのブログを GitHub Codespace で開けます。

<!-- step 01 #install stage: 準備 · `cybertrain` CLI -->
## CLI をインストールする

> [!WHY]
> `cybertrain` は、アプリの作成、リソースのスキャフォールド、マイグレーション、サーバーの起動、ビルドを行うコマンドです。

1 行目で RubyGems からインストールします。残りはチュートリアル全体を一望したもので、以降のステップでは 1 コマンドずつ進めます。

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">ターミナル &mdash; 任意のディレクトリ、その後 blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="コード：ターミナル &mdash; 任意のディレクトリ、その後 blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># 初回は Spinel をインストール（数分）</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># 本番用: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

[すべてのコマンド](install.md#the-cybertrain-command)とそのオプションは、インストールのガイドに一覧があります。

<!-- step 02 #new-app stage: 自分で書く · `blog/` -->
## アプリケーションを作成する

> [!WHY]
> Rails のディレクトリ規約に加えて、3 つの `bin/` プログラムが手に入ります：`bin/blog.rb`（アプリ本体）、`bin/gen.rb`（ジェネレーター）、`bin/db.rb`（開発用のマイグレーション）。

```shell ターミナル — 任意のディレクトリ
cybertrain new blog
cd blog
```

`cybertrain new` はアプリケーションを書き出します。その `spin.toml` は CLI と一致するリリースを指しています（X.Y.Z は `cybertrain version` が表示するもの）：

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }
```

次に Spinel がインストールされていることを確認し（初回は固定された Spinel のリリースを `~/.cybertrain` にビルドします：数分、初回のみ。[ステップ 00](#requirements) を参照）、`spin lock`（spin がフレームワークをキャッシュ `~/.cache/spin/packages/` に取得し、コミットを `spin.lock` に固定します）と `SPIN_DEBUG=1 spin run gen`（gen は spin のデバッグモードでビルドされます）を実行します。`rails new` が `bundle install` を実行するのと同じようなもので、これで `cybertrain server` がすぐに動きます。最後に次の手順を表示して終わります。フレームワークのファイルはアプリに一切コピーされません。`spin.toml` と `spin.lock` をコミットしてください。

> [!NOTE]
> Spinel のインストールか、2 つの `spin` ステップのいずれかが失敗した場合、ファイルは残したまま `new` は終了コード 1 で終了し、原因を解消した後に実行すべきコマンドを表示します（Spinel の場合：`cybertrain setup` を実行し、続いて新しいディレクトリで `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen`）。`--skip-spin` はファイルを書き出すだけです。`--path DIR` は代わりにローカルのチェックアウトに依存し、`--git URL [--ref R]` は URL にあるフレームワーク（ブランチまたはタグ R）に、`--version V` は `cybertrain` が `spin-index` に登録された後、インデックスのバージョンに依存します。

アプリ名には英小文字、数字、`_` を使い、先頭は英字にします。生成されるツリー：

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb  config/locales/en.yml  .env.example
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/  app/jobs/
  app/assets/stylesheets/application.css  app/assets/images/
  app/javascript/application.js  config/importmap.rb
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/  .github/workflows/ci.yml
  Dockerfile  config/deploy.yml  .kamal/secrets
```

`bin/blog.rb` はアプリケーション唯一のエントリーポイントで、`spin build blog` がコンパイルするプログラムです：`./blog` でサーバーを起動し、`./blog migrate` と `./blog db status` でデータベースを管理します。`bin/gen.rb` はジェネレーターを実行し（`spin run gen`）、`bin/db.rb` は開発中にマイグレーターを実行します（`cybertrain db migrate` がこれを使います。最初のマイグレーションで `gen/models/` が生成されるまで、`bin/blog.rb` はコンパイルできないためです）。`gen/` にはすでに `spin run gen` が書き出したものが入っています。そのひとつが `views.rb` で、これはコミットされる、空の埋め込みビューのテーブルです。

レイアウトは `stylesheet_link_tag` で `app/assets/stylesheets/application.css` を読み込み、`javascript_importmap_tags` で `config/importmap.rb` のインポートマップを通じて `app/javascript/application.js` を読み込みます。`spin run gen` がこの 2 つをダイジェスト付きで `public/assets/` に書き出し、そこは git の管理から外してあります（[アセット](assets.md)を参照）。`.env.example` にはアプリが読む環境変数の一覧があり、`.github/workflows/ci.yml` は GitHub 上でテストを実行します（[継続的インテグレーション](testing.md#continuous-integration)）。ツリーの最後の行は [ステップ 19](#ship) の Kamal 用の設定です。

`ApplicationController` は最初は次のようになっており、レコードが見つからない場合は `rescue_from` によって 404 になります：

```ruby app/controllers/application_controller.rb
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

<!-- step 03 #scaffold-article stage: 自分で書く · `app/`, `db/migrate/` -->
## 記事をスキャフォールドする

> [!WHY]
> ひとつのコマンドで、CRUD 一式を Rails 流に書き出します。

```shell ターミナル — blog/
cybertrain generate scaffold article title:string body:text
```

マイグレーション、モデル、コントローラー、5 つのビュー（`index`、`show`、`new`、`edit`、`_form`）、フィクスチャのファイルとテスト（[ステップ 16](#test)）を書き出し、`config/routes.rb` に `resources :articles` を挿入します。フィールドの型は `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime`、`references`、`attachment`（アップロードされたファイル。[ステップ 18](#attachments)）で、デフォルトは `string` です。クイックスタートの `cybertrain g scaffold` も同じコマンドです。

> [!NOTE]
> 既存のファイルが上書きされることはありません：各ファイルは `create`、`identical`、`exist` のいずれかとして報告されます。

<!-- step 04 #root-route stage: 自分で書く · `config/routes.rb` -->
## root ルートを設定する

> [!WHY]
> `/` で記事一覧を表示するためです。

```ruby config/routes.rb
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!NOTE]
> ルーティングはビルド時に読み込まれます：`spin run gen` がそれを `gen/routes.rb` に変換します。`cybertrain server`、`cybertrain db migrate`、`cybertrain build` がこれを代わりに実行します。

<!-- step 05 #validations stage: 自分で書く · `app/models/` -->
## モデルにバリデーションを追加する

> [!WHY]
> Rails ガイドと同じように、長さのバリデーションを手で追加します。

```ruby app/models/article.rb
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` にはスーパークラスを書きません：スーパークラスの `Cybertrain::Model`、カラム、ファインダーは `gen/models/article.rb` から来ます。保存に失敗すると、「Title can't be blank」（タイトルは空にできません）、「Title has already been taken」（タイトルはすでに使われています）、「Body is too short (minimum is 10 characters)」（本文が短すぎます。最小 10 文字）のようなメッセージが報告されます。ほかのバリデーター（`format`、`inclusion`、`numericality` など）は[バリデーション](models.md#validations)にあります。

<!-- step 06 #articles-controller stage: 自分で書く · `app/controllers/` -->
## ArticlesController

> [!WHY]
> 完全な CRUD で、Strong Parameters やフラッシュを設定してからのリダイレクトに至るまで Rails 流です。ただし、Spinel がどこでも強制する 2 つの点だけは異なります。

```ruby app/controllers/articles_controller.rb
# app/controllers/articles_controller.rb (index/show/edit are as plain as
# Rails' own scaffold; update mirrors create)
class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  def new_action   # a `new` method would shadow ArticlesController.new
    @article = Article.new
  end

  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = "Article was successfully created."
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
```

> [!RULE] Spinel のルール：new_action
> ### `new` ではなく `new_action`
>
> 文字どおり `new` という名前のメソッドは、フレームワークがコントローラーの生成に使う `ArticlesController.new(ctx)` を覆い隠してしまいます。ルート `GET /articles/new` は引き続きこのメソッドに対応し、変えるのはメソッド名だけです。ビューは `new.html.erb` のままで、`render :new` も変わりません。

> [!RULE] Spinel のルール：コールバック
> ### コールバックはコントローラーを明示的に受け取る
>
> 保存したブロックに対する `instance_exec` がないため、ブロックのコールバックはコントローラー（またはレコード）を引数として受け取ります：`before_action { |c| c.do_thing }` と書き、`before_action { do_thing }` とは書きません。アクションとコールバックはリテラルの名前で呼び出され、`send` は決して使われません。

スキャフォールドは `index`、`show`、`edit`、`update`、`destroy` も含めたコントローラー全体を書き出しますが、上の抜粋では省略しています。`index` では `@articles = Article.all.to_a` と書きます：この `.to_a` は必須です。

> [!NOTE]
> インスタンス変数は `@ivar =` の字句スキャンで見つけるため、追加したら `cybertrain spin run gen` を再実行してください。開発サーバーはこれを自動で行います。

<!-- step 07 #run stage: ビルド時、次に実行時 · `gen/` &rarr; `build/bin/blog` -->
## 生成、マイグレーション、実行

> [!WHY]
> スキーマとルーティングを `gen/` に変換し、SQLite データベースを作成して、サーバーを起動します。

```shell ターミナル — blog/
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen（gen と db はデバッグモード）
cybertrain server        # http://127.0.0.1:3000。Ruby の編集はまず CRuby ですぐに反映され、その後コンパイル版に。ビューはどちらも不要
```

`spin run gen` は `db/schema.rb` と `config/routes.rb` を読み、`app/` をスキャンして `gen/` を書き出します。`spin run db -- migrate` は `db/migrate/*.rb` を適用して `db/schema.rb` を書き換えます。順序が重要です：1 回目の `spin run gen` は新しいマイグレーションを `gen/migrations.rb` に入れ（これを `bin/db.rb` が require します）、2 回目は書き換えられた `db/schema.rb` からモデルを構築します。

`cybertrain server` は 1 秒以内に CRuby からアプリを配信し、バックグラウンドで Spinel によるビルドを行います。最初のビルドはアプリ全体をコンパイルするので数分かかります。それが終わるまでは CRuby のプレビューが応答し、どのページも右下隅でそのことを示します：

```text 出力 — cybertrain server
=> Booting cybertrain X.Y.Z
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> preview: CRuby (0.5s)
```

ビルドが終わるとサーバーは `=> spinel: ready in …s; serving the compiled binary` と表示し、それ以降はコンパイル済みのバイナリが応答します。Ruby を編集すると `Changed` とファイル名を表示し、すぐに CRuby から応答し直して、もう一度ビルドします（[開発ループ](how-it-works.md#the-development-loop)）。Ctrl-C で止まります。

<!-- list: points -->
- スキーマ、ルーティング、コントローラーやモデルのコールバックとインスタンス変数、ヘルパー・コンポーネント・ジョブ、アセットのいずれかを変更したら、`cybertrain spin run gen` を再実行して `gen/` をコミットしてください。開発サーバーはこれを自動で行います。`cybertrain spin run gen -- --check` は、何も書き込まずに、古くなっているファイルを一覧します。
- ポートは `cybertrain server 4000`（または `PORT=4000`）で変更できます。
- `cybertrain db` は、`--`（`spin run db` が引数の前に必要とするもの）を補います。`cybertrain db status` などのデータベースコマンドも同じように動きます。

> [!RULE] Spinel のルール：コンソールは Ruby ではない
> ### コンソールは Ruby ではない
>
> `rails console` にそのまま相当するものはありません：Spinel には `eval` がないからです。`cybertrain spin run blog -- console`（ビルド後は `./blog console`）は、`Article.where(title: "x").count` のようなテンプレートの式をモデルに対して評価し、`dbconsole` は `sqlite3` を開きます（[コンソール](background-and-operations.md#the-console)）。Ruby の変更には再ビルドが必要です：開発環境では `cybertrain server` が CRuby のプレビューからすぐに応答し、ビルドが終わるとコンパイル済みのバイナリにポートを引き渡します。開発環境ではビューはリクエストごとにディスクからパースされるので、ビューの編集に再ビルドは不要です。本番用には `cybertrain build` がビューを埋め込みます。

<!-- step 08 #scaffold-comment stage: 自分で書く · `db/migrate/`, `app/` -->
## コメントをスキャフォールドする

> [!WHY]
> `references` 型によって、関連付けの元になる外部キーが作られます。

```shell ターミナル — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # スキャフォールドが comments テーブルのマイグレーションを書き出している
```

`article:references` は `article_id` カラム、インデックス、外部キーを追加します — `Article`/`Comment` の関連付けにはこれで十分です。`spin run gen` が外部キーから `Article#comments` と `Comment#article` を読み取ります。生成されるスキーマ：

```ruby db/schema.rb（抜粋）
  s.create_table "comments" do |t|
    t.string "commenter"
    t.text "body"
    t.integer "article_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"

  s.add_foreign_key "comments", "articles", column: "article_id"
```

スキャフォールドは独立した `resources :comments` の行を挿入しますが、これは次のステップで置き換えます。

> [!NOTE]
> `cybertrain server` を動かしたままにしていると、スキャフォールドが書き出したファイルを、まだテーブルがないうちにすぐ取り込みます。新しい `Comment` モデルのカラムは `gen/models/comment.rb` から来ますが、gen はテーブルが `db/schema.rb` に入って初めてこのファイルを書くので、CRuby のプレビューはモデルを読み込めません（`NoMethodError`）：サーバーはエラーを示す自前の 503 のページで応答し、Spinel のビルドも失敗します。`cybertrain db migrate` が `db/schema.rb` を書き換えると、サーバーは再び応答するようになります。

> [!EXAMPLE] コメントのある記事を削除する
> ### コメントのある記事を削除する
>
> 外部キーは、まだコメントのある記事の削除を拒みます。Rails と同じく関連付けを宣言すれば、`destroy` が自分のトランザクションの中で先にコメントを削除します：
>
> ```ruby app/models/article.rb（抜粋）
>   # each comment's own destroy runs, callbacks included
>   has_many :comments, dependent: :destroy
> ```

<!-- step 09 #nested-routes stage: 自分で書く · `config/routes.rb` -->
## ルーティングをネストする

> [!WHY]
> Rails ガイドではコメントを記事の下にネストしています。

```ruby config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper explicitly (Spinel's instance_eval
  # trampoline only rewires `self` for the outermost block): `articles.resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] Spinel のルール：明示的なマッパー
> ### ネストしたブロックはマッパーを明示的に受け取る
>
> `resources :articles do |articles|` と `articles.resources :comments` のように書き、裸の `resources :comments` とは書きません。Spinel の `instance_eval` トランポリンが `self` を差し替えるのは、最も外側のブロックだけだからです。

<!-- step 10 #comments-controller stage: 自分で書く · `app/controllers/` -->
## CommentsController

> [!WHY]
> 到達できるアクションは 2 つだけです。親の記事は URL（`params[:article_id]`）から取り出し、`:id` は使いません。

```ruby app/controllers/comments_controller.rb
class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    if @comment.save
      flash[:notice] = "Comment was successfully created."
    else
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
    end
    redirect_to article_path(@article), status: :see_other
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    @comment.destroy
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:commenter, :body)
  end
end
```

次に、コメントのモデルにバリデーションを追加します：

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true

  belongs_to :article
end
```

宣言した `belongs_to` は、記事のないコメントも、データベースが拒む前に無効にします（「Article can't be blank」）。

> [!NOTE]
> `Article#comments` はコメントのリレーションなので、Rails の `@article.comments.find(params[:id])` が `destroy` でそのまま使えます。別の記事に属するコメントを指定すると 404 が返ります。

<!-- step 11 #views stage: 実行時 · `app/views/`（開発環境ではディスクから読み込み、`cybertrain build` で埋め込み） -->
## ビューとパーシャル

> [!WHY]
> 記事のページにはコメントの一覧を表示し、最後に `[@article, @comment]` に結び付いたフォームを置きます。

まず、もう到達できなくなったコメントのビュー `index`、`show`、`new`、`edit` を削除し、`ArticlesController#show` に空の `@comment` を用意します：

```ruby app/controllers/articles_controller.rb（抜粋）
  def show
    @comment = Comment.new
  end
```

次に、記事のページの末尾でコメントとフォームをレンダリングし、スキャフォールドが書き出したコメントのフォームを置き換えます：

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<h2>Comments</h2>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>

<h2>Add a comment:</h2>
<%= render "comments/form", comment: @comment %>

<%# app/views/comments/_form.html.erb %>
<%# locals: (comment:) %>
<%= form_with(model: [@article, comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

コメントのパーシャル：

```erb app/views/comments/_comment.html.erb
<%# locals: (comment:) %>
<div class="comment">
  <p>
    <strong>Commenter:</strong>
    <%= comment.commenter %>
  </p>

  <p>
    <strong>Comment:</strong>
    <%= comment.body %>
  </p>

  <%= button_to "Destroy comment", [@article, comment], method: :delete %>
</div>
```

### フォームとボタンの送信先

`button_to ... [@article, comment]` と `form_with(model: [@article, comment])` はどちらも同じ `[parent, child]` のルールで解決されます：新しい子はネストしたコレクション（`article_comments_path`）に、保存済みの子はネストしたメンバー（`article_comment_path`）にルーティングされます。どちらも上のネストした `resources` ブロックから `gen/routes.rb` に生成されます。フォームはコメントをローカル変数として受け取ります。[ステップ 13](#turbo) で、新しいコメントを渡してもう一度レンダリングできるようにするためです。

> [!RULE] ビューは閉じた文法
> ### ビューは Ruby ではなく、閉じた文法
>
> Spinel には `eval` がないため、テンプレートは固定の文法に従って解釈されます。`link_to` には `method:` オプションがないので、`button_to` を使ってください。`each` が受け取るブロック引数は 1 つか 2 つです。`<%# locals: (comment:) %>` のような strict locals コメントではデフォルト値を指定できません。パーシャルは呼び出し元の環境のコピーを受け取るので、`@article` は `comments/_form` の中からも見えます。

> [!EXAMPLE] コメント数と日付フィルターのある一覧
> ### コメント数と日付フィルターのある一覧
>
> examples/blog は新しい記事から順にコメント数とともに一覧し（記事がいくつあってもクエリは 2 回）、日付で絞り込みます：
>
> ```ruby app/models/article.rb（抜粋） · app/controllers/articles_controller.rb（抜粋）
>   scope :recent, -> { order(created_at: :desc) }
>
>   def index
>     articles = Article.recent.includes(:comments)
>     from = Cybertrain::Cast.date_or_nil(params[:from])   # nil unless YYYY-MM-DD
>     unless from.nil?
>       articles = articles.where_between(:created_at, Time.utc(from.year, from.month, from.day), nil)
>     end
>     @articles = articles.to_a
>   end
> ```
>
> ビューの `article.comments.size` は先読みしたコメントから答えます。Rails の `where(created_at: from..)` はここでは `where_between` です。Spinel は Time の Range を作れないからです（[条件と検索](models.md#conditions-and-finders)）。

<!-- step 12 #component stage: 自分で書く · `app/components/`, `app/helpers/` -->
## コンポーネントとヘルパー

> [!WHY]
> 次のステップから、コメントは 2 か所でレンダリングされます：ページの中と、背後にリクエストのないブロードキャストの中です。コンポーネント（テンプレートを横に置いたクラス）はどちらでも同じようにレンダリングされます。ヘルパーは、どのテンプレートからも呼べるメソッドです。

```shell ターミナル — blog/
cybertrain generate component comment comment   # 名前、続いて属性：ここでは 1 つで、これも comment
cybertrain generate helper comments
```

1 つ目は、属性ごとにキーワード引数を 1 つ持つ `app/components/comment_component.rb` とそのテンプレートを書き出し、2 つ目は空の `CommentsHelper` を書き出します。どちらもテストを 1 つ書き出しますが、これは [ステップ 16](#test) で扱います。クラスはすでに、このブログに必要な形になっています：

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

<!-- step 13 #turbo stage: 実行時 · Server-Sent Events 上の Turbo Streams -->
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

<!-- step 14 #job stage: 自分で書く · `app/jobs/` -->
## バックグラウンドジョブ

> [!WHY]
> 通知のように、レスポンスを待たせるべきでない処理は、レスポンスの後に実行します。Solid Queue 上の Active Job と同じく、ジョブは `app/jobs/` のクラスであり、アプリケーション自身のデータベースの 1 行です：ほかのサービスは要りません。

```shell ターミナル — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

オプションで指定した `retry_on` の行と空の `perform` を持つ `app/jobs/notify_comment_job.rb` と、テストを書き出します。`perform` の中身を書いてください。ここではログを出すだけですが、実際のアプリケーションならメールを送るところです：

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

コメントを投稿すると、サーバーのログから、ジョブがレスポンスの後に実行されたことが分かります：

```text 出力 — cybertrain server
[INFO] Started POST "/articles/1/comments" for 127.0.0.1
[INFO] Completed 200 in 2ms
[INFO] new comment 1 on article 1
[INFO] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` は `perform_later` に渡した Hash で、JSON として保存され、String のキーで読み戻されます：レコードではなく id を渡し、値は `Cybertrain::Cast` で絞り込んでください。`perform_in(seconds, args)` と `perform_at(time, args)` は、後で実行するようにキューに入れます。
- ジョブは `cybertrain_jobs` の行で、サーバーのプロセスの 3 本のジョブスレッドが実行します。`./blog worker` で起動した別のプロセスに実行させることもできます（[プロセスの役割](background-and-operations.md#process-roles)）。
- `retry_on StandardError, wait: 30, attempts: 3` は、失敗した実行を 30 秒後にもう一度キューに入れ、試行は全部で 3 回です。それでも失敗した行は `failed` になり、残されます（[再試行と破棄](background-and-operations.md#retries-and-discards)）。
- ジョブは 2 回以上実行されることがあります（実行の途中でプロセスが落ちると、そのジョブはもう一度実行されます）。`perform` は繰り返しても安全なように書いてください。
- 失敗したジョブの一覧・再試行・破棄は、`./blog jobs` か、`config/routes.rb` にコメントアウトされている `jobs_page` の行を有効にするとマウントされるページ（ステップ 04 と 09 のルートはこの行を残しています）で行います（[ジョブページ](background-and-operations.md#the-jobs-page-and-the-jobs-command)）。

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

<!-- step 15 #json stage: 自分で書く · `app/controllers/` -->
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

<!-- step 16 #test stage: ビルド時 · `cybertrain test` -->
## テストする

> [!WHY]
> minitest や RSpec はリフレクションでテストを見つけますが、事前（AOT）コンパイラーにはそれができません。それでもテストは Rails のクラスです：`spin run gen` がそれらを 1 つのプログラムに書き換え、`cybertrain test` がコンパイルして実行します。

### ジェネレーターが書いたもの

ステップ 03 と 08 のスキャフォールドは Rails のスキャフォールドのテストを書き出しました：`test/fixtures/articles.yml` と `comments.yml`（各テストが最初に持つ `one` と `two` の行）、`test/models/article_test.rb` と `comment_test.rb`（「the fixture is valid」）、そして `test/controllers/articles_controller_test.rb` と `comments_controller_test.rb`（アクションごとに 1 つのリクエスト）。ステップ 12 は `test/components/comment_component_test.rb` と `test/helpers/comments_helper_test.rb` を、ステップ 14 は `test/jobs/notify_comment_job_test.rb` を書き出し、`cybertrain new` は各ファイルが読み込む `test/test_helper.rb` と、`/up` へのリクエストである `test/integration/health_test.rb` を書き出しました。そのうち 3 つは、その後に育ったブログに合わせる必要があります。

### バリデーションを通るフィクスチャ

スキャフォールドの見本の値（`MyString`、`MyText`）は[ステップ 05](#validations) の検査に落ちます：同じタイトルの記事が 2 つあり、本文は 10 文字に足りません。記事に本物の値を与えます：

```yaml test/fixtures/articles.yml
one:
  title: Hello Rails
  body: I am on Rails! This is my first article.

two:
  title: Second article
  body: Another article, with no comments.
```

作成のテストはフィクスチャ自身のタイトルを送りますが、それはもう使われています。新しいタイトルを与えます：

```ruby test/controllers/articles_controller_test.rb（抜粋）
  test "should create article" do
    assert_difference(-> { Article.count }, 1) do
      post articles_url, params: { article: { body: @article.body, title: "A new title" } }
    end

    assert_redirected_to article_url(Article.last)
  end
```

`comments.yml` の行は `article: one` に属します。Rails と同じく、記事を指すフィクスチャがあるとその記事は削除できません。そのため、`Article` が `has_many :comments, dependent: :destroy` を宣言していなければ（[ステップ 08](#scaffold-comment) の最後の囲み）、「should destroy article」は外部キーで失敗します。まだなら、examples/blog と同じく `app/models/article.rb` に加えてください：

```ruby app/models/article.rb（抜粋）
  has_many :comments, dependent: :destroy
```

### 記事の下のコメント

スキャフォールドのコメントのテストは、[ステップ 09](#nested-routes) で記事の下に入れ子にしたルートをリクエストします。そのヘルパーはいまは `article_comments_path` と `article_comment_path` です。テストを置き換えます：

```ruby test/controllers/comments_controller_test.rb
require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  test "a comment is added to its article" do
    article = articles(:one)
    assert_difference(-> { Comment.count }, 1) do
      post article_comments_path(article), params: { comment: { commenter: "Dave", body: "First!" } }
    end
    assert_redirected_to article_path(article)
  end

  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end

  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

テストはジョブのスレッドを動かさないので、キューに入ったジョブはテストが実行するまで待ちます（`perform_enqueued_jobs`）。リクエスト偽造対策は Rails と同じくテストでは無効なので、`post` にトークンは要りません。

### コンポーネント

ステップ 12 のテストは、テンプレートがいまはコメントを期待しているところに String を渡して `CommentComponent` をレンダリングします。代わりにフィクスチャのコメントをレンダリングします：

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` はブロードキャストと同じく、リクエストなしでレンダリングし、`assert_select` はレンダリングされたものを読みます。ほかのアサーションは[アプリをテストする](testing.md#assertions)、[ジョブのテスト](testing.md#testing-jobs)、[ストリームとコンポーネントのテスト](testing.md#testing-streams-and-components)にあります。

### テストを実行する

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

最初の実行はすべてのテストを 1 つのプログラムにコンパイルするので、数分かかります（examples/blog の 149 テストは 4 vCPU のクラウドマシンで約 9 分）。何も変えていなければ、次の実行でテストのプログラムはコンパイルし直されません。gen を 1 回ビルドし直すことはあり（`build gen`、数秒）、そのあとは 1 秒よりずっと短い時間で始まります。ファイルや `-n` はどのテストを実行するかを選ぶもので、何をコンパイルするかは変えません：どのテストを編集しても、プログラムはコンパイルし直されます。ファイルごとに見出し、テストごとに 1 行（`ok`、または `FAIL` と `ERR` にテストの行とメッセージ）、最後に合計が出ます。その間には、テスト対象のコードが自分で出力したもの（たとえばコマンドの出力行）も混じります。失敗したテストがあれば終了ステータスは 1 です。2026-11-13 に測ったところ、このステップのチュートリアルのブログは 17 テスト、25 アサーションです。

> [!NOTE]
> 各テストの前にすべてのテーブルが空になり、フィクスチャが入れ直されるので、テストはお互いに依存しません。`gen/tests.rb` と `gen/test/` は生成されるもので、`gen/` のほかの部分と一緒にコミットします。

<!-- step 17 #authentication stage: 自分で書く · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## サインインを追加する

> [!WHY]
> ここまでは誰でも記事を編集・削除できます。Rails 8 の `bin/rails generate authentication` と同じく、ひとつのコマンドでメールアドレスとパスワードによるサインインを追加します。エンジンとして組み込むのではなく、アプリが所有するコードとして書き出します。

```shell ターミナル — blog/
cybertrain generate authentication
cybertrain db migrate    # users と sessions のテーブルを作る
```

`users` と `sessions` のマイグレーションとモデル、`ApplicationController` にインクルードする `Authentication` コンサーン、サインイン・サインアップ・パスワードリセット・アカウントページのコントローラーとビュー、メーラー、`./blog user` コマンド、そしてテストを書き出します。さらにルート、レイアウトの先頭の `sessions/_nav` パーシャル、メール中のリンクの始まりになる `config/app.rb` の `base_url` 設定を加えます。すべてのファイルは [認証](authentication.md#generating-it) に一覧があります。

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

> [!RULE] Spinel のルール：has_secure_password
> ### `has_secure_password` は書き下される
>
> Spinel は実行時にメソッドを定義できないため、`User` モデルには `has_secure_password` が定義するはずのもの、つまり `password=`、`authenticate`、`User.authenticate_by(email_address:, password:)` がそのまま書かれています。パスワードは `Cybertrain::Password` でハッシュ化されます。Ruby で書かれた PBKDF2-HMAC-SHA256 で、既定は 10 万回反復（コンパイル後で約 0.2 秒）です。bcrypt を使うと、バイナリが C ライブラリをリンクする必要があるためです。コストは `config/app.rb` に `Cybertrain::Password.iterations = 600_000` と書いて引き上げられ、`User#authenticate` が各ユーザーのサインイン時にハッシュを作り直します。

### テストを更新する

[ステップ 16](#test) のテストのうち、フォームを開くもの、フォームを送信するもの、`index` と `show` 以外のアクションに届くものは、いまはサインインのページに行き当たります。ジェネレーターは `test/fixtures/users.yml`（`one` と `two`。パスワードは `"password"`）と `test/support/session_test_helper.rb` を書き出しており、`test/test_helper.rb` がその `sign_in_as` をいまはすべての統合テストに与えます。記事のテストの `setup` には、ジェネレーターがサインインをすでに加えています（`insert test/controllers/articles_controller_test.rb (sign_in_as users(:one))` と表示されます）。次のようになっているはずです：

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

画像は記事のページに表示されます。このページはステップ 17 から訪問者も読めるので、画像のダウンロードも訪問者に開いておく必要があります。ジェネレーターを実行する前に、ステップ 17 で書いたリストに `:cover` を加えます：

```ruby app/controllers/articles_controller.rb（抜粋）
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell ターミナル — blog/
cybertrain generate attachment article cover   # 新しいモデルなら: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # articles に cover_* のカラムを追加する
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

ダウンロードは `show` と同じく `set_article` を通して記事を見つけるので、`set_article` がユーザーに見せる記事を制限しているなら、その制限はダウンロードにも及びます。この `show` には独自のコードがあるので、ジェネレーターは出力の中で警告を表示します：

```text 出力 — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

ここでは、そのコードはコメントを用意してフォーマットを選ぶだけで、誰の閲覧も拒みません。したがって `cover` に写すものはありません。

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
> ジェネレーターは `show` のアクセスルールをダウンロードに写しますが、写すのは読み取れるもの、つまりコールバックだけです。`set_article` 以外の `before_action` が、新しいアクションを含まずに `:show` を挙げていると、`cannot preserve show's authorization for :cover` と表示して止まり、何も書き出しません。`def show` の中のコードは、何を確かめているのかを読み取れません。警告が出るのはそのためです。`show` が空なら、`:show` が挙がっている `allow_unauthenticated_access` にジェネレーターが自分で `:cover` を加えます。`show` にコードがあるとその行には手を付けず、そこに `:cover` がなければ画像にはサインインが必要になります。

> [!RULE] Spinel のルール：has_one_attached
> ### `has_one_attached` は書き下される
>
> Spinel は実行時にメソッドを定義できない（`define_method` がない）ため、`has_one_attached` も、共有の添付テーブルもありません。ジェネレーターは、それが定義するはずのものを、フィールド名にちなんだメソッドとして `Article` に書き下し、メタデータは `articles` の 5 つのカラムに入れます。これらは `NOT NULL` で、`""` と `0` が「添付なし」を表します。NULL を許すカラムでは Spinel の型推論が効かなくなるためです。SQLite に入るのはメタデータだけ（テキスト値は NUL バイトで途切れます）で、バイト列はファイルとして保存されます。

### ファイルの配信方法

<!-- list: points -->
- **種類。**既定では 2 MB までの PNG、JPEG、GIF、WebP だけを受け付けます（モデルの `COVER_TYPES` と `COVER_MAX_BYTES`。`--any` を付けるとどの種類も受け付けます）。種類はファイルの先頭バイトから判定し、ブラウザーが送ってきた値は使いません。
- **保存。**バイト列は `storage/uploads/<2 hex>/<32 hex key>` に書き込まれます（`Cybertrain::BlobStore`、パーミッション 0600）。ファイルを差し替えると古いファイルは削除され、記事を削除するとそのファイルも削除されます。`storage/uploads/` は SQLite のファイルと一緒にバックアップしてください。
- **配信。**ファイルはコントローラーの `send_blob` 経由で返し、`public/` からは返しません。4 種類の画像はそのまま表示され、それ以外はダウンロードになります（`application/octet-stream`）。すべてのレスポンスに `X-Content-Type-Options: nosniff` と `Content-Security-Policy: default-src 'none'; sandbox` が付きます。
- **パラメーター。**`params.nested(:article).upload(:cover)` は `Cybertrain::UploadedFile` を返し、ファイルが選ばれていなければ nil です。`permit` はファイルを返さないので、ファイルはこの明示的な 1 行を通ってしか入ってきません。CSRF トークンは、通常のフォームと同じように multipart のボディからも読み取られます。壊れたボディやサイズ超過のボディは 400 になります。上限は `config/app.rb` の `max_upload_bytes` と `max_multipart_parts` で、保存先のディレクトリは `upload_root` で設定します。

サーバーを起動し、記事を編集して画像を選びます。ジェネレーターは `test/integration/article_cover_attachment_test.rb` と画像 `test/fixtures/files/cover.png` も書き出しています。このテストは一連の流れ全体を確かめ、アプリに `User` があるので最初にサインインします。ここでは `:cover` が公開されているので、訪問者がカバー画像をダウンロードできることを確かめます。本文には、[ステップ 05](#validations) の最小 10 文字に合わせて伸ばした `"A article."` を入れます。

> [!NOTE]
> [ステップ 16](#test) と同じく `cybertrain test` で実行します（2026-11-13 に測ったところ、チュートリアルのブログはこの時点で 83 テスト、870 アサーションです）。`examples/blog` にもこのステップが入っており、その JSON は `cover_*` のカラムを含みません（`Article#public_json`）。未対応のもの：1 つのフィールドに複数のファイル、S3 などのリモートストレージ、画像のバリアント、大きなボディをディスクへストリーミングすること（ボディ全体がメモリに読み込まれます。上限は `max_body_bytes`）。

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
- サーバーのプロセスは、ステップ 13 と 14 のジョブ、定期タスク、ストリームのポーラーも実行します：プロセス 1 つでデプロイ全体が成り立ちます。`./blog worker` を使うと、ジョブを専用のプロセスに移せます（[プロセスの役割](background-and-operations.md#process-roles)）。
- 本番環境では、`CYBERTRAIN_SECRET_KEY_BASE` がないと起動を拒否します。
- 本番環境では例外に対して 500 を返し、素のエラーレスポンス（ルーターのプレーンテキストの 404、`head :not_found`、`render plain:`）は、`public/<status>.html` が存在すればそれに置き換えられます。`cybertrain new` は `404.html` と `500.html` を書き出します。
- `SIGTERM` を受けると新たな受け付けを止め、処理中のリクエストを完了させ、それらが終わった時点か、サーバーの `drain_timeout`（10 秒）が過ぎた時点で終了します。
- ファイル監視、CRuby プレビュー、再ビルドのループが本番環境で動くことはありません。実行中の `cybertrain server` は、`cybertrain build` が `tmp/cybertrain-build.lock` を保持している間、再生成も再起動も行いません。

`cybertrain new` は [Kamal 2](https://kamal-deploy.org) 用の設定も書き出します。`Dockerfile` は Ubuntu のビルドステージで `cybertrain setup` と `cybertrain build` を実行し、`dist/` を同じリリースの軽量なステージにコピーします。このイメージは起動時にマイグレーションを流してから `0.0.0.0:3000` で待ち受けます。ほかに `.dockerignore`、`config/deploy.yml`（前段に Let&rsquo;s Encrypt 付きの kamal-proxy、ヘルスチェックは `public/up.html`、SQLite のファイルは `/app/storage` のボリューム）、`KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE` を環境変数から読む `.kamal/secrets` が作られます。`config/deploy.yml` の `CHANGE ME` の値を書き換えてコミットし、次を実行します：

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
- [**認証**](authentication.md) — パスワードリセット、確認、ロックアウト、ログインしたままにする、アカウントページ、管理者ユーザー。
- [**国際化**](i18n.md) — 辞書、`t` と `l`、リクエストごとのロケール。
- [**ガイド**](index.md) — トピックごとに 1 ページ：モデル、リクエスト、テンプレート、リアルタイム、バックグラウンド処理、テスト。
- [**GitHub の CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — ソースコード、README、リリース。
- [**API リファレンス**](site:api/index.html) — アプリが使うすべてのクラスとメソッドを、例とともに。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — スパイク（技術検証）と、そこで見つかったコンパイラの制約。
- [**Spinel**](https://github.com/matz/spinel) — matz による Ruby の AOT コンパイラ。
- [**CyberTrain ホーム**](site:index.html) — 概要、機能、仕組み。
