---
source_sha256: 7fc302298fd20959b22acd10653c103b8a8b01a96b97fbe159edbf336958e282
path: tutorial.html
title: "はじめよう：ブログを作る"
description: "Rails の Getting Started のブログ（コメント付きの記事）を CyberTrain で作ります：スキャフォールド、マイグレーション、ルーティングのネスト、Cybertrain::Test によるテスト、cybertrain build によるデプロイ用ビルド。"
og_title: "CyberTrain をはじめよう：ブログを作る"
og_description: "Rails 公式の Getting Started に沿った内容です：記事とコメントのあるブログを、Spinel 上の CyberTrain で作ります。"
og_image: tutorial.png
crumb: "チュートリアル"
nav: tutorial
toc_title: "ステップ 00–15"
meta:
  - term: "必要なもの"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3 のヘッダー（Spinel `2026.10.27.7020` は自動でインストールされます） <a class="meta-link" href="#requirements">ステップ 00</a>'
  - term: "出発点"
    text: "`gem install cybertrain`"
  - term: "完成物"
    text: "`dist/blog`"
---

# はじめよう：ブログを作る

Rails 公式の [Getting Started](https://guides.rubyonrails.org/getting_started.html) に沿って、記事とコメントのあるブログを作ります。記事をスキャフォールドし、バリデーションを追加し、記事の下にコメントをネストし、アプリをプロセス内で動かすテストを書き、サインインを追加し、アップロードした画像を添付し、最後にアプリをデプロイ可能な `dist/` フォルダーにビルドします。完成したアプリは [`examples/blog`](../../examples/blog) にあり、Linux と macOS の CI で検証されています。


<!-- step 00 #requirements stage: 準備 · Ruby、`cc`、SQLite -->
## 必要なもの

> [!WHY]
> CyberTrain は Spinel を通じて C にコンパイルされるため、C ツールチェーンと SQLite のヘッダーが必要です。`cybertrain` コマンドは gem なので、Ruby が必要です。

<!-- list: checklist -->
- Ruby 3.2+ と RubyGems。`cybertrain` コマンドのためだけに必要で、アプリケーションが CRuby 上で動くことはありません。Spinel のビルドには Ruby の `prism` gem も必要です：Ruby 3.3 以上には同梱されています。Ruby 3.2 では `gem install prism` を実行します（Ruby の開発用ヘッダーが必要です。Debian/Ubuntu なら `ruby-dev`）。`cybertrain doctor` が確認します。
- Spinel `2026.10.27.7020`。CyberTrain が必要とする修正を本家より先に取り込んだフォーク [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) のリリースです。他のバージョンでは未テストです。手動でインストールする必要はありません：Spinel を必要とする最初のコマンドが、そのリリースを `~/.cybertrain` にビルドします（数分、初回のみ）。ただし、そのリリースの `spinel` がすでに `PATH` 上にある場合は除きます。
- C ツールチェーン（`cc`、または `CC` で指定したコンパイラ）と `make`、さらに `git` と `curl`。すべてのプログラムを C にコンパイルする Spinel をビルドするために使います。
- SQLite 3 と zlib のヘッダーとライブラリ：Debian/Ubuntu では `libsqlite3-dev` と `zlib1g-dev`、macOS では Xcode のコマンドラインツールに含まれています。
- OpenSSL のヘッダー（`libssl-dev`）は任意です：ない場合、Spinel は `openssl` パッケージなしでビルドされますが、CyberTrain はこのパッケージを使いません。

`cybertrain doctor` はこれらのツールとヘッダー、Spinel のインストールを確認します。必要なものが欠けている場合は、プラットフォームに応じたインストールコマンドも表示します。

<details><summary>CyberTrain が Spinel をインストールする仕組み — コマンドが初めて `spin` を必要としたときに起きること</summary>

`cybertrain new`、`db`、`server`、`build`、`spin` は、まず Spinel `2026.10.27.7020` を探します：そのリリースの `spinel` と `spin` がすでに `PATH` 上にあればそれを、なければ `~/.cybertrain/spinel/2026.10.27.7020/` 以下のコピーを使い、それもなければ Spinel のリリースタグからそのコピーをビルドします（`git clone`、`make deps`、`make -j`、`make install`）。ビルドは一度だけで、数分かかります。ログは `~/.cybertrain/log/spinel-2026.10.27.7020-build.log` です。ビルドに必要なツールが欠けている場合、`cybertrain` はビルドを始める前に、どれが足りないかを伝え、プラットフォームに応じたインストールコマンドを表示します。

`cybertrain setup` は同じことを求めに応じて行います（`--force` は `~/.cybertrain` 以下のコピーを再ビルドします）。さらに、自前のコピーが使われている場合は、それを `PATH` に加える行を表示します。`spin` を自分で実行するためのものです：

```shell ターミナル — 任意のディレクトリ
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` には、使用中のリリースを指す `spinel` と `spin` のリンクがあります。これを `PATH` に入れなくても、`cybertrain spin ARGS...` を使えば、任意のディレクトリからそのリリースの `spin` を実行できます。`CYBERTRAIN_HOME` は `~/.cybertrain` の代わりになり、`CYBERTRAIN_SPINEL_HOME=PREFIX` を指定すると、代わりに `PREFIX` にインストールされた Spinel を使います（そのリリースである必要があります）。`PATH` 上にある別リリースの `spinel` が使われたり変更されたりすることはありません。

</details>

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
<span class="ln cmd">cybertrain new blog          <span class="c"># 初回は Spinel 2026.10.27.7020 をインストール（数分）</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># 本番用: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

`cybertrain` コマンドは素の Ruby で書かれており、gem はこれを CRuby（3.2 以降）で実行します。フレームワークも Spinel も gem には含まれません。コマンドは次のとおりです（`cybertrain help` で表示されます）：

<!-- list: points -->
- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]` は NAME にアプリケーションを作成し、その中で `spin lock` と `spin run gen` を実行します。必要なら先に Spinel をインストールします。
- `cybertrain generate scaffold NAME field:type ...`（エイリアスは `g scaffold`）は、カレントディレクトリのアプリケーションにリソースを追加します。
- `cybertrain generate authentication` は、カレントディレクトリのアプリケーションにメールアドレスとパスワードによるサインインを追加します（[ステップ 13](#authentication)）。
- `cybertrain generate attachment MODEL FIELD [--any]` は、カレントディレクトリのアプリケーションのスキャフォールド済みモデルにファイルアップロードを追加します（[ステップ 14](#attachments)）。
- `cybertrain db migrate` は生成を行い、未適用のマイグレーションを適用して、もう一度生成します（`spin run gen; spin run db -- migrate; spin run gen`）。`cybertrain migration` もエイリアスとして残されています。
- `cybertrain db COMMAND...` は `spin run gen` の後に、その他のデータベースコマンドを実行します：`status`、`rollback [N]`（実行後にもう一度生成します）、`schema:dump`、`create`。
- `cybertrain server [PORT]` は生成を行ってから開発サーバーを起動します（`spin run gen; spin run NAME`、または `spin run NAME -- PORT`。デフォルトのポートは 3000）。
- `cybertrain build` は `app/views/` を埋め込んで NAME をビルドし、`dist/`（バイナリ、`public/`、`storage/`、`tmp/`）を組み立てます。
- `cybertrain spin ARGS...` は、固定された Spinel で `spin` を任意のディレクトリから実行します：`cybertrain spin test`、`cybertrain spin run gen -- --check`。
- `cybertrain setup [--force]` は Spinel `2026.10.27.7020` を `~/.cybertrain` にインストールします（そのリリースの `spinel` がすでに `PATH` 上にある場合を除く）。`--force` は `~/.cybertrain` 以下のコピーを再ビルドします。
- `cybertrain doctor` は C ツールチェーン、SQLite のヘッダー、Spinel のインストールを確認します。
- `cybertrain version` はバージョン（`cybertrain 0.3.1`）を、`cybertrain help` は使い方を表示します。

> [!NOTE]
> `db`、`server`、`build` はアプリケーションの中で実行します。NAME はそのアプリケーションの `spin.toml` にある `[package] name` です。

<!-- step 02 #new-app stage: 自分で書く · `blog/` -->
## アプリケーションを作成する

> [!WHY]
> Rails のディレクトリ規約に加えて、3 つの `bin/` プログラムが手に入ります：`bin/blog.rb`（アプリ本体）、`bin/gen.rb`（ジェネレーター）、`bin/db.rb`（開発用のマイグレーション）。

```shell ターミナル — 任意のディレクトリ
cybertrain new blog
cd blog
```

`cybertrain new` はアプリケーションを書き出します。その `spin.toml` は CLI と一致するリリースを指しています：

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

次に Spinel がインストールされていることを確認し（初回は Spinel `2026.10.27.7020` を `~/.cybertrain` にビルドします：数分、初回のみ。[ステップ 00](#requirements) を参照）、`spin lock`（spin がフレームワークをキャッシュ `~/.cache/spin/packages/` に取得し、コミットを `spin.lock` に固定します）と `spin run gen` を実行します。`rails new` が `bundle install` を実行するのと同じようなもので、これで `cybertrain server` がすぐに動きます。最後に次の手順を表示して終わります。フレームワークのファイルはアプリに一切コピーされません。`spin.toml` と `spin.lock` をコミットしてください。

> [!NOTE]
> Spinel のインストールか、2 つの `spin` ステップのいずれかが失敗した場合、ファイルは残したまま `new` は終了コード 1 で終了し、原因を解消した後に実行すべきコマンドを表示します（Spinel の場合：`cybertrain setup` を実行し、続いて新しいディレクトリで `cybertrain spin lock && cybertrain spin run gen`）。`--skip-spin` はファイルを書き出すだけです。`--path DIR` は代わりにローカルのチェックアウトに依存し、`--git URL [--ref R]` は URL にあるフレームワーク（ブランチまたはタグ R）に、`--version V` は `cybertrain` が `spin-index` に登録された後、インデックスのバージョンに依存します。

アプリ名には英小文字、数字、`_` を使い、先頭は英字にします。生成されるツリー：

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` はアプリケーション唯一のエントリーポイントで、`spin build blog` がコンパイルするプログラムです：`./blog` でサーバーを起動し、`./blog migrate` と `./blog db status` でデータベースを管理します。`bin/gen.rb` はジェネレーターを実行し（`spin run gen`）、`bin/db.rb` は開発中にマイグレーターを実行します（`cybertrain db migrate` がこれを使います。最初のマイグレーションで `gen/models/` が生成されるまで、`bin/blog.rb` はコンパイルできないためです）。`gen/` にはすでに `views.rb` があります。これはコミットされる、空の埋め込みビューのテーブルです。

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

