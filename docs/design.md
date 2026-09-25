# cybertrain 設計文書

- 状態: 合意済み（2026-09-24 の grilling セッションで 15 項目を確認）
- 対象: Spinel `2026.09.12` リリース
- 次の工程: M0 スパイク（第 9 章）。本文書の「未検証の前提」が確認できるまで、M1 以降には着手しない。

## 0. 一言でいうと

cybertrain は、matz の Ruby AOT コンパイラ **Spinel** の上で動く、**Rails 風の開発体験を持つ Web アプリケーションフレームワーク**である。Rails の実行時メタプログラミングに相当する部分を「ビルド時のコード生成」と「実行時のデータ」に置き換え、アプリを `spin build` で単一の native バイナリにする。

既存の Rails アプリを Spinel で動かす **Roundhouse**（Sam Ruby）とは目的が異なる。cybertrain のアプリは最初から cybertrain 向けに、Spinel の Ruby 部分集合で書く。

## 1. 背景と前提

### 1.1 Spinel とは

- Ruby ソースを全プログラム型推論にかけ、C を生成し、システムの C コンパイラで native バイナリにする AOT コンパイラ。ランタイム依存なし。初回リリースは 2026.09.12。
- パーサは libprism。`require_relative` はパース時にファイルをインライン展開する。
- 付属ツール `spin` がプロジェクトの雛形生成、依存解決（git ホストの `spin-index`）、ビルド、スナップショットテストを担う。依存パッケージはソースツリーとしてバイナリに取り込まれ、`.c` ファイルも同梱できる。

### 1.2 確認した制約（設計の全分岐がここに依存する）

使えないもの:

- `eval`、文字列の `instance_eval` / `class_eval`
- `method_missing`（定義すると警告、dispatch されない）
- 名前を実行時に計算する `define_method` / `send`（リテラル名なら可。非リテラル `send` は「プログラム中に現れるリテラル名に限って」dispatch される）
- `Class.new`、クラス本体の外での `include` / `attr_accessor`（実行時のクラス変更）
- `ObjectSpace`、`autoload`、`require` のロード順序の意味論、glob による require
- `instance_variable_get` / `const_get` の非リテラル名、`Exception#backtrace`（空を返す）
- `Refinements`、`TracePoint`、`binding` のオブジェクト化
- `require "time"` の解析部、`json/pure` などメタプロ依存の標準ライブラリ

使えるもの:

- クラス、継承、`super`、`include`、open class、`attr_accessor`、`Struct`、リテラル名の `define_method` / `send`、ブロック形の `instance_eval` / `instance_exec`
- Thread（M:N グリーンスレッド、GVL なし、真の並列）、Fiber、Mutex、Queue / SizedQueue、ConditionVariable
- TCPServer とソケット（整数オプションのみ、non-blocking 系は未整備）、Net::HTTP（HTTP/1.1、keep-alive なし）
- FFI: `ffi_func` / `ffi_lib` / `ffi_const` / `ffi_buffer` / `ffi_struct` / `ffi_callback` / `ffi_source`、`blocking: true`。ポインタは GC 非追跡。sqlite3 の公式例あり
- 標準パッケージ 22 個: base64, bigdecimal, cgi, csv, digest, erb, fileutils, forwardable, io, json, net, openssl, optparse, pathname, securerandom, set, stringio, strscan, tempfile, tmpdir, uri, zlib
- RBS サイドカー（`.rbs`）による型の補助

注意点:

- 型付き配列は要素型の混在を拒否する。混在させるとタグ付き共用体（poly）になる。
- `nil` と `String` が混ざると nullable String になる。
- ユーザ定義の `#hash` / `#eql?` は Hash キーで呼ばれない。
- ソケット読み取りで停止したグリーンスレッドが他の I/O を止める不具合（issue #4528）は close 済みだが、ワーカー数と同時接続数の関係で劣化する報告があった。
- Roundhouse の Spinel ターゲットは「接続ごとにグリーンスレッド、Spinel 自身のネットワーク層、`-lsqlite3` リンク、prefork は未完成」で実運用している。

### 1.3 Roundhouse との関係

