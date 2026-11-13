---
source_sha256: e9f54a9f55d52674351fe3c7cbf908b9cea71747715df0fbfc08f2bb15e41506
---
# リクエスト

コントローラーがリクエストから受け取るものと、フレームワークがその実行前に確認するもの：ルートとそのフォーマット、`respond_to`、コンサーンと `helper_method`、Strong Parameters、ダウンロードと HTTP キャッシュ、Cookie と暗号化されたセッション、レート制限とプロキシの後ろにいるクライアントのアドレス、Content Security Policy、`force_ssl` とホストの確認、パラメーター付きヘッダー、そしてクエリ文字列とリクエストボディがどうパースされ、どう制限されるかです。

## ルーティング

`config/routes.rb` は Rails のルーティング DSL を使います。`spin run gen` がそれを評価し、`gen/routes.rb`（ルート表、ディスパッチャー、`*_path` / `*_url` ヘルパー）を書きます。トップレベルの呼び出しにはレシーバーが要りませんが、入れ子のブロックでは渡されたレシーバーを書きます。Spinel がレシーバーなしで評価するのは `Routes.draw` のトップレベルだけだからです：

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
end
```

`namespace :admin` はパスの前に `/admin` を、ヘルパーの前に `admin_` を付けます（`admin_articles_path`、`admin_article_path(article)`）。コントローラーは `app/controllers/admin/articles_controller.rb` の `Admin::ArticlesController` で、ビューは `app/views/admin/articles/` に置きます。namespace は入れ子にできます。namespace の中のコントローラーは、入れ子（`module Admin` / `class ArticlesController < ApplicationController`）でも、短縮形（`module Admin` がすでにあれば `class Admin::ArticlesController`）でも書けます。スキャンはどちらも読みます。namespace の中の `jobs_page` はそのプレフィックスを受け継ぎます。

`scope` は一度に一つの部分だけを変え、三つは Rails と同じく組み合わせられます：

```ruby
scope "/dashboard" do |s|          # パスのプレフィックスだけ
  s.get "/stats", to: "stats#show"
end
scope module: "billing" do |s|     # コントローラーのモジュールだけ：Billing::InvoicesController
  s.resources :invoices
end
scope "/v1", as: "v1" do |v|       # パスとヘルパーのプレフィックス：v1_about_path
  v.get "/about", to: "pages#about"
end
```

`namespace` と `scope` は `resources` ブロックの外で使います（中で使うと gen が拒否します）。

### 単数リソース、`controller:` と `param:`

`resource`（単数）は `resources` と同じく、ブロックと `controller:` を受け取ります。ブロックはメンバーのルートと入れ子のリソースを足し、パスと名前は Rails と同じです：

```ruby
resource :profile, controller: "pages", only: [:show] do |r|
  r.get :refresh, on: :member       # GET /profile/refresh、refresh_profile_path
end
resources :indicators, param: :key  # /indicators/:key、params[:key]
```

`on: :member` と `on: :collection` は、`member` ブロックや `collection` ブロックと同じ位置にカスタムルートを置きます。単数リソースにコレクションはありません。`param: :key` はメンバーのセグメントの名前（`params[:key]`）を決め、その下の入れ子のリソースは `:indicator_key` を使います。`indicator_path(ind)` は変わらず `ind.to_param` を読むので、モデルはキーを返すようにそれを上書きします。カスタムルートの `:id` と `:x_id` のセグメントは、これまでのヘルパー引数名のままです（`get "/users/:id"` なら `user_path(user)`）。

### リダイレクトとクエリ文字列

`get "/old", to: redirect("/new")` は 301 を返します（別のコードなら `redirect("/new", status: 302)`）。ターゲットの `%{name}` はセグメントの値をエスケープしたものになります：`get "/old-posts/:id", to: redirect("/posts/%{id}")`。リダイレクトのルートは、`as:` を書かない限りヘルパーを持ちません。`redirect` のブロック形式には対応していません。ターゲットを計算するのはコントローラーのアクションです。

パスヘルパーのキーワード引数は、渡した順にエスケープしてクエリ文字列になります：`article_path(a, page: 2)` は `/articles/3?page=2` です。値が nil ならそのキーは省かれ、Array なら要素ごとに `key[]=v` になり、Hash の値は `ArgumentError` を発生させます。`format: :json` は拡張子を（`/articles/3.json`）、`anchor: "c4"` はフラグメントを（`#c4`、最後に）付けます。キーワードがパスのセグメントを埋めることはありません。セグメントは位置引数です（`post_path(id: 3)` ではなく `post_path(3)`）。`url_for("/x", format: :csv)` は同じオプションを String に付けます。

