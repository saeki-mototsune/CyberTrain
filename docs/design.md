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

ジョブについては、MVP 後の 2026-10-25 に「後で送る」と「N 秒ごとに実行」を賄う最小の形（`Cybertrain::Scheduler` とデータベースのジョブキュー `Cybertrain::Job`）を D28 として追加した。メーラーは引き続き非目標。

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
- 2026-10-25 追記: `pluck`（型別の `pluck_str` / `pluck_int` / `pluck_float`）、`upsert`、`increment`、`count_by`、`sum_int` / `sum_float`、`where_like` を D22 で足した。

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
  - パスワードリセット・メーラー: メーラーが無い（2.3 節）。レート制限: 当初は未実装（2026-10-25 に D26 で `rate_limit` を足し、生成する SessionsController が使う）。`Current`: スレッドローカルの代わりに `resume_session` が `@current_user` / `@current_session` を置き、`view_assigns` 経由でテンプレートが読む。
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

### D21. マイグレーションのデータ操作: `execute` を操作として記録する（2026-10-25）

- 背景: マイグレーション DSL はスキーマ操作だけで、だから `change` から `down` を導ける。だが安全なスキーマ変更にデータ操作が要ることがある（既定値 90 の `retention_days` 列を足すとき、既存行は「無期限」の 0 に保たないと、新しい列の最初のデプロイで誰も選んでいない削除が始まる）。これまでは `up` を上書きし、`DB::CLI.resolved_path(".")` で 2 本目の `Connection` を開き、ロールバックのために migrator が `up` を呼んで操作を集めるときに再実行しないよう `schema_migrations` を手で調べ、`:memory:` を避けて閉じるしかなく、migrator の内部に依存していた（issue #73）。
- 決定:
  - `Migration::Base#execute(sql, binds = [])` を `change` / `up` / `down` の中で使える DSL にする。その場では何も実行せず、`Operation` の `:execute` 種別（`exec_sql` と、`Cast.to_sql` で変換済みの `exec_binds`）として記録する。`up` / `down` は今までどおり純粋な記録なので、migrator がロールバックの前に `up` を呼んでも文は走らない。
  - migrator は `:execute` を自分の接続で、そのバージョンのスキーマ操作と同じトランザクションの中で、記録順に実行する。前の `add_column` が済んでから `UPDATE` が走り、後の操作はその後に走る。データ操作が失敗すればそのバージョンのスキーマ操作も巻き戻り、バージョンは記録されない。バインドが無いときは `exec_script`（`;` で区切った複数文を流せる）、あるときは 1 文のプリペアドステートメント。
  - `:execute` に自動の逆操作は無い。`change` に `execute` を含み `down` を書いていないバージョンのロールバックは `IrreversibleMigration`（"version N is irreversible: it executes SQL in change; write down"）。migrator は対象のバージョンすべてについて `down` を先に記録してみて、記録できないものがあれば**何も戻す前に**止める（ファイルの消えたバージョンの検査と同じ位置）。この事前検査は `drop_table` など他の不可逆な `change` にも効き、メッセージにバージョンが付くようになった。`N` 段のロールバックが途中まで戻って止まることはもう無い。
  - `db/schema.rb` は DB からダンプするので、データ操作は現れない。ジェネレータ（`gen/migrations.rb`）はマイグレーションのファイルを `require_relative` するだけで中身を字句走査しないので、変更は要らない。
- 却下した案:
  - Rails の `reversible { |dir| dir.up { ... } }`。ブロックをレシーバ付きで後から呼ぶ形になり（`instance_exec` は無い、NOTES 規則 2）、`up` と `down` を書けば同じことができる。
  - `execute` の逆操作として `down` 側の SQL を引数で受ける（`execute up_sql, down_sql`）。バインドとの組み合わせが分かりにくく、`down` を書くほうが読める。
  - `execute` がその場で SQL を流す。migrator が操作を集めるために `up` を呼ぶたびに走ってしまう、issue が挙げたもろさそのもの。
- 名前: `Operation` の読み出しは `exec_sql` / `exec_binds`。`Relation#binds` と同名にしない（NOTES 規則 10 / 34）。`Base#execute` は `nil` を返し、`Connection#execute`（行の Array）と戻り値の型が違うが、一つのプログラムに両方があってもコンパイルできることを test/migration_execute.rb と test/db_integration.rb で確かめた。

### D22. クエリ API の追加: upsert、集計、pluck、binds、LIKE、JSON の Cast（2026-10-25、issue #74）

- 決定: 汎用のクエリビルダは作らず、アプリで何度も手書きされていた生 SQL の型を、型の決まった小さなメソッドとして足す。
  - `Model.upsert(attrs, conflict: [...], update: { col: "SQL 式" })`: `INSERT ... ON CONFLICT (...) DO UPDATE SET`。`update` が空なら `DO NOTHING`。戻り値は書いた行数（`changes`）。基底 `Model` のクラスメソッドで、サブクラスの `table_name` を読む（継承したクラスメソッドからの `table_name` 呼び出しは Spinel で各サブクラスのものに解決されることを確認した）。生成コードは増やさない。検証・コールバック・タイムスタンプの自動設定はしない。
  - `Relation#increment(column, by: 1)`: `UPDATE ... SET col = col + ?`。limit / offset があれば `delete_all` と同じく `id` の副問い合わせで窓を選ぶ。
  - `Relation#pluck_str` / `pluck_int` / `pluck_float`、`sum_int` / `sum_float`: Spinel ではメソッドごとに戻り値の型が一つなので、Rails の多相な `pluck` / `sum` ではなく型別に分ける。`sum` を Float 一本にすると、カウンタの合計（主な用途）が 2^53 を超えたところで丸まるため、整数版を別に持つ。`sum_float` は SQLite の `TOTAL`（行が無ければ 0.0）。
  - `Relation#count_by(column)` → `Hash{String => Integer}`（キーは `Cast.str`、昇順、NULL と `""` は同じキー `""` に合算）。生の式で集計する逃げ道は `count_by_sql(expr)`（時間バケツの `strftime(...)` など）。issue の `group_sql` は、連鎖メソッドにすると各モデルの生成コードが要り、しかも「複数の集計列を持つ行」の型が Spinel では多相 Hash にしかならないので、終端の `count_by_sql` にした。`order_sql` と同じく、式にリクエストのデータを入れてはいけない。`GROUP BY 1`（位置指定）を使うのは、表に `k` 列があると GROUP BY では別名より列が優先されるため。
  - `Relation#where_like(column, text)`（生成コードの連鎖メソッドと `Model.where_like`）と `Cast.like_escape(text)`: `\`・`%`・`_` を `\` でエスケープし、`LIKE ? ESCAPE '\'` に `%text%` を束縛する。前方一致は `like_escape(q) + "%"` を `where_sql` に渡す。
  - `Cast.binds(*values)`: `execute` が受け取る多相配列を `Cast.to_sql` を通して作る。可変長引数は Spinel でコンパイルできる（`Params#permit` が前例）ので、`binds1`〜`binds4` のような版は作らない。
  - `Cast.hash(v)` / `Cast.array(v)` と `Cast.empty_hash` / `Cast.empty_array`: JSON の値を Hash / Array に絞る。`when Time` を先に置く（NOTES 規則 8）。`v` そのものではなく、型の付いた新しい容器（`Hash[String, untyped]` / `Array[untyped]`、全スカラー型で種を入れる: 規則 9・46）に要素を浅く写して返す。`when Hash then v` で `v` を返すと戻り値が箱詰めの untyped になり（`--emit-rbs` で確認）、以後の呼び出しがすべて遅い経路に乗るため。
  - 列名はすべて `Ident.column?` で検査してバッククォートで囲み、不正な名前は `ArgumentError`（開発者の誤りなので 500）。値はすべて束縛する。