- Roundhouse は「Rails を仕様とみなし、Rails アプリを Spinel 向けの平易な Ruby（メタプロなし）に変換する」トランスパイラ。cybertrain は Rails 互換を目指さず、Spinel ネイティブの新しいフレームワークを作る。
- Roundhouse の `runtime/ruby/`（router、action_view、active_record 相当をメタプロなしで書いたもの）は依存先ではなく先行事例として参照する。

## 2. 目的、合格基準、非目標

### 2.1 目的

- Rails の語彙と規約（MVC のディレクトリ、`resources`、`before_action`、`validates`、`form_with`、`link_to`、flash、scaffold）を、Spinel の制約下で可能な限りそのまま提供する。
- ビューの編集は再コンパイルなしで即座に反映する。
- アプリは `spin build` 一発で単一バイナリになり、逆プロキシと SQLite ファイルだけで本番稼働できる。

### 2.2 合格基準（MVP）

Rails Guides「Getting Started」相当のブログ（Article と Comment）が、以下を満たして動くこと。

- `resources :articles do resources :comments end` によるルーティングと CRUD コントローラ
- validations、`has_many` / `belongs_to`（外部キー由来）
- ERB 構文のビュー、レイアウト、パーシャル、フォームヘルパー、flash、redirect
- マイグレーションと SQLite
- integration テストが CI（ubuntu / macOS）で通る
- `spin build` で単一バイナリ

### 2.3 非目標（MVP）

認証、メーラー、ジョブ、WebSocket / ActionCable、アセットパイプライン（静的ファイル配信のみ）、i18n、API 専用モード（`render json:` の最小限のみ）、Rails 互換、Rack 互換、Windows ネイティブ。

## 3. 設計原則

1. **リクエスト間で変わらない決定はビルド時に解決する。** ルーティング、属性、関連、URL ヘルパー、polymorphic path はすべて生成コードで固定する。
2. **生成コードは手でも書ける普通の Ruby で、リポジトリにコミットする。** Spinel のエラーは生成コードの行を指すので、読めて grep できなければならない。
3. **データ構造は型付きにする。** Rack の `env` や `[status, headers, body]` のような混在コンテナを避け、Spinel の型推論に乗せる。
4. **Rails の語彙を借り、意味論は Spinel 向けに定義し直す。** 同名の API が Rails と細部で異なることは許容し、文書化する。
5. **Spinel の Ruby だけで閉じる。** 開発機に CRuby を要求しない。C を使うのは FFI 経由の SQLite と、将来の性能最適化のみ。

## 4. アーキテクチャ決定

各項目は「決定 / 理由 / 却下した案 / 帰結」で記す。

### D1. 位置づけ: Spinel ネイティブのフレームワーク

- 決定: 既存 Rails アプリの移植は扱わない。アプリは cybertrain の API に対して直接書く。
- 理由: 既存 Rails の移植は Roundhouse が担っており、そこと競合しても意味がない。ネイティブなら Spinel の制約に合わせて API を設計でき、Roundhouse が扱えない「Spinel の強みを活かす設計」が可能。
- 却下: Rails トランスパイラ（Roundhouse と重複）、Roundhouse の出力先ランタイム（Roundhouse は自前ランタイムを持つ）。

### D2. 合格基準: ブログ、サーバサイド HTML

- 決定: 第 2 章のとおり。
- 理由: 全 Rails 開発者が知る題材で、全サブシステムを通過する。API 専用にすると最難関のビュー層を先送りしてしまう。

### D3. 生成コードは「手でも書ける普通の Ruby」でコミットする

- 決定: ジェネレータは Rails の generators と同じ糖衣。`spin build` 単体でビルドできる。生成に必ず頼るのは「schema 由来のモデル属性」と「routes 由来の dispatch / URL ヘルパー」（ビューは D9 により実行時解釈になり、生成対象から外れた）。
- 理由: 原則 2。`spin` にビルドフックがないので、生成物をコミットしておけば `spin build` / `spin test` がそのまま使える。CI では生成物の鮮度を diff で検査する。
- 却下: 専用 DSL を必ずトランスパイルする方式（生成物が隠れ、フレームワークが実質コンパイラになり、パーサとエミッタなしには何も動かない）。

### D4. ジェネレータは Spinel プログラム、入力はデータ DSL と字句走査のみ