## フォーマットと `respond_to`

どのルートも、最後のセグメントの省略可能な拡張子にマッチします：`/articles/3.json` は `params[:id] == "3"`、`request.format == :json` になります。フォーマットを取るルートでは、動的セグメントは `.` を取り込みません（Rails の既定）。そのため `/articles/3.json.bak` は 404 です。セグメントがそれ自体の理由でドットを含むルートには `format: false` を書きます（`get` などの動詞、`resources`、`resource`、`root` に書けます）：

```ruby
get "/files/:name", to: "files#show", format: false   # /files/report.v2 の name は "report.v2"
```

`request.format` は Symbol です：拡張子があれば、Rails に登録された型（`:html`、`:json`、`:csv`、`:xml`、`:pdf`、`:turbo_stream` など。`jpg` は `:jpeg`、`htm` は `:html`、`txt` は `:text`）から決まり、それ以外の拡張子は `:unknown` です。拡張子がなければ `Accept` から決まります：`text/vnd.turbo-stream.html` があれば `:turbo_stream`、`application/json` があってその前に `text/html` がなければ `:json`、それ以外は `:html` です（`q=0` の型は除きます）。

```ruby
def show
  @article = Article.find(params[:id])
  respond_to do |format|
    format.html
    format.json { render json: @article.as_json }
    format.turbo_stream
  end
end
```

コレクター（`Cybertrain::FormatCollector`）には `html`、`json`、`turbo_stream`、`csv`、`xml`、`text`、`any` があります。最初にマッチした宣言がその場でブロックを実行するので、ブロックからアクションのインスタンス変数が見えます。ブロックのない宣言は、そのフォーマットのアクションのテンプレートを描画します（`show.html.erb` はレイアウトの中、`show.turbo_stream.erb` はレイアウトなし）。どれもマッチしなければ `406 Not Acceptable` を返します。`any` は `:unknown` 以外のどのフォーマットにもマッチします。Turbo はフォームを `text/vnd.turbo-stream.html, text/html` を求めて送ります。このリクエストのフォーマットは `:turbo_stream` で、`format.turbo_stream` のないアクションは Rails と同じく `format.html` で応えます（`.turbo_stream` の拡張子はそのフォーマットだけを求めます）。同じフォールバックは、html 以外のフォーマットと並べて `text/html` か `*/*` を挙げるどの `Accept` にも働きます。html のテンプレートしかないアクションに `application/json, text/plain, */*` を送るクライアントは、406 ではなく html を受け取ります。フォールバックはブロックを html のためにもう一度実行するので、`format.` の行以外の文はブロックの中で二度実行されます。ブロックには `format.` の行だけを書いてください。`q=0` の付いた項目はその型を拒否します。`application/json, text/html;q=0` には、`*/*` が並んでいてもいなくても html は返りません。

フォーマットが `Accept` から決まった応答（拡張子がなく、`Accept` ヘッダーが送られたもの）には `Vary: Accept` が付きます。アクションが設定した `Vary` があればそこに統合されます。これで、ブラウザーやキャッシュが、ある URL の html を、その JSON や Turbo Stream を求めるリクエストに渡すことはなくなります。拡張子付きのパスには付きません。

`respond_to` がなければ、アクションは `<action>.<format>.erb` があればそれを描画し（`create.turbo_stream.erb`、レイアウトなし、そのフォーマットの Content-Type）、なければ 406 を返します。html はこれまでどおりです。JSON にはテンプレートがありません。アクションは `render json:` で JSON を返します。ブロックの中の `render :edit` は、そのブロックがマッチしたフォーマットのテンプレートを描画します（`format.turbo_stream` の中なら `edit.turbo_stream.erb`）。

コントローラーは `turbo_stream` で Turbo Stream の応答を組み立てます（turbo-rails のビルダー：`replace`、`update`、`append`、`prepend`、`before`、`after` はそれぞれターゲットと、`locals:` 付きの `partial:` か `html:` のどちらかを取り、`remove` もあります）：

```ruby
render turbo_stream: [turbo_stream.remove(@comment), turbo_stream.update("count", html: @count.to_s)]
```

## コンサーンと `helper_method`

コントローラーのコンサーンは、Rails と同じく `app/controllers/concerns/` のモジュールです：

```ruby app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 20
  end
end
```

