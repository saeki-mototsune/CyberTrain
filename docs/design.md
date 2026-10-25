# cybertrain 設計文書

- 状態: 合意済み（2026-09-24 の grilling セッションで 15 項目を確認）
- 対象: Spinel `2026.09.12` リリース
- 実装状況: 第 13 章（M0〜M5 はすべて到達。以降の変更は各決定の改訂注記（「2026-09-26 改訂」など）と第 13 章に記録）

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
- （スパイク 2 で判明）`instance_exec(&stored_block)` / `instance_eval(&stored_block)` は、保存済みブロックに対してはどの形でもコンパイルできない（ブロックはクラス本体時点の `self` で固定される）。リテラルブロックを直接渡す形だけ動く。
- （スパイク 2 で判明）非リテラル `send` は「プログラム中の Symbol / String リテラルが 128 個以下」のときだけ desugar される（`src/analyze_desugar.c`）。実アプリは確実に超えるので、フレームワークは非リテラル `send` と非リテラル `respond_to?` を一切使わない。
- （スパイク 2 で判明）インスタンスメソッドから `self.class.foo` を呼ぶとき、`foo` が基底クラスにしか定義されていないと `self` が静的な基底クラスに束縛される（サイレントなミスコンパイル）。クラスを引数で明示的に渡すか、全サブクラスで `foo` を上書きする（生成コードの `self.table_name` など）。
- （スパイク 2 で判明）`Method` オブジェクトを配列に入れて `call` すると実行時 `NoMethodError`。コレクションに入れるのは lambda にする。
- （ハーネス実装で判明）多相な受け手に多相な引数で `include?` を呼ぶと誤った結果になる。`case` で受け手の型を絞ってから呼ぶ。
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

認証（MVP 後の 2026-10-22 に D15 として追加）、メーラー、ジョブ、WebSocket / ActionCable、アセットパイプライン（静的ファイル配信のみ）、i18n、API 専用モード（`render json:` の最小限のみ）、Rails 互換、Rack 互換、Windows ネイティブ。

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
  3. `app/controllers/**/*.rb` と `app/models/**/*.rb` の**字句走査**（正規表現で `@name =` 代入、`class X < Y` 行、`before_action :name` / `after_action :name` / `rescue_from X, with: :name`、モデルの引数なし `def name` を拾う。構文解析はしない）
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
- 帰結: サーバは「accept したソケットから Request を作り Response を書き戻す」小さなインターフェースの裏に置き、後から picohttpparser を spin パッケージの `.c` として同梱し `ffi_func` で差し替えられるようにする。prefork は Spinel 側が未完成と明言しているので扱わない。スパイク 5 で確定した実装規則: (1) すべての `readpartial` の直前に `sock.wait_readable(timeout)` を呼ぶ（nil ならアイドルタイムアウト）。素の `readpartial` は `read(2)` で OS ワーカーを止め、他の接続の I/O を止める。(2) ソケットを `Thread.new` の引数で渡さず、`def spawn_conn(sock); Thread.new { serve(sock) }; end` のようにメソッド引数をクロージャで捕まえる（引数渡しは静的型を失う）。(3) I/O 中心の負荷では `SPINEL_WORKERS=1` の方が速く（54〜58k rps 対 25〜45k）、`config.workers` で既定を 1 にし環境変数で上書き可能にする。テンプレートと SQLite が入った後に再計測する。

### D6. 型付きの Request / Response、Rack 非互換

- 決定: `Request`（method、path、query、headers、body、cookies、params）と `Response`（status、headers、body）をクラスとして定義する。ミドルウェアは `Middleware` 基底クラスを継承し `call(ctx)` を実装する。`@app` の型は基底クラスに固定される。
- 理由: `[Integer, Hash, Array]` の 3 つ組や `Hash<String, 何でも>` の `env` は poly になり、毎リクエストの共用体の出し入れが増える。Rack 互換の最大の動機である gem の流用は Spinel では不可能。
- 帰結: コントローラ API は Rails と同じ語彙（`request`、`response`、`params`、`cookies`、`session`、`headers`）。テストは `Request` を直接組み立ててプロセス内で呼ぶ。

### D7. ルーティングは生成、DSL は Rails 構文

- 決定: `config/routes.rb` は `root`、`resources`（ネスト、`only:` / `except:`、`member` / `collection`）、`get` / `post` / `patch` / `put` / `delete` + `to: "ctrl#action"` を受け付ける。実装で確定した形: トップレベルは `root "posts#index"`、`resources :posts`、`get "/about", to: "pages#about"` と受け手なしで書けるが、ネストしたブロックは受け手を明示する（`resources :posts do |posts| posts.resources :comments, only: [:create, :destroy]; posts.member { |m| m.get "preview" } end`。Spinel の `instance_eval` はフラットなブロックにしか効かない）。ジェネレータは `gen/routes.rb` に (1) 経路表（メソッド、分割済みセグメント、controller / action 名、経路名）、(2) 経路ごとに `PostsController.new(ctx).process(:show) { |c| c.show }` を呼ぶ dispatch、(3) `posts_path` / `post_path(post)` / `edit_post_path(post)` / `*_url` をリテラル名のメソッドとして吐く。
- 実行時: HTTP メソッド別に線形走査してセグメント比較する。`_method` パラメータによる PATCH / DELETE の上書きをミドルウェアで行う。
- 帰結: 存在しない controller / action を指す経路はコンパイルエラーになる。`process(:show) { |c| c.show }` の形により、コントローラは action 名（テンプレート選択と暗黙 render に使う）とアクション本体をリテラルで受け取れ、`send(:show)` に頼らない。
- MVP 外: `namespace` / `scope`、`constraints`、format サフィックス、`mount`、glob / 正規表現セグメント、`redirect` ルート。

### D8. コントローラ

- コールバック（スパイク 2 の結果で改訂）: 公式構文は Rails と同じシンボル形 `before_action :set_post, only: [:show, :edit]`。宣言はクラス名をキーにした実行時データ（`Hash<String, Array<Callback>>`）に積み、継承チェーンは `Controller.chain_for(self.class)` で `superclass` を明示的に辿る。呼び出しは `send` ではなく、ジェネレータが `app/controllers/**/*.rb` を字句走査して拾った `before_action :name` / `after_action :name` / `rescue_from X, with: :name` の名前から、コントローラごとに `def run_callback(name); case name; when :set_post then set_post; else super; end; end` を `gen/controllers.rb` に生成して dispatch する。ブロック形も提供するが、`instance_exec` が使えないためブロックはコントローラを引数で受け取る: `before_action(only: [:show]) { |c| c.set_post }`。暗黙 `self` のブロック形は提供しない。
- `params`: 型付き `Params` クラス。`params[:id]` は `String | nil`、`params[:post]` は子 `Params`、配列値は `params.list(:ids)`。`params.require(:post).permit(:title, :body)` は `Hash<Symbol, String>` 相当を返し、モデルの生成済み `assign_attributes` に渡す。MVP で permit できる値は文字列のみ。
- render / redirect: `render :new`（リテラルシンボル）、`render json: post`（生成 `to_json`）、`render plain:`、`head :not_found`、`redirect_to post_path(post)`、`redirect_to posts_path, status: :see_other`。action が何もしなければ action 名のテンプレートを暗黙 render する。
- session: クッキーストアのみ。値は `String` だけ。HMAC-SHA256 で署名し、改竄は捨てる。HMAC はランタイム同梱の `Digest::SHA256.digest`（`digest` パッケージ、外部リンク不要）の上に Ruby で実装する（動作確認済み）。`openssl` パッケージは Homebrew の OpenSSL をリンクパスに要求するため使わない。`flash[:notice]` / `flash.now[:alert]` は session 上に載せる。
- CSRF: 既定で有効。トークンを session に持ち、フォームヘルパーが hidden field を出し、GET 以外で検証する。
- 例外: `rescue_from RecordNotFound, with: :not_found`（生成 `run_callback` 経由）または `rescue_from(RecordNotFound) { |c, e| c.head :not_found }`。例外クラスは `e.class.name` の文字列比較で照合する。開発時のエラーページは例外クラス・メッセージ・テンプレート名と行のみ。スタックトレースは Spinel の制約で出せない。
- MVP 外: `respond_to` / format、streaming、`helper_method`、`layout` の動的切り替え（`application` 固定）。

### D9. ビューは「ERB 構文の実行時解釈テンプレート言語」

