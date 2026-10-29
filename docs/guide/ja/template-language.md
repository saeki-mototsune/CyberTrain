---
source_sha256: cd5c852e558335bf66577245c96a3ff581c1ffe95980c14b930f78243312e4dc
---
# Cybertrain テンプレート言語リファレンス

Cybertrain のビュー（`app/views/**/*.html.erb`）は Rails の ERB のように見えますが、Ruby ではありません：実行時に読み込まれ（開発環境とテスト環境ではディスク上の `app/views/` から、本番用のバイナリでは `cybertrain build` が `gen/views.rb` 経由で埋め込む文字列テーブルから）、トークンに分割されて AST にパースされ、一度だけフラットなノードツリーにコンパイルされ、木を辿るインタープリターによって実行されます。このパイプラインは `cybertrain/template/` にあります：

| ファイル | 役割 |
| --- | --- |
| `lexer.rb` | ソースを `<% %>`/`<%= %>`/`<%== %>`/`<%# %>` のタグとプレーンテキストに分割する |
| `parser.rb` | `TreeBuilder` がタグを AST にネストさせ、`ExprParser` が 1 つのタグの中の式の文法をパースする |
| `ast.rb` | パーサーが生成する AST ノードのクラス |
| `inode.rb` | `Compile` が AST を、高速に解釈できるよう単相の `INode`（整数の「種類」と型付きのスロット）に平坦化する |
| `interpreter.rb` | `env`（`Hash<String, value>`）に対して `INode` を辿る。型ごとの「どのメソッドがあるか」のテーブルはすべてここにある |
| `helpers.rb` | `link_to`、`form_with`、`render`、`pluralize` など — テンプレートがレシーバーなしで呼ぶものすべて |
| `form_builder.rb` | `form_with(...) do \|f\| ... end` が渡す `f` |
| `engine.rb` | `.html.erb` のソースを読み込み — ルート以下のディスクから、または埋め込まれた `gen/views.rb` のテーブル（`Engine.embedded`）から — パースし（必要ならキャッシュし）、レイアウト付きでレンダリングする |

この文書は、このパイプラインが何を受け付け、何を実行するかを正確に説明します。`docs/design.md` の 7 節（当初の仕様の草案）や Rails の開発者が期待するものと食い違う場合はコードが正しく、この文書はその旨を記しています（「**As built**」（実装の実態）で検索してください）。

## 1. ここで Ruby であるもの、そうでないもの

テンプレートは Ruby **ではありません**。Spinel（cybertrain が対象とする、Matz の Ruby の AOT コンパイラ）には `eval` がないので、「リクエスト時にビュー自身の Ruby を解釈する」ことは最初から選択肢にありませんでした（`docs/design.md` の D9）。代わりに動くのは、ERB や Ruby のような見た目の構文をまとっただけの、小さな閉じた文法です。タグの中に任意の Ruby を書くことはできません — 書けるのは、`ExprParser`（`parser.rb`）が文または式として認識するものだけです。`eval`、`send`、`instance_eval`、メソッド・クラス・モジュールの定義、`require`、例外（`begin/rescue`）、`case/when`、範囲、正規表現、多重代入はありません。ブロックは `each`、`each_with_index`、ヘルパーの呼び出し（`form_with(...) do |f| ... end`）だけです — `{ }` のブロックも、`map`/`select` などのブロックを取る Enumerable のメソッドもありません。すべてのメソッド呼び出し（`recv.name`）は、`interpreter.rb` に手書きされた `case` のディスパッチテーブルで、レシーバーの実行時の Ruby のクラスをキーにして解決されます。その型のテーブルにない名前は `RuntimeError` で失敗します — `method_missing` もリフレクションもなく、（`Interpreter#call_method` にあるとおり）これがメタプログラミングによる検索ではなく `case` になっているのは、まさに Spinel に `send` がないためです。テンプレートにできるのは、この文書に書かれていることだけです。

## 2. タグ

| タグ | 意味 |
| --- | --- |
| `<% code %>` | 文を実行する。何も出力しない |
| `<%= expr %>` | `expr` を評価し、HTML エスケープして出力する |
| `<%== expr %>` | `expr` を評価し、エスケープ**せずに**出力する |
| `<%# comment %>` | 無視される（下記の 1 行目の `locals:` の形を除く） |