- 決定: アプリ側の `bin/gen.rb` をアプリごとにコンパイルして `spin run gen` で実行する。入力は次の 3 つに限る。
  1. `db/schema.rb`（`create_table` DSL を実行して表データを得る）
  2. `config/routes.rb`（`resources` などを実行して経路データを得る）
  3. `app/controllers/**/*.rb` の**字句走査**（正規表現で `@name =` 代入と `class X < Y` 行を拾う。構文解析はしない）
  さらに `app/` 配下のファイル一覧から `gen/app.rb`（`require_relative` 一覧）を生成する。
- 理由: Spinel には Ruby パーサが公開されていない。`bin/gen.rb` がモデルを `require_relative` すると、生成前の属性メソッドを呼ぶモデルでジェネレータ自身がコンパイルできない（鶏と卵）。入力をデータに限ればこの問題が構造的に消える。ivar の字句走査は例外だが、コントローラを変えたときはどのみち再コンパイルするので開発体験を損なわない。
- 却下: CRuby + Prism のスクリプト（開発機に CRuby が必須になり、二つのランタイムを抱える）。
- 帰結:
  - `db/schema.rb` と `config/routes.rb` にはアプリの定数を書けない（文字列とシンボルのみ）。
  - モデル内の `validates` / `before_save`、コントローラの `before_action` は生成ではなく実行時データで実装する。
  - 関連は schema の `t.references` / 外部キーから既定で生成する。`through` などは MVP 外。

### D5. HTTP サーバは純 Ruby の HTTP/1.1

- 決定: `TCPServer` で accept、接続ごとにグリーンスレッド 1 本。HTTP パース、keep-alive、chunked をフレームワーク内の Ruby で書く。TLS と HTTP/2 は逆プロキシ（nginx / Caddy）に任せる。プロセスは 1 つ、ワーカー数は `SPINEL_WORKERS` に従う。
- 理由: 全体が Spinel の Ruby だけで閉じ、`spin build` 一発で単一バイナリになる。Roundhouse が同構成で実運用済み。
- 却下: C の HTTP ライブラリを FFI で使う（ポインタ寿命の手動管理、ビルド依存）、CGI / FastCGI（プロセス起動が毎回、またはどのみちソケットが要る）。
- 帰結: サーバは「accept したソケットから Request を作り Response を書き戻す」小さなインターフェースの裏に置き、後から picohttpparser を spin パッケージの `.c` として同梱し `ffi_func` で差し替えられるようにする。prefork は Spinel 側が未完成と明言しているので扱わない。

### D6. 型付きの Request / Response、Rack 非互換

- 決定: `Request`（method、path、query、headers、body、cookies、params）と `Response`（status、headers、body）をクラスとして定義する。ミドルウェアは `Middleware` 基底クラスを継承し `call(ctx)` を実装する。`@app` の型は基底クラスに固定される。
- 理由: `[Integer, Hash, Array]` の 3 つ組や `Hash<String, 何でも>` の `env` は poly になり、毎リクエストの共用体の出し入れが増える。Rack 互換の最大の動機である gem の流用は Spinel では不可能。
- 帰結: コントローラ API は Rails と同じ語彙（`request`、`response`、`params`、`cookies`、`session`、`headers`）。テストは `Request` を直接組み立ててプロセス内で呼ぶ。

### D7. ルーティングは生成、DSL は Rails 構文

- 決定: `config/routes.rb` は `root`、`resources`（ネスト、`only:` / `except:`、`member` / `collection`）、`get` / `post` / `patch` / `delete` + `to: "ctrl#action"` を受け付ける。ジェネレータは `gen/routes.rb` に (1) 経路表（メソッド、分割済みセグメント、controller / action 名、経路名）、(2) 経路ごとに `PostsController.new(ctx).process(:show) { |c| c.show }` を呼ぶ `case` 文、(3) `posts_path` / `post_path(post)` / `edit_post_path(post)` / `*_url` をリテラル名のメソッドとして吐く。
- 実行時: HTTP メソッド別に線形走査してセグメント比較する。`_method` パラメータによる PATCH / DELETE の上書きをミドルウェアで行う。
- 帰結: 存在しない controller / action を指す経路はコンパイルエラーになる。`process(:show) { |c| c.show }` の形により、コントローラは action 名（テンプレート選択と暗黙 render に使う）とアクション本体をリテラルで受け取れ、`send(:show)` に頼らない。
- MVP 外: `namespace` / `scope`、`constraints`、format サフィックス、`mount`、glob / 正規表現セグメント、`redirect` ルート。