- 却下した案: 汎用クエリビルダ（`select` / `group` / `having` の連鎖）。型の決まらない行を返すことになり、生成コードも大きくなる。`pluck` を多相配列で返して `Cast` で絞らせる案は、呼び出し側が毎回同じ `Cast` を書くことになるので型別にした。
- 帰結: `Ident::RESERVED_COLUMN_NAMES` は変えない（足したのは Relation のメソッドと Model・Cast のクラスメソッドだけで、レコードのインスタンスメソッドは増えていない）。生成モデルには `where_like` の 2 行が増える。

### D23. ページ送り: `Relation#page` と `Page`、`params.page_number`、`paginate` ヘルパ（2026-10-25、issue #75）

- 決定: オフセット方式のページ送りをフレームワークに置く。
  - `Params#int(key, default:, min:, max:)`: 任意の `-` と 1〜18 桁の数字だけを `to_i` に渡し、それ以外は `default`、範囲外は `min..max` に丸める。Spinel の `String#to_i` は 2**63-1 を超えると `RangeError` を投げる（NOTES 規則 25）ので、リクエストの文字列を長さ確認なしに `to_i` しない。`Params.parse_int(text, default)` は同じ読み方で、`Config` も使う。
  - `Params#page_number`: `page` を 1 始まりで読み、`1..Params.max_page` に丸める。`Params.max_page` は Multipart と同じモジュール ivar で、`Application#boot` が `Config#max_page`（既定 10000、`CYBERTRAIN_MAX_PAGE`）を入れる。Params は HTTP 層にあり Config を読めないため。
  - `Relation#page(n, per: 50)`: リレーションを `LIMIT per OFFSET (n - 1) * per` に絞り（それまでの limit/offset は置き換える）、`Cybertrain::Page`（`number` / `per` / `row_offset` / `next?` / `prev?` / `next_number` / `prev_number`）を返す。`n` も `1..max_page` に丸めるので、オフセットは `(max_page - 1) * per` を超えない。`per` は 1〜1000 で、外れたら開発者の誤りとして `ArgumentError`。
  - `next?` は同じ窓に対する `SELECT 1 ... LIMIT per + 1` 一本で決める。`COUNT(*)` で全件は数えない。
  - テンプレートヘルパ `paginate(page, path)`: `<nav class="pager">` に「Newer」（`rel="prev"`）、「Page N」、「Older」（`rel="next"`）を出す。存在しないページへのリンクは出さない。リンクの問い合わせ文字列は、現在のリクエストのものから `page` を除き（`Query.without_key`、各組を復号して符号化し直す）、`page=N` を足したもの（1 ページ目は付けない）。`path` が自前の `?` を持つときはそちらを使う。`href` は `Html.escape` を通す。テンプレートからは `@page.next?` なども読める（`Helpers#call_object_method`）。
- 型付きの行について: 行は `Page` に載せず、リレーションに残す。`page` で窓を決めた後の `to_a` / `each` は、生成された `<Model>Relation` を通るので `Article` の配列のまま型付けされる。
- 却下した案:
  - `Page#rows`。型付きにするにはモデルごとに `ArticlePage` を生成する必要があり、すべてのアプリの gen/ が変わる。
  - 行を per + 1 件読んでリレーションにキャッシュし、1 本のクエリで済ませる案。生成された `to_a` が呼ぶ基底の `rows` を変え、`execute_models` と同じ型で種を入れた行配列の ivar を持ち、後続のチェーン呼び出しで無効化する必要がある。その代わりに `SELECT 1` を 1 本足すほうを選んだ。
  - `Params#page`。`Relation#page`（`Page` を返す）と同名で戻り値の型が違うと、推論が壊れる（NOTES 規則 34）。同じ理由で、`Page` のオフセットは `offset` ではなく `row_offset` と呼ぶ。
  - `paginate(page, path, params)`。`Params` は木を問い合わせ文字列に戻せない。リクエストの生の問い合わせ文字列を組ごとに読み直すほうが、入れ子やリストもそのまま残る。
  - 範囲外の `page` を 404 にすること。丸めるだけにした。
- 今後: キーセット方式（`after: id`）は大きなテーブル向けに後から足す。scaffold の index ビューは変えない（gen/ を新しいまま保つ）。使い方は README の「Pagination」に書いた。

### D24. 外向き HTTP クライアント: 待ちをすべて有界にし、非公開アドレスを既定で拒否する（2026-10-25、#63）

- 問題: アプリが Webhook・Slack・外部 API を呼ぶ手段が無かった。Spinel の `Net::HTTP` は TLS ハンドシェイク（`SSL_connect`）と最初の 1 バイト以降の読み取り（`SSL_read`）をブロッキングの C 呼び出しで行い、そのあいだ OS ワーカーを握る。既定の `SPINEL_WORKERS=1` ではそれがサーバ全体なので、止まった相手一つで全リクエストが止まる。`TCPSocket.new(connect_timeout:)` は Spinel では無視され（到達不能アドレスで 60 秒以上）、`IO#gets` は後の `wait_readable` に見えないバイトを抱える。
- 決定: フレームワークに `Cybertrain::HttpClient`（名前は issue で未定だったものをこう決めた）を置く。三層に分ける。
  - `cybertrain/net/socket.rb`（`Cybertrain::Net`）: 有界な TCP。`Socket.new` + `connect_nonblock(exception: false)` + `wait_writable(t)` の後に `getsockopt(SOL_SOCKET, SO_ERROR)` で結果を見る（二度目の `connect_nonblock` は CRuby では `EISCONN`、Spinel では素の `SystemCallError` になり、揃わない）。読み取りは必ず `read_nonblock` を先に試し、`:wait_readable` のときだけ `wait_readable(t)` で待つ（受信済みのバイトを待たない）。書き込みは `write_nonblock` + `wait_writable(t)`。待ちはどれも「1 回の待ちの上限 `timeout`」と「リクエスト全体の締め切り `deadline`」の小さい方（`Net::Timer`、単調時計）。行・長さ・終端までの読み取りは `Net::Reader`（バイトのバッファ + 読み位置）。メーラー（別 issue）も同じ層を使う前提で、HTTP を知らない。
  - `cybertrain/net/tls.rb`: openssl パッケージの `SSLSocket#connect_nonblock` / `read_nonblock` / `write_nonblock`（`exception: false`）で同じ有界な待ちを TLS に通す。**このファイルだけが `require "openssl"` する**。socket.rb と http_client.rb は openssl を要求しないので、https を使わないアプリは libssl をリンクしない。require すると `Net.tls_connector`（モジュールレベルの ivar、NOTES 18 / 64）に `OpenSSLConnector` が入り、入っていなければ https は「`require "cybertrain/net/tls"` が要る」という `TLSError` になる。検証はパッケージの `SSLContext#set_params` そのもの: `VERIFY_PEER` を OS の信頼ストアで（`SSL_CERT_FILE` / `SSL_CERT_DIR` で差し替え可。パッケージに `X509::Store` は無い）、`SSL_set1_host` によるホスト名検査、SNI、TLS 1.2 以上。CRuby の `SSLContext.new` の既定は `VERIFY_NONE` なので、両方で同じになるよう必ず `set_params` を呼ぶ。`close_notify` 無しの切断（`Connection: close` の後によくある）は終端として扱う。Content-Length / chunked で枠付けされた本文はそれでも完全でなければならない。
  - `cybertrain/http_client.rb`: HTTP/1.1、`Connection: close`、リダイレクト・プロキシ・keep-alive・Cookie・圧縮なし（通知用のクライアントでブラウザではない）。`get(url, headers:)` / `post(url, body, content_type:, headers:)` が `HttpClient::Response`（`status` Integer、小文字名の `headers`、`body`）を返す。応答は Content-Length、chunked（最後の転送コーディングが chunked のとき）、切断まで、の三通り。ヘッダは 1 行 8 KiB・合計 64 KiB・100 行、本文は `max_body`（既定 1 MiB）が上限。1xx は 5 個まで読み飛ばし、101 は拒否。URL は `URI` ではなく自前のバイト走査（rule 62 の `s = text.to_s` で）で分解し、userinfo・空白・制御文字・非 ASCII を拒否する。