空白の制御（`Lexer.tokenize`）：

- その行にある**唯一の**ものである `<% %>`/`<%# %>` タグ（両側から改行までの間に空白とタブしかない）は、Rails の ERB のトリムモードのように、自身のインデントと末尾の改行を黙って取り除きます。`<%= %>`/`<%== %>` は、1 行に単独でいても、このように自動でトリムされることは**決して**ありません。
- `<%-` はタグの前の空白とタブを明示的に取り除き、`-%>` はタグの直後の改行を 1 つ取り除きます — どの種類のタグでも同じです。行のその側に空白以外のものがある場合は、どちらも何もしません。
- テキスト中の `<%%` はリテラルの `<%` です。タグの中の `%%>` はリテラルの `%>` で、タグを閉じません。
- `<% # a Ruby-style comment %>`（内容が `#` で始まるコードのタグ）は `<%# %>` と同じく無視されます。同じタグの中で実際のコードの**後に**コメントを書くことはサポートされていません — `<% x = 1 # note %>` は `SyntaxError` です。
- 閉じられていないタグは字句解析の時点で例外を出します：`"posts/show:2: unterminated <% tag"`。

### strict locals のコメント

内容が `locals:` で始まり、**かつファイルの最初のタグで 1 行目にある**コメントタグは、テンプレート（ほとんどの場合パーシャル）が受け付ける唯一のローカル変数を宣言します：

```erb
<%# locals: (post:, comment:) %>
<%= post.title %>
```

- `<%# locals: () %>`（空のリスト）は「このパーシャルはローカル変数を取らない」という意味です。
- 各エントリーは、素の小文字の `name:` でなければなりません（`Lexer.identifier?` は `[a-z_][a-z0-9_]*` だけを受け付けます）。**As built（実装の実態）：** Rails 7.1 と異なり、エントリーにデフォルト値を付けることはできません — Rails 7.1 がサポートするまさにその形 `<%# locals: (post:, comment: nil) %>` は `SyntaxError` になります：`"t:1: bad strict locals entry 'comment: nil' (expected name:)"`。`comment: nil` が `:` で終わっていないためです。宣言したローカル変数は、事実上すべて必須です。形式の壊れた指定（括弧がない）は `"t:1: bad strict locals comment (expected locals: (name:, ...))"` を出します。
- このコメントが**ない**場合、テンプレートはローカル変数のリストを宣言しません：`render` は与えられたローカル変数を検査せずにそのまま渡し、テンプレートは呼び出し元の環境にすでにあるものを何でも読めます（8 節を参照）。
- コメントより前の行に何かがある場合（空行 1 行でも）、それはローカル変数の宣言ではなく、何の効果もない普通のコメントです。

## 3. 式

### リテラル

| リテラル | 構文 | 注記 |
| --- | --- | --- |
| Integer | `1`、`1_000` | アンダースコアを使える。16 進・8 進・2 進・指数はない |
| Float | `2.5`、`12_3.4_5` | `.` の両側に数字が必要。指数形式はない |
| String | `"..."`、`'...'` | ダブルクォートは式展開とエスケープをサポートする。シングルクォートが理解するのは `\'` と `\\` だけ |
| Symbol | `:title` | 識別子の文字だけ — `:"quoted"` も、`:+` のような演算子のシンボルもない |
| `nil` / `true` / `false` | | |
| Array | `[1, "a", :b]`、`[]` | 要素は完全な式 |
| Hash | `{ a: 1, b: "x" }`、`{}` | **シンボル形式のキーのみ**で、キーワード引数と同じ形。`"key" => value` のハッシュロケットはない |

ダブルクォートの文字列は `#{...}`（任意の完全な式で、ネストできる）を展開し、`\n \t \r \0 \e \s`、`\"`、`\\` をサポートします。それ以外のエスケープされた文字はそのまま通ります。`#{}` のない文字列は素のリテラルに、式展開のある文字列はリテラルの断片と式の列にコンパイルされます。

### 変数