- 決定: `app/views/**/*.html.erb` を実行時に読んで AST にパースし、フレームワークのインタプリタが評価する。開発時は mtime を見て変更があれば再パース、production では初回だけパースしてキャッシュ。テンプレートはバイナリの外に置く。（2026-09-26 改訂: production はビルド時に `gen/views.rb` へ埋め込んだテンプレートだけを描画する。第 13 章）
- 理由: ビュー編集は開発で最も回数の多いサイクルであり、そこに再コンパイルを挟みたくない（コンパイル済み ERB 案はこの理由で却下）。Spinel に `eval` はないので、実行時に動かせるのは「ERB の見た目をした、文法を自分で定義したテンプレート言語」だけである。両立はできない。
- 式の文法（Ruby の部分集合、第 7 章に詳細）: リテラル、`@ivar`、ローカル変数、メソッド呼び出し（位置引数・キーワード引数）、`&.`、演算子、文字列補間、`if / elsif / else / unless / end`、`each do |x|` / `each_with_index`、`form_with ... do |f|`。ブロックはこの 2 種類だけ。
- 値の表現（スパイク 3 の結果で改訂）: 明示的な `Value` ラッパクラスは作らず、素の多相 Ruby 値（nil / bool / Integer / Float / String / SafeString / Array / Hash / Time / Model）をそのまま `Hash<String, 多相>` の環境に入れる。ラッパは中間結果ごとに割り当てを増やすだけで、`read_attribute` が多相値を返す以上ボクシングは減らない（実測 203 µs 対 298 µs）。
- AST の表現（スパイク 3 の結果）: パーサはノードごとのクラスで読みやすく書き、パース後に 1 回だけ「整数 kind + 型付きスロット」の単相 `INode` に変換して評価する。クラス階層のまま評価すると多相 dispatch が毎回発生して 2.7 倍遅い。値の `case` では `when Time` を `when Array` より先に置く（多相スロットの Time は `Array` にもマッチする）。
- モデルへのアクセス: 属性と関連は schema 由来の生成コード `read_attribute(:title)` / `read_association(:comments)` で名前解決する。手書きメソッドは、ジェネレータが `app/models/**/*.rb` を字句走査して引数なしの `def name` を拾い、モデルごとに `def call_view_method(name); case name; when :summary then summary; ... end; end` を生成することでテンプレートから呼べる（`view_methods` 宣言は不要。非リテラル `send` は 128 リテラル制限のため使わない）。
- `@post` の受け渡し: D4 の字句走査で `gen/controllers.rb` にコントローラごとの `view_assigns`（`{ "post" => @post, ... }`）を吐く（既定）。`render :show, locals: { post: @post }` の明示渡しも併用できる。
- パーシャル: Rails 7.1 の strict locals 構文 `<%# locals: (post:) %>` を採用する。`<%= render "form", post: @post %>` はリテラル名のみ。
- レイアウト: `application` 固定。`<%= yield %>` と `content_for :title` / `yield :title`（`Hash<Symbol, String>`）。
- エスケープ: `<%= %>` は既定でエスケープ、`<%== %>` と `raw` で無効化。ヘルパーの戻り値は `SafeString`（String のサブクラスではないラッパ）。
- ヘルパー（組み込み）: `link_to`、`button_to`、`form_with(model:)` と `f.label` / `f.text_field` / `f.text_area` / `f.submit`、`render`、`pluralize`、`truncate`、`number_*`、`time_ago_in_words`。URL ヘルパーと polymorphic path は routes 由来の生成 `case` 文で解決する（`form_with(model: [@post, @comment])` は routes に存在する組だけ生成）。
- 代償: テンプレート内の任意 Ruby は書けない。テンプレートの型エラーは実行時（開発時のエラーページ）で出る。速度は実測で、32 KB のページ描画が手書きコンパイル済み 122〜136 µs に対しインタプリタ 203 µs（1.54 倍）。同じインタプリタを CRuby で動かすより 3.2 倍速い。
- 将来: 同じ AST から Ruby メソッドを吐くコンパイルバックエンドを足せば、production だけコンパイル済みにして型検査と単一ファイル化を取り戻せる。速度面では 1.54 倍差しかないので必須ではない。MVP には入れない。

### D10. モデル

- 真実の源の流れ: `db/migrate/*.rb`（`create_table`、`add_column`、`add_reference`、`add_index` の DSL）→ `spin run db -- migrate`（`cybertrain migration`）が適用 → DB から `db/schema.rb` をダンプ → ジェネレータが `gen/models/*.rb` を吐く。マイグレーションはアプリ定数を含まないデータ DSL なので `bin/db.rb` にそのまま取り込める。
- モデルごとの生成物: `attr_accessor`（schema の型から `String | nil`、`Integer | nil`、`Time | nil` などが推論される代入コード付き）、`read_attribute` / `write_attribute` / `assign_attributes` の `case` 文、`from_row`、`to_json`、`attribute_names`、外部キー由来の関連（`Comment#post`、`Post#comments`）。
- Relation はモデルごとに生成（スパイク 4 で理由を修正）: `Post.where(...)` は `PostRelation`、`.first` / `.find` / `.find_by` は箱詰めなしの `Post | nil` に推論される（`rows` → `Post.from_row(rs[0])` の形で書く）。`to_a` はどの設計でも多相配列（Spinel はユーザオブジェクトの配列を常に poly_array にする）で、これは正しく動く。汎用 Relation でも `case rec when Post` や共用体への直接呼び出しは動くので、モデルごとの生成は「型付き `first`」と生成コードの読みやすさのために選ぶ。基底 `Cybertrain::Relation` の setter は `nil` を返し、`PostRelation` が `def where(h) = (add_where(h); self)` で型を付け直す（基底で `self` を返すと基底型に推論される）。
- 属性のキャスト（スパイク 4 で判明した必須事項）: `from_row` / `assign_attributes` は `Cast.int` / `Cast.str` / `Cast.str_or_nil` / `Cast.time_or_nil` などのキャストメソッドを通す。nil 初期化した ivar に `Time` を直接代入するとミスコンパイルする（nil が `Time.at(0)` として読める）。非 null の Integer / String は `0` / `""` で初期化し `to_i` / `to_s` でキャストする。
- 基底クラスの抽象スタブ（スパイク 4 で判明した必須事項）: `Cybertrain::Model` は生成側が上書きするフック（`read_attribute`、`assign_attributes`、`run_before_save` など）をすべて `def read_attribute(name) = nil` の形で宣言しておく。宣言がないと Spinel 2026.09.12 はコード生成でクラッシュする。
- API（ActiveRecord の部分集合）: `find`、`find_by`、`where(hash)`、`where("sql ?", bind)`、`order`、`limit`、`offset`、`first` / `last` / `all` / `count` / `exists?`、`new` / `create` / `save` / `save!` / `update` / `destroy`、`persisted?`、timestamps 自動更新。動的ファインダ（`find_by_title`）は提供しない。scope は `def self.published = where(published: true)` の普通のクラスメソッド。
- validations / callbacks: `validates :title, presence: true, length: { minimum: 5 }` は生成された `model_name` 文字列をキーにした登録簿に積み、`valid?` が `read_attribute` 経由で評価する。`errors.full_messages` / `errors[:title]` / `errors.any?` を提供。コールバックはレコードを引数に取るブロック `before_save { |r| r.title = r.title.strip }`（`instance_exec` が使えないため、暗黙 `self` の形は提供しない）。
- アダプタ: SQLite（FFI）のみ。`Connection#execute(sql, binds)` が `Array<Hash<String, Integer | Float | String | nil>>` を返す（スパイク 6 でこの型が混在しても正しく動くことを確認）。モデルの行読み出し（`Relation#rows`、`reload`）だけは `Connection#execute_models` を通り、DATETIME 列は文字列ではなく UTC のエポック秒（Integer）で返る（`Cast.time_or_nil` が Time にする。理由と数値は docs/benchmark.md）。接続は `SizedQueue` によるプール（初期値はワーカー数）、WAL モード・busy 待ち（現在は C の busy handler、100 µs 間隔で約 5 秒。`PRAGMA busy_timeout` は使わない）・foreign_keys を既定で設定、`sqlite3_step` / `prepare` / `exec` は `blocking: true`。`sqlite3_bind_text` の破棄関数には整数リテラル `-1`（SQLITE_TRANSIENT）を渡す。`sqlite3_open_v2` / `prepare_v2` の出力ポインタは静的 `ffi_buffer` を使わず、呼び出しごとに `malloc(8)` した領域を使う（静的バッファはスレッド間で競合して SIGSEGV する。スパイク 6 で再現と修正を確認）。複数行の書き込みは `BEGIN` / `COMMIT` で包む（自動コミットの 20 倍速い）。PostgreSQL は libpq の FFI で後日。
- MVP 外: `has_many :through`、`includes` / `preload`、`pluck`、モデル API の `transaction`、enum、STI、polymorphic 関連、`dependent:`。

### D11. 名前、パッケージ構成、雛形