- 非公開アドレス: 名前を一度だけ解決し（`Socket.getaddrinfo`、最初のストリームアドレス）、そのアドレスを `Net::Address.blocked_reason` で検査してから、そのアドレスに接続する。名前で判定しないので、`/etc/hosts` や DNS rebinding で私設アドレスを返す名前もリテラルと同じに拒否される。TLS の証明書は URL のホスト名で検査する。拒否するのは loopback、private（RFC 1918、`fc00::/7`、廃止済みの `fec0::/10`）、link-local（`169.254/16` はクラウドのメタデータ、`fe80::/10`）、unspecified（`0/8`、`::`）、multicast、broadcast、CGNAT `100.64/10`、文書用・ベンチマーク用・予約、IPv4-mapped / NAT64 / 6to4 に埋め込まれた同種、IPv4-compatible。IP の解析は `IPAddr`（Spinel に無い）ではなくバイト走査。`Config#http_allow_private`（`CYBERTRAIN_HTTP_ALLOW_PRIVATE=1` / `true`、既定 false）か `HttpClient.new(allow_private: true)` で許す。テストでローカルサーバを相手にするときと、社内サービスを呼ぶときのため。
- エラー: `HttpClient::Error` の下に `TimeoutError` / `RefusedError`（接続拒否・到達不能・名前解決失敗・リセット）/ `TLSError` / `BlockedAddressError` / `TooLargeError` / `BadResponseError`。メッセージは `host:port` だけを含み、**パスとクエリは決して含まない**（Webhook の URL は秘密をそこに持つ）。URL やヘッダの不正は `ArgumentError` で、これも URL を繰り返さない。Net 層は `Net::Error` の下の自前の例外を投げ、`HttpClient#perform` が rescue の段で HttpClient の例外に移す（NOTES 47: 例外の判別は rescue 節で。ブロックを取らないメソッドの中で、NOTES 32 / 45）。メーラーは同じ Net 例外を自分の例外に移せる。
- 名前解決はブロッキングのまま: ランタイムに非同期のリゾルバが無い。`getaddrinfo` の待ちは呼び出したスレッドの OS ワーカーを握る（通常は数ミリ秒、リゾルバが死んでいればシステムのタイムアウト）。締め切りはその時間を数えるが中断はできない。README に書いた。Spinel の `Socket.getaddrinfo` は解決できない名前に例外ではなく空配列を返し（CRuby は `SocketError`）、要素の配列は添字では読めず（`entry[3]` がコンパイルできない）、`each` のブロック引数の分解でだけ読める。
- 却下した案:
  - Spinel の `Net::HTTP` を使う、または包む: 待ちが C の中にあり、Ruby から上限を付けられない。
  - `IO#gets` で行を読む: 受信済みのバイトが stdio のバッファに残り、`wait_readable` がそれを見ずにタイムアウトまで待つ。
  - openssl を http_client.rb で直接 require する: TLS を使わないアプリにも libssl のリンクと、rule 62 の名前衝突面（openssl パッケージは `getbyte` / `read` / `write` / `close` / `<<` を Ruby で定義する）を強いる。
  - `require "cybertrain"` に含める: 呼ばれないコードを全アプリに入れると推論の穴を踏む（NOTES 36）。使う所で require する。
  - 解決したアドレスを全部検査して一つでも私設なら拒否、または複数アドレスへのフォールバック: 接続するのは一つだけなので、そのアドレスを検査すれば足りる。フォールバックは今は無い。
  - TLS の端から端までのテスト: パッケージに X509 が無く証明書を作れず、TLS サーバも無い。test/http_client.rb はハンドシェイクの失敗（平文の HTTP サーバ相手）とタイムアウト（黙るサーバ相手）までを確かめ、実サイトへの検証付きハンドシェイクは手で確認した。
- 帰結: test/template_integration.rb はフレームワーク全体に http_client と net/tls（つまり openssl パッケージ）を加えたプログラムになり、HttpClient で Server に POST する。rule 62 の回帰はここと test/openssl_dispatch.rb で見る。

### D25. ログインの方針をフレームワークへ: 直列化した照合、ダミー照合、パスワード変更でのセッション失効、テスト時の反復回数、絶対有効期限、安全な戻り先（2026-10-25、issue #71）