- **`@ivar`** は `env["ivar"]` を直接読みます — `@` は表面上の構文にすぎません。D9 にあるとおり、ひとつの環境の Hash の中で「post は `@post` でもあり、ローカル変数 `post` でもある」のです。存在しないインスタンス変数は単に `nil` です：`[<%= @missing %>]` は `[]` をレンダリングし、決してエラーになりません。
- **素のローカル変数名**（`post`、`title`）も `env["name"]` を読みますが、キーが**まったく**存在しない場合、インタープリターは代わりに引数なしのヘルパー呼び出しとして扱います。キーが存在する場合は（たとえば、渡されなかったが宣言された strict local のように `nil` に束縛されていても）、ヘルパーにフォールバックせずにその値を返します。これが、`<%= csrf_meta_tags %>` と `<%= flash %>` が括弧なしで動き、`<%= nope %>` が「no such local」のエラーではなく `"undefined helper 'nope'"` で失敗する理由です。
- ローカル変数は、`each`/`each_with_index` のブロックパラメーター、`form_with` のブロックパラメーター、パーシャルの strict locals、そして `<% name = expr %>` から来ます。

### メソッド呼び出し

```erb
recv.method
recv.method(arg1, key: value)
recv&.method             # nil 安全：recv が nil なら引数を評価せず nil に短絡する
method(arg1, key: value) # ヘルパー呼び出し：レシーバーなし
method arg1, key: value  # 同じ呼び出しを括弧なしで（「コマンド」構文）
```

- 括弧なしの（「コマンド」の）引数リストが開かれるのは、式の中の**最も外側の**呼び出しだけです：`link_to "Show", post_path(post)` は動きますが、`link_to "Show", post_path post` は `SyntaxError` です — 内側の呼び出しには自分の括弧が必要です。
- 呼び出し対象と開き括弧 `(` の間に空白は置けません：`link_to("x")` と `link_to "x"` はどちらも動きますが、`link_to ("x")` は `SyntaxError` です。
- `yield` と `yield :key` は常に呼び出しとしてパースされます（8 節を参照）。
- 大文字で始まる素の単語は即座に拒否されます — `"constants are not supported: 'Time'"` — テンプレートは Ruby の定数に到達できません。
- 次の単語は予約されており、専用のメッセージ（`"'x' is not supported in templates"`）で拒否されます：`and or not do end if unless elsif else then while until case when def class module begin rescue return`。

### 演算子と優先順位（低いものから高いものへ）

```
?:            ternary, right-associative on both branches
||
&&
==  !=
<  >  <=  >=
+  -
*  /  %
!  -            (unary, prefix)
.  &.  []       (method call / safe-nav / indexing, left-to-right chaining)
```

`&&`/`||` は、真偽値に変換したものではなく、オペランドそのものを返します（`nothing || title` は `true` ではなく `title` に評価されます）。条件は**真偽性**で判定します：Ruby と同じく、偽になるのは `nil` と `false` だけです — `0`、`""`、空の配列やハッシュは真です（`<% if 0 %>yes<% end %>` は `yes` を出力します）。

インデックスは `target[index]` で、`[` の前に**空白を置きません**（`items [0]` は構文エラーで、`items[0]` はそうではありません）。他の後置のものと同じように連鎖できます：`h["k"].first`、`params[:id]`。

## 4. 文

`<% %>` タグはちょうど 1 つの文を保持します：代入、または副作用のために評価される式（値は捨てられます）です。`<%= %>`/`<%== %>` が保持するのは常に式だけです — `<%= x = 1 %>` は `SyntaxError` です。