### D8. コントローラ

- コールバック: ブロックが公式構文。`before_action { set_post }`、`before_action(only: [:show, :edit]) { ... }`。実行時は `instance_exec` のブロック形で呼ぶ。`before_action :set_post` のシンボル形は、非リテラル `send` の動作をスパイクで確認できた場合に限り追加する。
- `params`: 型付き `Params` クラス。`params[:id]` は `String | nil`、`params[:post]` は子 `Params`、配列値は `params.list(:ids)`。`params.require(:post).permit(:title, :body)` は `Hash<Symbol, String>` 相当を返し、モデルの生成済み `assign_attributes` に渡す。MVP で permit できる値は文字列のみ。
- render / redirect: `render :new`（リテラルシンボル）、`render json: post`（生成 `to_json`）、`render plain:`、`head :not_found`、`redirect_to post_path(post)`、`redirect_to posts_path, status: :see_other`。action が何もしなければ action 名のテンプレートを暗黙 render する。
- session: クッキーストアのみ。値は `String` だけ。`openssl` / `digest` の HMAC で署名し、改竄は捨てる。`flash[:notice]` / `flash.now[:alert]` は session 上に載せる。
- CSRF: 既定で有効。トークンを session に持ち、フォームヘルパーが hidden field を出し、GET 以外で検証する。
- 例外: `rescue_from(RecordNotFound) { head :not_found }` のブロック形。開発時のエラーページは例外クラス・メッセージ・テンプレート名と行のみ。スタックトレースは Spinel の制約で出せない。
- MVP 外: `respond_to` / format、streaming、`helper_method`、`layout` の動的切り替え（`application` 固定）。

### D9. ビューは「ERB 構文の実行時解釈テンプレート言語」

- 決定: `app/views/**/*.html.erb` を実行時に読んで AST にパースし、フレームワークのインタプリタが評価する。開発時は mtime を見て変更があれば再パース、production では初回だけパースしてキャッシュ。テンプレートはバイナリの外に置く。
- 理由: ビュー編集は開発で最も回数の多いサイクルであり、そこに再コンパイルを挟みたくない（コンパイル済み ERB 案はこの理由で却下）。Spinel に `eval` はないので、実行時に動かせるのは「ERB の見た目をした、文法を自分で定義したテンプレート言語」だけである。両立はできない。
- 式の文法（Ruby の部分集合、第 7 章に詳細）: リテラル、`@ivar`、ローカル変数、メソッド呼び出し（位置引数・キーワード引数）、`&.`、演算子、文字列補間、`if / elsif / else / unless / end`、`each do |x|` / `each_with_index`、`form_with ... do |f|`。ブロックはこの 2 種類だけ。
- 値の表現: `Value` というタグ付き共用体（nil / bool / Integer / Float / String / SafeString / Array / Hash / Time / Model）。
- モデルへのアクセス: 属性と関連は schema 由来の生成コード `read_attribute(:title)` / `read_association(:comments)` で名前解決する。手書きメソッドをテンプレートから呼ぶには、モデル側で `view_methods :summary` と宣言する。これは非リテラル `send` の仕様に依存するのでスパイクで検証する。
- `@post` の受け渡し: D4 の字句走査で `gen/view_assigns.rb` に `{ "post" => @post, ... }` を吐く（既定）。`render :show, locals: { post: @post }` の明示渡しも併用できる。
- パーシャル: Rails 7.1 の strict locals 構文 `<%# locals: (post:) %>` を採用する。`<%= render "form", post: @post %>` はリテラル名のみ。
- レイアウト: `application` 固定。`<%= yield %>` と `content_for :title` / `yield :title`（`Hash<Symbol, String>`）。
- エスケープ: `<%= %>` は既定でエスケープ、`<%== %>` と `raw` で無効化。ヘルパーの戻り値は `SafeString`（String のサブクラスではないラッパ）。
- ヘルパー（組み込み）: `link_to`、`button_to`、`form_with(model:)` と `f.label` / `f.text_field` / `f.text_area` / `f.submit`、`render`、`pluralize`、`truncate`、`number_*`、`time_ago_in_words`。URL ヘルパーと polymorphic path は routes 由来の生成 `case` 文で解決する（`form_with(model: [@post, @comment])` は routes に存在する組だけ生成）。
- 代償: テンプレート内の任意 Ruby は書けない。テンプレートの型エラーは実行時（開発時のエラーページ）で出る。速度はコンパイル済みより落ちるが、インタプリタ自体が C にコンパイルされるので CRuby の ERB より遅くはならない見込み（スパイクで測る）。
- 将来: 同じ AST から Ruby メソッドを吐くコンパイルバックエンドを足せば、production だけコンパイル済みにして速度・型検査・単一ファイル化を取り戻せる。パーサを共有するので意味のずれは抑えられる。MVP には入れない。

