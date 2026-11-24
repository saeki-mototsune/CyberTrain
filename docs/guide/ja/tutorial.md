---
source_sha256: 6089daf50cee57c1a9721c18dbb9a850c8b9b6fdc50d6498999b523a0bb023a4
path: tutorial.html
title: "はじめよう：ブログを作る"
description: "Rails の Getting Started のブログ（コメント付きの記事）を CyberTrain で作ります：インストール、スキャフォールド、バリデーション、マイグレーション、記事の下へのコメントのネスト、cybertrain test によるテスト。"
og_title: "CyberTrain をはじめよう：ブログを作る"
og_description: "Rails 公式の Getting Started に沿った内容です：記事とコメントのあるブログを、Spinel 上の CyberTrain で作ります。"
og_image: tutorial.png
crumb: "チュートリアル"
nav: tutorial
toc_title: "ステップ 00–12"
meta:
  - term: "必要なもの"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3・zlib・OpenSSL のヘッダー（Spinel は自動でインストールされます） <a class="meta-link" href="#requirements">ステップ 00</a>'
  - term: "出発点"
    text: "`gem install cybertrain`"
  - term: "完成物"
    text: "記事とコメントとテストのあるブログ"
---

# はじめよう：ブログを作る

Rails 公式の [Getting Started](https://guides.rubyonrails.org/getting_started.html) に沿って、記事とコメントのあるブログを作ります。CLI をインストールし、記事をスキャフォールドし、バリデーションを追加し、記事の下にコメントをネストしてテストを実行し、手元で動くブログを完成させます。そのあとは[発展編のチュートリアル](advanced-tutorial.md)が同じブログを先へ進めます：Turbo によるコメントのライブ更新、バックグラウンドジョブ、JSON、サインイン、アップロードした画像、デプロイ可能なビルドです。


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

1 行目で RubyGems からインストールします。残りは全体の流れを一望したものです：以降のステップでは `cybertrain server` まで 1 コマンドずつ進め、`cybertrain build` で終わるのは[発展編のチュートリアル](advanced-tutorial.md#ship)です。

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

`bin/blog.rb` と `bin/db.rb` はどちらも `require "cybertrain/core"` で始まります：オプションのサブシステム（ジョブ、Turbo Streams、メーラー、キャッシュなど）を除いたフレームワークで、どのビルドも短くなります。発展編のチュートリアルのステップでサブシステムを使うときに、その行を追加します（[サブシステム](how-it-works.md#subsystems)）。

レイアウトは `stylesheet_link_tag` で `app/assets/stylesheets/application.css` を読み込み、`javascript_importmap_tags` で `config/importmap.rb` のインポートマップを通じて `app/javascript/application.js` を読み込みます。`spin run gen` がこの 2 つをダイジェスト付きで `public/assets/` に書き出し、そこは git の管理から外してあります（[アセット](assets.md)を参照）。`.env.example` にはアプリが読む環境変数の一覧があり、`.github/workflows/ci.yml` は GitHub 上でテストを実行します（[継続的インテグレーション](testing.md#continuous-integration)）。ツリーの最後の行は [ステップ 19](advanced-tutorial.md#ship) の Kamal 用の設定です。

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

マイグレーション、モデル、コントローラー、5 つのビュー（`index`、`show`、`new`、`edit`、`_form`）、フィクスチャのファイルとテスト（[ステップ 12](#test)）を書き出し、`config/routes.rb` に `resources :articles` を挿入します。フィールドの型は `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime`、`references`、`attachment`（アップロードされたファイル。[ステップ 18](advanced-tutorial.md#attachments)）で、デフォルトは `string` です。クイックスタートの `cybertrain g scaffold` も同じコマンドです。

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

  def new_action   # the `new` action: the generated routes call new_action
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

> [!RULE] new_action
> ### `new` ではなく `new_action`
>
> `new` アクションは `new_action` と書きます。生成されたルートがこの名前で呼び出すからです。この名前は、`ArticlesController.new(ctx)` と並ぶ `new` という名前のインスタンスメソッドを Spinel がコンパイルできないと記録されていた時期に付けられました。同じ形の小さなプログラムは、ピン留めされたリリースではコンパイルできますが、名前は API としてそのまま残っています。ルート `GET /articles/new` は引き続きこのメソッドに対応し、変えるのはメソッド名だけです。ビューは `new.html.erb` のままで、`render :new` も変わりません。

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

  # A nested block takes the mapper as its argument: `articles.resources`,
  # not Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] 明示的なマッパー
> ### ネストしたブロックはマッパーを明示的に受け取る
>
> `resources :articles do |articles|` と `articles.resources :comments` のように書き、裸の `resources :comments` とは書きません。この書き方は、`instance_eval` の中にネストしたブロックでのレシーバーなしの呼び出しを Spinel がコンパイルできないと記録されていた時期に導入されました。同じ形の小さなプログラムは、ピン留めされたリリースではコンパイルできますが、マッパーを明示する書き方が、ジェネレーターもテストも使う正式な書き方として残っています。

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

スキャフォールドは、`belongs_to :article` と、最初の文字列フィールドである `commenter` の存在チェックを持つコメントのモデルを書き出しています。本文のチェックを 1 行追加します：

```ruby app/models/comment.rb
class Comment
  belongs_to :article
  validates :commenter, presence: true
  validates :body, presence: true
end
```

スキャフォールドが宣言した `belongs_to` は、記事のないコメントも、データベースが拒む前に無効にします（「Article can't be blank」）。

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

`button_to ... [@article, comment]` と `form_with(model: [@article, comment])` はどちらも同じ `[parent, child]` のルールで解決されます：新しい子はネストしたコレクション（`article_comments_path`）に、保存済みの子はネストしたメンバー（`article_comment_path`）にルーティングされます。どちらも上のネストした `resources` ブロックから `gen/routes.rb` に生成されます。フォームはコメントをローカル変数として受け取ります。[ステップ 14](advanced-tutorial.md#turbo) で、新しいコメントを渡してもう一度レンダリングできるようにするためです。

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

<!-- step 12 #test stage: ビルド時 · `cybertrain test` -->
## テストする

> [!WHY]
> minitest や RSpec はリフレクションでテストを見つけますが、事前（AOT）コンパイラーにはそれができません。それでもテストは Rails のクラスです：`spin run gen` がそれらを 1 つのプログラムに書き換え、`cybertrain test` がコンパイルして実行します。

### ジェネレーターが書いたもの

ステップ 03 と 08 のスキャフォールドは Rails のスキャフォールドのテストを書き出しました：`test/fixtures/articles.yml` と `comments.yml`（各テストが最初に持つ `one` と `two` の行）、`test/models/article_test.rb` と `comment_test.rb`（「the fixture is valid」）、そして `test/controllers/articles_controller_test.rb` と `comments_controller_test.rb`（アクションごとに 1 つのリクエスト）。`cybertrain new` は各ファイルが読み込む `test/test_helper.rb` と、`/up` へのリクエストである `test/integration/health_test.rb` を書き出しました。そのうち 3 つは、その後に育ったブログに合わせる必要があります：記事のフィクスチャと 2 つのコントローラーテストです。

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

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

リクエスト偽造対策は Rails と同じくテストでは無効なので、`post` にトークンは要りません。ほかのアサーションは[アプリをテストする](testing.md#assertions)にあります。

### テストを実行する

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

最初の実行はすべてのテストを 1 つのプログラムにコンパイルするので、数分かかります（examples/blog のテストは、2026-11-13 の計測時点で 149 個あり、4 vCPU のクラウドマシンで約 9 分）。何も変えていなければ、次の実行でテストのプログラムはコンパイルし直されません。gen を 1 回ビルドし直すことはあり（`build gen`、数秒）、そのあとは 1 秒よりずっと短い時間で始まります。ファイルや `-n` はどのテストを実行するかを選ぶもので、何をコンパイルするかは変えません：どのテストを編集しても、プログラムはコンパイルし直されます。ファイルごとに見出し、テストごとに 1 行（`ok`、または `FAIL` と `ERR` にテストの行とメッセージ）、最後に合計が出ます。その間には、テスト対象のコードが自分で出力したもの（たとえばコマンドの出力行）も混じります。失敗したテストがあれば終了ステータスは 1 です。このステップでのブログのテストは 12 個です。

> [!NOTE]
> 各テストの前にすべてのテーブルが空になり、フィクスチャが入れ直されるので、テストはお互いに依存しません。`gen/tests.rb` と `gen/test/` は生成されるもので、`gen/` のほかの部分と一緒にコミットします。

<!-- step → #where-next -->
## 次に読むもの

記事とコメントがあり、バリデーションとテストを備え、`cybertrain server` で動くブログができました。発展編のチュートリアルは、同じアプリでここから続きます。

<!-- list: next-list -->
- [**発展編チュートリアル**](advanced-tutorial.md) — ステップ 13–19：コンポーネントとヘルパー、Turbo によるコメントのライブ更新、バックグラウンドジョブ、JSON、サインイン、カバー画像、デプロイ用のビルド。
- [**知っておくこと**](advanced-tutorial.md#things-to-know) — 驚かされる前に知っておきたい制限と癖。
- [**`examples/blog`**](../../examples/blog) — 2 つのチュートリアルを発展させたアプリとそのテスト。
- [**ガイド**](index.md) — トピックごとに 1 ページ：モデル、リクエスト、テンプレート、リアルタイム、バックグラウンド処理、テスト。
- [**モデルとデータベース**](models.md) — マイグレーション、クエリ、関連付け、すべてのバリデーター。
- [**テスト**](testing.md) — フィクスチャ、アサーション、`cybertrain test` の詳細。
- [**API リファレンス**](site:api/index.html) — アプリが使うすべてのクラスとメソッドを、例とともに。
- [**GitHub の CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — ソースコード、README、リリース。
- [**CyberTrain ホーム**](site:index.html) — 概要、機能、仕組み。