### 条件分岐

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` は Ruby の規則に従います。`else` の後の `elsif`、迷子の `else`/`elsif`/`end`、`end` で閉じられないブロックは、どれも開始行を示す `SyntaxError` です。

### ループ

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` が認識されるのは、ブロックの先頭の接尾辞（`x.each do |...|`）としてだけです。**As built（実装の実態）では**、どちらもブロックパラメーターを 1 つか 2 つ宣言する必要があります — 素の Ruby ではゼロでもかまいませんが、`xs.each do end` は `SyntaxError`（「takes one or two block parameters」）です。
- Array とパラメーター 1 つ：要素。Array とパラメーター 2 つ：`Array` の要素は分解され（`a, b = item[0], item[1]`）、そうでなければ 2 つ目は `nil` です。
- Array に対する `each_with_index`：`item, i`。Hash に対しては：最初のパラメーターが `[key, value]` のペア、2 つ目がインデックスです。
- Hash に対するパラメーター 2 つの `each`：`key, value` を直接。パラメーター 1 つでは `[key, value]` のペアです。
- `nil`、`Time`、その他のスカラーを反復すると `RuntimeError`（`"undefined method 'each' for Time"`）です — 黙って何もしないことは決してありません。
- ブロックパラメーターが同じ名前の外側のローカル変数を覆い隠すのはループの間だけで、その後は取り除かれます（ループの終了後は `refute env.key?("item")`）。ブロックの前から存在した変数は、ブロックの中でも*同じ*変数です（ループの後にも見えます）。ブロックの**中で初めて代入された**変数はブロックローカルです — 各反復の開始時には `nil` で、その後は消えます。

### ブロック付きの呼び出し（ヘルパー）

`do ... end` は、レシーバーのないヘルパー呼び出しがブロックを受け取る方法でもあります — ブロックの唯一の他の正当な使い方で、レシーバーがない場合に限られます（`f.each do |x| end` は拒否されます：「blocks are only supported on each, each_with_index and helper calls」）：

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

ブロックの結果が出力されるかどうかはタグに従います：`<%= helper do |x| %>` は出力し、`<% helper do |x| %>` は捨てます。束縛されるブロックパラメーターは常にちょうど 1 つです。ヘルパーのブロックがインデックスや 2 つ目の値を受け取ることはありません。

### 代入

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

使えるのは、1 つの素のローカル変数に対する `name = expr` だけです — `@ivar = ...` も、`arr[0] = ...`/`h[:k] = ...` も、`a, b = ...` もありません。`each` と同じブロックローカルの規則が、ブロック内にネストした `if`/`unless` の中の代入にも適用されます。

## 5. 型ごとのメソッドテーブル

`nil?`、`present?`、`blank?` は型ごとのディスパッチの**前に**確認されるので、モデルやヘルパーが返したオブジェクトも含めて、どの値に対しても使えます（`blank?` は、`nil`/`false`/空の `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params` 以外では `false` です）。算術（`+ - * / %`）と比較（`== != < > <= >=`）は**中置演算子**としてだけ存在し、決して `.method` の呼び出しにはなりません — この文法では、演算子の記号が `.` の後に来ることはありえません。

| 型 | メソッド | 例 |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values`、および `h[key]` | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`、および `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`、および `params[key]` | `params[:id]` |
| `Page`（`Relation#page`） | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s`（`""` を返す） | |

インデックス（`x[key]`）は `.[]` の呼び出しではなく、独立した文法の規則です（3 節）：`Array`/`String` は整数のインデックスを取り、`Hash` は任意のキーをその `to_s` で照合し（`h[:k]` と `h["k"]` は同じエントリー）、`Errors` はシンボルで、`Params` は `to_s` で照合します。

上の `to_s` 以外の出力（`<%= %>` や式展開）：`Array` は inspect のようなリストとして出力されます — `[1, "a", nil]` はテキスト `[1, "a", nil]` をレンダリングします（その後エスケープされるので、引用符は `&quot;` になります）。`Hash` は Ruby 自身の `Hash#to_s` にフォールバックします。`Cybertrain::Model` は `#<Post id: 7>` と出力されます（属性は決して出力されません）。それ以外は自身の `to_s` で出力されます。上記のどの型でも、一覧にないメソッドは `RuntimeError`（`"undefined method 'first' for Time"`）です。`Integer` のゼロによる除算・剰余は `"divided by 0"` です。`Float` は代わりに IEEE-754 に従います（`Infinity`/`NaN` で、エラーにはなりません）。

## 6. テンプレート内のモデル

`Cybertrain::Model` のサブクラス（生成された `Post`、`Note` など）は、素の名前を次の順序で解決します（`Interpreter#model_method`）：

1. 常に使える 5 つの組み込み：`id`、`persisted?`、`new_record?`、`to_param`（`id.to_s`）、`errors`（`Errors`。5 節）。
2. `read_attribute(:name)` — 生成されたカラム。
3. `read_association(:name)` — 生成された `has_many`/`belongs_to`。
4. `call_view_method(:name)` — モデルのジェネレーターが `app/models/**/*.rb` で見つけた、手書きの引数なしの `def`（引数を取ることは決してありません）。