`include AdminGate` と書いたコントローラーは、`included` ブロックが宣言するもの（`before_action`、`skip_before_action`、`after_action`、`helper_method`、`rate_limit`、`rescue_from`、`layout`）を、`include` の位置に、書いた順で受け取り、アクションの中で `self.class.per_page` が使えます。コンサーンはコンサーンを include できます：gen はそれらを深さ優先で、それぞれ一度だけ展開し、循環は名前を挙げて拒否します（`concern cycle: A includes B includes A`）。`include A, B` は Ruby と同じく B を先に include するので、B の `included` ブロックとコールバックが A のものより先に来ます。`around_action` は拒否されます（around コールバックはありません）。コンサーンのメソッドの中の `@x =` の代入は、コントローラーのビュー変数になります。

Spinel は実行されることのない `included` と `class_methods` のブロックもコンパイルするので、gen が代わりに展開します：各コンサーンを、その二つのブロックを空行にして `gen/concerns/<app/ 以下のパス>` に書き（アプリのファイルはこのコピーを読み込みます）、`gen/concerns.rb` で include する各クラスを開き直して、差し込んだ宣言と、`class_methods` のメソッドごとの転送メソッドを書きます。ここから二つの規則が出てきます。`class_methods` のメソッドは、コンサーン、include するクラス、その祖先のインスタンスメソッドと同じ名前にはできません（Spinel はどちらもインスタンスメソッドとして定義してしまいます。spikes/NOTES.md のルール 93）。gen は両方の場所（インスタンスメソッドの `ファイル:行`）を挙げて拒否します。また、コンサーンでないモジュール（`include Comparable` や、`app/*/concerns` の下にファイルのない名前）の `include` は、そのまま Ruby に任されます。そのためコンサーン名の綴り間違いは、gen のメッセージではなく、アプリの読み込み時の `NameError` になります。gen は名前を Ruby と同じように、クラス自身のモジュールから先に探すので、`module Admin` の中の `include Gate` は `Admin::Gate` を取り込みます。どのコンサーンにも届かないのに最後の部分がコンサーンの名前と同じ名前（`Admin::Gate` しかないときの `include Gate`）では gen が止まります。Ruby は別のモジュールを include するか例外を出し、コンサーンの `included` ブロックが失われるからです。

モデルのコンサーンは `app/models/concerns/` に置き、同じように働きます：`included` ブロックには、モデルのクラスレベルの宣言（`validates`、`validate`、`scope`、`belongs_to`、`has_many`、`has_one`、`encrypts`、コールバック、`normalizes`）をどれでも書け、`include` の位置でモデルに書いたものとして扱われます。コンサーンのコールバックは、同じ種類のモデル自身のコールバックの後に実行され、モデルのコンサーンの `included` ブロックの中の `include` は、そのコンサーンを取り込みます。モデルのコンサーンの `class_methods` のメソッド名は、そのモデルのスコープや、どのモデルにもあるクラスメソッドと同じにはできません（`scope :recent` と並べた `recent` や `where`）。gen はそれを拒否します。

コントローラー、またはコンサーンの `included` ブロックに `helper_method :current_user, :admin?` と書くと、そのコントローラーのメソッドを、そのコントローラーのテンプレートと、そこから描画するコンポーネントとパーシャルから、引数付きで呼べるようになります。フレームワークのヘルパーの名前、`_path` や `_url` で終わる名前、`app/helpers` のモジュールが定義する名前、コントローラー・その親・そのコンサーンに `def` がない名前、テンプレートから引数を渡せない（`*rest`、`**opts`、`...`）名前は、gen が拒否します。

## パラメーター：`params.expect` と入れ子の `permit`

```ruby
def article_params
  params.expect(article: [:title, :body, tags: [], meta: [:source]])
end
# => {"title" => "Hi", "body" => "...", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
```

`permit` も同じ形を受け取ります：キーは String を、`key: []` は String のリストを、`key: [...]` は入れ子の階層を許可します。Array でないフィルター（`permit(meta: :source)`、`expect(article: :title)`）や、Array を含むフィルター（`[[:title]]`）は `ArgumentError` を発生させます。これは不正なリクエストではなくコードの誤りなので、400 にはなりません。種類の違う値、列挙していないキー、アップロードされたファイルは捨てられます。`expect` はただ一つのキーの下の階層を返し、そのキーがない、種類が違う、何も許可しないときは `Params::ParameterMissing`（400 で応答）を発生させます。`params.expect(:id)` は String を一つ読んで `{"id" => "3"}` を返し、`params.expect(tags: [])` は空でないリストを同じ形で返します。どちらも `Hash{String => Object}` を返します：値は String、String の Array、入れ子の Hash のどれかなので、String のメソッドを呼ぶ前に `Cybertrain::Cast.str`（または `.to_s`）で型を絞ってください。