### D10. モデル

- 真実の源の流れ: `db/migrate/*.rb`（`create_table`、`add_column`、`add_reference`、`add_index` の DSL）→ `spin run db migrate` が適用 → DB から `db/schema.rb` をダンプ → ジェネレータが `gen/models/*.rb` を吐く。マイグレーションはアプリ定数を含まないデータ DSL なので `bin/db.rb` にそのまま取り込める。
- モデルごとの生成物: `attr_accessor`（schema の型から `String | nil`、`Integer | nil`、`Time | nil` などが推論される代入コード付き）、`read_attribute` / `write_attribute` / `assign_attributes` の `case` 文、`from_row`、`to_json`、`attribute_names`、外部キー由来の関連（`Comment#post`、`Post#comments`）。
- Relation はモデルごとに生成: `Post.where(...)` は `PostRelation`、`.first` は `Post | nil`、`.to_a` は `Array<Post>`。SQL 組み立ては基底 `Cybertrain::Relation`、実体化だけ生成側で型付けする。汎用 Relation の共有は要素型が `Post | Comment | ...` に広がる恐れがあるため避ける。
- API（ActiveRecord の部分集合）: `find`、`find_by`、`where(hash)`、`where("sql ?", bind)`、`order`、`limit`、`offset`、`first` / `last` / `all` / `count` / `exists?`、`new` / `create` / `save` / `save!` / `update` / `destroy`、`persisted?`、timestamps 自動更新。動的ファインダ（`find_by_title`）は提供しない。scope は `def self.published = where(published: true)` の普通のクラスメソッド。
- validations / callbacks: `validates :title, presence: true, length: { minimum: 5 }` は検証器の配列に積み、`valid?` が `read_attribute` 経由で評価する。`errors.full_messages` / `errors[:title]` / `errors.any?`。`before_save { }` / `after_create { }` はブロック。
- アダプタ: SQLite（FFI）のみ。`Adapter` インターフェースの裏に置き、`execute(sql, binds)` が行の配列を返す。接続は `SizedQueue` によるプール（初期値はワーカー数）、WAL モードと busy_timeout を既定で設定、`sqlite3_step` は `blocking: true`。PostgreSQL は libpq の FFI で後日。
- MVP 外: `has_many :through`、`includes` / `preload`、`pluck`、モデル API の `transaction`、enum、STI、polymorphic 関連、`dependent:`。

### D11. 名前、パッケージ構成、雛形

- 名前は `cybertrain`、ライセンスは MIT。
- フレームワークは spin のライブラリパッケージ（`spin new cybertrain --lib` の配置）。`spin.toml` の `[package] name = "cybertrain"`、入口 `cybertrain.rb`、機能ごとに `cybertrain/server.rb`、`router.rb`、`template.rb`、`model.rb`、`sqlite.rb`、`generator.rb` などに分割。`native/` を将来の `.c` 用に予約。公開は `matz/spin-index` への登録、それまでは `{ path = "../cybertrain" }` 参照。
- CLI はフレームワーク側の `bin/cybertrain.rb`。`spin build` で単一バイナリになり PATH に置く。役割は `cybertrain new blog` の雛形生成と `cybertrain generate scaffold post title:string body:text` のコード生成のみ。
- アプリの雛形と bin は第 11 章。ビルドは `spin run gen` → `spin build` の 2 段。

### D12. 開発ループ: サーバが自分で再ビルドして自分を置き換える