マイグレーション、モデル、コントローラー、5 つのビュー（`index`、`show`、`new`、`edit`、`_form`）を書き出し、`config/routes.rb` に `resources :articles` を挿入します。フィールドの型は `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime`、`references` で、デフォルトは `string` です。クイックスタートの `cybertrain g scaffold` も同じコマンドです。

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
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` にはスーパークラスを書きません：スーパークラスの `Cybertrain::Model`、カラム、ファインダーは `gen/models/article.rb` から来ます。保存に失敗すると、「Title can't be blank」（タイトルは空にできません）や「Body is too short (minimum is 10 characters)」（本文が短すぎます。最小 10 文字）のようなメッセージが報告されます。

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
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000。Ruby を編集すると再ビルド、ビューは再ビルドなしで再読み込み
```

`spin run gen` は `db/schema.rb` と `config/routes.rb` を読み、`app/` をスキャンして `gen/` を書き出します。`spin run db -- migrate` は `db/migrate/*.rb` を適用して `db/schema.rb` を書き換えます。順序が重要です：1 回目の `spin run gen` は新しいマイグレーションを `gen/migrations.rb` に入れ（これを `bin/db.rb` が require します）、2 回目は書き換えられた `db/schema.rb` からモデルを構築します。

`cybertrain server` は実行する `spin` コマンドをひとつずつ表示し、続いてアプリの起動バナーを表示します。初回の起動ではアプリをコンパイルするため、しばらく時間がかかります：