```erb
<%= post.title %>            <%# read_attribute %>
<% post.comments.each do |c| %>...<% end %>   <%# read_association %>
<%= post.summary %>          <%# call_view_method %>
<%= post.errors.full_messages.join(", ") %>
```

4 つすべてが `nil` を返した場合は、`attribute_or_method?(:name)` が、それがたまたま `nil` を保持している正当な名前なのか（`nil` を返す）、タイプミスなのか（`"undefined method 'bogus' for Post"`）を判断します。

**As built（実装の実態）として、インタープリターのファイル自身が指摘している本当の欠落**（`interpreter.rb` の `class Model` の上にある `TODO(integrator)` のコメントを参照）：*基底の* `Cybertrain::Model#attribute_or_method?` は常に `true` を返します。タイプミスで実際に例外を出すのは、明示的な `case` でこれをオーバーライドした生成モデル（手書きのテスト用モデルがそうしているように）だけです。そのオーバーライドがないと、綴りを間違えた属性やメソッドは、失敗せずに黙って空としてレンダリングされます。モデルがこのフックをオーバーライドしているとわかっていない限り、タイプミスが捕まると思わないでください。

2 つのモデルは、クラスと `id` によって `==` で比較されます（`Model#==`）。これは普通の `==` 演算子として使えます（`call_method` ではなく、ネイティブの等価性のディスパッチです）。

## 7. ヘルパーとフォームビルダー

レシーバーのない呼び出しはすべて `Helpers#helper_call`（`helpers.rb`）に行きます。これは以下の組み込みのいずれかに一致させるか、`_path`/`_url` で終わる名前を生成されたルートヘルパーとして扱うか（`Cybertrain::Views.url_resolver` 経由。アプリがリゾルバーを設定するまでは `"no routes"` を出します）、`"undefined helper 'name'"` を出します。

| ヘルパー | シグネチャ | 注記と例 |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` はすでに `SafeString` でなければエスケープされる。**`method:` はない** — 例外を出し、`button_to` を使うよう伝える（rails-ujs/turbo による DELETE リンクの偽装はない） |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | ボタン 1 つの `<form class="button_to">`。`get`/`post` 以外のメソッドには hidden の `_method`、セッションがあれば CSRF のフィールドも付く |
| `form_with` | `form_with(model:, url:, method:, class:, multipart:) do \|f\| ... end` | ブロックが必要。`model:` が新規 → コレクションのルートと POST、保存済み → メンバーのルートと PATCH。ネストしたルートには `[parent, child]`。`url:`/`method:` は導かれたアクションやメソッドを上書きする。`multipart: true` は `enctype="multipart/form-data"` を追加する（`f.file_field` に必須。ブロックから推測されることはなく、GET のフォームでは `ArgumentError` を出す） |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` | 8 節を参照 |
| `h`、`escape` | `h(text)` | エスケープする。`SafeString` はエスケープされずにそのまま通る |
| `raw` | `raw(text)` | テキストを `SafeString` で包む（エスケープせずに出力される） |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`、`pluralize(2, "mouse")` → `"2 mice"`（`Cybertrain::Inflector` による Rails のデフォルトの英語の語形変化。アプリが定義する語形変化はサポートされない）。明示的な 3 つ目の引数が常に優先される |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n)` | `1234567` → `"1,234,567"`、`-1000` → `"-1,000"`、`1234.5` → `"1,234.5"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails 風の区分で、秒単位の精度はない：`"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`、`content_for(:key, "text")`、`content_for?(:key)` | 8 節を参照 |
| `csrf_meta_tags` / `csrf_token` | | コントローラーのセッションがなければ空 / なし |
| `flash` | | `Hash` のようなもの：`flash[:notice]` |
| `params` | | 現在の `Cybertrain::Params` |
| `request_path` | | 現在のパス。コントローラーがなければ `""` |
| `url_for` | `url_for(target)` | `String` はそのまま、`Model` → メンバーのルート、`[parent, child]` → ネストしたルート |
| `paginate` | `paginate(page, path)` | `page` は `Cybertrain::Page`（`Relation#page` から）。`<nav class="pager">` をレンダリングし、「Newer」（`rel="prev"`）、`<span class="pager-current">Page N</span>`、「Older」（`rel="next"`）を含める。該当するページがなければリンクは省かれる。各リンクは `path` に、`page` を置き換えた（1 ページ目では取り除いた）現在のリクエストのクエリ文字列を付けたもので、再エンコードされ HTML エスケープされる。独自の `?query` を持つ `path` では代わりにそれを使う。`Page` はテンプレートの中で `number`、`per`、`row_offset`、`next?`、`prev?`、`next_number`、`prev_number` にも応える（`<% if @page.next? %>`） |
| `*_path` / `*_url` | 例：`post_path(post)` | アプリが生成し、`Cybertrain::Views.url_resolver` 経由で解決される |