- 名前は `cybertrain`、ライセンスは MIT。
- フレームワークは spin のライブラリパッケージ（`spin new cybertrain --lib` の配置）。`spin.toml` の `[package] name = "cybertrain"`、入口 `cybertrain.rb`、機能ごとに `cybertrain/http/`、`router.rb`、`template/`、`model.rb`、`db/`、`generator/` などに分割（第 11 章）。C は `ffi_source` でファイル内に書く（`dev/reexec.rb`）。アプリからは GitHub のタグを `{ git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }` で参照し、`spin.lock` でコミットを固定する（フレームワークのコードはアプリに置かない）。`matz/spin-index` への登録後は `--version` 指定も使える。
- CLI はフレームワーク側の `bin/cybertrain.rb`（spin でビルド）と、同じソースを CRuby で動かす gem（`gem install cybertrain`、`exe/cybertrain`）の 2 通りで配る。spin には索引からツールを入れるコマンドがまだ無く（`spin install` はローカルのソースのみ）、利用者の Rails 開発者は Ruby を持っているため、配布は gem を主とする。gem には CLI とそれが require するファイルだけを入れ、フレームワーク本体は入れない。役割は `cybertrain new blog` の雛形生成と `cybertrain generate scaffold post title:string body:text` のコード生成のみ。（2026-09-26 改訂: 役割は `new`、`generate scaffold`、`migration`、`db`、`server`、`build`。後の 4 つはアプリのディレクトリで `spin run gen` / `spin run db` / `spin run NAME` / `spin build NAME` を順に呼ぶ薄いラッパ。第 13 章）`new` は既定で CLI と同じバージョンのタグを依存に書き、`rails new` の `bundle install` にあたる `spin lock` と `spin run gen` まで実行する（`--skip-spin` で省略）。gem とフレームワークは同じタグからリリースする。
- `new` はデプロイ用に Kamal 2 の雛形（`Dockerfile`、`.dockerignore`、`config/deploy.yml`、`.kamal/secrets`、ヘルスチェック用の `public/up.html`）も書く（2026-10-22）。バイナリはシステムの libc と SQLite にリンクするので、イメージはビルド段と実行段を同じ Ubuntu リリースにし、ビルド段で `gem install cybertrain -v <CLI のバージョン>`・`cybertrain setup`・`cybertrain build` を実行して `dist/` だけを実行段へコピーする。起動は `./NAME migrate && exec ./NAME`（SIGTERM がサーバーに届く）。ヘルスチェックは静的ファイル: ルートを足すとアプリのルーティングとコントローラに手が入り、kamal-proxy にはプロセスが HTTP に応答することだけが分かればよいため。DB は SQLite のままボリューム（`/app/storage`）に置き、サーバー 1 台を前提にする。
- アプリの雛形と bin は第 11 章。ビルドは `spin run gen` → `spin build` の 2 段。（2026-09-26 改訂: 配布用ビルドは `cybertrain build` → `dist/`。`spin run gen -- --embed-views` → `spin build NAME` → `spin run gen` で空の表に戻し、バイナリと `public/` を `dist/` にまとめる。第 13 章）

### D12. 開発ループ: サーバが自分で再ビルドして自分を置き換える

- 決定: アプリの入口（当初 server 用の bin、2026-09-26 から `bin/<name>.rb`）が `CYBERTRAIN_ENV=development` のときだけ監視モードになる。監視対象は `app/**/*.rb`、`config/**/*.rb`、`db/schema.rb`、`gen/**/*.rb`（再ビルド自身が書き換えた `gen/` は基準に吸収し、`gen/views.rb` は無視する。`cybertrain/dev.rb`）。mtime を 0.5 秒間隔でポーリング。`app/views/**/*.erb` は監視対象外（テンプレートエンジンが自分で再読み込み）。
- 変更を検知したら `spin run gen && spin build <name>` を `system` で実行し、成功したら自分に `SIGHUP` を送る。`trap("HUP")` のハンドラ（スパイク 7 で実機動作を確認）が listen ソケットを閉じ、`ffi_source` の 6 行の C シム `sp_reexec(path, port_arg)` 経由で `execv` を呼んで新しいバイナリに自分を置き換える。PID は変わらない。元の listen ソケットに `SO_REUSEADDR` を立てておけば、新プロセスは同じポートを即座に再バインドできる（スパイク 7 で確認）。ポートなどの引き継ぎ状態は argv で渡す。（2026-09-27 注記: 実装は `SIGHUP` を送らず、再ビルドに成功したウォッチャースレッドが `trap("HUP")` と同じ再起動フラグを直接立てる（外部からの `kill -HUP` も同じ経路）。監視スレッドが listener を止め、`Server#wait` が戻ったあとメインスレッドが `execv` を呼ぶ。`cybertrain/application.rb`）
- ビルド失敗でサーバは死なない。旧バイナリのまま動き続け、コンパイラの stderr を保持して次のリクエストで開発用エラーページとして返す。
- マイグレーションは自動で流さない。`spin run db -- migrate` の結果 `db/schema.rb` が変わることで再ビルドが走る。
- production: 監視もビルドも無効。production はビューを `cybertrain build`（`spin run gen -- --embed-views`）がバイナリに埋め込んだものだけを描画し、development は `app/views/` をディスクから読む。`cybertrain build` はそのバイナリと `public/` を `dist/` にまとめる（第 13 章）。（2026-09-26 改訂: 当初は `app/views/` を同梱して配布し、バイナリ単体では動かない設計だった）
- 却下: 別プロセスの監視ツール（構成が増える）。

### D13. テストと CI

- `spin test` の仕組み（`test/*.rb` の各ファイルが 1 プログラム、stdout を `.expected` と diff）に合わせ、`Cybertrain::Test` を用意する。`test "saves a post" do ... end` を配列に積んで順に実行、決定的な形式で出力、失敗があれば非ゼロ終了。アサーションは `assert`、`assert_equal`、`assert_nil`、`assert_raises`、`assert_includes`。
- アプリのテストは model、controller / integration（`get "/posts"`、`post "/posts", params: {...}`、`assert_response :ok`、`assert_redirected_to`、`assert_includes response.body, "..."`。ソケット不使用）、テンプレート（エンジンに文字列を渡す）の 3 種類。
- テスト用 DB は `storage/test.sqlite3`。各テストをアダプタ層の `BEGIN` / `ROLLBACK` で包む。（2026-09-27 改訂: トランザクションで各テストを包む仕組みは未実装。`examples/blog/test/support/blog_test.rb` はテスト開始時に `storage/test.sqlite3` を作り直してマイグレーションし、各テストの前にテーブルを `delete_all` で空にする）
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
- エラーページ: production は `public/404.html` / `public/500.html`（最外周の `ErrorPages` ミドルウェア。例外は 500 にし、本文が空・Content-Type なし・`text/plain` のエラー応答を `public/<status>.html` に差し替える。アクションが HTML / JSON で描画したエラーはそのまま）、development は診断ページ。
- セッション Cookie: production では `Secure` 属性を付ける（`Config#session_secure`、既定は `production?`）。
- セッション Cookie の SameSite は `Config#session_same_site`（既定 `Lax`、`CYBERTRAIN_SESSION_SAME_SITE`、`Lax`/`Strict`/`None` 以外は起動時エラー）、`Partitioned` は `Config#session_partitioned`（既定 false、`CYBERTRAIN_SESSION_PARTITIONED`）。`None` か `Partitioned` のときは `session_secure` に関係なく `Secure`。待ち受けアドレスは `Config#host`（既定 `127.0.0.1`、`CYBERTRAIN_HOST`）。（2026-10-02、web playground SP1）
- development は `HostAuthorization` を最外周に置き、DNS rebinding に備えて Host を完全一致で検査する。既定は `localhost` / `127.0.0.1` / `[::1]`（数値ポート可）。`Config#allowed_hosts` または `CYBERTRAIN_ALLOWED_HOSTS`（カンマ区切りで既定に追加）で転送先のホスト名を明示する。ワイルドカード、DNS 解決、Forwarded ヘッダは使わない。拒否は 403 で、静的ファイル・セッション・CSRF トークン・開発診断より前。`CYBERTRAIN_HOST=0.0.0.0` は許可ホストを増やさない。playground のランチャーは Codespaces の環境設定から自分の転送ホスト名だけを追加する。production / test は従来どおり。（2026-10-23）
- 安全側の既定: 出力エスケープ、CSRF、署名クッキー、SQL は常にバインド変数、`X-Content-Type-Options: nosniff`、`X-Frame-Options: SAMEORIGIN`。`nosniff` と `SAMEORIGIN` は `Response#to_http` が、レスポンスにその名前のヘッダ（大文字小文字は問わない）が無いときだけ付ける。Server が書くのは常に `to_http` なので、エラーページ・開発の診断ページ・Server 自身の 400 / 411 / 413 / 500・HEAD も同じ。アクションが `set_header` で別の値を入れれば（埋め込みウィジェットの枠付けなど）その値が出て、二重にはならない。アプリ全体の `Config` スイッチは作らない: 例外は個々のレスポンスの話で、全体を切るスイッチは安全側の既定を一行で外せる穴になる。リバースプロキシでの上書きもヘッダを足すだけなので、アプリ側に切る口は要らない。web playground SP1 の spec は「入れるときは切り替え可能に」としていたが、それはエディタのプレビュー（iframe）を前提にした注意で、SP1 はアプリを別タブで開き（playground/README.md）、iframe で見せる SP2 は中止したので当たらない。`nosniff` は Content-Type を厳密に守らせるので、`Static::EXTENSIONS` に webp / avif / woff / ttf / otf / wasm / mjs / pdf / 音声・動画などを足した。表に無い拡張子は `application/octet-stream`（ダウンロード扱い）。（2026-10-23）
- 終了処理: `SIGTERM` で listen を止め、処理中のリクエストを待って終了。`trap` が使えなければ libc の `signal` を FFI で呼ぶ。trap ブロックは C のシグナルハンドラから直接呼ばれるので、ハンドラはフラグを落とすだけ（`Server#request_stop`）にし、`Thread#join` などは通常のスレッド文脈で行う。フラグが落ちると accept ループが listener を閉じ、`Server#run` は開いている接続が閉じるのを最大 `drain_timeout`（既定 10 秒、systemd の `TimeoutStopSec` より短く）待ってから戻る。処理中のリクエストは `Connection: close` 付きで応答してから閉じ、リクエスト間で待機中の keep-alive 接続は待たずに閉じる。接続数は accept スレッドで数え（`Mutex` で保護）、`serve` の ensure で減らす。
- i18n なし。バリデーションメッセージは英語固定。