## ダウンロード、HTTP キャッシュ、ステータスコード

`send_data(bytes, filename: "report.csv", type: "text/csv", disposition: "attachment")` はそのバイト列で応え、`Content-Disposition` にファイル名を引用符付きの形と RFC 5987 の `filename*` の両方で入れるので、アクセント記号や引用符も崩れません。`disposition: "inline"` ならブラウザの中で表示します。バイト列は渡した `type` のまま送るので、アプリが作ったデータ用です。ユーザーがアップロードしたファイルは、ブラウザに実行させない `send_blob` で返してください。

```ruby
def show
  @post = Post.find(params[:id])
  fresh_when etag: @post, last_modified: @post.updated_at
end

def feed
  @posts = Post.order(created_at: :desc).limit(20).to_a
  return unless stale?(etag: @posts.first)
  expires_in 300, public: true
end
```

`fresh_when` は弱い `ETag`（String から、またはレコードのテーブル、`to_param`、`updated_at` から）と `Last-Modified` を付け、リクエストの `If-None-Match`（それがなければ `If-Modified-Since`）がクライアントが最新の版を持っていると示すときは `304 Not Modified` を返します。`stale?` も同じことをして、アクションが描画すべきかを返します。304 になるのは GET と HEAD だけです。`Cache-Control` は `max-age=0, private, must-revalidate`（`public: true` なら `public`）ですが、先に `expires_in seconds` が `max-age=<seconds>` を付けていればそれが残ります。ほかの応答に自動で ETag は付きません。`If-None-Match: *` は、アクションが付けた検証子が `ETag` でも `Last-Modified` だけでもマッチします。

ETag は、渡したキー、リクエストのフォーマット、ビルドのダイジェスト（アセットのダイジェストとインポートマップ、`cybertrain build` のバイナリではビューも）から作られます。そのため、同じ URL の html と JSON が ETag を共有することはなく、アセットやビューを変えるデプロイは、すべてのクライアントに再検証をさせます。これには二つの帰結があります。開発では、`--embed-views` なしだとテンプレートはディスクから読まれ、ダイジェストには入りません。ビューを編集しても、レコードが変わるか、キャッシュされたコピーなしでページを再読み込みするまで `304` が返ることがあります。また、キーはページが何を表示するかを表すもので、誰が見るかではありません。ユーザーごとに内容が違うページは、キーにユーザーを入れてください（`etag: "posts/#{@post.id}-#{@post.updated_at.to_i}-#{current_user.id}"`）。入れないと、別の人に見せてしまいます。CSP のナンス（ナンス付きの `content_security_policy`、`javascript_importmap_tags`）を含むページを `public` にしないでください。共有キャッシュはすべての訪問者に同じページ、つまり同じナンスを渡し、ナンスは何も守らなくなります。

`status:` と `head` は Rack のすべてのシンボル（`:unauthorized`、`:payment_required`、`:unprocessable_content`、`:too_many_requests` など。以前の `:unprocessable_entity` と `:payload_too_large` は別名として残ります）を受け取り、理由句は RFC 9110 のものです（413 "Content Too Large"、422 "Unprocessable Content"）。

## Cookie とセッション

```ruby
cookies[:theme] = "dark"
cookies[:theme] = { value: "dark", expires: Time.now + 86_400, same_site: "Strict" }
cookies.permanent[:locale] = "ja"
cookies.signed[:user_id] = "5"     # クライアントは読めるが、書き換えられない
cookies.encrypted[:card] = "4242"  # 読むことも書き換えることもできない
cookies.signed[:user_id]           # => "5"、書き換えられていれば nil
cookies.delete(:theme)
```