ヘルパーのテキスト引数はすべて 1 つの規則に従います：`SafeString` はエスケープされずにそのまま通り、それ以外はエスケープされます — `link_to raw('<b>raw</b>'), post` は太字のタグを文字どおりに出力しますが、`link_to post.title, post` はエスケープします。

### FormBuilder（`form_with ... do |f|` の `f`）

どのメソッドも `SafeString` を返します。一覧にないメソッドは `RuntimeError`（`"undefined method 'color_wheel' for FormBuilder"`）です。

| メソッド | レンダリング結果 |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — デフォルトのテキストは属性を人間向けにしたもの（`published_at` → 「Published at」、`author_id` → 「Author」）。明示的なテキストは `SafeString` でなければエスケープされる |
| `f.text_field :title`（`email_field`、`password_field`、`number_field`、`date_field`、`hidden_field` も） | `<input type="..." name="post[title]" id="post_title" value="...">`。`password_field` は決して `value=` を出力しない |
| `f.file_field :cover`（`accept: "image/*"`、`required: true` も） | `<input type="file" name="post[cover]" id="post_cover">` — `value=` は決して付かず、属性はカラムでなくてもよい。フォームは `form_with ..., multipart: true` でなければならない。`multiple: true` は `ArgumentError` を出す（フィールドごとにファイル 1 つ） |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>`（Rails と同じく先頭に `\n` — ブラウザーは最初の改行を食べる） |
| `f.check_box :published` | hidden の `value="0"` の input の後に本物のチェックボックスが続くので、チェックしていないボックスも `"0"` を送信する |
| `f.submit` / `f.submit "Text"` | デフォルトのテキストは（`persisted?` によって）`"Create Post"`/`"Update Post"`、モデルがなければ `"Save changes"` |

モデルがある場合、フィールドの名前は `post[title]`/`id="post_title"` になります（スコープは `Inflector.underscore(model.model_name)`）。モデルなしの `form_with(url: ...)` では、どちらにも素の属性名が使われます。追加のキーワード引数は、与えた順に HTML の属性になります：`true` → `attr="attr"`、`false`/`nil` は捨てられ、それ以外は → `attr="value"`（エスケープされます）。アンダースコアはハイフンになり（`data_confirm: "Sure?"` → `data-confirm="Sure?"`）、`class:` は、`model.errors.key?(attr)` のときに自動で付く `field_with_errors` クラスと合わせられます。

## 8. レイアウト、`yield`、`content_for`、パーシャル

`Engine#render_with_layout(name, layout, env, helpers)` は `name` を `env["__content"]`（`SafeString`）にレンダリングし、その後、同じ `env` に対して `layout` をレンダリングします：

```erb
<title><%= yield :title %></title>
<%= yield %>
```

`yield` は `env["__content"]` を出力し、`yield :key` は `env["__content_key"]` を出力します。設定されていなければ何も出力しません。`yield` はインタープリターの中で直接特別扱いされており、ヘルパーとして上書きすることはできません。ページは本文のどこででも `content_for` でスロットを埋めます（`yield` との前後関係は問題になりません — ページはレイアウトより前に完全にレンダリングされます）：

```erb
<% content_for :title do %>Post: <%= @post.title %><% end %>
<% content_for :title, " (draft)" %>   <%# appends: calls accumulate, they don't replace %>
```

### パーシャルと `render`