### D15. 認証: フレームワークの原始関数 + アプリが所有するコードを書くジェネレータ（2026-10-22）

- セッションの有効期限: 生成する `resume_session` は、DB 行の `created_at` から `Cybertrain.config.session_max_age` 秒（既定 2 週間）が経過した認証を拒否し、クッキーから `session_id` を削除する。署名済みクッキーの再送でも期限を延ばせない。クッキー自体の Max-Age は更新時に再開するが、認証の期限はサインイン時から固定する。
- 決定: Rails 8 の `bin/rails generate authentication` と同じ分割にする。(1) フレームワーク側には「自分で書くと間違えるもの」だけを置く: パスワードハッシュ `Cybertrain::Password`（PBKDF2-HMAC-SHA256、PHC 形式の文字列、定数時間比較、`needs_rehash?`）、`Controller.skip_before_action`、ルーティング DSL の `resource`（単数）。(2) `cybertrain generate authentication` が、users / sessions のマイグレーション、`User`（`password=` / `authenticate` / `authenticate_by` を手書きの形で）と `Session` モデル、`SessionsController` / `RegistrationsController` とビュー、`ApplicationController` への `before_action :resume_session` / `:require_authentication` と補助メソッド、routes、レイアウトの nav パーシャル、統合テスト（`test/authentication.rb`）を**アプリのファイルとして**書く。外部ライブラリ（spin パッケージ）としての認証「エンジン」は作らない。
- 理由（Rails 8 と同じ結論に、Spinel がさらに重みを足す）:
  - **拡張点が無い。** cybertrain のアプリは `config/routes.rb`・`app/controllers`・`app/views`・`db/migrate` を `spin run gen` が読んで `gen/` を書く構造（D3 / D4）で、パッケージ側のコントローラは字句走査の対象外（`view_assigns` / `run_callback` を自分で書けば動くが、ivar をテンプレートに見せる仕組みの外に出る）、ビューは `app/views/` からしか読まれず埋め込みもそこからだけ、マイグレーションも `db/migrate/` だけ、モデルは schema からの生成物。routes は `config/routes.rb` から `Package.draw(r)` を呼べば足せるが、他が足せない以上、認証パッケージは結局「ファイルをアプリにコピーするジェネレータ + 少しの原始関数」になる。それなら最初からそう作る。
  - **全プログラム推論の衝突面。** Spinel は依存パッケージのコードもアプリと一つのプログラムとしてコンパイルし、無関係なクラス間でもメソッド名と戻り値型の衝突で推論が壊れる（NOTES 10 / 34 / 41 / 43）。パッケージ作者は「どのアプリと一緒にコンパイルされるか」を知り得ないので、薄い原始関数はよいが、コントローラやモデルのような名前の多いコードを外から持ち込むほどリスクが増える。生成してアプリに置けば、衝突したときに直すのはアプリの中の、読める普通の Ruby になる（原則 2）。
  - **カスタマイズの道筋。** 認証はアプリごとに必ず変わる（登録の可否、招待制、2 要素、ログイン後の遷移）。Devise 型のエンジンは設定とオーバーライドの層を要求するが、生成コードは直接編集すればよい。Rails 8 が同じ理由で生成方式を選んだ。
  - **CLI は CRuby、フレームワークは Spinel。** ジェネレータは gem（CRuby）で動き、生成物は Spinel でコンパイルされる。この 2 層はすでに `scaffold` で成立しており、認証ジェネレータは同じ型（`cybertrain/cli/authentication.rb`、gemspec に列挙、`spin run gen` には何も足さない）。
- パスワードハッシュの選定: Spinel で使えるのは、ランタイム同梱の SHA-256（`Digest::SHA256.digest`、C 実装）、libc の `String#crypt`（bcrypt は glibc / libxcrypt のみで macOS に無い。CI は macOS でも走る）、`openssl` パッケージ（リンクパス問題で D8 で不採用）、C の `ffi_source`（自前の暗号実装のレビュー負担）。純 Ruby の PBKDF2-HMAC-SHA256（`Crypto` の HMAC と同じ作り）を選び、RFC 6070 / 7914 のテストベクタで検証した。実測: 10 万反復で CRuby 660 ms、Spinel コンパイル後 197 ms、60 万反復で 1.09 s（NOTES「数値」）。既定は 10 万反復（Django 2019 年相当、bcrypt cost 12 と同程度の時間）で、`Cybertrain::Password.iterations=` で上げられ、`needs_rehash?` によりログイン時に再ハッシュされる。ループは `while` なのでバックエッジがセーフポイントになり、`SPINEL_WORKERS=1` でも他のリクエストを止めない（docs/thread.md「Preemption」）。アルゴリズムは PHC 文字列の識別子で切り替えられるので、argon2 / bcrypt を C で同梱する spin パッケージが後から出ても既存のダイジェストはそのまま検証できる。**この種の「原始関数だけのパッケージ」はエコシステムに向く**（`sources = [...]` で C を運べ、フレームワークの拡張点を要らない）。
- 却下した案:
  - `cybertrain-auth` spin パッケージ（エンジン）: 上記のとおり拡張点が無く、あったとしても推論衝突と `app/views` の制約で薄い層にしかならない。
  - `has_secure_password` マクロ: `define_method` が無い。ジェネレータの字句走査で `has_secure_password` を拾って `gen/models/user.rb` に吐く案は可能だが、15 行の手書きメソッドのためにジェネレータの入力を増やす価値がない。アプリの `app/models/user.rb` に書き出し、コメントで Rails との対応を示す。
  - concern（`app/controllers/concerns/authentication.rb` を `include`）: 字句走査は `include` を追わず、`gen/app.rb` の require 順も `application_controller` が先なので CRuby で未定義になる。`ApplicationController` のクラス行の直後にブロックを挿入する（`add_route` と同じ一回限りの編集。`def require_authentication` があれば二度目は何もしない）。concern 対応（`include` を辿る走査と require 順）は将来の独立した機能。
  - パスワードリセット・メーラー: メーラーが無い（2.3 節）。レート制限: 未実装。`Current`: スレッドローカルの代わりに `resume_session` が `@current_user` / `@current_session` を置き、`view_assigns` 経由でテンプレートが読む。
  - 登録画面を書かない（Rails 8 と同じ）: Rails は console で最初のユーザーを作るが、cybertrain に console は無い（8 章）。`RegistrationsController`（`/sign_up`）を書き、招待制なら消すようコメントする。
- 帰結:
  - フレームワークに足したもの: `Cybertrain::Password`、`Controller.skip_before_action`（クラス名キーの実行時データ。`run_before_callbacks` が名前で照合、継承される。ブロック形は名前が無いので飛ばせない）、`Mapper#resource`、カスタム経路の派生名が既出なら無名にする Rails の規則（`get "/sign_up"` と `post "/sign_up"` で一つの `sign_up_path`。`as:` の重複は従来どおりエラー）。
  - モデル名 `Session` は `Cybertrain::Session` と共存する（検証済み: 実スタックで cookie session に Session 行の id を往復）。`User` の NOT NULL 文字列列 `password_digest` は空文字が「未設定」（nil を入れると生成コードの型が崩れる、NOTES 7 / 11）。
  - エコシステムの型: 「原始関数は spin パッケージ、アプリに置くコードはジェネレータ」。cybertrain 自身が gem（CLI）+ spin パッケージ（フレームワーク）を同じタグで出しているのと同じ型を、第三者も `my-gem`（`cybertrain generate NAME` のプラグイン）+ `spinel-my-lib`（原始関数）で踏める。`cybertrain generate` に gem からジェネレータを読み込む仕組みは未実装で、二つ目の外部ジェネレータが要るときに入れる。

### D16. ファイルアップロード: フレームワークの原始関数 + アプリが所有するコードを書くジェネレータ（2026-10-22）