- 背景: D15 は「自分で書くと間違えるもの」だけをフレームワークに置いたが、どのアプリも要る方針（絶対有効期限 ad3cb63、戻り先の検査 536665f）が生成コードの側に書かれ、アプリが自分で足すしかないもの（照合の直列化、存在しないアドレスの時間差、パスワード変更時の失効）も残っていた。README の機能一覧だけを見た設計調査が `Cybertrain::Password` と `skip_before_action` を見落として代替を書いたこともあり、README に「Authentication: what the framework provides」節を設けた。
- 決定:
  - `Password.verify_serialized(plain, digest)`: `verify?` をプロセス内の `Mutex`（モジュール ivar、NOTES 規則 18 / 64）の中で一つずつ走らせる。PBKDF2 は 1 回約 0.2 s の CPU を使い、ログインの集中が `SPINEL_WORKERS` 個の OS ワーカーを全部ふさぐと他のページが待つ。直列化すれば計算しているワーカーは高々一つ。待つスレッドは Mutex で止まる（回らない）。ロックはログイン時だけで、リクエストごとの経路には置かない（NOTES 規則 57）。
  - `Password.dummy_digest`: 乱数パスワードのダイジェストをプロセスで一度だけ作り（`iterations` が変わったら作り直す）、存在しないアドレスでもこれに対して一回照合する。応答時間でアカウントの有無が分からない。生成コードは従来 `Password.hash` を呼んでいた（照合ではなく生成なので、塩の生成など費用の形が違った）。
  - `Password.session_key(digest)` / `session_key_matches?(key, digest)`: パスワードダイジェストの HMAC-SHA256（鍵は `secret_key_base`、ラベル付き）。サインイン時にセッションへ入れ、毎リクエスト比較する。パスワードを変えるとダイジェスト（塩ごと）が変わるので、それ以前のセッションは一致しなくなる。クッキーは署名のみで読めるが、値は秘密鍵なしではダイジェストについて何も言わない。再ハッシュ（`needs_rehash?`）でもダイジェストが変わるため、反復回数を上げた直後に各ユーザーの他のブラウザが一度サインアウトされる。これは受け入れた。
  - `Password.iterations`: 明示的に設定していなければ、`Cybertrain.config.test?` で `TEST_ITERATIONS`（1000、`iterations=` の下限）、それ以外で `ITERATIONS`（10 万）。ダイジェストは自分の反復回数を持つので、検証側は何も変わらない。値は問い合わせのたびに決める（`password.rb` の読み込み時点では Config がまだ作られていないことがある）。そのため `password.rb` は `cybertrain/config` を require する。
  - `Config#session_absolute_max_age`（既定 1209600 = 2 週間、ad3cb63 が生成コードで使った値と同じ。0 で無効）: `SessionStore` が、セッションを初めて書くときに `"_issued_at"`（エポック秒）をクッキーに入れ（署名の内側）、読み込み時にこの時間を過ぎていれば空のセッションとして扱う。送る Max-Age は残り時間を超えない。この設定より前のクッキーは最初のリクエストで開始時刻を刻む。`Session#restart_lifetime!` で数え直す（生成コードはサインイン時に呼ぶ）。`SessionStore.new` の既定は 0（無効）で、`Application` が Config の値を渡す。テストは `SessionStore#fixed_now=` で時計を固定する（ラムダをキーワード引数で渡すのは NOTES 規則 42 で不可）。
  - `Controller#local_path?(text)` / `safe_redirect_path(text, fallback)`: `/` で始まり `//` でも `/\` でもなく、印字可能な ASCII（0x21〜0x7E、バックスラッシュを除く）だけで、2048 バイト以下のときだけ自サイトのパスとして受け入れる。ブラウザが送るパスはすでにパーセント符号化されているので、非 ASCII を拒んでも正しいリンクは落ちない（536665f の生成コードは `/記事` を通していたが、今は拒む）。
  - 生成コード（`cybertrain generate authentication`）: `User.authenticate_by` / `#authenticate` は `verify_serialized` とダミーダイジェストを使い、`start_new_session_for` は `session.restart_lifetime!` と `session[:password_key]` を書き、`resume_session` は鍵が一致しなければ Session 行を消してサインアウトし、行の `created_at` の期限には `session_absolute_max_age` を使う（クッキー側の期限と同じ値で、行の側でも止める）。`after_authentication_url` は `safe_redirect_path` の一行になった。
- 却下した案:
  - パスワード鍵を sessions テーブルに持つ: 行は消せば失効するが、パスワード変更時に全行を消す処理をアプリが書く必要がある。セッションの値として持てば比較だけでよい。
  - 絶対有効期限を生成コード（行の `created_at`）だけで持つ: 認証を使わないアプリのセッション（CSRF トークン、フラッシュ）は期限なしのままになる。両方に置いた。
  - `verify?` 自体を直列化する: 認証以外の用途（API トークンのバッチ照合など）まで一列に並ぶ。別名にした。
- 帰結: `ATTACHMENT_RESERVED_ACTIONS` に `safe_redirect_path` を足した（コントローラのメソッド名と添付フィールド名の衝突、`script/check-reserved-names`）。`local_path?` は `?` 付きなのでフィールド名になれない。テスト: test/password.rb（直列化はロックを保持したまま別スレッドの照合が終わらないことと、並行時の同時実行数 1 で確かめる）、test/session.rb（固定した時計で期限）、test/controller.rb（戻り先）、test/cli_authentication.rb（生成物）。

### D26. レート制限と `request.client_ip`: 同一ホストの信頼済みプロキシだけを信じる（2026-10-25、issue #70）

- 決定:
  - `Request#client_ip`: 既定は `remote_addr`。`Config#trusted_proxy`（既定 false、`CYBERTRAIN_TRUSTED_PROXY=1` / `true`）が真で、**かつ**接続元がループバック（127.0.0.0/8、`::1`、`::ffff:127.x.x.x`）のときだけ、`X-Forwarded-For` の**最後の**要素（同じホストのプロキシが付け足したもの）を使う。それより前の要素はクライアントが自由に書けるので一切使わない。最後の要素が空、45 バイト超、印字可能 ASCII（0x21〜0x7E）以外を含む、またはヘッダが無いときは `remote_addr`。走査はすべてバイト単位（`getbyte` / `byteslice`）で、`split` / `strip` / `downcase` は使わない（ヘッダは任意のバイトを含みうる。CRuby の `split` は不正な UTF-8 で例外を投げる、NOTES 規則 52）。引数は `s = value.to_s` の新しいローカルで読む（規則 62）。
  - `Request#loopback?`: `remote_addr` がループバックか（X-Forwarded-For は見ない）。初回セットアップ画面や管理用エンドポイントの「このマシンからだけ」の判定用。ドット区切り 4 要素・各 0〜255 を検査し、`127.0.0.1x` や `1270.0.0.1` は偽。サーバは TCP だけで UNIX ソケットを持たないので、その場合分けは無い。
  - 信頼フラグは HTTP 層のモジュール ivar `Request.trusted_proxy` に置き、`Application#boot` が `Config#trusted_proxy` を入れる（`Params.max_page` / `Multipart.configure` と同じ形。HTTP 層は Config を読めない、`script/check-http-layer`）。
  - `Controller.rate_limit(to:, within:, only: [], except: [], by: :client_ip, redirect_to: "", alert: "")`: 宣言ごとに `Cybertrain::RateLimit`（issue では名前未定だったのでこれにした）を一つ作って `RateLimit::ALL`（定数なので GC ルート、NOTES 規則 64）に登録し、その添字を持つ before コールバック（`Callback#limit_id`、他のコールバックは -1）を足す。`run_one` は添字があればストアドブロックではなくコントローラ自身の private メソッド `apply_rate_limit` を呼ぶ。ストアドブロックからの呼び出しは呼び先の引数の型を決めない（規則 30）ので、ブロックで包む形は避けた。宣言順で他の before_action と並ぶ。`by:` は `:client_ip`（既定）と `:remote_addr`。
  - 数え方は固定窓: キー（`"<controller_path> <アドレス>"`。親で宣言した制限もサブクラスごとに別に数える。Rails の `rate_limit` と同じ）ごとに窓の開始秒と回数を持つ。窓の最初の要求が窓を開き、`to` 回目までを通し、`within` 秒後に閉じる。超えたら 429・本文 `Too Many Requests`・`Retry-After`（窓が閉じるまでの秒、最小 1）。`redirect_to:` があれば 303 でそこへ送り、`alert:` を `flash[:alert]` に入れる（Rails の生成コードの `with: -> { redirect_to ..., alert: ... }` に当たる。ブロック形は上の理由で採らない）。どちらでもアクションは走らない。
  - メモリの上限: 型付き Hash 2 つ（開始秒・回数。種を入れて空にする、規則 9）を Mutex 一つで守る。キーは窓を開いた順に並べ、窓を開き直したキーは削除して入れ直すので、表は常に開始秒順で、期限切れは先頭に固まる。新しいキーが満杯（既定 10 000 キー、`max_keys=`）の表に来たら、先頭から期限切れを消し、それでも 9 割を超えていれば古い窓から消す（1 割ずつ空けるので、`keys` の複製を作るのは満杯のときだけ）。大量のアドレスで攻撃されても他のクライアントの窓が早く閉じるだけで、プロセスは育たない。
  - 時刻は `RateLimit.current_time`（エポック秒）。テストは `RateLimit.current_time = n` で固定し、-1 でシステム時計に戻す。
  - `cybertrain generate authentication` の `SessionsController` は `rate_limit to: 10, within: 3 * 60, only: [:create], redirect_to: "/session/new", alert: "Try again later."` を書く（Rails 8 の生成物と同じ値と振る舞い）。`start_new_session_for` が記録する `ip_address` も `request.client_ip` にした。生成する `AppTest.sign_in` は最初に `RateLimit.reset_all!` を呼ぶ: テストクライアントはすべて 127.0.0.1 なので、毎テストでサインインするスイートは 10 回を超える（Rails はテスト環境のキャッシュが null store なので数えない）。
  - `Controller::STATUS_SYMBOLS` と `Test::Client` の `assert_response` に `:too_many_requests`（429）を足した。