- 決定: `bin/server.rb` が `CYBERTRAIN_ENV=development` のときだけ監視モードになる。監視対象は `app/**/*.rb`、`config/`、`db/schema.rb`。mtime を 0.5 秒間隔でポーリング。`app/views/**/*.erb` は監視対象外（テンプレートエンジンが自分で再読み込み）。
- 変更を検知したら `spin run gen && spin build server` を `system` で実行し、成功したら listen ソケットを閉じて libc の `execv` を FFI で呼び、新しいバイナリに自分を置き換える。`SO_REUSEADDR` を立てる。
- ビルド失敗でサーバは死なない。旧バイナリのまま動き続け、コンパイラの stderr を保持して次のリクエストで開発用エラーページとして返す。
- マイグレーションは自動で流さない。`spin run db migrate` の結果 `db/schema.rb` が変わることで再ビルドが走る。
- production: 監視もビルドも無効。バイナリ、`storage/*.sqlite3`、`app/views/`、`public/` を同梱して配布する。ビューを外部ファイルに置く決定の帰結として、バイナリ単体では動かない。
- 却下: 別プロセスの監視ツール（構成が増える）。

### D13. テストと CI

- `spin test` の仕組み（`test/*.rb` の各ファイルが 1 プログラム、stdout を `.expected` と diff）に合わせ、`Cybertrain::Test` を用意する。`test "saves a post" do ... end` を配列に積んで順に実行、決定的な形式で出力、失敗があれば非ゼロ終了。アサーションは `assert`、`assert_equal`、`assert_nil`、`assert_raises`、`assert_includes`。
- アプリのテストは model、controller / integration（`get "/posts"`、`post "/posts", params: {...}`、`assert_response :ok`、`assert_redirected_to`、`assert_includes response.body, "..."`。ソケット不使用）、テンプレート（エンジンに文字列を渡す）の 3 種類。
- テスト用 DB は `storage/test.sqlite3`。各テストをアダプタ層の `BEGIN` / `ROLLBACK` で包む。
- テストプログラムは領域ごとに 1 ファイル（`test/models.rb`、`test/controllers.rb`）。`spin test` はファイルごとにアプリ全体をコンパイルする。
- フレームワーク自身のテストは `.expected` をコミットして CRuby 非依存にする。
- CI は GitHub Actions、Spinel `2026.09.12` を固定、ubuntu / macOS の 2 ジョブ。`examples/blog` の integration テストを回す。

### D14. 横断的な既定値

- 環境: `CYBERTRAIN_ENV` = `development` / `test` / `production`。設定は `config/app.rb` の Ruby DSL。YAML は使わない。
- 秘密鍵: `CYBERTRAIN_SECRET_KEY_BASE`。production で未設定なら起動を拒否。development / test は `tmp/secret_key` に生成して固定。
- DB: `storage/<env>.sqlite3`。`created_at` / `updated_at` は UTC の ISO 8601 文字列。タイムゾーン変換は持たない。日付文字列の解釈はフレームワークが最小限を自前で持つ。
- 静的ファイル: `public/` をミドルウェアで配信。拡張子 → Content-Type の表のみ。production では逆プロキシに配信させることを推奨。
- JSON: `json` パッケージ。`render json:` と、`application/json` のリクエストボディの `params` 取り込みに限る。
- ログ: 標準出力に 1 リクエスト 2 行（`Started GET "/posts"`、`Completed 200 in 3ms`）。`Cybertrain.logger` に `info` / `warn` / `error`。
- エラーページ: production は `public/404.html` / `public/500.html`、development は診断ページ。
- 安全側の既定: 出力エスケープ、CSRF、署名クッキー、SQL は常にバインド変数、`X-Content-Type-Options: nosniff`、`X-Frame-Options: SAMEORIGIN`。
- 終了処理: `SIGTERM` で listen を止め、処理中のリクエストを待って終了。`trap` が使えなければ libc の `signal` を FFI で呼ぶ。
- i18n なし。バリデーションメッセージは英語固定。

## 5. リクエストの流れ