書き込みには String か、`value:`、`expires:`（Time）、`max_age:`、`path:`、`httponly:`、`secure:`、`same_site:` を持つ Hash を渡します。Cookie は `Path=/`、`HttpOnly`、`SameSite=Lax` で書かれ、セッション Cookie が `Secure` のとき（本番、または `force_ssl` のとき）は `Secure` も付きます。書き込みで別の指定をすればそちらが使われます。`permanent` は 20 年の `Max-Age` を書きます。署名付きの値は `secret_key_base` から導いた鍵での HMAC-SHA256、暗号化した値は別の鍵での AES-256-GCM です。どちらもその Cookie の名前に結び付いているので、別の名前では検証も復号もできず、書き換えられた値は nil として読まれます。同じリクエストの中で書いた後に読むと、書いた値が返ります。jar の下では、`Cybertrain::Cookies.serialize(name, value, expires: time)` が `Set-Cookie` の値を 1 つ作ります。`expires:` を省く（既定値は nil ではなく `Cybertrain::Cookies::NO_EXPIRES` で、Spinel の事情によります：spikes/NOTES.md のルール 109 を参照）か nil を渡すと、`Expires` は書かれません。

セッション Cookie は、Rails の cookie store と同じく AES-256-GCM で暗号化・認証され、`secret_key_base` から導いた専用の鍵を使います：クライアントは読むことも書き換えることもできません。復号できない Cookie（書き換えられたもの、別のアプリのもの、以前の署名付きのもの）は空のセッションとして読み込まれ、4096 バイトを超えるものも同じです。Cookie が 4096 バイトを超えるセッション、または `name=value` が 4096 バイトを超えるジャーの Cookie は、書き込むときに `Session::CookieOverflow` を発生させます。値は String のままです。`secret_key_base` を変えると、これまでどおり全員がサインアウトします。

## レート制限とクライアントのアドレス

コントローラーの `rate_limit` は、ひとつのクライアントがいくつかのアクションを呼び出せる頻度に上限を設けます。数えるのはアクションの実行前です。`bin/<app>.rb` と `bin/db.rb` に `require "cybertrain/rate_limit"`（キャッシュも読み込みます）が必要で、`cybertrain generate authentication` が追加します：

```ruby
class SessionsController < ApplicationController
  # 使い切ると、flash[:alert] を付けてフォームへ 303 で戻す
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
  rate_limit to: 5, within: 60, only: [:create], by: :account_key, with: :slow_down, name: "account"
end
```

各宣言は、クライアントとコントローラーごとに、`within` 秒の時間枠あたり最大 `to` 件のリクエストを数え、それを超えると `Retry-After` ヘッダー（時間枠の残りの秒数）付きで 429 を返すか、`redirect_to:` が指定されていればリダイレクトします。ほかのオプションはコントローラーのメソッドを指します：`by:` はキー（既定は `:client_ip`、接続の相手なら `:remote_addr`、または `account_key` のようなメソッド。その値が nil か `""` なら、全クライアントをまとめて数える代わりに例外を発生させます）、`with:` は代わりに返す応答（何も描画しなければ 429 が続きます）、`if:` / `unless:` は制限をかける条件です（除外されたリクエストは数えません）。制限を二つ持つコントローラーは、それぞれに別の `name:` を付けます（一つのコントローラーの中で、親のものも含めて同じ名前の二つ目の制限と、`:` を含む名前は gen が拒否します）。`within:` は秒単位で、`only:`/`except:` は Array を受け取ります。