- 却下した案:
  - X-Forwarded-For の最初の要素を使う案、または信頼するプロキシの一覧（CIDR の設定）を右から辿る Rails の `remote_ip` 方式。最初の要素はクライアントが選べる。一覧を辿る実装は多段構成のためのもので、cybertrain の想定（同じホストの nginx / Caddy / kamal-proxy 一段、docs/deploy.md）には過剰。直接つながるクライアントが自分のアドレスを選べないことは「ループバックからの接続に限る」で保証する。
  - ループバック判定なしで `trusted_proxy` だけを見る案。設定したままアプリを外部に直接公開すると、誰でもアドレスを詐称できる。
  - 単調時計。窓の秒数はそのまま `Retry-After` に出すので壁時計の整数秒で足り、テストで差し替えやすい。
  - データベースで数える案（複数プロセスで共有）。今回はプロセス内だけ。後から宣言はそのままに裏側を差し替えられるよう、カウンタは `RateLimit` に閉じ込めた。
  - `only: :create`（Symbol 単体）や `within: 3.minutes`。`before_action` と同じく配列だけを受け、`Integer#minutes` は無いので秒の整数にした。
- 帰結: 制限されたアクションへの要求は一つのロックを取る（NOTES 規則 57: 全要求でロックを取ると複数ワーカーで詰まる）ので、`only:` で絞るようドキュメントに書いた。ロックの保持区間は Hash の数回の操作で、満杯時の掃除も 1 割ぶん。`apply_rate_limit` はコントローラの private メソッドなので `ATTACHMENT_RESERVED_ACTIONS` に足した（`script/check-reserved-names`）。使い方は README の「Rate limiting and the client address」に書いた。
- 追記（PR #79 のレビュー指摘）: 信頼するプロキシを CIDR で列挙できるようにした。リポジトリ自身のデプロイ手順（docs/deploy-kamal.md、examples/blog の Kamal 設定）では kamal-proxy とアプリが別々の Docker コンテナで動き、アプリから見た接続元は Docker のブリッジネットワーク上の kamal-proxy のアドレス（既定で 172.16.0.0/12 の中）でループバックにならない。ループバックに限る規則のままでは `trusted_proxy` がそこで効かず、`rate_limit` が全員を kamal-proxy の一つのアドレスとして数える。上の却下案「信頼するプロキシの一覧」は、多段構成のために右から辿る形を却下したもので、一段のまま一覧で照合する形はここで採る。
  - `Config#trusted_proxies`（既定 `[]`、`CYBERTRAIN_TRUSTED_PROXIES` をカンマで分けて前後の空白を除く）: IPv4 / IPv6 のアドレスまたは CIDR。`Config#trusted_proxies_error` が起動時に検査し（`fail_boot`、他の `*_error` と同じ形）、アドレスでも CIDR でもない項目、/32・/128 を超える接頭辞、`%zone` 付きの項目を拒む。`Application#boot` が `Request.trusted_proxies=` に入れ、そこで解析済みの形（接頭辞長と IPv6 形の 16 バイト、計 17 個の Integer を一本の型付き配列に並べる）にする。`Request.trusted_proxies=` に直接渡した不正な項目は ArgumentError で、入っていた一覧はそのまま。
  - `Request#client_ip`: `remote_addr` が「`trusted_proxy` が真でループバック」または「一覧のどれかに入る」ときだけ、従来と同じ検査で `X-Forwarded-For` の最後の要素を使う。一段だけ、という原則（issue #70）は変えない。`CYBERTRAIN_TRUSTED_PROXY=1` は `127.0.0.0/8,::1` の略記で、一覧と足し合わされる。
  - 照合は HTTP 層の新しいファイル `cybertrain/http/ip_address.rb`（`Cybertrain::IpAddress`）で、バイト走査だけ（IPAddr も Regexp も使わない）。IPv4 の項目は IPv4 射影形（`::ffff:a.b.c.d`、接頭辞 +96）として持つので、デュアルスタックの待ち受けが報告する `::ffff:172.18.0.2` も IPv4 の項目に一致する。相手のアドレスの `%zone` は無視する。IPv4 / IPv6 の解析は `Net::Address`（外向き HTTP クライアントの検査）にあったものをここへ移し、`Net::Address.parse_ipv4` / `parse_ipv6` / `hex_value` は委譲だけにした（HTTP 層は単独で読み込めなければならない、`script/check-http-layer`）。`Config` がこのファイルを require する（依存のない一ファイルだけで、サーバ本体は読まない）。
  - `cybertrain new` が書く `config/deploy.yml`（と examples/blog の同じ設定）は `env.clear` に `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` を書く。Kamal はアプリのポートをホストに公開しないので、アプリに届くのは Docker ネットワーク上のコンテナだけ。`proxy.forward_headers` は設定しない: `ssl: true` の kamal-proxy はクライアントが送った `X-Forwarded-For` を渡さず自分で付ける（Kamal のドキュメント）。`forward_headers: true` は kamal-proxy の前にさらにプロキシがあるときのもので、ここで付けるとクライアントの書いた値が届く。
  - 却下: 既定で 172.16.0.0/12 などの私用アドレスを信頼する案。同じホストの nginx（ループバック）や LAN 内から直接つながる構成で、LAN の誰もがアドレスを選べてしまう。設定はアプリ（生成した deploy.yml）の側で明示する。
  - テスト: test/client_ip.rb（v4 / v6 / v4 射影の一致、範囲外は `remote_addr`、単一アドレス、不正な項目の拒否、ループバックの略記との併用）、test/cli_new.rb（生成される deploy.yml）。