```erb
<%= render "form", post: @post %>
<%= render partial: "form", locals: { post: @post } %>
<%= render "comments/comment", comment: c %>
```

- `/` を含まない素の名前は、**現在のテンプレート自身のディレクトリ**で解決されます（レンダリングの仕組みが設定する環境のキー `__template_dir` によって）：`posts/show` からの `render "form"` は `posts/_form.html.erb` を探します。`/` を含む名前は明示的なパスで、最後のセグメントにだけ `_` の接頭辞が付きます（`"comments/comment"` → `comments/_comment.html.erb`）。
- パーシャルは、**呼び出し元の環境全体の複製**（インスタンス変数と、すでにスコープにあるローカル変数）に加えて、`render` に与えた明示的なローカル変数を受け取ります — 渡されたものだけに隔離されるわけではありません。strict locals が宣言されたリストに対して検査するのは、**その `render` の呼び出しに明示的に与えた**名前だけです。パーシャルが呼び出し元の環境から受け継いだ別の名前を読むことは止めません。
- パーシャルのスコープから呼び出し元のスコープに書き戻されるのは、`content_for` のキー（`__content_*`）だけです。パーシャルが代入した普通のローカル変数は外に漏れません。
- `<%# locals: %>` の宣言に対してローカル変数が足りない・余分な場合は `RuntimeError` です：`"missing local 'post' for posts/_form.html.erb"`、`"unknown local 'extra' for posts/_form.html.erb"`。

### ファイルの解決（`engine.rb`）

`"posts/show"` と `"posts/show.html.erb"` は同じテンプレートを指します。開発環境は `cache: false` で `app/views/` をディスクから読みます（mtime かサイズが変わるたびに、ファイルを読み直して再パースします）。テスト環境は `cache: true` でディスクから読みます（一度だけパースします）。本番用のバイナリは決してディスクに触れません：`cybertrain build` は `spin run gen -- --embed-views` を実行し、`app/views/` 以下のすべての `*.erb`（ドットファイルとシンボリックリンクのディレクトリはスキップ）を `gen/views.rb` に書き込みます。`Engine.embedded(sources)` は各エントリーを一度だけパースします（エラーメッセージは同じ `posts/show.html.erb:12` の形を保ちます）。テーブルが空のバイナリは、本番環境での起動を拒否します。存在しないテンプレートは `Cybertrain::Template::MissingTemplate` を出します — ディスクからなら `"Missing template <full path>"`、テーブルからなら `"Missing template posts/nope.html.erb (embedded)"` です。

ファイルの検索は、ビューのルートとテンプレートのパスをシンボリックリンクを辿って解決し、そのルートの中にある通常のファイルだけを読み込みます。ルートの外に出るパスは（シンボリックリンクを通じたものも含めて）`MissingTemplate` を出し、そうしたパスに対して `exists?` は false を返します。

## 9. エラー

例外クラスは 2 つで、どちらも `ast.rb` の `Cybertrain::Template` 名前空間にあります（`::SyntaxError`/`::RuntimeError` とは別のものです）：

- **`SyntaxError`** — トークン分割やパースの最中、解釈が始まる前に出ます。形：`"<template>:<line>: <what>"`。例えば `"posts/show:2: 'if' without 'end'"`、`"posts/show:1: unterminated <% tag"`、`"posts/show:1: unexpected ')' in 'foo(1))'"`。ページやレイアウトのファイルがパースに失敗したとき、`Engine#template`（したがって `#render`/`#render_with_layout`）から直接出され、インタープリターに捕まえられたり包み直されたりすることは決してありません。
- **`RuntimeError`** — 評価の最中に出ます。メッセージの形は同じですが、`<template>` は*そのときレンダリング中の*テンプレートです（`Interpreter#render` が `@name` を入れ替えます）— パーシャル自身のエラーは、呼び出し元ではなくパーシャルの名前と行を保ちます：`"posts/_row:1: undefined method 'bogus' for String"`。