カウントはアプリのデータベースの `Cybertrain::Cache` にあるので、アプリを動かすすべてのプロセスがまとめて数え、再起動してもカウントは残ります。時間枠は固定で、時計にそろえてあります（`now / within`）。`store: :memory` は以前のプロセスごとのカウンターです：各プロセスがそれぞれ、最大 10,000 キーのテーブルで数え（満杯になると、期限切れの時間枠、次に最も古いものが場所を空けます）、再起動で失われ、時間枠はキーの最初のリクエストで始まり、制限されたアクションへのリクエストはどれもロックを 1 回取ります（アクションは `only:` で指定してください）。テストでは、`Cybertrain::RateLimit.reset_all!` がすべてのカウント（メモリのテーブルと、キャッシュのレート制限の行）を忘れます（`cybertrain test` は各テストの前にこれを行います）。どちらのストアもフレームワークの時計を読むので、`travel 1.minute` や `travel_to` でテストを時間枠の先に進められます（[タイムトラベル](testing.md#time-travel)）。

### プロキシの後ろにいるクライアントのアドレス

数えられるアドレスは `request.client_ip` です（`by: :remote_addr` を指定すると、代わりに接続の相手を数えます）。これは `request.remote_addr` ですが、`config.trusted_proxy` が有効（`CYBERTRAIN_TRUSTED_PROXY=1`）で、**かつ**接続がループバック、つまり同じホスト上のリバースプロキシ（nginx、Caddy、kamal-proxy）から来ている場合は別です。そのときは `X-Forwarded-For` の最後のアドレス、つまりプロキシが追加したものになります。それより前のエントリーはクライアントが送ってきた何かであり、決して使われません。最後のエントリーが空、45 バイトより長い、または表示可能な ASCII でない場合は `remote_addr` になります。この設定がないと、そうしたプロキシの後ろにいる訪問者は全員がプロキシのアドレスを共有し、10 回のパスワード間違いで全員が締め出されます。設定があれば、別の場所から直接接続してくるクライアントは、それでも自分のアドレスを選べません。`request.loopback?` は、接続がこのマシン（127.0.0.0/8、`::1`、`::ffff:127.x.x.x`）から来ているかを返します。サーバー上の運用者だけが到達すべきページのためのものです。同じホスト上のプロキシの後ろではどのリクエストもループバックになるので、そこでは `client_ip` も確認してください。設計：[docs/design.md](../design.md) D26。

ループバックではなくネットワーク越しにアプリに到達するプロキシは、代わりにアドレスで列挙します：`config.trusted_proxies` は `CYBERTRAIN_TRUSTED_PROXIES` から読まれ、カンマ区切りの IPv4 または IPv6 のアドレスか CIDR を受け取ります（`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`、または単一の `172.18.0.2`）。そのいずれかの内側からの接続は、上のループバックの接続と同じ扱いを受けます：`X-Forwarded-For` の最後のアドレスを、同じ方法で検証して使います。IPv4 のエントリーは、そのアドレスの IPv4 射影形式（`::ffff:172.18.0.2`）にも一致し、相手の `%zone` は無視されます。アドレスでも CIDR でもないエントリーや、`/32`（IPv4）または `/128`（IPv6）を超えるプレフィックスを持つエントリーがあると、サーバーは起動時に停止します。`CYBERTRAIN_TRUSTED_PROXY=1` は `127.0.0.0/8,::1` の省略形で、両者は足し合わされます。

これは Kamal の場合です：kamal-proxy は自身の Docker コンテナーで動き、Docker ネットワーク上の自分のアドレスから接続するので、`cybertrain new` が書き出す `config/deploy.yml` は `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` を設定します（Docker のデフォルトの範囲です。ネットワークが別の範囲を使っている場合は変更してください。`docker network inspect kamal`）。Kamal の `proxy.forward_headers` は設定しないでおきます：`ssl: true` のとき、kamal-proxy はクライアントのものを引き継ぐのではなく、`X-Forwarded-For` を自分で設定します。列挙するのは、クライアントが接続してこられないネットワークだけにしてください：列挙したネットワークの内側にいる人は誰でも、レート制限が数えるアドレスを選べてしまいます。

## Content Security Policy、`force_ssl` とホスト

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

ポリシーは、Rails と同じく `config/app.rb` で宣言するまでは無効です。宣言すると、すべての応答に `Content-Security-Policy`（`c.content_security_policy_report_only = true` なら `Content-Security-Policy-Report-Only`）が付き、nonce を付けるディレクティブにはリクエストごとに新しい nonce が入ります。304 には付かないので、キャッシュされたページは、スクリプトを書いたときの nonce を保ちます。`csp_meta_tag`、`javascript_tag(nonce: true)`、`javascript_importmap_tags`、`stylesheet_link_tag(nonce: true)` がこの nonce を書きます（[テンプレート言語](template-language.md#helpers-and-the-form-builder)）。Symbol はキーワードとスキームです（`:self` は `'self'`、`:data` は `data:`）。空白、`;`、`,`、制御文字を含む String のソースは、宣言した時点で拒否されます。コントローラーは自分のアクション用にコピーを調整でき、サブクラスはそれを受け継ぎます：

```ruby
class EmbedController < ApplicationController
  content_security_policy do |p|
    p.frame_ancestors "https://partner.example"
  end
end
```

どの応答にも、自分で付けていなければ `Permissions-Policy: camera=(), microphone=(), geolocation=()` も付きます。`c.permissions_policy` で値を変えられ、`""` なら送りません。

`CYBERTRAIN_FORCE_SSL=1`（`config.force_ssl`）は http を https にリダイレクトし（GET と HEAD は 301、それ以外は 307）、https の応答に `Strict-Transport-Security: max-age=63072000; includeSubDomains` を付けます。TLS を終端するプロキシの後ろでは、`X-Forwarded-Proto: https` と書かれたリクエストが https です。このヘッダーは `trusted_proxy` の設定にかかわらず読みます（偽造したクライアントは自分のリダイレクトを飛ばすだけです）。`request.base_url` は信頼するプロキシからのときだけこれを信じるので、`CYBERTRAIN_TRUSTED_PROXY` か `CYBERTRAIN_TRUSTED_PROXIES` も設定してください。しないと、アプリが組み立てる URL は http のままです。リダイレクト先のホストは正しい形の `Host` から取り（形が正しくなければ 400）、ヘルスチェックのパスへの http の GET と HEAD はリダイレクトしません。`force_ssl` が有効なら、セッションと Cookie jar は `Secure` の Cookie を書きます。

ホストの確認は開発時のガードを広げたものです：`CYBERTRAIN_HOSTS`（カンマ区切りのホスト名。スキーム、ポート、ワイルドカードは不可）は、どの環境でも、ループバックの名前の後に `allowed_hosts` に足されます。開発ではこれまでどおり確認し、本番とテストでは `CYBERTRAIN_HOSTS` が設定されているときだけ確認します。拒否した `Host` には 403 `Blocked host` を返してログに残します。ヘルスチェックのパスへの GET と HEAD は Host にかかわらず通るので、アドレスで調べるロードバランサーもヘルスチェックに届きます。

## パラメーター付きヘッダー

API クライアントは、`Scheme k1=v1, k2="v2"` 形式のヘッダー（`Authorization:
Digest ...`、ベンダー独自の `X-Example-Auth`）や `k1=v1;k2=v2, k3` 形式のリスト（`Forwarded`、`Prefer`）をよく送ってきます。`request.header_params(name)` はそれをパースして、小文字の名前から値への `Hash` にするので、API コントローラーが手で分割する必要はありません：

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

`,` と `;` はどちらもパラメーターを区切り、同じ名前が複数あれば最初のものが優先されます。引用符で囲まれた値は引用符が外され（`\"` と `\\` も元に戻されます）、囲まれていない値は前後の空白が取り除かれ、`=` のない名前は `""` に対応します。先頭のスキームの単語（`Digest`、`Bearer`）はパラメーターではありません：`request.header_scheme(name)` がそれを返します（ない場合は `""`）。ヘッダーがない、または 8 KiB より長い場合は `{}` になります。値は送られたままのバイト列で、パーセントデコードされることはなく、有効な UTF-8 でない場合もあります。`Bearer <token>` や `Basic <base64>` の資格情報はパラメーターではありません：スキームを確認してから、`request.header("authorization")` から資格情報を読んでください。設計：[docs/design.md](../design.md) D31。

## クエリ文字列とボディ

`Query.parse`、`Query.value_of`、`Query.decode`、`request.form_value` / `query_value` は、次の場合に `Cybertrain::QueryMalformed`（`Cybertrain::QueryInvalid` 配下の `StandardError` で、`ArgumentError` ではない）を出し、400 が返されます：

- 形式の壊れたパーセントエスケープ（どちらのランタイムでも）
- 不正な UTF-8 のバイト列。生のもの（String のタグにかかわらず）でも、パーセントエンコードされたものでも（Rails も不正なパラメーターのエンコーディングには 400 を返します）
- エスケープによってしか完成しない生のバイト（`a=\xC3%A9`）

`Cookies.parse` はそうした値を代わりに生のまま保持します。不正なバイト列を含むパス（生のもの、またはセグメント内でパーセントデコードされたもの）も 400 になります（`request.path_segments`）。パス内の形式の壊れたエスケープは文字どおりに扱われ、一致しないので 404 です。リクエストパラメーターのネストは最大 32 階層、4096 ペアで、それを超えると 400 です。アップグレードの注意点：これらの呼び出しを `ArgumentError` で rescue していたアプリのコードは、代わりに `Cybertrain::QueryInvalid` を rescue してください。

リクエストは自前のパラメーターツリーを持ちません（`params` は Router が組み立て、ミドルウェアはキーをひとつ読みます）。ツリー全体が欲しいアプリは自分でパースし（`Query.parse(request.utf8_query_string)`）、結果を自分で管理します。

Rack は gzip されたリクエストボディをそのままにします。ここでは、`Content-Encoding: gzip` で送られたボディ（数キロバイトを超える SDK や API クライアント）は `request.decoded_body` で、出力の上限のもとでシステムの zlib を通じて一度だけ展開されます：上限はデフォルトで 10 MiB で、それ以上を期待するエンドポイントは自分の上限を渡します（`request.decoded_body(limit)`）。壊れたボディや gzip/identity 以外のエンコーディングは `Cybertrain::BodyUndecodable`、上限を超えて展開されそうなものは `Cybertrain::BodyTooLarge` で、どちらも 400 を返す `QueryInvalid` です。`request.body` は送られたままのバイト列です。

## 0.4 のアプリを更新する

0.4 向けに書いたアプリで変わること（全体は [設計](../superpowers/specs/2026-11-10-phase4-web-layer-design.md) の 14 節にあります）：

- どのセッションも一度だけ終わります：暗号化した Cookie は以前の署名付きのものを読めないので、ユーザーはもう一度サインインします。`Session.load` や `Session.dump` を呼ぶコードは、導いた鍵 `Crypto.derive_key(secret, SessionStore::SESSION_KEY_LABEL)` を渡します。生の秘密鍵を渡すと `Encryptor::Error` になります。
- どのアプリも OpenSSL をリンクします（[インストール](install.md#requirements)）。以前の `cybertrain new` が書いた Dockerfile には、ビルド段に `libssl-dev`、実行段に `libssl3t64` が要ります。
- フォーマットを取るルートでは、動的セグメントが `.` を取り込まなくなりました：ドットを含む id のルートには `format: false` が要ります。
- 手で書いた `url_resolver` のラムダは三つの引数 `->(name, args, options)` を取ります。`Gen::Routes.url_resolver` を渡しているアプリは `spin run gen` だけで済みます。
- `params.permit` は `Hash{String => Object}` を返します：値を String として使う前に `Cast.str` か `.to_s` を呼んでください。
- `rate_limit` はキャッシュで数えます：`store: :memory` で以前のプロセスごとのカウンターになり、一つのコントローラーの二つの制限にはそれぞれの `name:` が要り、nil か `""` を返す `by:` のメソッドは例外を発生させ、何も描画しない `with:` のメソッドの後には 429 が続きます。
- 数値のヘルパーは、数でない値と、0 から 100 の範囲外の精度で例外を発生させます（nil はテンプレートでは従来どおり `""` になります）。
- コントローラーやモデルの `include A, B` は、Ruby と同じく B を先に include します。コンサーンでないモジュールの `include` は Ruby に任されます。
- すべての ETag が一度変わります（リクエストのフォーマットとビルドのダイジェストを含むようになったため）。`Accept` で決まった応答は `Vary: Accept` を送り、html のフォールバックは `text/html` か `*/*` を挙げるどの `Accept` にも働きます。html にフォールバックしうるリクエスト（`application/json, text/html`）は、そのフォーマットだけを求めるリクエストとは別の ETag を持ちます。`Accept` の `text/html;q=0` には、`*/*` が並んでいても html のフォールバックは働きません（html しかないアクションでは 406）。`If-None-Match: *` は、`last_modified:` だけで検証した応答からも 304 を受け取ります。
- `permit` と `expect` は、Array でないフィルターで `ArgumentError` を発生させます。存在しないレイアウトを指す `layout` は `MissingTemplate` を発生させます（既定の `application` レイアウトは省略可能なままです）。ジャーの Cookie が 4096 バイトを超えると `Session::CookieOverflow` を発生させます。
- `public/style.css` はそのまま動きます。`app/assets/stylesheets/` への移動は任意です（[アセット](assets.md#moving-publicstylecss)）。
- バリデーションメッセージは同梱の辞書から来ます（[国際化](i18n.md#models-and-validation-messages)）。英語の文面は同じですが、3 つだけ違います：`:base` のメッセージの頭に "Base" が付かなくなり、`_id` で終わる属性は "id" なしで呼ばれ（"Article id can't be blank" ではなく "Article can't be blank"）、長さの上限 1 は "1 character" になります。これらのメッセージを比べるテストは変わります。
- `format:` なし、または書式名つきの `time_tag` は `I18n.l` で整形されます（英語のページでは以前と同じ英語の文面です）。
- gen は `gen/locales.rb`（`config/locales/` がなければ空）を書き、`app/mailers/**/*.rb` を読み込みます。`cybertrain new` は `config/locales/en.yml` を書きます。古いアプリケーションも足せます。
- `allow_unauthenticated_access` はフレームワークのメソッドになりました。0.4 のジェネレーターが `ApplicationController` に書いたものも動き続け、そちらが優先されます。`cybertrain generate authentication` をもう一度実行すると、パスワードリセット、ロックアウト、ログインしたままにする、アカウントページ、管理者ユーザーが加わり、0.4 が書いたファイルの差分が表示されます（[0.4 からのアップグレード](authentication.md#upgrading-from-04)）。