1. `Server` が accept したソケットで HTTP/1.1 をパースし、`Request` を作る。
2. ミドルウェア連鎖: ログ → 静的ファイル → `_method` 上書き → session（署名クッキーの復号）→ CSRF 検証 → ルーター。
3. ルーターは `gen/routes.rb` の経路表を走査し、一致した経路の dispatch 節を呼ぶ: `PostsController.new(ctx).process(:show) { |c| c.show }`。
4. `process` は `before_action` ブロックを `instance_exec` し、アクション本体を呼び、render も redirect も起きていなければ action 名のテンプレートを暗黙 render する。
5. render はテンプレートエンジンに `view_assigns`（生成済み）、ヘルパー群、`Value` 化した値を渡して描画し、レイアウトで包む。
6. `Response` をソケットに書き戻す。keep-alive なら次のリクエストを待つ。

## 6. ジェネレータの入出力

| 入力 | 出力 | 内容 |
| --- | --- | --- |
| `db/schema.rb` | `gen/models/<model>.rb` | `attr_accessor`、`read_attribute` / `write_attribute` / `assign_attributes` の `case`、`from_row`、`to_json`、`attribute_names`、外部キー由来の関連、`<Model>Relation` |
| `config/routes.rb` | `gen/routes.rb` | 経路表、dispatch の `case`、`*_path` / `*_url`、polymorphic path の `case` |
| `app/controllers/**/*.rb`（字句走査） | `gen/view_assigns.rb` | コントローラごとの `view_assigns` メソッド（open class） |
| `app/` のファイル一覧 | `gen/app.rb` | `require_relative` 一覧 |

生成物はすべてコミットする。CI で `spin run gen` 後に `git diff --exit-code gen/` を実行し、鮮度を検査する。

## 7. テンプレート言語の仕様案

ERB のタグ: `<% %>`、`<%= %>`（エスケープ）、`<%== %>`（非エスケープ）、`<%# %>`、`<%- -%>`（トリム）、先頭の `<%# locals: (a:, b:) %>`。

式:

- リテラル: 整数、浮動小数、文字列（`"..."` は `#{}` 補間可、`'...'` は不可）、シンボル、`nil` / `true` / `false`、配列 `[...]`、ハッシュ `{ key: value }`（キーワード引数と同じ形）
- 変数: `@ivar`（`view_assigns` から）、ローカル（`each` の束縛と strict locals）
- 呼び出し: `recv.method`、`recv.method(args, key: value)`、`recv&.method`、`method(args)`（ヘルパー）
- 演算子: `== != < <= > >= && || ! + - * / % ?:`
- 制御: `if` / `elsif` / `else` / `unless` / `end`、`each do |x|` / `each_with_index do |x, i|`、`form_with(...) do |f|`
- 値ごとの許可メソッド表: String（`upcase` `downcase` `capitalize` `strip` `size` `length` `empty?` `to_s`）、Integer / Float（算術と `to_s`）、Time（`strftime` `year` `month` `day` `to_s`）、Array（`size` `length` `empty?` `first` `last` `any?`）、Model（生成属性、生成関連、`errors`、`persisted?`、`new_record?`、`to_param`、`view_methods` で宣言したもの）、`errors`（`any?` `full_messages` `[]` `count`）

明示的に非対応: 任意ブロック（`map { }` など）、代入以外のローカル定義、`case`、正規表現、範囲、メソッド定義、`require`。

## 8. 意図的に捨てたもの

- `rails console`（`eval` が存在しない）
- テンプレート内の任意 Ruby、テンプレートの型エラーのコンパイル時検出、スタックトレース付きエラー画面
- production バイナリの完全単一ファイル化（`app/views` と `public` を同梱。将来のコンパイルバックエンドで回収可能）
- `namespace` / format / `respond_to`、`has_many :through`、`includes`、`transaction` API、i18n、認証、メーラー、ジョブ、WebSocket
- Rack 互換、Rails 互換、CRuby 上での実行

## 9. 未検証の前提とスパイク計画（M0）

`spikes/` に小さな Spinel プログラムを置き、`2026.09.12` で検証する。