- 決定: D15 と同じ分割にし、別ライブラリ（spin パッケージ）は作らない。
  - フレームワーク（`cybertrain/`）に置くのは、閉じた層にあるものと、自分で書くと間違えるものだけ:
    - `cybertrain/http/multipart.rb`: バイナリ安全な multipart/form-data パーサ `Cybertrain::Multipart` と、その結果 `MultipartForm`。例外 4 種（`MultipartMalformed` / `MultipartTooManyParts` / `MultipartPartTooLarge` / `MultipartHeaderTooLarge`）は `QueryInvalid` の子で、`CLIENT_FAULTS` に列挙して 400 にする。
    - `cybertrain/http/uploaded_file.rb`: `UploadedFile`。マジックバイトによる型判定、ファイル名の無害化、ASCII だけの `Content-Disposition` 生成を含む。
    - `Params` の 4 つ目の型付き Hash と `params.upload(:key)`。`permit` は今までどおり文字列だけを返すので、ファイルが一括代入に紛れ込むことはない。
    - `Request#multipart_form`: リクエストごとに一度だけ解析してキャッシュする。`form_or_query_value` もこれを読むので、`CsrfProtection` と `MethodOverride` がトークンと `_method` を multipart 本文から読める。これまでは multipart の POST がすべて 403 だった。
    - `form_with(multipart: true)` と `f.file_field`。
    - `Config#max_upload_bytes`（5 MiB）、`max_multipart_parts`（128）、`upload_root`（`storage/uploads`）。
    - ディスク保存の原始関数 `Cybertrain::BlobStore`: サーバが生成する 32 桁 hex のキー、`0600`、一時ファイルからの rename。
    - 信頼できないバイト列を安全なヘッダで返す `Controller#send_blob`。
  - `cybertrain generate attachment MODEL FIELD [--any]` と、scaffold の `FIELD:attachment` 型が、アプリのファイルとして次を書く:
    - 所有テーブルにメタデータ列 5 本（`<f>_key` / `_filename` / `_content_type` / `_byte_size` / `_checksum`）を足すマイグレーション。
    - モデルのフィールド名付きメソッドとコールバック。
    - 所有コントローラのメンバーアクション `GET /posts/:id/cover` と、その route。アクションは `before_action :set_post` の `only:` に足し、`@post` を読む。show と同じ絞り込み（アプリが `set_post` に書いた認可）がダウンロードにも効く。公開範囲も show と同じにする: `allow_unauthenticated_access` の `only:` が `:show` を含み（`except:` が除いていない）、ダウンロードが show と同じ `before_action :set_post` でレコードを引くなら、そこに `:cover` も足す（公開ページの画像が訪問者をサインイン画面へ送らないように）。認証だけではレコード別・役割別の認可を代替できない。継承元までコールバックを確認し、show と同じ `set_post` が無い場合、show だけに効く `before_action` や `def show` 内のチェックがある場合、またはポリシーを安全に読み取れない場合は、ファイルを書き込む前に生成を拒否する。アプリ側で明示的な認可コールバックを show とダウンロードの両方に適用し（例: `before_action :authorize_post, only: [:show, :cover]`）、`set_post` も共有してから再実行する（2026-10-23）。生成テストはそれに合わせて、訪問者がダウンロードできること、またはサインイン画面へ送られることを確かめる。フォームの値は、モデルの `length: { minimum: / maximum: }` を満たすように埋める（2026-10-23）。
    - `create` / `update` への 1 行 `@post.cover_file = params.nested(:post).upload(:cover)`。`require` ではなく `nested` にするのは、ファイルだけのフォームでファイルを選ばずに送ると `post` キー自体が無くなり（空のファイル入力は捨てる）、`require` だと 400 になるため。
    - フォームと show の編集、アプリの統合テスト。
  - フィールド名は、ダウンロードアクション `def <field>` が `Cybertrain::Controller` のメソッド（`params`、`render`、`head` など）、scaffold のアクション、`ApplicationController` に生成されるメソッド、`set_<model>` / `<model>_params` を上書きする名前なら拒否する。`script/check-reserved-names` が、この表が `controller.rb` と生成テンプレートに追随しているかを検査する。
- 理由:
  - **拡張点が無い。** D15 の理由 1 がここではもっと強く効く。multipart の解析は、ルーティングより前に動く `CsrfProtection` / `MethodOverride` が読めるよう `Request` の中に要る。`Params` の型付きスロット、`FormBuilder` の閉じた case 表、`ClientError::CLIENT_FAULTS`、HTTP 層の単独ロード規則（`script/check-http-layer`）も同じで、どれも spin パッケージからも生成コードからも届かない。パッケージに残せるのは `BlobStore` と配信ヘッダの百行ほどだけになる。
  - **フレームワーク自体が spin パッケージである。** 「セキュリティ修正をバージョン一つで配れる」という別パッケージ案の利点は、`cybertrain/` に置いても同じ形で得られる。別パッケージにすると、二つ目のタグ、アプリの spin.toml の編集、全プログラム推論の衝突面（NOTES 10 / 34 / 41 / 43）が増えるだけになる。
  - **モデル・コントローラ・ビュー・マイグレーションは生成してアプリに置く。** `has_one_attached` は `define_method` が無いので書けない（D15 の `has_secure_password` と同じ）。許可する型、サイズ、認可、表示はアプリごとに変わるので、直接編集できる生成コードが向く。
  - **配信は所有コントローラを通す。** アプリの `before_action`（認証）がそのまま効く。
    - `Static` / `public/` は使わない。html・svg をインラインで返し、public なキャッシュを付け、ビルドのたびに置き換わるため。
    - バイト列は永続ボリュームの `storage/uploads/` に置く。SQLite にはメタデータだけを入れる（NUL で切れるため）。
    - 型はクライアントの申告を信じず、マジックバイトで判定する。インラインで返すのは PNG / JPEG / GIF / WebP だけで、それ以外は `attachment` + `application/octet-stream`。配信には必ず `nosniff` と `Content-Security-Policy: default-src 'none'; sandbox` を付ける。
- 却下した案:
  - `cybertrain-storage` パッケージ（原始関数だけのものも、エンジンとしてのものも）。理由は上記。
  - 生成のみ（パーサをアプリに複製する）。ルーティング前の層に届かず、セキュリティ修正が配れない。
  - Active Storage 型の共有テーブルと `has_one_attached`。`define_method` が無く、polymorphic な関連も無い。
  - SQLite の BLOB。
  - `public/` からの配信。
  - ストリーミング受信。サーバは本文を全部メモリに読むので（`max_body_bytes` が上限）、サーバの改修として別件にする。
  - v1 での 413 / 415 への対応付け。サイズ超過は 400。`ClientError.status_for_name` と `Controller#rescue_with_handler` を広げる別件にする。
  - 1 フィールドに複数ファイル（`name[]`）。v1 では `MultipartMalformed` にする。
- 帰結と今後:
  - D14 の「安全側の既定」にある `X-Content-Type-Options: nosniff` / `X-Frame-Options: SAMEORIGIN` は、いまは全レスポンスの既定になっている（`Response#to_http`）。`send_blob` はこれに加えて `Content-Security-Policy: default-src 'none'; sandbox` と `Cache-Control` を付け、`nosniff` は自分でも設定する（同名ヘッダがあれば `to_http` は足さないので二重にならない）。
  - S3 など二つ目の保存先が要るときは、`BlobStore` と同じ `write` / `read` / `delete` / `exist?` の面を持つ「原始関数だけの spin パッケージ」として足す（D15 のエコシステムの型）。
  - 既知の穴:
    - `before_save` の後で DB の書き込みが失敗すると、孤児ファイルが残る（`save` にトランザクションが無い）。
    - EXIF などのメタデータはそのまま保存される。
    - `SPINEL_WORKERS=1` では、ディスク書き込みの間ワーカーが止まる。
    - 配信は同一オリジン。
  - 孤児ファイルの掃除、ETag / Range、別オリジン配信は後続の作業。

### D17. アプリ定義の設定: `Config` 上の型付き宣言（2026-10-25、issue #69）

- 決定: アプリ独自の設定（公開 URL、機能スイッチ、間隔、SMTP ホスト）は `config/app.rb` の `Cybertrain.configure` ブロックで `Config` に宣言する。宣言は型ごとのメソッド `c.setting_string(name, env:, default:, secret: false)`、`c.setting_int(name, env:, default:, min:, max:)`（`min` / `max` は省略可）、`c.setting_bool(name, env:, default:)`。読み出しは `Cybertrain.config.string_setting(:base_url)` / `int_setting` / `bool_setting`、テスト用の書き込みは `set_string_setting` / `set_int_setting` / `set_bool_setting`。
- 値は宣言の時点、つまり起動時に `config/app.rb` が走るときに一度だけ環境変数から読む。空または未設定は既定値（`Config.env_or` と同じ規則）。真偽値は `1` / `true` と `0` / `false`（既存の `CYBERTRAIN_SESSION_PARTITIONED` と同じ綴り）、整数は先頭の `-` と 10 進数字で、先頭の 0 を除いて 18 桁まで（`String#to_i` が 2**63-1 を超えると RangeError を投げるため。NOTES 25）。解釈できない値と範囲外の値は既定値に戻し、`Cybertrain.logger` に `[WARN]` を 1 行出す。起動は止めない: 設定の誤りでサーバが上がらないより、既定値で上がって理由がログに残るほうが運用で扱いやすい（フレームワーク自身の `session_same_site` のように誤りが安全性に関わるものは、従来どおり起動時エラー）。宣言の誤り（名前の二重宣言、空の `env:`、範囲外の既定値）と、未宣言・別の型の名前の読み出しはプログラムの誤りなので `ArgumentError`。
- 値は型ごとの Hash（名前の String がキー、NOTES 9 に従って要素型で種を入れる）に入れ、宣言（名前、環境変数、型と既定値の説明、secret か）を宣言順に記録する。`./NAME help`（`Main.usage`）はこれを環境変数・名前・型・既定値の一覧として出し、起動バナーは `=> Settings: base_url="" worker=true ...` の 1 行で現在値を出す。`secret: true` の設定はどちらにも名前と環境変数しか出さない（バナーでは `[FILTERED]`、help では既定値も出さない）。設定を宣言していなければ help もバナーも従来と同じ。help は設定を読むために `Cybertrain.config` を新しく作らない（作ると、その時点の環境変数で `database_path` などが固まる）。
- 却下した案:
  - `c.setting :base_url, ...` で `Cybertrain.config.base_url` という読み出しメソッドを生やす形（issue の原案）。`define_method` も `method_missing` も無い（NOTES 1）。既定値から型を推論する 1 本の `setting` も、戻り値の型が呼び出しごとに変わるので Spinel では型付きの読み出しにならない。
  - ジェネレータ（`gen/app.rb`）が `config/app.rb` を字句走査して型付きアクセサを書く案。`base_url` のように名前で読めるのは利点だが、`config/app.rb` をジェネレータの入力に加え、`spin run gen` の対象と生成物を増やす。名前を Symbol で渡す型付きメソッド 3 組で足りる。必要になれば後から生成アクセサを薄く被せられる。
  - 読み出しを `string` / `int` / `bool` と短く名付ける案。`StringIO#string` などの組み込みと同名のメソッドは箱入りの受け手での呼び出しを壊す（NOTES 62）ので、`*_setting` と区別できる名前にした。
  - `cybertrain settings` という独立したコマンド。一覧は既存の `help` に足し、現在値は起動バナーに出すことで足りる。