```text 出力 — cybertrain server
=> Booting cybertrain 0.3.1
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- スキーマ、ルーティング、またはコントローラーやモデルのコールバックとインスタンス変数を変更したら、`cybertrain spin run gen` を再実行して `gen/` をコミットしてください。開発サーバーはこれを自動で行います。
- ポートは `cybertrain server 4000`（または `PORT=4000`）で変更できます。
- `cybertrain db` は、`--`（`spin run db` が引数の前に必要とするもの）を補います。`cybertrain db status` などのデータベースコマンドも同じように動きます。

> [!RULE] Spinel のルール：コンソールなし
> ### コンソールはない
>
> `rails console` に相当するものはありません：Spinel には `eval` がないからです。Ruby の変更には再ビルドが必要ですが、開発環境では `cybertrain server` が代わりに行います（再ビルド、停止、`execv`）。開発環境ではビューはリクエストごとにディスクからパースされるので、ビューの編集に再ビルドは不要です。本番用には `cybertrain build` がビューを埋め込みます。

<!-- step 08 #scaffold-comment stage: 自分で書く · `db/migrate/`, `app/` -->
## コメントをスキャフォールドする

> [!WHY]
> `references` 型によって、関連付けの元になる外部キーが作られます。

```shell ターミナル — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # スキャフォールドが comments テーブルのマイグレーションを書き出している
```

`article:references` は `article_id` カラム、インデックス、外部キーを追加します — `Article`/`Comment` の関連付けにはこれで十分です。`has_many`/`belongs_to` を書く必要はなく、`spin run gen` が外部キーから読み取ります。生成されるスキーマ：

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

> [!EXAMPLE] コメントのある記事を削除する
> ### コメントのある記事を削除する
>
> 関連付けは外部キーからしか作られず、`dependent:` は実装されていません。サンプルでは、レコードを明示的に受け取る `before_destroy` コールバックを追加しています：
>
> ```ruby app/models/article.rb（抜粋）
>   # Rails' `has_many :comments, dependent: :destroy`: the foreign key
>   # would refuse to delete an article that still has comments.
>   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
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
    @comment = Comment.where(article_id: @article.id).find(params[:id])
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
end
```

> [!NOTE]
> ここでの `Article#comments` は Array なので、Rails の `@article.comments.find(params[:id])` は `Comment.where(article_id: @article.id).find(params[:id])` になります。別の記事に属するコメントを指定すると 404 が返ります。

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

次に、記事のページでコメントとフォームをレンダリングします：

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>
<%= render "comments/form" %>