### D27. メーラー: 有界なソケット層の上の最小の SMTP クライアント（2026-10-25、#64）

- 問題: アプリからメールを送る手段が無かった。`cybertrain generate authentication` もメーラーが無いことを理由にパスワードリセットを省いている。STARTTLS・暗黙の TLS・有界な待ちを正しくやると自前の SMTP クライアントは数百行になり、アプリごとに書くものではない。
- 決定: `Cybertrain::Mailer`（cybertrain/mailer.rb、`Smtp` ではなくこの名前にした）。D24 の `Cybertrain::Net` の上に作り、ソケットのコードは複製しない。接続・TLS の各段・各応答の読み取り・書き込みはどれも `timeout`（既定 10 秒）と配信全体の `deadline`（既定 60 秒）の小さい方まで（`Net::Timer`）。応答は `Net::Reader` の行読みで、複数行応答（`250-...`）はコードが変われば `ProtocolError`、1 行 4 KiB・100 行が上限。
  - API: `Mailer.deliver(to:, subject:, body:, from: "")`（`Config` の設定で）と `Mailer.new(host:, port:, user:, password:, from:, tls:, timeout:, deadline:, helo:)#deliver(...)`（各キーワードの既定は `Config`、テストやアプリが Config を迂回できる）。戻り値は本文に対するサーバの応答（`250 ... queued as ...`）。`to:` は String 一つで、複数の宛先はカンマ区切り（String と Array を受ける多相の引数は Spinel で危うい、NOTES 14 / 29）。
  - 対話: 220 の挨拶、`EHLO`、`starttls` では `STARTTLS` → 220 → TLS ハンドシェイク（`Net.tls_connector`）→ `EHLO` をやり直す、ユーザがあれば `AUTH PLAIN`（初期応答付き、RFC 4616。`\0user\0password` の base64 は Spinel の base64 パッケージの `strict_encode64`。NUL を含むので補間でなく `<<` で組む、NOTES 60）、`MAIL FROM:<>`、宛先ごとの `RCPT TO:<>`（250 か 251）、`DATA`（354）、ドット詰めした本文と `.`、`QUIT`（221 は待つが、失敗しても配信の失敗にしない）。パイプライン化はしない。
  - TLS モード: `starttls`（既定、587）、`tls`（暗黙の TLS、465）、`none`（平文、25）。`smtp_port` の既定は 0 で「モードの番号」を意味する（Config 初期化後に `config/app.rb` が `smtp_tls` を変えても番号が追随するように）。TLS が要るモードで `cybertrain/net/tls` が require されていなければ、接続する前に `TLSError`（`TlsConnector#tls_ready?` を足した。openssl を mailer.rb から require しないのは D24 と同じ理由）。STARTTLS の 220 の後に届いていた平文のバイトは TLS 越しに来たものとして読まれてしまう（STARTTLS コマンド注入）ので、`Reader` に残っていれば `ProtocolError`。サーバが STARTTLS を広告しなければ `TLSError`（平文へ黙って落ちない）。
  - 資格情報: `none` でユーザが設定されているとき、名前を解決したアドレスが loopback でなければ接続前に `InsecureError`。パスワードはエラーメッセージ・ログ・起動バナー・`help` のどれにも出ない（Config の組み込み属性はバナーに出ないし、メッセージは `host:port`・段・サーバの応答だけで組む。サーバの応答は印字可能な ASCII に直して 300 バイトで切る）。`inspect` は上書きしない: 組み込みと同名のメソッドを定義すると箱入りの受け手への呼び出しがすべて切り替わる（NOTES 62）。
  - メッセージ: `Date`（UTC）、`From`、`To`（78 桁を超えるところで折る）、`Subject`、`MIME-Version: 1.0`、`Content-Type: text/plain; charset=UTF-8`、`Content-Transfer-Encoding`。件名は印字可能な ASCII ならそのまま、それ以外（非 ASCII、`=?` を含む、900 バイト超）は RFC 2047 の B 符号化語（生の 45 バイトまで、UTF-8 の文字の途中で切らない、語ごとに折り返す）。本文は改行を CRLF にそろえ、行頭の `.` を二重にする。転送符号化は ASCII なら `7bit`、UTF-8 でサーバが 8BITMIME を広告すれば `8bit`（`MAIL FROM ... BODY=8BITMIME`）、それ以外か 998 バイトを超える行があれば `base64`（76 桁）。issue の案（広告が無くても 8bit で送る）ではなく、RFC 6152 どおり広告の無いサーバに 8bit を送らないほうを選んだ。`Message-ID` は付けない（投稿用サーバが付ける、RFC 6409）。
  - 拒否するもの（接続前に `ArgumentError`、メッセージは値を繰り返さない）: 裸の ASCII `local@domain` でないアドレス（CR/LF、空白・制御文字・非 ASCII、`<>()[],;:\"`、`@` が一つでない、ローカル部 64 バイト・全体 254 バイト超）、CR/LF/NUL を含む件名（ヘッダ注入）や 998 バイト超の件名、UTF-8 として不正か NUL を含む本文、101 以上の宛先。
- エラー: `Mailer::Error` の下に `TimeoutError` / `ConnectError` / `TLSError` / `ProtocolError` / `InsecureError` / `RejectedError`（`smtp_code` にサーバのコード、メッセージに段とサーバの文面）。Net の例外は `Mailer#perform` の rescue の段で移す（HttpClient と同じ、NOTES 32 / 45 / 47）。
- 設定: `Config#smtp_host` / `smtp_port` / `smtp_user` / `smtp_password` / `smtp_from` / `smtp_tls`、環境変数 `CYBERTRAIN_SMTP_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_FROM` / `_TLS`。初期化は `Config#initialize` の中に直接書く: 初期化から呼ぶ補助メソッドで初めて代入した ivar は箱入りになり、キーワード引数の既定値で読むとコンパイルできない（NOTES 73）。
- 却下・後回し: HTML・multipart・添付・テンプレート・表示名・`Cc` / `Bcc` ヘッダ・AUTH LOGIN / CRAM-MD5・SMTPUTF8・パイプライン化・配信キュー（`deliver_later`）。パスワードリセットの生成（`cybertrain generate authentication`）は別の作業として残し、ジェネレータのコメントもまだ変えていない。TLS の端から端までのテストは D24 と同じ理由で無い: test/mailer.rb は STARTTLS と暗黙の TLS をハンドシェイクの失敗（平文で答えるサーバ）まで確かめる。

### D28. バックグラウンド処理: `Scheduler` とデータベースのジョブキュー `Job`（2026-10-25、issue #65）