ヘルパーや `FormBuilder`・独自オブジェクトのメソッド呼び出しから出た素の `StandardError`（素の `raise "text"`、`ArgumentError`、`KeyError`、さらにはネストした `render` からの `Cybertrain::Template::RuntimeError`）は捕まえられて「再配置」されます：`"<current template>:<current line>: <original message>"` に書き換えられます。ただし、それがすでに最後に再配置したメッセージとまったく同じ場合（ネストした `render` がすでに、より具体的な自分の位置を付けている場合）は、変更されずにそのまま通ります。ヘルパーが出した `Cybertrain::Template::SyntaxError`（レンダリング中にパースに失敗したパーシャル）は決して包み直されません — 自身の `"<partial>:<line>: ..."` のメッセージとクラスを保つので、壊れたパーシャルは常に、それをレンダリングした側についての `RuntimeError` ではなく、自分自身についての `SyntaxError` として報告されます。

`MissingTemplate`（`StandardError`、`engine.rb`）は、トップレベルの `Engine#template`/`#render`/`#render_with_layout` の呼び出し（例えば、存在しないアクションのテンプレートやレイアウトをレンダリングするコントローラー）からは、**包まれずに**、`template:line` の接頭辞なしで出されます：`"Missing template <path>"`。同じ例外でも、`render` ヘルパーのパーシャル検索によってテンプレートの*中で*出されたものは、代わりに再配置を経て `RuntimeError` として出てきます：`"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`。

## 10. Rails の ERB との違い

| Rails の ERB | Cybertrain |
| --- | --- |
| Ruby のメソッドにコンパイルされる。どんな Ruby でも、どんなオブジェクトでも、どんなメソッドでも動く | 型ごとに固定されたディスパッチテーブルに対して解釈される。呼び出せるのは 5 節に挙げたものだけ |
| `ActiveSupport::SafeBuffer` は `String` のサブクラス | `SafeString` は独立したラッパークラス — 呼び出せるのは `to_s`/`html_safe?`/`size`/`length`/`empty?` だけ |
| ブロック：`each`、`{ }`、`map`、任意の Enumerable のメソッド | `do...end` だけで、`each`/`each_with_index`/ヘルパー呼び出しに対してだけ |
| `xs.each { }` — ブロックパラメーターがゼロでもかまわない | `each`/`each_with_index` はブロックパラメーターを 1 つか 2 つ宣言する必要がある |
| `link_to text, path, method: :delete`（JS 駆動） | `link_to` に `method:` はない — GET 以外の本物のフォームには `button_to` を使う |
| strict locals は `name: default_expr` を受け付ける（Rails 7.1） | 素の `name:`（必須）だけ。デフォルト値付きのエントリーは `SyntaxError` |
| 未定義のインスタンス変数やローカル変数は Ruby やビューコンテキストのメソッドで解決される | `@x` は決して失敗しない単純な環境の参照。未定義の素のローカル変数は、明示的で閉じたヘルパー呼び出しの試み（一致しなければ `"undefined helper"`） |
| `and`/`or`/`not`、`case/when`、範囲、正規表現、多重代入がすべて動く | どれも存在しない。予約語は、一般的なパースエラーではなく、「not supported in templates」という専用のメッセージで失敗する |
| 数値リテラル：16 進、8 進、2 進、指数、有理数 | `_` の区切りを使える 10 進の整数と浮動小数点数だけ |
| `:"quoted symbol"`、`:+` の演算子シンボル | シンボルは識別子の文字だけ |
| `foo (x)`、`foo [x]`（空白は許容され、警告が出ることもある） | どちらも厳格な `SyntaxError` — 呼び出しの `(` やインデックスの `[` の前に空白は置けない |
| ネストした括弧なしの呼び出しは Ruby 自身のパーサーが解決する | 括弧なしの引数を取れるのは、式の中の最も外側の呼び出しだけ |
| 宣言されていない・綴りを間違えた属性は確実に `NoMethodError` を出す | 特定の生成モデルが `attribute_or_method?` をオーバーライドしていない限り、黙って空としてレンダリングされる（記録されている欠落で、保証ではない） |
| `1 / 0` と `1.0 / 0` はどちらも `ZeroDivisionError` を出す | `Integer` のゼロによる除算・剰余は `"divided by 0"` を出す。`Float` は IEEE-754 に従い（`Infinity`/`NaN`）、エラーにならない |
| `distance_of_time_in_words` や複数形化は i18n のロケールをサポートする | 英語のみで、ロケールのサポートはない |