<%# app/views/comments/_form.html.erb %>
<%= form_with(model: [@article, @comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

サンプルに含まれているとおりのコメントのパーシャル：

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

`button_to ... [@article, comment]` と `form_with(model: [@article, @comment])` はどちらも同じ `[parent, child]` のルールで解決されます：新しい子はネストしたコレクション（`article_comments_path`）に、保存済みの子はネストしたメンバー（`article_comment_path`）にルーティングされます — これらは上のネストした `resources` ブロックから `gen/routes.rb` に生成されます。

> [!RULE] ビューは閉じた文法
> ### ビューは Ruby ではなく、閉じた文法
>
> Spinel には `eval` がないため、テンプレートは固定の文法に従って解釈されます。`link_to` には `method:` オプションがないので、`button_to` を使ってください。`each` が受け取るブロック引数は 1 つか 2 つです。`<%# locals: (comment:) %>` のような strict locals コメントではデフォルト値を指定できません。パーシャルは呼び出し元の環境のコピーを受け取るので、`@article` は `comments/_form` の中からも見えます。

<!-- step 12 #test stage: ビルド時 · `cybertrain spin test` -->
## テストする

> [!WHY]
> minitest や RSpec はリフレクションでテストを見つけますが、AOT コンパイラではそれができません。そこで CyberTrain は `Cybertrain::Test` を同梱しています。

### モデルのテスト

```ruby test/articles.rb（スニペット）
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

アサーション：`assert`、`refute`、`assert_equal`、`assert_nil`、`assert_includes`、`assert_raises("Class") { }`、`flunk`。サンプルでは `assert_response` と `assert_redirected_to` も使っています。

### HTTP の一連の流れ

```ruby test/articles.rb（スニペット）
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

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

`Cybertrain::Test::Client` は cookie jar を持ち、アプリをプロセス内で（ソケットなしで）動かすので、セッションと CSRF はブラウザ越しと同じように振る舞います。トークンのないリクエストには 403 が返ります。

> [!COMPILE] スニペットで省略しているもの
> ### スニペットで省略しているもの
>
> - `support/blog_test` は [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb) のことです：これをアプリの `test/support/` にコピーしてください。このディレクトリのファイルは実行されず、require されるだけです。このファイルは新しい `storage/test.sqlite3` にマイグレーションを適用し、アプリを `BLOG` として起動し、`Cybertrain::Test` とそのクライアントを読み込み、`BlogTest.form_token`（最後にレンダリングされたフォームの CSRF トークン）と `BlogTest.article_path` を提供します。
> - ファイルの最後に `Cybertrain::Test.run!` を書きます。これがテストを実行し、スナップショットで比較される行を出力します。
> - 比較される出力にリクエストログが混ざらないよう、`c.log_level = :none if c.test?` を `config/app.rb` で設定します。

### テストを実行する

```shell ターミナル — blog/
cybertrain spin test
```

`cybertrain spin test` は固定された Spinel で `spin test` を実行します。ツールチェーンが `PATH` 上にあれば（[ステップ 00](#requirements)）、`spin test` でも同じです。各 `test/*.rb` をそれぞれ独立したプログラムにコンパイルし、その出力（stdout と stderr をまとめたもの）を、コミット済みのスナップショット `test/<name>.rb.expected` と比較します。`test/support/` 内のファイルは実行されず、require されるだけです。スナップショットを書き出すには：

```shell ターミナル — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` は CRuby での出力からスナップショットを書き出します。FFI 経由で SQLite に触れるテストは CRuby では実行できないため、そのスナップショットはコンパイル済みバイナリから作ります（上の 2 行目）。スナップショットが古い間は `cybertrain spin test` が 0 以外で終了するため、後続は `;` でつなぎ、`&&` は使いません。`[ -x ]` のチェックにより、コンパイルに失敗したときは出力の取り込みをスキップするので、古いスナップショットが残ります。CRuby で実行できないテストは、このスナップショットがないと `cybertrain spin test` が通りません。スナップショットのないその他のテストは、CRuby での出力と比較されます。

<!-- step 13 #authentication stage: 自分で書く · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## サインインを追加する

> [!WHY]
> ここまでは誰でも記事を編集・削除できます。Rails 8 の `bin/rails generate authentication` と同じく、ひとつのコマンドでメールアドレスとパスワードによるサインインを追加します。エンジンとして組み込むのではなく、アプリが所有するコードとして書き出します。

```shell ターミナル — blog/
cybertrain generate authentication
cybertrain db migrate    # users と sessions のテーブルを作る
```

`users`（`email_address`、`password_digest`、ユニークインデックス）と `sessions`（サインイン中のブラウザーごとに 1 行）のマイグレーション、`User` と `Session` のモデル、`SessionsController`（`/session/new`、`POST /session`、`DELETE /session`）と `RegistrationsController`（`/sign_up`）およびそのビュー、レイアウトの先頭に描画される `sessions/_nav` パーシャル、そして `test/authentication.rb` と `test/support/app_test.rb` を書き出します。さらにルートを挿入し、`ApplicationController` のクラス行の直後に次のブロックを挿入します：

```ruby app/controllers/application_controller.rb（抜粋）
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
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
  <%= render "comments/form" %>
<% end %>
```

サーバーを起動して `http://127.0.0.1:3000/sign_up` を開き、最初のユーザーを作成します。Rails のジェネレーターにはサインアップ画面がなく、最初のユーザーはコンソールで作りますが、CyberTrain にはコンソールがないため `RegistrationsController` を書き出します。招待制のアプリでは、これとそのルートを削除してください。

<details><summary>招待制のアプリ：`--invite-only` — サインアップ画面はなく、最初のユーザーはコマンドラインか、サーバーのマシンからしか開けないページで作る</summary>

サインアップ画面があると、サーバーにたどり着いた人は誰でも登録できます。これは社内ツールにとって誤った既定値です：管理者より先にたどり着いた人がアカウントを持ってしまいます。`--invite-only` は `RegistrationsController` もサインアップのリンクも書き出しません。最初のユーザーはコマンドラインから作るか、サーバー自身のマシンからしか開けないページで作ります。そのページへのリンクは、サーバーが起動時に表示します：

```shell ターミナル — blog/
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # 表示された http://127.0.0.1:3000/setup?token=... のリンクを同じマシンで開く
```

本番環境では、バイナリを実行するディレクトリで：

```shell ターミナル — 本番ホスト
./blog user ann@example.com                        # パスワードを標準入力から読む（1 行）
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user ann@example.com 's3cr3t-s3cr3t'        # または引数で渡す（ps で見える）
```

<!-- list: points -->
- `app/commands/user_command.rb` は `Cybertrain::Main.command` で `user` コマンドを登録し（そのため `./blog help` に表示されます）、`bin/blog.rb` から require されます。`EMAIL [PASSWORD]` はユーザーを作成するか、そのアドレスを持つユーザーのパスワードを設定します（パスワードの変更はいつもそうですが、そのユーザーのブラウザーはサインアウトされます）。`created ADDRESS` または `updated ADDRESS` を表示して 0 で終了します。`PASSWORD` を省くと標準入力から 1 行を読み（端末からの場合はプロンプトを出します。入力した文字は表示されます）、末尾の改行を取り除くので、パスワードは `ps` にもシェルの履歴にも残りません。空のパスワード、バリデーションを通らないレコード（8 文字未満のパスワード）、誤った引数では、エラーまたは使い方の行を表示して 1 で終了します。
- `SetupController`（`GET`/`POST /setup`、`app/views/setup/new.html.erb`）は最初のユーザーを作成し、サインインさせます。応答するのは、ユーザーがまだいない間だけ、ワンタイムトークン（下記）がある場合だけ、そしてソケットの接続相手がループバックアドレス（`request.loopback?`：`127.0.0.0/8` または `::1`）で、`X-Forwarded-For` ヘッダーを持たない接続に対してだけです（同じホスト上のプロキシを通すとどのリクエストもループバックからのものになりますが、プロキシはこのヘッダーを付けます）。ヘッダーはページを閉じることはあっても、開くことはありません。それ以外の相手と、トークンがない・誤っているリクエストには 404 を返します。
- トークン：`SetupController::SETUP_TOKEN`。プログラムの起動時に作られる 32 文字のランダムな 16 進文字列（`Cybertrain::Crypto.random_token(16)`）で、終了するまで保持されるので、再起動すると新しくなります。`GET /setup` は `?token=` でこれを受け取り、フォームは hidden フィールドで送り返し、どちらも定数時間で比較します（`Cybertrain::Crypto.secure_compare`）。アドレスのチェックが役に立たないときにページを閉じておくのが、このトークンです：同じホスト上で `X-Forwarded-For` を付けないプロキシ（`proxy_set_header X-Forwarded-For ...` のない nginx）を通すと、どのクライアントもループバックに見えますが、トークンを知っているのはサーバーのログを読める人だけです。リクエストログがトークンを繰り返すことはありません：`token` はデフォルトの `filter_parameters` に含まれるので、その行は `Started GET "/setup?token=[FILTERED]"` となります（`config.filter_parameters` や `CYBERTRAIN_FILTER_PARAMETERS` で `token` を外した場合を除きます）。ユーザーができた後は、このトークンでは何も開きません。
- 別のホストにあるプロキシの後ろで初めて起動するときは、`BLOG_SETUP_OPEN=1`（`config/app.rb` で `c.setting_bool :setup_open` として宣言）でアドレスのチェックを外せます。それでも、ユーザーがいない間だけ、トークンがある場合だけです。ユーザーができたら設定を外してください。
- ユーザーがいない間、サーバーは起動前に `[WARN] no user exists yet: run ./blog user EMAIL, or open /setup?token=<token> from this machine` をログに出します（`UserCommand.warn_if_no_user`。`Cybertrain::Main.server?(ARGV)` のときに `bin/blog.rb` から呼ばれます。この確認のためだけにデータベースに接続し、users テーブルがまだマイグレーションされていなければ何も出しません）。トークンが表示されるのはこの行だけです。

生成される `test/authentication.rb` は両方を確かめます：トークンあり・なし（`SetupController.setup_token`）・誤ったトークンでの `/setup`、別のアドレスから（`client.peer_address = "203.0.113.7"`）、プロキシ経由、ユーザーがいる状態、スイッチを入れた状態、そして `Cybertrain::Main.run` でプロセス内から実行する `user` コマンドです。これはすべてアプリケーションのコードで、自由に変えられます（docs/design.md D29）。フレームワークが提供するのは、`request.loopback?`、`Main.command`、`Main.server?`、`Crypto.random_token` / `Crypto.secure_compare` と、テストクライアントの `peer_address` だけです。

</details>

> [!RULE] Spinel のルール：has_secure_password
> ### `has_secure_password` は書き下される
>
> Spinel は実行時にメソッドを定義できないため、`User` モデルには `has_secure_password` が定義するはずのもの、つまり `password=`、`authenticate`、`User.authenticate_by(email_address:, password:)` がそのまま書かれています。パスワードは `Cybertrain::Password` でハッシュ化されます。Ruby で書かれた PBKDF2-HMAC-SHA256 で、既定は 10 万回反復（コンパイル後で約 0.2 秒）です。bcrypt を使うと、バイナリが C ライブラリをリンクする必要があるためです。コストは `config/app.rb` に `Cybertrain::Password.iterations = 600_000` と書いて引き上げられ、`User#authenticate` が各ユーザーのサインイン時にハッシュを作り直します。

<details><summary>認証：フレームワークが提供するもの — ジェネレーターを組み立てている部品で、ジェネレーターなしでも使える</summary>

上のジェネレーターは一連の流れを書き出しますが、それを組み立てている部品はフレームワークの API で、ジェネレーターなしでも使えます（API トークン、管理者パスワード、自分で書くサインインなどに）：

<!-- list: points -->
- **`Cybertrain::Password`**：`hash(plain)` は、自身のパラメーターを記録した（`$pbkdf2-sha256$i=100000$salt$key`）ソルト付きの PBKDF2-HMAC-SHA256 ダイジェストを作ります。`verify?(plain, digest)` は定数時間で照合し、形式の壊れたダイジェストでも例外を出しません。`needs_rehash?(digest)` は、ダイジェストが現在の `Password.iterations` より古いかどうかを返します。サインインのアクション向けには：
  - `verify_serialized(plain, digest)` は、プロセスごとに一度に 1 つずつ実行する（Mutex）`verify?` です。ハッシュ 1 回に約 0.2 秒の CPU を使うので、試行が一斉に押し寄せるとすべてのワーカーが塞がってしまいますが、このメソッドを通せば試行は順番待ちになり、ほかのワーカーはページの配信を続けます。
  - `dummy_digest` はランダムなパスワードのダイジェストで、プロセスごとに一度、現在のコストで作られます。アドレスが見つからないときはこれと照合してください。そうすれば、どのアドレスにアカウントがあるかが応答時間から分かりません：`Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)`。
  - `session_key(digest)` は、パスワードダイジェストの `secret_key_base` による HMAC です。サインイン時にセッションに保存し、リクエストごとに `session_key_matches?(session[:password_key], user.password_digest)` で確かめます。パスワードを変えるとダイジェストが新しくなるので、それ以前に始まったセッションはすべてサインアウトされます。
  - `iterations` は、`Cybertrain.config.test?` のときは `Password::TEST_ITERATIONS`（1,000）なので、テストスイートはユーザーごとに本番のコストを払わずに済みます。ダイジェストは自身の回数を記録しているので、ほかには何も変わりません。
- **セッション**（`session[:key]`、署名付き cookie）：`clear` はサインアウト時にセッションを空にします（CSRF トークンも含めて）。`config.session_absolute_max_age`（2 週間。`0` で無効）は、どれだけ頻繁に使われても、セッションの寿命全体に上限を設けます：cookie は最初に書かれた時刻を記録し、それより古い cookie は空のセッションとして読み込まれるので、コピーした cookie をいつまでも再利用することはできません。`session.restart_lifetime!` は（サインイン時に）カウントをやり直します。
- **`Controller#local_path?(text)` と `safe_redirect_path(text, fallback)`**：リクエストから来たパス（`return_to` パラメーター、記憶しておいたページ）にリダイレクトするのは、それが `/` で始まり、`//` や `/\` では始まらず、表示可能な ASCII 文字だけからなり、2,048 バイト以下の場合だけです：`redirect_to safe_redirect_path(params[:return_to], "/"), status: :see_other`。
- コントローラークラスの **`skip_before_action(name, only:, except:)`** は、継承した `before_action` を一部のアクションで外します。生成される `allow_unauthenticated_access` は、これを 1 行で包んだものです。
- **`cybertrain generate authentication`** は、アプリが所有するコードとして次のものを書き出します：`users` と `sessions` のマイグレーションとモデル、`SessionsController`、`RegistrationsController`、それらのビューとナビゲーションのパーシャル、`ApplicationController` のブロック（`resume_session`、`require_authentication`、`start_new_session_for`、`terminate_session`、`after_authentication_url`）、そして `test/authentication.rb`。このコードは、このリストのすべてを使います：`User.authenticate_by` は `verify_serialized` とダミーのダイジェストで照合し、`start_new_session_for` はパスワードのキーを保存して寿命をやり直し、`resume_session` はキーが一致しなくなった Session の行や `session_absolute_max_age` より古い行を終了させ、`after_authentication_url` は `safe_redirect_path` です。パスワードを変えたブラウザーをサインインしたままにするには、保存した後に新しいキーを格納します：`session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`。設計：[docs/design.md](../design.md) D25。

</details>

### テストを更新する

[ステップ 12](#test) のテストのうち、フォームを期待するもの、フォームを送信するもの、`index` と `show` 以外のアクションに到達するものは、代わりにサインイン画面に行き着きます。ジェネレーターが `test/support/app_test.rb` に書いたヘルパーで、先にクライアントをサインインさせます：

```ruby test/signed_in.rb
require_relative "support/app_test"   # written by generate authentication: APP, AppTest

test "a signed-in user creates an article" do
  client = Cybertrain::Test::Client.new(APP)
  AppTest.user("ann@example.com", "s3cr3t-s3cr3t")
  AppTest.sign_in(client, "ann@example.com", "s3cr3t-s3cr3t")
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => AppTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, "/articles/#{Article.last.id}"
end
```

> [!NOTE]
> [ステップ 12](#test) と同じく `cybertrain spin test` で実行します。`test/authentication.rb` とこのテストは SQLite を使うので、スナップショットはコンパイル済みバイナリから作ります。`examples/blog` はこのステップの手前までです。サインインの試行は Rails のジェネレーターと同じくレート制限されます：`SessionsController` が `rate_limit to: 10, within: 3 * 60, only: [:create]` を宣言しており、クライアントのアドレスごとに 3 分間で 10 回まで、それを超えるとウィンドウが閉じるまで "Try again later." とともにフォームに戻されます。パスワードリセット（CyberTrain にはメーラーがありません）は生成されません。

<!-- step 14 #attachments stage: 自分で書く · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## カバー画像を追加する

> [!WHY]
> 記事に画像を添えられるようにします。サインインと同じ役割分担です。フレームワークが `multipart/form-data` を解析してバイト列を保存し、残りはひとつのコマンドが、Active Storage の `has_one_attached` の代わりに、アプリが所有するコードとして書き出します。

```shell ターミナル — blog/
cybertrain generate attachment article cover   # 新しいモデルなら: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # articles に cover_* のカラムを追加する
```

`articles` に 5 つのカラム（`cover_key`、`cover_filename`、`cover_content_type`、`cover_byte_size`、`cover_checksum`。ファイルそのものは SQLite には入りません）を追加するマイグレーションと、`Article` に `cover_file=`、`cover_attached?`、`cover_url`、バリデーション、保存時と削除時のコールバックを持つブロックを書き出します。`ArticlesController` には、`before_action :set_article` の対象となる `cover` アクションと、`create` と `update` にそれぞれ 1 行を追加します：

```ruby app/controllers/articles_controller.rb （抜粋）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 13 wrote [:index, :show]; the generator added :cover
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

ステップ 13 ですべてのページが非公開になり、公開された記事ページの画像は `/articles/1/cover` から取得されます。ジェネレーターは、ダウンロードを記事ページとちょうど同じだけ公開します。`allow_unauthenticated_access` に `:show` があるので、上のコードの 1 行目のように、そのリストに `:cover` を加えます。これで、記事を読める訪問者には画像も表示されます。記事ページにサインインが必要なら、ダウンロードにも必要になります。`set_article` がユーザーに見せる記事を制限しているなら、その制限はダウンロードにも及びます。

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

サーバーを起動し、記事を編集して画像を選びます。ジェネレーターは `test/attachment_article_cover.rb` も書き出しています。このテストは一連の流れ全体を確かめ、アプリに `User` があるので最初にサインインします。ここでは `:cover` が公開されているので、訪問者がカバー画像をダウンロードできることを確かめます。本文には、[ステップ 05](#validations) の最小 10 文字に合わせて伸ばした `"A article."` を入れます。

> [!NOTE]
> [ステップ 12](#test) と同じく `cybertrain spin test` で実行します。このテストは SQLite を使うので、スナップショットはコンパイル済みバイナリから作ります。`examples/blog` はこのステップの手前までです。未対応のもの：1 つのフィールドに複数のファイル、S3 などのリモートストレージ、画像のバリアント、大きなボディをディスクへストリーミングすること（ボディ全体がメモリに読み込まれます。上限は `max_body_bytes`）。

<!-- step 15 #ship stage: 実行時 · `dist/blog` -->
## デプロイ用にビルドする

> [!WHY]
> ひとつのコマンドで、すべてのビューを埋め込んだ、デプロイ可能な `dist/` フォルダーにアプリをビルドします。

```shell ターミナル — blog/
cybertrain build
```

これは `dist/` を書き出します：すべてのビューを埋め込んだアプリのバイナリと、その横に置かれる、バイナリが使うファイルです。`spin run gen -- --embed-views`、`spin build blog`、`spin run gen`（失敗や Ctrl-C の後でも、コミット済みの空の `gen/views.rb` を元に戻します）を実行してから、次のものを組み立てます：

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>コンパイルされたフレームワーク、コントローラー、モデル、テンプレートインタプリタ。すべてのビューを埋め込み済み</span></li>
  <li><code>dist/public/</code><span>静的アセットとエラーページ。リバースプロキシに配信させてもよい</span></li>
  <li><code>dist/storage/</code><span>空の状態で作成。デフォルトでは SQLite のファイルを置く（再ビルドで空にされることはない）</span></li>
  <li><code>dist/tmp/</code><span>空の状態で作成（再ビルドで空にされることはない）</span></li>
</ul>

`dist/` を同じ OS と CPU のマシンにコピーし（バイナリはシステムの SQLite にリンクします）、そこで実行します。ビルドしたバイナリはデフォルトで本番環境として動きます（`CYBERTRAIN_ENV` で上書きできます）。`CYBERTRAIN_SECRET_KEY_BASE` を設定してください。例：

```shell ターミナル — 本番ホスト
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` はバイナリに組み込まれたマイグレーションを適用し、`./blog db status` はその状態を表示します。ポートは `PORT` で設定します。シークレットは再起動をまたいで同じ値に保ってください：変更するとすべてのセッションが終了します。

`Cybertrain::Config` はまず環境変数を読み、`config/app.rb` がそれを上書きします：

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
- サーバーが話すのは素の HTTP/1.1 です：TLS と HTTP/2 には前段に nginx か Caddy を置いてください。本番環境ではセッション cookie が `Secure` になるので、HTTPS で配信してください（本番環境が本当に素の http である場合に限り、`c.session_secure = false` を `config/app.rb` で設定します）。
- 本番環境では、`CYBERTRAIN_SECRET_KEY_BASE` がないと起動を拒否します。
- 本番環境では例外に対して 500 を返し、素のエラーレスポンス（ルーターのプレーンテキストの 404、`head :not_found`、`render plain:`）は、`public/<status>.html` が存在すればそれに置き換えられます。`cybertrain new` は `404.html` と `500.html` を書き出します。
- `SIGTERM` を受けると新たな受け付けを止め、処理中のリクエストを完了させ、それらが終わった時点か、サーバーの `drain_timeout`（10 秒）が過ぎた時点で終了します。
- ファイル監視と再ビルドのループが本番環境で動くことはありません。実行中の `cybertrain server` は、`cybertrain build` が `tmp/cybertrain-build.lock` を保持している間、再ビルドをスキップします。

`cybertrain new` は [Kamal 2](https://kamal-deploy.org) 用の設定も書き出します。`Dockerfile` は Ubuntu のビルドステージで `cybertrain setup` と `cybertrain build` を実行し、`dist/` を同じリリースの軽量なステージにコピーします。このイメージは起動時にマイグレーションを流してから `0.0.0.0:3000` で待ち受けます。ほかに `.dockerignore`、`config/deploy.yml`（前段に Let&rsquo;s Encrypt 付きの kamal-proxy、ヘルスチェックは `public/up.html`、SQLite のファイルは `/app/storage` のボリューム）、`KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE` を環境変数から読む `.kamal/secrets` が作られます。`config/deploy.yml` の `CHANGE ME` の値を書き換えてコミットし、次を実行します：

```shell ターミナル — blog/
kamal setup    # 初回：サーバーに Docker と kamal-proxy を入れ、ビルド・push・起動する
kamal deploy   # 以降のデプロイ
```

バイナリはイメージの中でコンパイルされるので、OS は常にイメージと一致します。`config/deploy.yml` の `builder.arch` はサーバーの CPU に合わせてください。デプロイ先はサーバー 1 台です：データベースはそのサーバーのボリュームにある SQLite のファイルです。手順はバックアップも含めて [`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) の第 8 部にあります（英語版は [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)）。

完成版のアプリ [`examples/blog`](../../examples/blog#deploying-with-kamal) にも同じ設定が入っています。違いは 1 つだけです：リポジトリのフレームワークに対してビルドする（`spin.toml` の `path = "../.."`）ので、その `Dockerfile` は gem を入れずにチェックアウトから `cybertrain setup` と `cybertrain build` を実行し、ビルドコンテキストはリポジトリのルートです（`builder.context: ../..`。送る中身は `Dockerfile.dockerignore` でフレームワークとアプリだけに絞ります）。CI（[`blog-image.yml`](../../.github/workflows/blog-image.yml)）は変更のたびにこのイメージをビルドし、ヘルスチェック、フォームからの記事の作成、正常な停止、ボリュームに残るデータベースを確かめ、`config/deploy.yml` を Kamal で読み込みます。

> [!NOTE]
> 各部品の組み合わせ方と、Kamal と Caddy の後ろのサーバーとの比較は、[デプロイのページ](site:deploy.html)にあります。

<!-- step + #things-to-know -->
## 知っておくこと

> [!WHY]
> 思わぬところでつまずく前に知っておきたい、制限とクセ。

<!-- list: points know -->
- セッションに保持できるのは String のみで、HMAC 署名付きの cookie に入ります。
- データベースは SQLite のみで、Spinel の FFI を経由します。
- バックトレースはありません：エラーにはクラス、メッセージ、リクエスト行、テンプレート名と行番号が表示されます。
- ビュー内で属性名を書き間違えると、例外にならず空としてレンダリングされます。これは既知の課題です。
- 関連付けはスキーマの外部キーからのみ作られます。`has_many :through`、`includes`、`pluck`、`dependent:`、enum、STI、ポリモーフィック関連付けはありません。
- `namespace`、`respond_to`/フォーマット、`constraints`、`mount` はありません。`render json:` は最小限です。
- スキャフォールドで生成したモデルでは、最初の string フィールドにだけデフォルトで presence バリデーションが付きます。
- ジェネレーターは `app/controllers` と `app/models` に対して、パーサーではなく字句スキャン（正規表現）を使います。
- ビューはビルド時に埋め込まれます：ビューだけの変更でも、本番環境に反映するには `cybertrain build` と再起動が必要です。
- `dist/` は、実行するマシンと同じ OS と CPU でビルドしてください：バイナリはシステムの SQLite にリンクします。
- `SPINEL_WORKERS` のデフォルトは `1` です。
- テスト済みなのは Spinel `2026.10.27.7020` だけです。

<!-- step + #differences -->
## Rails との違い

> [!WHY]
> README の完全な表を、ここにまとめて。

<!-- table: cmp -->
| Rails | CyberTrain |
|---|---|
| `rails console` | コンソールなし — Spinel には `eval` がない |
| コードを編集すると、実行中のアプリに反映される | Ruby の変更には再ビルドが必要。開発環境では `cybertrain server` が代わりに行う（再ビルド、停止、`execv`） |
| ビューを編集しても、リロードは不要 | 同じ — 開発環境ではビューをリクエストごとにディスクからパースする |
| `def new` | `def new_action` （`new` だと `Klass.new(ctx)` を覆い隠してしまう） |
| `before_action { do_thing }`（暗黙の `self`） | `before_action { |c| c.do_thing }` — 保存したブロックに対する `instance_exec` がないため、コールバックはコントローラー／レコードを明示的に受け取る |
| `resources :posts do resources :comments end` | `resources :posts do |posts| posts.resources :comments end` — ネストしたブロックはマッパーを明示的に受け取る |
| ERB はメソッドにコンパイルされる。任意のオブジェクト、任意のメソッドを使える | 固定の文法／ディスパッチテーブルに従って解釈される |
| セッションにはマーシャリングした任意のオブジェクトを保持できる | セッションの値は String のみ、HMAC 署名付き cookie |
| 多数のデータベースアダプター | SQLite のみ、FFI 経由 |
| `has_many :through`、`includes`、`pluck`、`dependent:`、enum、STI、ポリモーフィック関連付け | 未実装。関連付けはスキーマの外部キーからのみ作られる |
| `namespace`、フォーマット/`respond_to`、`constraints`、`mount` | 未実装 — フラットな名前、`render json:` のみ |
| 例外時には完全なバックトレース | クラス、メッセージ、リクエスト行、テンプレート名と行番号 — Spinel はバックトレースを公開しない |
| Rack とそのミドルウェア、`Gemfile` に書いた任意の gem | Rack 互換性なし。小さな固定のミドルウェアセット。Spinel 独自の `spin-index`（その Ruby サブセットでコンパイルできるものに限る） |
| minitest / RSpec | `Cybertrain::Test` — リフレクションに基づくテストランナーは AOT では動かない |
| `bin/rails generate authentication`、`has_secure_password` | `cybertrain generate authentication` が同じ構成を書き出し、コンソールがないためサインアップ画面も加える。`has_secure_password` は `Cybertrain::Password`（PBKDF2）を使って User モデルに書き下される。パスワードリセットはない（メーラーがない） |
| メーラー、ジョブ、ActionCable、アセットパイプライン、i18n | 未構築（MVP の範囲外） |
<!-- table-foot: すべてを網羅してはいません。 -->

<!-- step → #where-next -->
## 次に読むもの

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — 完成したアプリとそのテスト。
- [**GitHub の CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — ソースコード、README、リリース。
- [**API リファレンス**](site:api/index.html) — アプリが使うすべてのクラスとメソッドを、例とともに。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — スパイク（技術検証）と、そこで見つかったコンパイラの制約。
- [**Spinel**](https://github.com/matz/spinel) — matz による Ruby の AOT コンパイラ。
- [**CyberTrain ホーム**](site:index.html) — 概要、機能、仕組み。