- 決定: サーバとして動くプロセスにだけ、フレームワークがバックグラウンドのスレッドを一本起こす。
  - `Cybertrain::Scheduler.every(seconds, name) { ... }`: `config/app.rb` か `bin/<app>.rb` が読むファイルで登録する。タスクは型付きの `Scheduler::Task`（名前、間隔、Proc、次回の時刻）で、定数 `Scheduler::TASKS` の配列に積む（クラス変数は GC ルートにならない、NOTES 64。空配列は要素型で種付け、NOTES 9）。ブロックは引数を取らない（`instance_eval` が無いので暗黙の受け手は無い）。最初の実行は開始の `seconds` 秒後、以後は各実行の開始から `seconds` 秒後。
  - `Scheduler.start!(config)` を `Application#serve` が呼ぶ。`boot` が DB に接続し、ポートを bind し、`SPINEL_WORKERS` を設定した後（NOTES 22）で、起動バナーの後。`serve` に来るのは `Main.server?(argv)` が真のときだけなので、`migrate` / `db` / `Main.command` では動かない。アプリの `bin/` がスレッドを自前で起こす必要は無くなる。`Test::Client` は `serve` を通らないので、テストでも動かない。
  - 各回は `Scheduler.run_task` という yield しない普通のメソッドの中で、Task から読んだ Proc を `call` し、`rescue JSON::NestingError, JSON::ParserError, StandardError` で `[ERROR]` を記録して続ける（NOTES 32 / 45 / 61 / 69）。失敗したタスクも次の時刻にまた走る。
  - `Scheduler.run_due(now)` が 1 回の tick で、テストは時刻を渡して呼ぶ（眠らない）。`Scheduler.last_tick`（Integer の epoch 秒、Mutex の下で読み書き）はヘルスチェックが読める。`stop!` はスレッドに終了を頼み、`start!` の世代番号で古いループが新しいループと並んで走らないようにする。
  - `Cybertrain::Job`: `Job.handle(kind) { |payload| ... }` でハンドラを登録し（定数 `Job::HANDLERS`）、`Job.enqueue(kind, payload, run_at: Time.now)` でテーブル `cybertrain_jobs`（id, kind, payload, run_at, attempts, last_error, state = queued / running / done / failed, created_at, updated_at）に行を足す。payload は String で、構造のあるデータはアプリが JSON にする。未登録の kind の enqueue は `ArgumentError`（綴り間違いを enqueue の時点で知らせる。全プロセスが同じ `bin/<app>.rb` を通るので、どのプロセスでも登録は揃う）。
  - ワーカーはスケジューラのタスク（`"cybertrain jobs"`、`Config#job_poll_interval` 秒ごと、既定 5）として、ハンドラが一つでも登録されているときだけ `start!` が足す。1 回のポーリングで期限の来た行を最大 `Job::JOBS_PER_POLL`（20）件、1 件ずつ処理する（`Job.work_one(now)`、テストからも呼べる）。
  - 取得は `DB.transaction(immediate: true)` の短いトランザクションで、最も古い期限到来の `queued` 行を SELECT し、`UPDATE ... SET state = 'running', attempts = attempts + 1 WHERE id = ? AND state = 'queued'` の `changes == 1` を確かめる。ハンドラは COMMIT の後、ロックを持たずに呼ぶ。成功なら `done`、例外なら `last_error`（"Class: message"、1000 文字で切る）を残して `run_at` を後ろへずらし `queued` に戻す（待ちは 60, 300, 900, 3600 秒、以後 3600 秒）。試行回数が `Config#job_max_attempts`（既定 5）に達したら `failed`。ハンドラの無い kind の行（デプロイで消えたハンドラ）はすぐ `failed` にする。
  - 取得時に試行回数を数えるので、処理中にプロセスが落ちた行も 1 回と数える。ワーカーの開始時に `running` のまま残った行を `queued` に戻す（`Job.recover!`）。ワーカーはデータベースごとに一つ（次項）なので、その時点で他に処理中のプロセスは無い。
  - `Config#worker`（`CYBERTRAIN_WORKER`、既定は真。`0` / `false` で偽）が偽なら `start!` は何もしない。同じデータベースを共有するプロセスが複数あるとき、一つ以外はこれで止める。`scheduler_interval`（tick の間隔、既定 1 秒）、`job_poll_interval`、`job_max_attempts` が 1 未満なら boot が止まる。
- テーブルの用意: フレームワーク所有のマイグレーションではなく、`Job.install!` が `CREATE TABLE IF NOT EXISTS`（と索引）を発行する。最初の `enqueue`、ワーカーの開始、`work_one` などが DB の接続ごとに一度だけ呼ぶ（`DB.generation` は `DB.connect` の回数で、どの接続世代で用意したかを覚える）。時刻は epoch 秒の INTEGER で、SQL で `run_at <= ?` と比べるだけで済む。`db/schema.rb` のダンプからは `schema_migrations` と同じく外す（`SchemaDumper.table_names`）。入れるとジェネレータがモデル `CybertrainJob` を生成してしまう。
- 理由: スレッドを手で起こすと、`SPINEL_WORKERS` の設定順、DB 接続の待ち、rescue と記録、`Main.server?` の確認、SQLite の呼び出しが OS ワーカーを握る問題をアプリごとにやり直すことになる。確実な配送のキュー（期限順、指数的な再試行、最終状態、回数の上限）はさらに数百行になる。
- 却下した案:
  - フレームワーク所有のマイグレーションをアプリに含めさせる案。全アプリの `db/migrate` と `gen/migrations.rb` が変わり、ジョブを使わないアプリにもテーブルができる。schema.rb にも出てモデルが生成される。
  - ジェネレータでマイグレーションを書き出す案（`cybertrain generate jobs`）。テーブルの形はフレームワークのコードが決めるもので、アプリが変える理由が無い。形を変えたときにアプリのマイグレーションと食い違う。
  - タスクのブロックが引数（文脈オブジェクト）を取る形。渡すものが今は無い。必要になれば別名の登録メソッドで足せる。
  - ハンドラをトランザクションの中で呼ぶ案。長いハンドラが書き込みロックを握り続け、リクエストの書き込みを待たせる。
- 制約（SQLite と Spinel）: タスクもハンドラもスケジューラのスレッドで一つずつ走る。SQLite の呼び出しは戻るまで OS ワーカーを握るので、`SPINEL_WORKERS=1` では長いタスクがすべてのリクエストを止める。仕事は小分けにし（1 回に千行など）、タスクは短く保つ。README の「Background work」に書いた。
- 今後: cron 形式の時刻指定、ジョブの優先度と一意性、複数ワーカーでの分担（行の取得は既に排他なので、`worker` スイッチを外せば始められる）、`failed` 行の再投入コマンド。
- 検証: `test/scheduler.rb`（期限前に走らないこと、例外の記録とループの継続、`last_tick`、`worker` が偽なら何もしないこと、実スレッドの起動）、`test/jobs.rb`（フレームワーク全体と一緒にコンパイル。enqueue / 取得 / 実行 / done、期限順、バックオフと試行回数、最終の `failed`、未知の kind、`last_error` の上限、`recover!`、巻き戻されたトランザクション内の enqueue、`prune_done`、schema ダンプからの除外、スケジューラによるワーカータスクの追加）。

### D29. 招待制の初回セットアップ: `generate authentication --invite-only`（2026-10-25、issue #72）