- 帰結: 名前は Symbol で渡す（NOTES 51: 同じメソッドに Symbol と String のキーを混ぜない）。テスト用の書き込みは宣言時の範囲を検査しない。

### D18. アプリ独自のサブコマンド: `Main.command`（2026-10-25）

- 決定: `Cybertrain::Main.command(name, description) { |argv| ...; 0 }` で、アプリがバイナリにサブコマンドを登録できるようにする（#68）。登録は `bin/<app>.rb` で `Main.run` の前に書く。
  - `./<app> NAME ARGS...` は、名前の後ろの引数（`argv[1..]`）をブロックに渡し、ブロックの値（Integer）を終了コードにする。
  - ブロックの前に `Cybertrain::DB` を `Cybertrain.config.database_path` へプール 1 本で接続し、後で切断する。サーバ、ビュー、セッション秘密鍵は用意しない。設定は `bin/<app>.rb` が `config/app.rb` を先に require しているので読み込み済みで、未設定なら `Cybertrain.config` の既定（環境変数）になる。
  - `Cybertrain::DB::Error`（接続の失敗も含む）は `NAME failed: MESSAGE` を出して終了コード 1 にする。それ以外の例外は捕まえない（`db` コマンドの `StandardError` まで捕まえる扱いより狭い。アプリのバグは隠さない）。
  - 登録済みの名前は組み込みの判定より先に見る。`Main.server?` は登録済みの名前に対して偽になり、サーバ専用の起動処理（スケジューラなど）が一回きりのコマンドで動かない。`help` は組み込みの後に登録順で一覧する。
  - 組み込みの語（`server` / `migrate` / `db` / `help` / `--help` / `-h`）、数字だけの名前（ポート引数）、空文字、登録済みの名前は `ArgumentError`。
  - 実装は `Main::Command`（名前、説明、Proc）を定数 `Main::COMMANDS` の配列に積む。定数にするのはクラス変数が GC ルートにならないため（NOTES 64）、空配列は要素型で種付けする（NOTES 9）。アクセサは `command_name` などの固有名にし（NOTES 10 / 34）、`call` は定義しない（NOTES 40）。begin/rescue は yield しない普通のメソッドに置き、保存したブロックを `call` する（NOTES 32 / 45）。
- 理由:
  - これまでは `bin/` で `ARGV[0]` を自分で見て、`db migrate` が持っている「設定済みの DB に接続して実行し、表示して終了コードを返す」足場を書き直す必要があり、`help` にも出なかった。
  - Spinel には `instance_eval` が無いので、ブロックは `before_action { |c| ... }` と同じく引数を明示的に受け取る。
  - プール 1 本で足りる。一回きりのプロセスで `pool_size` 本を開いて閉じるのは無駄。
- 却下した案:
  - Rake 風のタスクファイルを走査して生成する案。字句走査と生成の面が増え、`bin/<app>.rb` に数行書くのと比べて得るものが無い。
  - 組み込みの名前の上書きを許す案。`migrate` が別物になると運用手順が壊れる。
  - コマンドごとに DB 接続を選ばせる案（接続しない指定）。必要になったら引数を足す。

### D19. タイムゾーン: システムの TZif を自前で読む `Cybertrain::TimeZone`（2026-10-25、issue #66）

- 決定: `cybertrain/time_zone.rb` に `Cybertrain::TimeZone` を置く（名前は issue で未定だったので、Rails の `ActiveSupport::TimeZone` に寄せた）。
  - `TimeZone.find("Asia/Tokyo")` が `$TZDIR/<name>`（既定 `/usr/share/zoneinfo/<name>`）を読み、TZif v1〜v4（RFC 8536）を解釈する。v2 以降は 32 ビットのブロックを読み飛ばして 64 ビットのブロックとフッタを使う。最後の遷移より後の時刻は POSIX TZ 文字列のフッタ（`JST-9`、`EST5EDT,M3.2.0,M11.1.0`、`<+09>-9`）で決める。`Mm.w.d`・`Jn`・`n` の規則、`/time` の省略・負の値・24 時間超（RFC の拡張、167 時間まで）を扱う。DST 名だけで規則が無いときは tzcode / glibc と同じく米国の規則を補う。
  - 値はすべて Integer の epoch 秒。`utc_offset_at` / `dst_at?` / `abbreviation_at`、`utc_to_local` / `local_to_utc`（「ローカル epoch」は壁時計を UTC とみなして数えた秒）と、暦との変換 `civil_to_epoch` / `epoch_to_civil`。issue の `local_to_utc(local_epoch, zone)` は、ゾーンのインスタンスメソッド `zone.local_to_utc(local_epoch)` にした。
  - 遷移の前後で `local_to_utc` の答えを一つに決める: 飛ばされた壁時刻（米国の春の 02:30）は遷移前のオフセットで読む（結果は遷移後、03:30 EDT になる）。二度ある壁時刻（秋の 01:30）は早いほうの瞬間を返す。前後 1 日の間に遷移は高々一つ、という tz データベースで成り立つ前提を置く。
  - 名前は `A-Za-z0-9_+-./` の 1〜255 バイトで、先頭の `/`、空・`.`・`..` のセグメントを拒む。ディレクトリの外のファイルを指せる名前は、ファイルを見る前に落とす。ファイルが無い・TZif でない・256 KiB を超える・カウントと長さが合わない（遷移が昇順でない、型番号や略称の位置が範囲外、略称が印字可能 ASCII でない）ときは、UTC として振る舞い `found?` が false のゾーンを返す（例外にしない）。`"UTC"` は組み込みでファイルを読まない（`TimeZone::UTC`）。読めないフッタは無視し、最後の遷移の型がそのまま続く。
  - キャッシュは、名前 → 添字の Hash とゾーンの型付き Array を持つ不変オブジェクトを一つ、クラスレベルの `@zone_cache` に置く。追加は Mutex の中で新しい組を作って参照を差し替える（copy-on-write）。読み手はロックを取らない（NOTES 57: リクエストごとの Mutex は 2 ワーカーで数秒止まった）。キーは解決後のパスなので、`TZDIR` を変えれば別のエントリになる。見つからなかった名前はキャッシュしない（利用者の入力で表が際限なく伸びないように）。
  - 解析は `getbyte` の算術で行い、`String#unpack` は使わない（NOTES 62 に従い、走査するメソッドの先頭で `s = bytes.to_s` を取る）。64 ビットの符号付き値は、負なら補数で読み、途中の値が 63 ビットに収まるようにする。
- 理由:
  - Spinel には tz データベースが無い。`ENV["TZ"]` を切り替えて `Time#localtime` に頼るのはプロセス全体の状態で、スレッド安全でない。毎日 09:00 Asia/Tokyo のスケジュール、ローカル日付ごとの集計、DST を考えた次回実行時刻の計算は、各アプリが 600 行ほどのパーサとキャッシュを書くことになる。
  - データを同梱せずシステムの zoneinfo を読むので、tzdata の更新は OS のパッケージで届く。バイナリも大きくならない。
  - Integer の epoch 秒に絞ると、Spinel の `Time` の差（NOTES 7）に触れずに済み、DB の列やクッキーにもそのまま入る。
- 却下した案:
  - tz データの同梱・生成（ビルドごとに古くなり、数百 KB 増える）。
  - `ENV["TZ"]` + `Time.at(t).localtime`（スレッド安全でない）。
  - 不明な名前で例外を投げる（設定ミスひとつで全リクエストが 500 になる。呼び出し側が `found?` を見て警告する）。
  - 不明な名前もキャッシュする（上記）。
  - `Time.zone` 相当のリクエストごとの既定ゾーンと、テンプレートの `l(time, zone:)`。変換ができた後の別件にする（issue のとおり今回は入れない）。
- 帰結と今後:
  - `right/` 系のゾーンのうるう秒レコードは読み飛ばすだけで適用しない（その分の秒がずれる）。通常のゾーンには無い。
  - コンテナイメージに tzdata が無いと `find` は `found?` false の UTC を返す。slim なイメージでは `tzdata` パッケージを入れるか `TZDIR` を指す。
  - `def name` をこのクラスに置くと、フレームワーク全体のプログラム（test/template_integration.rb）で `Class#name` が NoMethodError になった。読み出しは `zone_name` にした（NOTES 66）。