| # | 検証項目 | 落ちた場合 |
| --- | --- | --- |
| 1 | `spinel` / `spin` の導入、`spinel --help` の最適化レベル、2,000 行規模のコンパイル時間 | 開発ループ（D12）の体感を再評価 |
| 2 | 非リテラル `send` がリテラル名に dispatch できるか、戻り値の型、`instance_exec` のブロック形 | `view_methods` を生成 `case` 文に変更。コールバックのシンボル形は提供しない |
| 3 | **タグ付き共用体 `Value` を持つ木構造インタプリタが型推論を通り、100 行のテンプレート × 1 万回の描画速度が出るか** | D9 をコンパイル済み ERB（監視・再ビルド方式）に戻す。最大のリスク |
| 4 | 基底 `Relation` と `PostRelation` で `first` が `Post \| nil` に推論され、複数モデルで型が広がらないか | Relation を生成テンプレートで全量複製する |
| 5 | `TCPServer` + グリーンスレッド + keep-alive で 100 同時接続、レイテンシ、issue #4528 の再現有無 | `SPINEL_WORKERS` の既定値調整、または接続数上限の導入 |
| 6 | SQLite FFI の open / prepare / bind / step / column、`blocking: true`、`SizedQueue` プールの複数スレッド利用、WAL | 接続をスレッドローカルに変更 |
| 7 | `execv` の FFI、`trap` の可否、`SO_REUSEADDR` | 監視を別プロセスに分離 |
| 8 | `openssl` / `digest` の HMAC、`json`、`cgi` の `escapeHTML`、`uri` のクエリ解析 | 自前実装で代替 |

go / no-go: 2 と 3 の結果で D8 / D9 を確定してから M1 に進む。

## 10. マイルストーン

- **M0** スパイク完了と go / no-go 判定。
- **M1** HTTP サーバ、Request / Response、ミドルウェア、手書き経路表でのルーティング、静的ファイル、ログ。`hello world` コントローラが動く。
- **M2** テンプレートエンジン、レイアウト、パーシャル、ヘルパー、`view_assigns` 生成。
- **M3** SQLite アダプタ、マイグレーション、`db/schema.rb` ダンプ、モデル生成、validations、`Cybertrain::Test`。
- **M4** routes 生成と URL ヘルパー、フォームヘルパー、セッション、flash、CSRF。blog が end-to-end で動き、integration テストが CI で通る。**合格基準**。
- **M5** 開発ループ、エラーページ、`cybertrain new` / `generate scaffold`、README。

## 11. リポジトリ構成

フレームワーク（このリポジトリ）:

```
cybertrain/
  spin.toml                 # [package] name = "cybertrain"
  cybertrain.rb             # 入口
  cybertrain/
    server.rb  request.rb  response.rb  middleware.rb
    router.rb  controller.rb  params.rb  session.rb
    template/               # lexer.rb  parser.rb  interpreter.rb  helpers.rb  value.rb
    model.rb  relation.rb  validations.rb  migration.rb
    sqlite.rb               # FFI アダプタ
    generator/              # schema.rb  routes.rb  view_assigns.rb  manifest.rb
    test.rb                 # Cybertrain::Test
  bin/cybertrain.rb         # new / generate
  native/                   # 将来の .c
  test/                     # spin test（.expected をコミット）
  examples/blog/            # 合格基準のアプリ
  spikes/                   # M0
  docs/design.md            # 本文書
```

アプリ（`cybertrain new blog` が生成）:

```
blog/
  spin.toml                 # [dependencies] cybertrain = ...
  app/controllers/  app/models/  app/views/
  config/routes.rb  config/app.rb
  db/migrate/  db/schema.rb
  gen/                      # コミットする生成物（models/ routes.rb view_assigns.rb app.rb）
  bin/server.rb  bin/gen.rb  bin/db.rb
  test/models.rb  test/controllers.rb
  public/  storage/  tmp/
```

## 12. 参考

- Spinel: https://github.com/matz/spinel （README、`docs/limitations.md`、`docs/FFI.md`、`docs/spin.md`、`packages/`）
- Spinel issue #4528（ソケット読み取りで停止したスレッドが他の I/O を止める）: https://github.com/matz/spinel/issues/4528
- spin-index: https://github.com/matz/spin-index
- Roundhouse: https://github.com/rubys/roundhouse （`docs/guide/spinel.md`、`runtime/ruby/`）
- spinelgems（gem 互換性調査、bundler-spinel）: https://github.com/OriPekelman/spinelgems
- rubocop_spinel: https://github.com/gurgeous/rubocop_spinel