- 背景: console が無いので、認証ジェネレータは最初のユーザーを入れるために公開の登録画面（`/sign_up`）を書く（D15）。社内ツールでは既定として誤りで、管理者より先にサーバへ届いた誰もが登録できる。アプリが結局自分で書くのは (a) パスワードを標準入力から読む `myapp user EMAIL` サブコマンドと、(b) ユーザーが一人もいない間だけ、ループバック接続にだけ応える `/setup` 画面と、ユーザーがいない間の起動時の `[WARN]`。
- 決定: `cybertrain generate authentication --invite-only` を足す。既定の生成物との違いは次のとおりで、すべてアプリのコード（D15 の方針。フレームワーク側は D26 の `request.loopback?` と D18 の `Main.command` を使うだけ）。
  - `RegistrationsController`、`registrations/new.html.erb`、`/sign_up` の経路、サインイン画面の「Sign up」リンクを書かない。
  - `app/commands/user_command.rb`: `UserCommand` モジュールと `Cybertrain::Main.command("user", ...)` の登録。`EMAIL [PASSWORD]` で、そのアドレスのユーザーを作るか、いればパスワードを変える（`password=` でダイジェストが変わるので、そのユーザーの既存セッションは D25 のパスワード鍵で失効する）。`created ADDRESS` / `updated ADDRESS` を出して 0。引数の誤り（0 個、3 個以上、`-` で始まる）は使い方の行を出して 1、空のパスワードと検証エラー（8 文字未満など）はエラー行を出して 1。PASSWORD を省くと標準入力から 1 行読み（端末なら `Password: ` を出す）、末尾の改行 1 つ（`\n` / `\r\n`）だけを落とす。`ps` とシェル履歴にパスワードを残さないため。端末のエコーは止めない（`io/console` が無い）。`STDIN.gets` と `STDIN.tty?` は Spinel 2026.09.12 で CRuby と同じに動くことを確かめた。
  - `bin/<app>.rb` の `exit(Cybertrain::Main.run(` の行の直前に、上のファイルの `require_relative` と `UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)` を一度だけ挿入する（`ApplicationController` への挿入と同じ一回限りの編集。require が既にあれば何もしない）。
  - `SetupController`（`GET` / `POST /setup`、`app/views/setup/new.html.erb`）: `before_action :require_first_run` が、ユーザーが存在する（`User.all.exists?`）なら 404、そうでなく設定 `setup_open` が偽なら、`request.loopback?` かつ `X-Forwarded-For` ヘッダが無いときだけ通す。作成に成功したら `start_new_session_for` でサインインさせて `/` へ。
  - `config/app.rb` の `Cybertrain.configure` ブロックの先頭に `c.setting_bool :setup_open, env: "<APP>_SETUP_OPEN", default: false`（D17）を挿入する。真なら、ユーザーがいない間だけ、どのアドレスからでも `/setup` を開ける（別ホストのプロキシの後ろでの初回起動用）。
  - 生成するテスト（`test/authentication.rb` の招待制版）: 別アドレスからの 404（`client.peer_address = "203.0.113.7"`）、プロキシ経由（X-Forwarded-For 付き）の 404、ユーザーがいれば 404、スイッチで開くこと、作成とサインイン、短いパスワードの再表示、`user` コマンドの作成・更新・拒否を `Cybertrain::Main.run` 経由で（終わったらテスト側のプールを繋ぎ直す: コマンドはプール 1 本で繋いで切る、D18）、改行の扱い、警告の判定。サインイン以降のテストは既定版と共通。
  - フレームワークに足したのは二つだけ: `Test::Client#peer_address`（既定 `"127.0.0.1"`、テストが別のマシンからの要求を作るため。`remote_addr` と同名の読み出しは避けた、NOTES 規則 10）と、`Main.server?` を `@api public` にしたこと（起動時だけの処理をアプリが一回きりのコマンドで動かさないための判定）。
- 理由:
  - **ループバックの判定はソケットの相手だけ。** ヘッダはクライアントが書けるので、開く理由にはしない。逆に、同じホストのプロキシ（nginx / Caddy / kamal-proxy）の後ろでは全要求の `remote_addr` がループバックになり、`CYBERTRAIN_TRUSTED_PROXY` を設定し忘れると `/setup` が世界に開く。プロキシは `X-Forwarded-For` を付けるので、ヘッダがあれば閉じる。ヘッダで閉じる側に倒すのは安全（偽装しても自分が締め出されるだけ）。
  - **起動時の警告の置き場所。** `Application#boot` の後に呼ばれるフックは無い。フレームワークに `after_boot` の登録を足す案は、保存したブロックの呼び出し（NOTES 規則 30 / 69）を全プログラムの起動経路に入れ、そのための全体テストも要る。生成コードで済むので、`bin/<app>.rb` で `Main.run` の前に、サーバとして起動するとき（`Main.server?`）だけ、プール 1 本で繋いで `User.all.exists?` を聞き、切ってから boot に任せる（boot は `DB.connected?` でなければ自分のプールを繋ぐ）。users テーブルがまだ無い（未マイグレーション）ときの `Cybertrain::DB::Error` は黙って飛ばす（`./<app> migrate` が先で、そのときは `/setup` 自体がまだ動かない）。rescue / ensure は yield しない普通のメソッドに置く（規則 32 / 45）、rescue 節は完全名で書く（規則 70）。警告は起動バナーより前に出る。
  - **コマンドのファイルを `app/commands/` に置く。** `bin/<app>.rb` に直接書くと、テスト（`bin/` を読まない）からコマンドを呼べない。`spin run gen` は `app/models` と `app/controllers` しか読まないので、`app/commands/` は gen/app.rb に入らず、bin とテストがそれぞれ require する。
- 却下した案:
  - 既定を招待制にする: 既存の手順（CI、README のウォークスルー）と、公開登録が正しいアプリを壊す。フラグで選ぶ。
  - `/setup` をトークン付き URL にする（起動ログにワンタイムトークンを出す）: ログを読める人は普通サーバに入れるので、ループバック限定と比べて得るものが少なく、トークンの保存と失効を生成コードに足すことになる。
  - パスワードを環境変数から読む: プロセスの環境は `/proc/<pid>/environ` で同じユーザーから読め、シェル履歴にも残りやすい。標準入力か、承知の上での引数にした。
  - `/setup` の作成の競合（ユーザーがいない間の同時 POST）を排他する: ループバック限定でオペレータ自身しか届かず、同じアドレスは一意インデックスが拒む。トランザクションで囲む複雑さに見合わない。
- 帰結: `test/cli_authentication.rb` に招待制の生成物・挿入・再実行・拒否のケースを足した。生成したアプリを `cybertrain new` → `generate authentication --invite-only` → `db migrate` → `spin test test/authentication.rb` でコンパイルして走らせ、`cybertrain build` した本番バイナリで警告、標準入力からの作成、`/setup` のループバック判定と X-Forwarded-For での 404 を確かめた（CI にも同じ手順を足した）。

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
- `namespace` / format / `respond_to`、`has_many :through`、`includes`、`transaction` API、i18n、メーラー、ジョブ、WebSocket（認証は 2026-10-22 に D15 の形で入った: ジェネレータが書くコードと、`Cybertrain::Password`）（ジョブは 2026-10-25 に D28 の最小の形で入った）
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