### D20. トランザクション API: `DB.transaction` と `Model.transaction`（2026-10-25、issue #67）

- 決定: `Cybertrain::DB.transaction(immediate: false) { |c| ... }` を公開 API にする。プールから接続を借り、`BEGIN`（`immediate: true` なら `BEGIN IMMEDIATE`）を発行し、接続を渡してブロックを呼び、正常終了で `COMMIT`、例外で `ROLLBACK` して再送出し、接続をプールへ返す。`Model.transaction` は同じものを Rails の名前で呼ぶ薄い別名（クラスメソッドなので `Ident::RESERVED_COLUMN_NAMES` には入らない）。D10 の「MVP 外: モデル API の `transaction`」と §8 の `transaction` API はこれで置き換わる。
- 参加（Rails と同じ意味）: ブロックの実行中、同じスレッドの `DB.with`（したがって `save` / `update` / `destroy` / Relation の問い合わせ）はトランザクションの接続をそのまま受け取る。プールは借りた接続を `Thread.current` に記録し、`Pool#with` が `held_index` でそれを見つけたら借り出しも返却（`check_in` はトランザクションを巻き戻してしまう）もせずに yield する。入れ子の `DB.transaction` も同じ接続で深さを一つ増やすだけで、深さの数え方と「SQLite が自分で巻き戻した」検査は `Connection#transaction` のものをそのまま使う（両者とも新しいブロックなしの `Connection#begin!` / `commit!` / `rollback!` の上に書き直した）。最外段だけが `COMMIT` し、どの段の例外も最外段に届けば全体が巻き戻る。セーブポイントは無い。`immediate:` は最外段でだけ効く。ブロック内で起こしたスレッドは参加しない。
- 形（Spinel の制約から決まった）: `DB.transaction(&block)` は `DB.run_transaction(immediate, block)` を呼ぶだけで、借り出し・`begin!`・`block.call(conn)`・rescue・ensure はすべて `run_transaction` にある。`Controller#process` / `#run_action` と同じ形。
  - `&block` を受けて呼ぶメソッドは yield するメソッドと同じく呼び出し側に展開され、そこに rescue / ensure があると C がコンパイルできない（NOTES 規則 32/45、68）。
  - Proc をもう一段先のメソッド（`Pool` や `Connection` のメソッド）へ渡して呼ぶと、ブロック引数に接続のクラスが伝わらず、`c.execute` が NoMethodError になる（NOTES 規則 68）。
  - 参加の判定を `DB.with` 側で `block.call` にすると `DB.with` のブロックが Proc になり、外側のブロック引数を読むブロック（`5.times do |i| DB.with { ... i ... } end`）がコンパイルできなくなる（NOTES 規則 67）。だから判定は yield する `Pool#with` の中に置いた。
- ブロックなしの形: `c.begin!(immediate:)` / `c.commit!` / `c.rollback!`。rescue を普通のメソッドに置きたいコード向け。入れ子の `rollback!` は深さを一つ戻すだけで、判断は最外段に任せる（入れ子の `transaction` ブロックから例外が抜けたときと同じ）。
- 捨てたもの・制約:
  - 戻り値はブロックの値ではなく nil（`Connection#transaction` と同じく、総称的な戻り値は Spinel で型が付かない）。
  - `ActiveRecord::Rollback` と `requires_new:`（セーブポイント）は無い。
  - `DB.with` のブロックの中で `DB.transaction` を呼ぶと別の接続を借りる（`DB.with` はトランザクションではないので参加先が無い。1 接続のプールでは永久に待つ）。
  - ブロックの `c` は箱詰めの値なので、その上で `c.transaction { }` は呼べない（yield するメソッドは展開されるだけで実体が無い、NOTES 規則 66）。入れ子は `DB.transaction` か `begin!` / `commit!` で書く。
  - `DB.transaction` のブロックが外側のブロック引数を読み、その外側がさらにブロックの中にあると（三段）コンパイルできない（NOTES 規則 67）。アクションのようなメソッドの中なら二段で動く。
- 検証: `test/db_transaction_api.rb`（フレームワーク全体と一緒にコンパイル）。コミット、例外での巻き戻し、入れ子の参加、`Model.transaction` 内の `save` の参加、ブロックなしの形、`DB.with` のブロック内からの呼び出し、コントローラのアクションからの呼び出し、`immediate: true` が `BEGIN IMMEDIATE` を出すこと（別の接続の `BEGIN IMMEDIATE` が "database is locked" になる。遅延 `BEGIN` では通る）。

## 5. リクエストの流れ

1. `Server` が accept したソケットで HTTP/1.1 をパースし、`Request` を作る。
2. ミドルウェア連鎖: ログ → 静的ファイル → `_method` 上書き → session（署名クッキーの復号）→ CSRF 検証 → ルーター。
3. ルーターは `gen/routes.rb` の経路表を走査し、一致した経路の dispatch 節を呼ぶ: `PostsController.new(ctx).process(:show) { |c| c.show }`。
4. `process` は `before_action` を順に実行し（シンボル形は生成された `run_callback(name)` の `case`、ブロック形はコントローラを引数に `block.call(self)`。render / redirect した時点で連鎖は止まる）、アクション本体を呼び、render も redirect も起きていなければ action 名のテンプレートを暗黙 render し、最後に `after_action` を実行する。
5. render はテンプレートエンジンに `view_assigns`（生成済み）と locals、ヘルパー群を渡し、素の多相値の環境で描画してレイアウトで包む。
6. `Response` をソケットに書き戻す。keep-alive なら次のリクエストを待つ。

## 6. ジェネレータの入出力

| 入力 | 出力 | 内容 |
| --- | --- | --- |
| `db/schema.rb` | `gen/models/<model>.rb` | `attr_accessor`、`read_attribute` / `write_attribute` / `assign_attributes` の `case`、`from_row`、`to_json`、`attribute_names`、外部キー由来の関連、`<Model>Relation` |
| `config/routes.rb` | `gen/routes.rb` | 経路表、dispatch の `case`、`*_path` / `*_url`、polymorphic path の `case` |
| `app/controllers/**/*.rb`（字句走査） | `gen/controllers.rb` | コントローラごとの `view_assigns` と `run_callback(name)` の `case`（open class） |
| `app/models/**/*.rb`（字句走査） | `gen/models/<model>.rb` に追記 | モデルごとの `call_view_method(name)` の `case`（引数なし `def` のみ） |
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
- `namespace` / format / `respond_to`、`has_many :through`、`includes`、`transaction` API、i18n、メーラー、ジョブ、WebSocket（認証は 2026-10-22 に D15 の形で入った: ジェネレータが書くコードと、`Cybertrain::Password`）
- Rack 互換、Rails 互換、CRuby 上での実行

## 9. 未検証の前提とスパイク計画（M0）

`spikes/` に小さな Spinel プログラムを置き、`2026.09.12` で検証する。（結果は `spikes/NOTES.md`。プログラム自体は検証後に削除した）

| # | 検証項目 | 落ちた場合 |
| --- | --- | --- |
| 1 | `spinel` / `spin` の導入、`spinel --help` の最適化レベル、2,000 行規模のコンパイル時間 | 開発ループ（D12）の体感を再評価 |
| 2 | 非リテラル `send` がリテラル名に dispatch できるか、戻り値の型、`instance_exec` のブロック形 | **結果**: `send` は動くが 128 リテラル制限で実アプリでは無効。`instance_exec(&stored)` は不可。→ D8 / D9 を生成 `case` 文方式に改訂済み |
| 3 | **タグ付き共用体 `Value` を持つ木構造インタプリタが型推論を通り、100 行のテンプレート × 1 万回の描画速度が出るか** | **結果**: 通る。単相 `INode` AST + 素の多相値で手書きの 1.54 倍、CRuby の 3.2 倍速。`Value` ラッパは不採用 |
| 4 | 基底 `Relation` と `PostRelation` で `first` が `Post \| nil` に推論され、複数モデルで型が広がらないか | **結果**: 推論される。基底の抽象スタブ、setter が `nil` を返す形、キャストメソッド経由の nullable 属性が必須 |
| 5 | `TCPServer` + グリーンスレッド + keep-alive で 100 同時接続、レイテンシ、issue #4528 の再現有無 | **結果**: c=100 keep-alive で 52〜58k req/s（`SPINEL_WORKERS=1`）、p99 ≤ 2 ms。無言接続があっても他は止まらない。ただし `readpartial` の直前に必ず `wait_readable(timeout)` を呼ぶこと（素の `readpartial` は OS ワーカーを占有して #4528 と同じ停止を起こす） |
| 6 | SQLite FFI の open / prepare / bind / step / column、`blocking: true`、`SizedQueue` プールの複数スレッド利用、WAL | **結果**: 動作。静的 `ffi_buffer` の競合クラッシュを `malloc` スクラッチで回避 |
| 7 | `execv` の FFI、`trap` の可否、`SO_REUSEADDR` | **結果**: すべて動作（`trap("HUP")` 実機確認、execv シム、同一ポート即時再バインド）。D12 確定 |
| 8 | `openssl` / `digest` の HMAC、`json`、`cgi` の `escapeHTML`、`uri` のクエリ解析 | **結果**: json / uri / securerandom / base64 / strscan / stringio は動作。`cgi` はこのタグに存在せず、HTML エスケープは自前。HMAC は `Digest::SHA256` の上に自前実装 |

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
  spin.toml  cybertrain.rb  cybertrain.gemspec    # gem には CLI とその require だけ
  cybertrain/
    main.rb  application.rb  config.rb  views.rb  version.rb   # bin/<name>.rb の入口と起動
    db.rb  dev.rb  generator.rb  template.rb  schema.rb   # 各サブディレクトリの require 入口
    router.rb  controller.rb  params.rb  session.rb  flash.rb  callback.rb  errors.rb  context.rb
    middleware.rb  app.rb   # Middleware 基底クラスと既定のスタック（App）
    http/        # server.rb  parser.rb  request.rb  response.rb  query.rb  cookies.rb
    middleware/  # request_logger  static  method_override  session_store  csrf_protection  error_pages
    template/    # lexer  parser  ast  inode  interpreter  helpers  form_builder  engine
    model.rb  relation.rb  validator.rb  cast.rb  migration.rb
    schema/      # table.rb  definition.rb  dumper.rb（db/schema.rb の DSL）
    db/          # sqlite_ffi.rb  connection.rb  pool.rb  migrator.rb  schema_dumper.rb  sqlite_ddl.rb  cli.rb  error.rb
    generator/   # runner.rb  routes_dsl.rb  *_emitter.rb  model_scan.rb  controller_scan.rb  manifest.rb  inflector.rb  url_support.rb
    dev/         # watcher.rb  rebuilder.rb  reexec.rb  error_page.rb（D12）
    cli.rb  cli/ # new_app.rb  scaffold.rb  templates.rb  build.rb
    test.rb  test/client.rb  html.rb  crypto.rb  logger.rb
  bin/cybertrain.rb  exe/cybertrain   # CLI（spin install / gem）
  script/regen-snapshot
  test/                     # spin test（.expected をコミット）
  examples/blog/            # 合格基準のアプリ
  spikes/NOTES.md           # M0 スパイクの記録（プログラム自体は検証後に削除。git 履歴にある）
  README.md  docs/design.md  docs/deploy.md  docs/deploy.en.md  docs/deploy-kamal.md  docs/template-language.md  docs/superpowers/
  .github/workflows/ci.yml
```

アプリ（`cybertrain new blog` が生成）:

```
blog/
  spin.toml                 # [dependencies] cybertrain = ...
  spin.lock                 # spin lock が書く（examples/blog は path 依存なので無し）
  .gitignore  README.md
  app/controllers/  app/models/  app/views/  app/helpers/
  config/routes.rb  config/app.rb  config/deploy.yml   # deploy.yml: Kamal（D11）
  Dockerfile  .dockerignore  .kamal/secrets
  db/migrate/  db/schema.rb
  gen/                      # app.rb  controllers.rb  migrations.rb  models/  routes.rb  views.rb
  bin/blog.rb  bin/gen.rb  bin/db.rb   # blog.rb: server / migrate / db、db.rb: 開発時のマイグレーション
  test/                     # 雛形は .keep のみ（examples/blog では articles.rb comments.rb support/blog_test.rb）
  public/  storage/  tmp/   # build/ と dist/ は .gitignore。public/up.html は Kamal のヘルスチェック
```

## 12. 参考

- Spinel: https://github.com/matz/spinel （README、`docs/limitations.md`、`docs/FFI.md`、`docs/spin.md`、`packages/`）
- Spinel issue #4528（ソケット読み取りで停止したスレッドが他の I/O を止める）: https://github.com/matz/spinel/issues/4528
- spin-index: https://github.com/matz/spin-index
- Roundhouse: https://github.com/rubys/roundhouse （`docs/guide/spinel.md`、`runtime/ruby/`）
- spinelgems（gem 互換性調査、bundler-spinel）: https://github.com/OriPekelman/spinelgems
- rubocop_spinel: https://github.com/gurgeous/rubocop_spinel

## 13. 実装状況（2026-09-25）

- 第 10 章のマイルストーン M0〜M5 はすべて到達した。第 2.2 節の合格基準は `examples/blog`（Article + Comment、サーバサイド HTML、SQLite、`spin build` で単一バイナリ）で満たし、統合テスト 21 ケースと、フレームワーク自身の `spin test` 57 プログラムが通過している。
- 開発ループ（D12）は実機で確認済み: ビュー編集は再ビルドなしで即時反映、コントローラ編集は約 24 秒（`spin run gen` + `spin build`。当時のビルド対象は server 用の bin）で再ビルドされ、同じ PID のまま `execv` で新バイナリに置き換わった。
- 実装で判明した Spinel の制約 42 項目は `spikes/NOTES.md` に、計画との差分は `docs/superpowers/plans/2026-09-24-cybertrain-mvp.md` 末尾の「As built」節にある。利用者向けの説明は `README.md` と `docs/template-language.md`。
- 既知の未対応: strict locals の既定値構文（`<%# locals: (comment: nil) %>`）、`Model#attribute_or_method?` が常に true（typo した属性名が空文字で描画される）、`spin run db migrate` は `--` が必要（`spin run db -- migrate`）、`SPINEL_GC_STRESS=1` 下で最初の `form_with` が空文字を返す事象（Spinel 側のルーティング問題の疑い）。
- 2026-09-26: アプリの入口を `bin/<name>.rb`（`Cybertrain::Main`: server / migrate / db）に統合。`spin run gen` は `gen/views.rb` を常に書き、`--embed-views` で `app/views/` を文字列テーブルとして埋め込む。本番は埋め込みテーブルのみを描画し（`Template::Engine.embedded`）、空なら起動を拒否する。`cybertrain migration` / `db` / `server` / `build` を追加、`build` は `dist/`（バイナリ、public/、無ければ storage/ と tmp/）を組み立てる。開発時のマイグレーション用に `bin/db.rb` は残す（`bin/<name>.rb` は `gen/app` を読むため、最初のマイグレーションで `gen/models/` ができるまでコンパイルできない。`cybertrain migration` は `spin run db -- migrate` を使い、本番は `dist/<name> migrate`）。設計: docs/superpowers/specs/2026-09-26-cli-build-embedded-views-design.md、計画: docs/superpowers/plans/2026-09-26-cli-build-embedded-views.md。クロスビルドと public/ の埋め込みはスコープ外。
- 2026-09-27（PR #5 まで）: CLI は gem（`gem install cybertrain`、`cybertrain new` は同じタグを依存に書く。D11）でも配布。`cybertrain build` は `tmp/cybertrain-build.lock`（PID 入り）を dist/ の組み立てが終わるまで持ち、`dist/<name>` と `dist/public/` を rename で差し替える（`.public.old`）。開発サーバはロック中の再ビルドを飛ばしてログに出し、死んだ PID や 30 分以上古いロックは消して無視する。ポートを bind できないときは `PortInUse`（使用中 / 権限なし）を stdout に出して終了コード 1。`schema:dump` は `db/` があるところでだけ書く（無ければ終了コード 1）。`script/regen-snapshot` を追加。`spin test` は 64 プログラム。
- 2026-10-22: ファイルアップロード（D16）。フレームワーク側は `Multipart` / `MultipartForm` / `UploadedFile` / `BlobStore`、`Params#upload`、`Request#multipart_form`、`Controller#send_blob`、`form_with(multipart: true)` / `f.file_field`、`Config` の 3 キー。CLI 側は `cybertrain generate attachment` と scaffold の `FIELD:attachment`。CI の gem E2E が、添付付きの scaffold を生成・コンパイルし、生成テストを走らせ、curl でアップロードとダウンロード（バイト一致、ヘッダ）を確かめる。
- 2026-10-22: 認証（D15）。`cybertrain generate authentication` が users / sessions のマイグレーション、`User` / `Session` モデル、`SessionsController` / `RegistrationsController`、ビュー、`ApplicationController` への挿入、routes、`test/authentication.rb` を書く。フレームワーク側は `Cybertrain::Password`（PBKDF2-HMAC-SHA256）、`Controller.skip_before_action`、`Mapper#resource`、カスタム経路の派生名の衝突を無名にする規則。CI の gem E2E が生成したアプリをコンパイルしてサインアップ / サインインの統合テストを走らせる。
- 2026-10-23: `X-Content-Type-Options: nosniff` と `X-Frame-Options: SAMEORIGIN` を全レスポンスの既定にした（D14、D16）。`Response#to_http` が、同名のヘッダが無いときだけ出す。`Static::EXTENSIONS` に webp / avif / woff / ttf / otf / wasm などを追加。`Config` スイッチは作らず、上書きは `set_header`。
- 2026-10-25: アプリ定義の設定（D17、issue #69）。`Config#setting_string` / `setting_int` / `setting_bool` で宣言し、`string_setting` / `int_setting` / `bool_setting` で読む。`help` が宣言の一覧を、起動バナーが現在値（secret は伏せる）を出す。回帰テストは `test/config_settings.rb`。
