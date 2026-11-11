---
source_sha256: 313dd71eafa349732eb608c4c2d8645cd2c64b746099702e52e4efec991a4e79
---
# Cybertrain テンプレート言語リファレンス

Cybertrain のビュー（`app/views/**/*.html.erb`）は Rails の ERB のように見えますが、Ruby ではありません：実行時に読み込まれ（開発環境とテスト環境ではディスク上の `app/views/` から、本番用のバイナリでは `cybertrain build` が `gen/views.rb` 経由で埋め込む文字列テーブルから）、トークンに分割されて AST にパースされ、一度だけフラットなノードツリーにコンパイルされ、木を辿るインタープリターによって実行されます。

この文書は、このパイプラインが何を受け付け、何を実行するかを正確に説明します。`docs/design.md` の 7 節（当初の仕様の草案）や Rails の開発者が期待するものと食い違う場合はコードが正しく、この文書はその旨を記しています（「**As built**」（実装の実態）で検索してください）。

## ここで Ruby であるもの、そうでないもの

テンプレートは Ruby **ではありません**。Spinel（cybertrain が対象とする、Matz の Ruby の AOT コンパイラ）には `eval` がないので、「リクエスト時にビュー自身の Ruby を解釈する」ことは最初から選択肢にありませんでした（`docs/design.md` の D9）。代わりに動くのは、ERB や Ruby のような見た目の構文をまとっただけの、小さな閉じた文法です。タグの中に任意の Ruby を書くことはできません — 書けるのは、`ExprParser`（`parser.rb`）が文または式として認識するものだけです。`eval`、`send`、`instance_eval`、メソッド・クラス・モジュールの定義、`require`、例外（`begin/rescue`）、範囲、正規表現、多重代入はありません。ブロックがあるのは、この文書が挙げる場所だけです：`each`/`each_with_index`/`each_slice` のループ、Array と Hash の決まったメソッド（`map`、`select`、`sum`、`group_by` など — [ブロック](#blocks)を参照）、ヘルパーの呼び出し（`form_with(...) do |f| ... end`）、そして `tag` ビルダーです。すべてのメソッド呼び出し（`recv.name`）は、`interpreter.rb` に手書きされた `case` のディスパッチテーブルで、レシーバーの実行時の Ruby のクラスをキーにして解決されます。その型のテーブルにない名前は `RuntimeError` で失敗します — `method_missing` もリフレクションもなく、（`Interpreter#call_method` にあるとおり）これがメタプログラミングによる検索ではなく `case` になっているのは、まさに Spinel に `send` がないためです。テンプレートにできるのは、この文書に書かれていることだけです。

<details><summary>ソースのどこにあるか — テンプレートのパイプラインを成す 8 つのファイル</summary>

このパイプラインは `cybertrain/template/` にあります：

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

</details>

## タグ

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
- このコメントが**ない**場合、テンプレートはローカル変数のリストを宣言しません：`render` は与えられたローカル変数を検査せずにそのまま渡し、テンプレートは呼び出し元の環境にすでにあるものを何でも読めます（[レイアウト、`yield`、`content_for`、パーシャル](#layouts-yield-content_for-partials)を参照）。
- コメントより前の行に何かがある場合（空行 1 行でも）、それはローカル変数の宣言ではなく、何の効果もない普通のコメントです。

## 式

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
- `yield` と `yield :key` は常に呼び出しとしてパースされます（[レイアウト、`yield`、`content_for`、パーシャル](#layouts-yield-content_for-partials)を参照）。
- 大文字で始まる素の単語は即座に拒否されます — `"constants are not supported: 'Time'"` — テンプレートは Ruby の定数に到達できません。
- 次の単語は予約されており、式が来るべき場所ではどこでも専用のメッセージ（`"'x' is not supported in templates"`）で拒否されます：`and or not do end if unless elsif else then while until def class module begin rescue return`。`case` と `when` はそれ自体が文です（[`case`](#case)）。式の中（`<%= case x %>`）では同じように拒否されます。

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

## 文

`<% %>` タグはちょうど 1 つの文を保持します：代入、または副作用のために評価される式（値は捨てられます）です。`<%= %>`/`<%== %>` が保持するのは常に式だけです — `<%= x = 1 %>` は `SyntaxError` です。

### 条件分岐

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` は Ruby の規則に従います。`else` の後の `elsif`、迷子の `else`/`elsif`/`end`、`end` で閉じられないブロックは、どれも開始行を示す `SyntaxError` です。

### `case`

```erb
<% case @article.status %>
  <% when :draft, :review %>
  <span class="badge">unpublished</span>
  <% when :published %>
  <span class="badge">live</span>
  <% else %>
  <span class="badge">?</span>
<% end %>
```

- 対象は 1 回だけ評価されます。各 `when` の値（1 つ以上、カンマ区切り）は、順にテンプレートの `==` で比較され、等しい値を持つ最初の分岐が実行されます。数値は値で比較されます（`1` は `1.0` に一致します）。String と Symbol は値と型で比較されます（`"a"` は `:a` に一致しません）。レコードは `==` と同じく（クラスと `id`）、Array と Hash も `==` と同じく（値で、要素ごとに）比較されます。同じテキストの `SafeString` と `String` は等しくなります。`===` はありません：`when` の後に範囲、クラス、正規表現は書けません。
- `else` は、どの値も一致しなかったときに実行されます。`else` がなく一致もしなければ、何も出力されません。
- `case` と最初の `when` の間に置けるのは空白のテキスト（インデント、改行）だけで、それは捨てられます。それ以外のものがあると `SyntaxError`（`"text between 'case' and its first 'when'"`）です。
- `case` の外の `when`（`"'when' without 'case'"`）、対象や `when` のない `case`、値のない `when` や `else` の後の `when`、`end` で閉じられない `case` は、行を示す `SyntaxError` です。`then` は予約されたままです：`<% when :a then x %>` は `SyntaxError` です。
- 分岐の中で初めて代入されたローカル変数は、`if` と同じく、それを囲むブロックのブロックローカルの規則に従います。

### ループ

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` が認識されるのは、ブロックの先頭の接尾辞（`x.each do |...|`）としてだけです。コレクションは任意の式でよく、ブロックを取る呼び出しも含まれます（`<% items.group_by { |i| i.kind }.each do |kind, list| %>`）。**As built（実装の実態）では**、どちらもブロックパラメーターを 1 つか 2 つ宣言する必要があります — 素の Ruby ではゼロでもかまいませんが、`xs.each do end` は `SyntaxError`（「takes one or two block parameters」）です。
- `<% x.each_slice(n) do |slice| %>...<% end %>` は `n` 個ずつの区切り（最後は短いこともあります）を順にたどり、これもパラメーターを 1 つか 2 つ必要とします。2 つなら区切りは分解され（`do |a, b|`）、区切りが短いときは 2 つ目が `nil` になります。
- Array とパラメーター 1 つ：要素。Array とパラメーター 2 つ：`Array` の要素は分解され（`a, b = item[0], item[1]`）、そうでなければ 2 つ目は `nil` です。
- Array に対する `each_with_index`：`item, i`。Hash に対しては：最初のパラメーターが `[key, value]` のペア、2 つ目がインデックスです。
- Hash に対するパラメーター 2 つの `each`：`key, value` を直接。パラメーター 1 つでは `[key, value]` のペアです。
- `nil`、`Time`、その他のスカラーを反復すると `RuntimeError`（`"undefined method 'each' for Time"`）です — 黙って何もしないことは決してありません。
- ブロックパラメーターが同じ名前の外側のローカル変数を覆い隠すのはループの間だけで、その後は取り除かれます（ループの終了後は `refute env.key?("item")`）。ブロックの前から存在した変数は、ブロックの中でも*同じ*変数です（ループの後にも見えます）。ブロックの**中で初めて代入された**変数はブロックローカルです — 各反復の開始時には `nil` で、その後は消えます。

### ブロック付きの呼び出し（ヘルパー）

`do ... end` は、レシーバーのないヘルパー呼び出しがブロックを受け取る方法でもあります（レシーバーのある呼び出しについては[ブロック](#blocks)を参照）：

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

ブロックの結果が出力されるかどうかはタグに従います：`<%= helper do |x| %>` は出力し、`<% helper do |x| %>` は捨てます。束縛されるブロックパラメーターは常にちょうど 1 つです。ヘルパーのブロックがインデックスや 2 つ目の値を受け取ることはありません。

### ブロック

レシーバーのある呼び出しは、パラメーターが 0〜2 個のブロック `{ |x| expr }` または `do |x| ... end` を取れます。どのメソッドがブロックを受け付けるかは型ごとに決まっています。それ以外の場所のブロックは、呼び出しの実行時に出る `SyntaxError`（`"String#upcase takes no block"`）で、型にないメソッドは、ブロックの有無にかかわらず、いつもの `"undefined method 'x' for Array"` です。

| レシーバー | ブロックを取るメソッド | ブロックの値の使われ方 |
| --- | --- | --- |
| `Array` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | 変換後の値、判定、加える値、並べ替えのキー、グループのキー |
| `Hash` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | 同じで、ブロックには `\|key, value\|` が渡されます（パラメーターが 1 つなら `[key, value]` の組）。`select`/`reject` は Hash を返し、ほかは組に対して Array のメソッドが返すものを返します |
| `tag` ビルダー | すべての要素（`tag.div do ... end`） | その**出力**が要素の内容になります（[tag ビルダー](#the-tag-builder)） |

```erb
<%= @items.map { |i| i.name }.join(", ") %>
<%= @line_items.sum { |li| li.price } %>
<% @items.group_by { |i| i.kind }.each do |kind, list| %>
  <h2><%= kind %></h2> <%= list.size %>
<% end %>
<% total = @line_items.sum do |li| %>
  <% li.price * li.quantity %>
<% end %>
```

- **出力ではなく値。** Array と Hash のメソッドでは、ブロックの*値*が意味を持ちます：`{ }` のブロックなら式、`do` のブロックなら最後の文で、これは式の文（`<% x * 2 %>`）でなければなりません。そうでなければ（代入やテキスト）`"map's block must end in a value"` です。`do` のブロックの手前の文が出力したものは捨てられます。そうしたメソッドの `do` のブロックは、代入する（`<% total = items.sum do |li| %>`）か出力する（`<%= items.map do |x| %>`）形で、それだけのタグに置きます。
- **変更はできない。** テンプレートには累積値を変える手段がないので、`each_with_object` と `inject` は表にありません（`"undefined method 'each_with_object' for Array"`）：`map`、`select`、`sum`、`group_by` を使ってください。
- パラメーターが 2 つなら、`each` と同じく Array の要素を分解します（`pairs.map { |a, b| a }`）。
- 空の Array の `sum` は `0` です。Integer の合計は Integer で、どこかに Float があれば Float になります（Ruby と同じ補正付きで足されるので、`[0.1, 0.2, 0.3].sum` は `0.6` です）。String は拒否され（`"sum: use join for Strings"`）、数値でないものもすべて同様です。
- `sort_by`、`min_by`、`max_by`（とブロックなしの `sort`、`min`、`max`）は `<` と同じように比較します（数値、String、Time。それ以外は `"comparison of String with Integer failed"`）。`sort_by` は安定で、等しいキーは順序を保ちます。空の Array の `min_by`/`max_by` は `nil` です。
- `group_by` は、**String にした**各キー（テンプレートの Hash はすべて String のキーです：`:fruit` と `"fruit"` は 1 つのグループ）から、そのキーを持つ要素への Hash を、最初に現れた順で返します。
- `each`、`each_with_index`、`each_slice` は、ブロックを `<% %>` タグで取ります（[ループ](#loops)）。`items.each { |x| x }` は `SyntaxError` です。
- `FormBuilder` や `Page` のメソッドへのブロックも同じように拒否され（`"FormBuilder#label takes no block"`）、ブロックなしの Array のメソッドは引数を取りません（`nums.sum(10)` は `"wrong number of arguments for 'sum'"`）。
- ブロックが例外を出した場合、エラーが呼び出しから出ていく前に、そのパラメーターとローカル変数は元に戻されます。
- `{ }` のブロックにはレシーバーが必要です：`shout { |x| x }` は `SyntaxError` です（ヘルパー呼び出しは `do ... end` を取ります）。
- ブロックパラメーターは呼び出しの間だけ外側の名前を隠し、その後で元に戻されます。`do` のブロックの中で初めて代入されたローカル変数は、`each` と同じくブロックローカルです。

### 代入

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

使えるのは、1 つの素のローカル変数に対する `name = expr` だけです — `@ivar = ...` も、`arr[0] = ...`/`h[:k] = ...` も、`a, b = ...` もありません。`each` と同じブロックローカルの規則が、ブロック内にネストした `if`/`unless` の中の代入にも適用されます。

## 型ごとのメソッドテーブル

`nil?`、`present?`、`blank?` は型ごとのディスパッチの**前に**確認されるので、モデルやヘルパーが返したオブジェクトも含めて、どの値に対しても使えます（`blank?` は、`nil`/`false`/空の `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params` 以外では `false` です）。算術（`+ - * / %`）と比較（`== != < > <= >=`）は**中置演算子**としてだけ存在し、決して `.method` の呼び出しにはなりません — この文法では、演算子の記号が `.` の後に来ることはありえません。

| 型 | メソッド | 例 |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` `sum` `min` `max` `sort` `uniq` `compact` `flatten` `take(n)` `drop(n)` `each_slice(n)`（Array の Array） `zip(other)`、および[ブロック](#blocks)のブロック付きメソッド | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values` `to_a`（`[key, value]` の組）、および `h[key]` と[ブロック](#blocks)のブロック付きメソッド | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`、および `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`、および `params[key]` | `params[:id]` |
| `Page`（`Relation#page`） | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s`（`""` を返す） | |

インデックス（`x[key]`）は `.[]` の呼び出しではなく、独立した文法の規則です（[式](#expressions)）：`Array`/`String` は整数のインデックスを取り、`Hash` は任意のキーをその `to_s` で照合し（`h[:k]` と `h["k"]` は同じエントリー）、`Errors` はシンボルで、`Params` は `to_s` で照合します。

上の `to_s` 以外の出力（`<%= %>` や式展開）：`Array` は inspect のようなリストとして出力されます — `[1, "a", nil]` はテキスト `[1, "a", nil]` をレンダリングします（その後エスケープされるので、引用符は `&quot;` になります）。`Hash` は Ruby 自身の `Hash#to_s` にフォールバックします。`Cybertrain::Model` は `#<Post id: 7>` と出力されます（属性は決して出力されません）。それ以外は自身の `to_s` で出力されます。上記のどの型でも、一覧にないメソッドは `RuntimeError`（`"undefined method 'first' for Time"`）です。`Integer` のゼロによる除算・剰余は `"divided by 0"` です。`Float` は代わりに IEEE-754 に従います（`Infinity`/`NaN` で、エラーにはなりません）。

## テンプレート内のモデル

`Cybertrain::Model` のサブクラス（生成された `Post`、`Note` など）は、素の名前を次の順序で解決します（`Interpreter#model_method`）：

1. 常に使える 5 つの組み込み：`id`、`persisted?`、`new_record?`、`to_param`（`id.to_s`）、`errors`（`Errors`。[型ごとのメソッドテーブル](#per-type-method-table)）。
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

**生成されたモデルはスキーマからこれに答えます。** `spin run gen` はすべてのモデルに `attribute_or_method?` を、そのカラム（名前を変えたカラムは両方の名前）、関連、公開されたビューメソッドに対する `case` として出力します。そのため、生成されたモデルに対する `<%= post.titel %>` は `"posts/show:3: undefined method 'titel' for Post"` になり、`nil` を保持しているカラムは空としてレンダリングされます。*基底の* `Cybertrain::Model#attribute_or_method?`（`model.rb`）は今も `true` を返します：これをオーバーライドしていない手書きの `Cybertrain::Model` サブクラスは、未知の名前を空としてレンダリングします。アップグレード時の注意：モデルに存在しない名前を読んでいたテンプレートは、これまでは空としてレンダリングされていましたが、次の `spin run gen` 以降は例外を出します（docs/design.md D71）。

2 つのモデルは、クラスと `id` によって `==` で比較されます（`Model#==`）。これは普通の `==` 演算子として使えます（`call_method` ではなく、ネイティブの等価性のディスパッチです）。

## ヘルパーとフォームビルダー

レシーバーのない呼び出しはすべて `Helpers#helper_call`（`helpers.rb`）に行きます。これは以下の組み込みのいずれかに一致させ、[コンポーネント](#components)のテンプレートの中ならそのコンポーネントのビューメソッドを試し、`_path`/`_url` で終わる名前を生成されたルートヘルパーとして扱い（`Cybertrain::Views.url_resolver` 経由。アプリがリゾルバーを設定するまでは `"no routes"` を出します）、次に[アプリケーションのヘルパー](#application-helpers)を試し、それでもなければ `"undefined helper 'name'"` を出します。

| ヘルパー | シグネチャ | 注記と例 |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` はすでに `SafeString` でなければエスケープされる。**`method:` はない** — 例外を出し、`button_to` を使うよう伝える（rails-ujs/turbo による DELETE リンクの偽装はない） |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | ボタン 1 つの `<form class="button_to">`。`get`/`post` 以外のメソッドには hidden の `_method`、セッションがあれば CSRF のフィールドも付く |
| `form_with` | `form_with(model:, url:, scope:, method:, class:, data:, multipart:, local:) do \|f\| ... end` | ブロックが必要。`model:` が新規 → コレクションのルートと POST、保存済み → メンバーのルートと PATCH。ネストしたルートには `[parent, child]`、namespace のルートには `[:admin, @article]`。`url:`/`method:` は導かれたアクションやメソッドを上書きする。`scope: :q` はフィールドを `q[term]` と名付ける（`model:` と一緒ならモデルのプレフィックスを置き換える）。`data: { turbo_frame: "f" }` は `data-` 属性を書く。`local:` は受け付けるが何も変えない。`multipart: true` は `enctype="multipart/form-data"` を追加する（`f.file_field` に必須。ブロックから推測されることはなく、GET のフォームでは `ArgumentError` を出す） |
| `select_tag` | `select_tag(name, option_tags = nil, include_blank:, prompt:, multiple:)` | `select_tag "order", options_for_select([["Newest", "new"], ["Oldest", "old"]], "old")` → `<select name="order" id="order">...</select>`。`SafeString` でない `option_tags` はエスケープされる。`multiple: true` で名前は `order[]` になる。ほかのキーワードは属性になる |
| `options_for_select` | `options_for_select(choices, selected = nil)` | `f.select` の選択肢（下記）の `<option>` の行。`selected` は値か値の Array で、String として比べる |
| `options_from_collection_for_select` | `options_from_collection_for_select(records, :id, :name, selected = nil)` | レコードごとに 1 つの `<option>`。値とテキストは `f.collection_select` と同じように読む |
| `label_tag`, `text_field_tag`, `hidden_field_tag`, `submit_tag` | `label_tag(name, text = nil)`, `text_field_tag(name, value = nil)`, `hidden_field_tag(name, value = nil)`, `submit_tag(value = "Save changes")` | モデルなしのフォームのタグ：`label_tag(:term)` → `<label for="term">Term</label>`。`hidden_field_tag` は `autocomplete="off"` を書く。`submit_tag` の名前は `commit`。ほかのキーワードは属性になる（`id:` は名前から作った id を置き換える） |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` / `render partial: "comment", collection: @comments` / `render @comments` / `render component: "card", k: v` | [レイアウト、`yield`、`content_for`、パーシャル](#layouts-yield-content_for-partials)、[コレクション](#collections)、[コンポーネント](#components)を参照 |
| `h`、`escape` | `h(text)` | エスケープする。`SafeString` はエスケープされずにそのまま通る |
| `raw` | `raw(text)` | テキストを `SafeString` で包む（エスケープせずに出力される） |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`、`pluralize(2, "mouse")` → `"2 mice"`（`Cybertrain::Inflector` による Rails のデフォルトの英語の語形変化。アプリが定義する語形変化はサポートされない）。明示的な 3 つ目の引数が常に優先される |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n, delimiter: ",", separator: ".")` | `1234567` → `"1,234,567"`、 `-1000` → `"-1,000"`、 `1234.5` → `"1,234.5"` |
| `number_with_precision` | `number_with_precision(n, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false)` | `111.2345` → `"111.235"`、 `precision: 0` → `"111"` |
| `number_to_human` | `number_to_human(n, precision: 3, units: {})` | `1234` → `"1.23 Thousand"`, `1234567` → `"1.23 Million"`、 `units: { thousand: "K" }` は単位の名前（`unit`、`thousand` … `quadrillion`）を置き換える |
| `number_to_percentage` | `number_to_percentage(n, precision: 3)` | `100` → `"100.000%"` |
| `number_to_currency` | `number_to_currency(n, unit: "$", precision: 2, format: "%u%n")` | `1234.5` → `"$1,234.50"`、 負の数は書式の前に `-` を書く |
| `number_to_human_size` | `number_to_human_size(n)` | `1234` → `"1.21 KB"` (1024 進)、 `1` → `"1 Byte"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails 風の区分で、秒単位の精度はない：`"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`、`content_for(:key, "text")`、`content_for?(:key)` | [レイアウト、`yield`、`content_for`、パーシャル](#layouts-yield-content_for-partials)を参照 |
| `csrf_meta_tags` / `csrf_token` | | コントローラーのセッションがなければ空 / なし |
| `csp_meta_tag` / `content_security_policy_nonce` | | `<meta name="csp-nonce" content="...">` / nonce だけ。このリクエストの [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) の nonce。ポリシーがなければ `""` |
| `javascript_tag` | `javascript_tag(nonce: true) do ... end`, `javascript_tag(js)` | 内容を `<script>` に入れる（Rails と同じくエスケープしないので、リクエストのデータは決して入れない）。`nonce: true` でポリシーがあれば nonce を付ける。`id:`、`type:`、`data:` は属性 |
| `asset_path` | `asset_path("logo.svg")` | `/assets/logo-1a2b3c4d.svg`（[アセット](assets.md#helpers)を参照）。URL や `/` で始まるパスはそのまま返す |
| `stylesheet_link_tag` | `stylesheet_link_tag("application", media:, nonce:)` | `<link rel="stylesheet" href="/assets/application-1a2b3c4d.css">`（`.css` がなければ付ける） |
| `javascript_include_tag` | `javascript_include_tag("legacy", nonce:)` | `<script src="/assets/legacy-1a2b3c4d.js"></script>`（`.js` がなければ付ける） |
| `image_tag` | `image_tag(source, alt:, size:, class:)` | `size: "16x16"`（または `"16"`）なら `<img src="/assets/logo-1a2b3c4d.svg" alt="Logo" width="16" height="16">`。`alt` を勝手に作らず、`alt: ""` は書く |
| `javascript_importmap_tags` | `javascript_importmap_tags(entry = "application")` | インポートマップ、プリロードする pin ごとの `modulepreload` のリンク、`import "application"`。ポリシーがあればどれにも nonce を付ける（[アセット](assets.md#the-import-map)）。リクエストが必要 |
| `flash` | | `Hash` のようなもの：`flash[:notice]` |
| `params` | | 現在の `Cybertrain::Params` |
| `request_path` | | 現在のパス。コントローラーがなければ `""` |
| `url_for` | `url_for(target, format:, anchor:, k: v)` | `String` はそのまま、`Model` → メンバーのルート、`[parent, child]` → ネストしたルート、`[:admin, record]` → namespace のルート。キーワードはパスヘルパーと同じように付く（`url_for("/x", format: :csv)` → `/x.csv`） |
| `current_page?` | `current_page?(path)` | この GET か HEAD のリクエストが `path` へのものか（末尾のスラッシュは問わない。`path` にクエリがあればクエリも一致する必要がある）。レコードや Array は `url_for` を通す。ほかのメソッドなら false。リクエストが必要 |
| `paginate` | `paginate(page, path)` | `page` は `Cybertrain::Page`（`Relation#page` から）。`<nav class="pager">` をレンダリングし、「Newer」（`rel="prev"`）、`<span class="pager-current">Page N</span>`、「Older」（`rel="next"`）を含める。該当するページがなければリンクは省かれる。各リンクは `path` に、`page` を置き換えた（1 ページ目では取り除いた）現在のリクエストのクエリ文字列を付けたもので、再エンコードされ HTML エスケープされる。独自の `?query` を持つ `path` では代わりにそれを使う。`Page` はテンプレートの中で `number`、`per`、`row_offset`、`next?`、`prev?`、`next_number`、`prev_number` にも応える（`<% if @page.next? %>`） |
| `*_path` / `*_url` | 例： `post_path(post)`, `posts_path(page: 2, format: :json)` | アプリが生成し、`Cybertrain::Views.url_resolver` 経由で解決される。キーワードはクエリ文字列になり、`format:` は拡張子を、`anchor:` はフラグメントを付ける（[リダイレクトとクエリ文字列](requests.md#redirects-and-query-strings)） |
| `tag` | `tag.div(content, attrs) do ... end` | tag ビルダー：[tag ビルダー](#the-tag-builder)を参照 |
| `content_tag` | `content_tag(name, content = nil, attrs)`、または `do` のブロック付き | `content_tag "p", "<i>", class: "n"` → `<p class="n">&lt;i&gt;</p>`。規則は `tag` と同じ |
| `safe_join` | `safe_join(array, sep = "")`（キーワード引数なし） | `SafeString` に連結します。まだ `SafeString` でない各要素と区切りはエスケープします：`safe_join([tag.b("a"), "<"], " ")` → `<b>a</b> &lt;` |
| `class_names` | `class_names(*values)` | Rails の `class_names`/`token_list`：String と Symbol の単語、Array（入れ子も）の単語、値が真である Hash の各キーの単語を、それぞれ 1 回ずつ。キーワード引数はもう 1 つの Hash になります：`class_names("btn", active: @on, big: false)` → `"btn active"` |
| `dom_id` | `dom_id(record, prefix = "")`（Rails と同じく接頭辞は位置引数） | `"article_12"`、保存されていないレコードなら `"new_article"`、`dom_id(@article, "edit")` → `"edit_article_12"`（Ruby では `Cybertrain::Html.dom_id`） |
| `turbo_stream_from` | `turbo_stream_from(*streams, ws: false)` | ページをストリーム（String、または `"articles:12"` と名付けられるレコード）に購読させる `<turbo-stream-source>` を 1 つ。`ws: true` は `ws://`/`wss://` の URL を返し、リクエストが必要です。[リアルタイム](realtime.md#turbo-streams)を参照 |
| `signed_stream_name` | `signed_stream_name(*streams)` | 署名付きトークンだけ。手書きの JavaScript 用 |
| `stream_source_path` | `stream_source_path(*streams, mode: "json")` | トークンと `mode=json`（または `"raw"`）付きのストリームのエンドポイントのパス |
| `turbo_frame_tag` | `turbo_frame_tag(id_or_record, src:, loading:, target:, class:, data:) do ... end` | `<turbo-frame id="article_3" src="...">...</turbo-frame>`。レコードならその `dom_id`。属性は渡したときだけ書く |
| `turbo_stream` | `turbo_stream.replace(target, partial:, locals:)`, `.update(target, html:)`, `.append(target) do ... end`, `.prepend`, `.before`, `.after`, `.remove(target)` | `*.turbo_stream.erb` のテンプレート用の `<turbo-stream action="...">` 要素 1 つ。ターゲットは DOM の id かレコード。ブロック、`partial:`（`locals:` 付き）、`html:` のちょうど 1 つ |
| `time_tag` | `time_tag(time, text = nil, format:, class:, id:, title:, data:)`、またはブロック付き | `<time datetime="2026-11-10T12:00:00Z">Tue, 10 Nov 2026 12:00:00 +0000</time>`。Date なら `2026-11-10`。`format:` は `:short`、`:long`、strftime の String（知らない指示子は例外になり、strftime が別の意味に読む幅やフラグも同じ：`%6L` は `%6N` を使う。`:` は `%:z` の中だけ。`%F %T %D %R %r %c %x %X %v` にはパディングのフラグを付けられない。数値の幅はパディングを置き換え、`%5e` は `"    5"` になる） |

ヘルパーのテキスト引数はすべて 1 つの規則に従います：`SafeString` はエスケープされずにそのまま通り、それ以外はエスケープされます — `link_to raw('<b>raw</b>'), post` は太字のタグを文字どおりに出力しますが、`link_to post.title, post` はエスケープします。

六つの数値ヘルパーは `Cybertrain::NumberHelper` のもので、Ruby のコードからは同じキーワードのモジュール関数として呼べます（`Cybertrain::NumberHelper.number_to_currency(price, unit: "€")`）。Integer、Float、数値の String（decimal のカラムは Float です）を受け取り、10 進のテキストの桁で四捨五入するので、どちらのランタイムでも結果は同じです。それ以外の値は `ArgumentError`（`"number_with_delimiter: \"abc\" is not a number"`）になり、0 から 100 の範囲外の精度も同じです。テンプレートでは `nil` は `""` になります（null を許す decimal のカラムは Rails と同じく空で表示されます）。Ruby から呼んだ `Cybertrain::NumberHelper` は、`nil` に対して今も `ArgumentError`（`"number_with_delimiter: nil is not a number"`）を発生させます。書式は英語です。

### tag ビルダー

`tag` はビルダー（`Cybertrain::Html::TagBuilder`）に評価されます。それに対して呼んだメソッドはどれも要素で、`Cybertrain::Html.tag` がレンダリングします（Ruby からも呼べます：`Html.tag("a", { href: "/x" }, "Go")`）：

```erb
<%= tag.div(class: "card") do %>
  <%= tag.h2 @article.title, id: dom_id(@article) %>
<% end %>
<%= tag.input type: "text", name: "q", disabled: true %>   <%# <input type="text" name="q" disabled> %>
<%= tag.path d: "M0 0 L10 10" %>                         <%# SVG elements work %>
<%= tag.my_widget data: { turbo_frame: "f" } %>          <%# <my-widget data-turbo-frame="f"></my-widget> %>
```

- `<%= tag %>` だけでは何も出力しません。
- 要素名は、メソッド名の `_` を `-` にしたものです。`[a-z][a-z0-9-]*` に一致しなければなりません（そうでなければ `Html.tag` が `"invalid element name 'Div'"` を出します）。
- 内容は 1 つの位置引数（`SafeString` でなければエスケープされるので、`tag.script("alert(1)")` はテキストをエスケープして出力します）か、ブロックの**出力**（`do ... end`、または値がエスケープされて出力される `{ expr }`）で、ブロックが優先されます。どちらもなければ、`tag.div` は `<div></div>` です。
- 空要素（`area base br col embed hr img input link meta source track wbr`）は閉じタグなしでレンダリングされます。それに内容やブロックを与えるとエラーです（`"br is a void element"`）。
- 属性はキーワード引数で、順序どおりです：`nil` と `false` は属性を落とし、`true` は値なしの属性（`disabled`）にし、Array は `nil` でない要素を空白でつなぎ（`data: { ids: [1, 2] }` は Rails の JSON ではなく `data-ids="1 2"`）、`class:` は `class_names` と同じものを受け取り（`class: ["btn", { active: @on }]`）、`data:` と `aria:` の Hash は下線をダッシュにして `data-key="v"` / `aria-key="v"` に展開されます（そこでは `true`/`false` も文字として書かれます）。それ以外の Hash の値はエラーです（`"attribute 'title' cannot be a Hash"`）。値はすべてエスケープされ、`SafeString` も同じです。属性名は `[a-zA-Z_:][-a-zA-Z0-9_:.]*` に一致しなければなりません（`"invalid attribute name 'data-a b'"`）。`onclick:` なども、書き手のものなので許されます。

### FormBuilder（`form_with ... do |f|` の `f`）

どのメソッドも `SafeString` を返します。一覧にないメソッドは `RuntimeError`（`"undefined method 'color_wheel' for FormBuilder"`）です。

| メソッド | レンダリング結果 |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — デフォルトのテキストは属性を人間向けにしたもの（`published_at` → 「Published at」、`author_id` → 「Author」）。明示的なテキストは `SafeString` でなければエスケープされる |
| `f.text_field :title` ( `email_field`, `password_field`, `number_field`, `date_field`, `datetime_local_field`, `time_field`, `range_field`, `color_field`, `search_field`, `telephone_field`, `url_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`。`password_field` は決して `value=` を出力しない。`telephone_field` は `type="tel"`。Time はブラウザーが読む形で書く（`2026-11-10`、`2026-11-10T12:00:00`、`12:00:00.000`） |
| `f.select :status, ["draft", "published"]` ( `include_blank:`, `prompt:`, `selected:`, `disabled:`, `multiple:`) | 選択肢ごとに `<option>` を持つ `<select name="post[status]" id="post_status">` で、現在の値が選ばれる。選択肢は値、`[text, value]` の組、`<optgroup>` 用の Hash か `[label, [choices]]` のグループ。`multiple: true` で名前は `post[status][]` になり、先に空の hidden の input を書く |
| `f.collection_select :author_id, @authors, :id, :name` | レコードごとに 1 つの `<option>` を持つ `<select>`。値とテキストは二つのメソッドから読む |
| `f.radio_button :status, "draft"` | `<input type="radio" name="post[status]" id="post_status_draft" value="draft">`。値が一致すればチェックされる（`checked:` が優先） |
| `f.file_field :cover`（`accept: "image/*"`、`required: true` も） | `<input type="file" name="post[cover]" id="post_cover">` — `value=` は決して付かず、属性はカラムでなくてもよい。フォームは `form_with ..., multipart: true` でなければならない。`multiple: true` は `ArgumentError` を出す（フィールドごとにファイル 1 つ） |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>`（Rails と同じく先頭に `\n` — ブラウザーは最初の改行を食べる） |
| `f.check_box :published` | hidden の `value="0"` の input の後に本物のチェックボックスが続くので、チェックしていないボックスも `"0"` を送信する。`include_hidden: false` なら hidden の input を書かない |
| `f.submit` / `f.submit "Text"` | デフォルトのテキストは（`persisted?` によって）`"Create Post"`/`"Update Post"`、モデルがなければ `"Save changes"` |

モデルがある場合、フィールドの名前は `post[title]`/`id="post_title"` になります（スコープは `Inflector.underscore(model.model_name)`）。`form_with(..., scope: :q)` なら代わりに `q[title]`/`id="q_title"` です。モデルもスコープもない `form_with(url: ...)` では、どちらにも素の属性名が使われます。属性の値と選択肢のテキストは、どれも一度だけエスケープされます（`SafeString` はそのまま）。追加のキーワード引数は、与えた順に HTML の属性になります：`true` → `attr="attr"`、`false`/`nil` は捨てられ、それ以外は → `attr="value"`（エスケープされます）。アンダースコアはハイフンになり（`data_confirm: "Sure?"` → `data-confirm="Sure?"`）、`class:` は、`model.errors.key?(attr)` のときに自動で付く `field_with_errors` クラスと合わせられます。

## アプリケーションのヘルパー

`app/helpers/` の下のモジュールは、Rails と同じくヘルパーモジュールです：その公開メソッドはどれも、レシーバーなしでどのテンプレートからでも呼べます。

```ruby app/helpers/prices_helper.rb
module PricesHelper
  def price(value, unit: "USD", precision: 2)
    amount = Cybertrain::Cast.float(value).round(Cybertrain::Cast.int(precision))
    Cybertrain::Html.tag("span", { class: "price" }, "#{amount} #{unit}")
  end

  def panel(title, &block)
    Cybertrain::Html.tag("section", { class: "panel" }, Cybertrain::Html.safe_join([Cybertrain::Html.tag("h2", {}, title), yield]))
  end
end
```

```erb
<%= price @item.cost %>                  <%# <span class="price">12.5 USD</span> %>
<%= price @item.cost, unit: "EUR" %>
<%= panel "Totals" do %><p><%= @total %></p><% end %>
```

- **生成されるディスパッチ。** テンプレートは `send` できないので、`spin run gen` が `app/helpers/**/*.rb` をテキストとして読み、`gen/helpers.rb` を書きます：すべてのモジュール（とルートヘルパー）を include する `ApplicationHelpers` クラスと、ヘルパー名の `case` です。ヘルパーを追加したりシグネチャを変えたりすると、次のビルドがそれを生成し直します（開発サーバーは両方を行います）。`cybertrain generate helper prices` は空の `PricesHelper` とテストを書きます。
- **何がヘルパーか。** `module` の公開インスタンスメソッドです（`def self.x`、セッター、`private` や `protected` の後のものは含みません）。ファイルは問いません。テンプレートは値を位置かキーワードで渡すので、パラメーターにはすべて名前があります：`*rest`、`**opts`、`...` は生成時のエラーで、省略可能なパラメーターの後の必須パラメーターも同様です。省略可能なパラメーターは 3 つまでです（生成される `case` には与えられた組み合わせごとに 1 つの分岐があるので、省略したキーワードにはメソッド自身のデフォルトが使われます）。呼び方の誤りはレンダリング時の `ArgumentError` です：`"wrong number of arguments for 'price' (given 0, expected 1)"`、`"unknown keyword 'cur' for 'price' (known: unit, precision)"`。
- **予約された名前。** ヘルパーには、フレームワークのヘルパーの名前（`link_to`、`render`、`tag`、`dom_id`、`params`、`content` など）、`Cybertrain::Template::Helpers` のメソッドの名前（公開・非公開を問いません：`include` がフレームワークにとってもそれを置き換えてしまいます）、`yield`、`_path` / `_url` で終わる名前（それにはルートヘルパーが応答します）は付けられません。2 つのモジュールに同じ名前があるのもエラーです。`spin run gen` はファイル、行、理由を示して止まります。
- **値。** 引数はテンプレートの値（String、Integer、Float、`nil`、レコード、Array、Hash）として届きます。計算の前に `Cybertrain::Cast`（`Cast.str`、`Cast.int`、`Cast.float`）で絞り込んでください。ヘルパーが返したものは、ほかの値と同じように出力されます：`String` はエスケープされ、`SafeString` はされないので、HTML は `Cybertrain::Html.tag(name, attrs, content)`、`Html.safe_join`、`Html.class_names`、`Html.dom_id`、`Html.escape`、`Cybertrain::SafeString.of`、あるいはリンクヘルパーの Ruby の形 `link_to_path(text, path, attrs)` と `button_to_path(text, path, attrs)`（`method:` は `attrs` の中）で組み立てます。
- **ブロック。** `&block` パラメーターを持つヘルパーは `do ... end` のブロックを取ります。`yield`（引数なし）は、ブロックが出力したものを `SafeString` として返します。

## コンポーネント

コンポーネントは、キーワード引数を取るクラスと、その隣のテンプレートです。[ViewComponent](https://viewcomponent.org) と同じ形です：

```ruby app/components/card_component.rb
class CardComponent < Cybertrain::Component
  def initialize(title:, value: 0, tone: "neutral")
    @title = title
    @value = value
    @tone = tone
  end

  def value_text = "#{@value} pts"
  def tone_class = "card--#{@tone}"
end
```

```erb app/components/card_component.html.erb
<%= tag.div(class: class_names("card", tone_class)) do %>
  <h3><%= title %></h3><p><%= value_text %></p><%= content %>
<% end %>
```

```erb
<%= render component: "card", title: "Visitors", value: @count %>
<%= render component: "card", title: "Notes", tone: "warm" do %>
  <p><%= @note %></p>
<% end %>
```

- テンプレートからは、コンポーネントのインスタンス変数がローカル変数（`title`）として、パラメーターのない公開メソッドが名前（`value_text`）で、そして `do` のブロックが出力したもの `content`（ブロックがなければ `""`）が見えます。レイアウトなしでレンダリングされ、パーシャルやほかのコンポーネントをレンダリングでき、パーシャルと同じく `max_render_depth` に数えられます。コンポーネントがレンダリングしたパーシャルからは、コンポーネントのメソッドは見えません。コンポーネントのテンプレート内でディレクトリのないパーシャル名（`render "chip"`）は `app/components/` の下（`app/components/_chip.html.erb`）から探され、ディレクトリ付きの名前（`render "shared/note"`）は通常どおり `app/views/` の下から探されます。
- コンポーネントは、パーシャルがパスで指定されるのと同じく、`_component` を除いたスネークケースの名前で指定します：`CardComponent` なら `"card"`、`Admin::UserRowComponent`（`app/components/admin/user_row_component.rb`）なら `"admin/user_row"` です。テンプレートは定数を名指しできません。
- `spin run gen` は、ヘルパーと同じく字句的な走査から `gen/components.rb` を書きます：クラスの行、`@x =` の代入、パラメーターのない `def`、`initialize` のキーワードです。`initialize` はキーワードだけを取り（省略可能なものは 3 つまで）、テンプレートがなければなりません。キーワードの不足や未知のキーワードはレンダリング時の `ArgumentError` です。未知のコンポーネントは `Cybertrain::Component::Unknown` です：`` "no component 'crad' (app/components/crad_component.rb, then `spin run gen`)" ``。`content` は予約されています：その名前の `initialize` のキーワードや `@content` インスタンス変数はブロックの出力で上書きされてしまうので、`spin run gen` はファイルと行を示して拒否します。`app/views/components/` はほかと同じビューのディレクトリのままです（`ComponentsController` のもの）。予約されているのは、コンポーネントのテンプレートが置かれる名前の `app/views/__components/` だけです。
- `cybertrain generate component card title value:integer` は、クラス、そのテンプレート、そして `Cybertrain::Test.render_component` でそれをレンダリングするテストを書きます。

### リクエストの外でのレンダリング

ブロードキャスト、ジョブ、メールの本文は、リクエストなしでレンダリングします：

```ruby
html = Cybertrain::Views.render_partial("articles/article", article: article)   # app/views/articles/_article.html.erb
card = Cybertrain::Views.render_component(CardComponent.new(title: "Visitors", value: 12))
```

どちらも、アプリケーションのヘルパーを使って HTML を String で返します。パスヘルパーは動き（`article_path(article)`）、strict locals は検査され、フォーム（`form_with`、`button_to`）は認証トークンなしでレンダリングされます（Turbo のページは `csrf_meta_tags` のトークンを送信します）。リクエストを必要とするヘルパーは `Cybertrain::Views::OutsideRequest`（`"csrf_token needs a request"`）を出します：`csrf_token`、`csrf_meta_tags`、`params`、`flash`、`request_path`、`current_page?`、`content_security_policy_nonce`（そのため `csp_meta_tag` と、`nonce: true` を渡したタグヘルパーも）、`javascript_importmap_tags`、あらゆる `*_url` ヘルパー、`turbo_stream_from ... ws: true` です。`paginate` のリンクは、パス自身のクエリ文字列だけを持ちます。（単体テストで作るような素の `Cybertrain::Template::Helpers.new(nil)` は、それらに代わりに空の値で応えます。）

## レイアウト、`yield`、`content_for`、パーシャル

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

### コントローラーごとのレイアウト

アクションは、コントローラー、その親、include したコンサーンが別のものを選ばない限り、`app/views/layouts/application.html.erb`（あれば）の中でレンダリングされます：

```ruby
class AdminController < ApplicationController
  layout "print", only: [:receipt]      # app/views/layouts/print.html.erb
  layout :choose_layout                 # メソッド：名前、なしなら false、親のものなら nil

  private

  def choose_layout = request.header("Turbo-Frame").to_s.empty? ? "application" : "frame"
end
```

`layout "admin"` だけなら、すべてのアクションに一つのレイアウトを指定します。`spin run gen` は `layout` の行（引用符付きの名前、`false`、メソッドの Symbol に、`only:` / `except:`）を読み、コントローラーの `controller_layout(action)` を書きます。宣言は順に試され、**最初に当てはまったものが勝ちます**（Rails では後の宣言が前のものを置き換えます）。コンサーンの行はその `include` の位置で数えます。`render layout: "x"` はその呼び出しだけ `layouts/x` を使い、`render layout: false` はレイアウトなしです。先頭の `layouts/` は受け付けます（`layout "layouts/x"` は `layouts/x` です）。存在しないレイアウトを指す `layout` の行や `render layout:` は `MissingTemplate` を発生させます。省略できるのは既定の `application` レイアウトだけです（そのときアクションはレイアウトなしで描画されます）。レイアウトの中にレンダリングされるのは html だけで、ほかのフォーマットのテンプレートはレイアウトなしです。それ以外の `layout` の引数（`nil`、ラムダ、定数）は gen が拒否します。

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

### コレクション

```erb
<%= render partial: "comment", collection: @comments, as: :comment, spacer_template: "divider" %>
<%= render @comments %>      <%# each record's comments/_comment.html.erb %>
<%= render @comment %>       <%# one record, no counter %>
<%= render component: "comment", collection: @comments %>
```

- `collection:` は Array の要素ごとにパーシャルを 1 回レンダリングします。要素は `as:` が指すローカル変数（既定はパーシャル自身の名前）になり、`<as>_counter` が 0 から数え、`locals:` はそれぞれに渡され、要素の間には `spacer_template:`（パーシャル）が入ります。空のコレクションは何も出力しません。strict locals のパーシャルがカウンターを受け取るのは、それを宣言したときだけで、同じ名前のローカル変数より要素が優先されます。
- `render @comments` は、各レコードのパーシャルをそのモデルから選びます：`<plural>/_<singular>`（`Admin::Note` なら `admin/notes/_note`）。そのため、一覧に複数のモデルが混ざっていても構いません。
- ただ一つの必須キーワードが自分の名前と同じコンポーネント（`comment:` を取る `CommentComponent`）には `CommentComponent.with_collection(items)` があり、`render component: "comment", collection: @comments` は要素ごとに 1 回レンダリングし、`initialize` が `comment_counter:` を宣言していればそれも渡します。`collection:` はほかのキーワードを受け付けません（`render component: "comment", collection: @comments, extra: 1` は、そのキーワードを挙げるエラーになります）。ブロックの内容は渡されません。

### ファイルの解決（`engine.rb`）

`"posts/show"` と `"posts/show.html.erb"` は同じテンプレートを指します。開発環境は `cache: false` で `app/views/` をディスクから読みます（mtime かサイズが変わるたびに、ファイルを読み直して再パースします。この再パースはエンジンのキャッシュに書き込むので、開発サーバーは `SPINEL_WORKERS` を無視して常に 1 ワーカーで動き、そのことを起動バナーに表示します）。テスト環境は `cache: true` でディスクから読みます（一度だけパースします）。本番用のバイナリは決してディスクに触れません：`cybertrain build` は `spin run gen -- --embed-views` を実行し、`app/views/` 以下のすべての `*.erb`（ドットファイルとシンボリックリンクのディレクトリはスキップ）を `gen/views.rb` に書き込みます。`Engine.embedded(sources)` はバイナリの起動時にすべてのエントリーを一度だけパースします（エラーメッセージは同じ `posts/show.html.erb:12` の形を保ちます）。そのため、構文エラーのあるテンプレートはそのページではなく起動を失敗させます。テーブルが空のバイナリは、本番環境での起動を拒否します。存在しないテンプレートは `Cybertrain::Template::MissingTemplate` を出します — ディスクからなら `"Missing template <full path>"`、テーブルからなら `"Missing template posts/nope.html.erb (embedded)"` です。

ファイルの検索は、ビューのルートとテンプレートのパスをシンボリックリンクを辿って解決し、そのルートの中にある通常のファイルだけを読み込みます。ルートの外に出るパスは（シンボリックリンクを通じたものも含めて）`MissingTemplate` を出し、そうしたパスに対して `exists?` は false を返します。

## エラー

例外クラスは 2 つで、どちらも `ast.rb` の `Cybertrain::Template` 名前空間にあります（`::SyntaxError`/`::RuntimeError` とは別のものです）：

- **`SyntaxError`** — トークン分割やパースの最中、解釈が始まる前に出ます。形：`"<template>:<line>: <what>"`。例えば `"posts/show:2: 'if' without 'end'"`、`"posts/show:1: unterminated <% tag"`、`"posts/show:1: unexpected ')' in 'foo(1))'"`。ページやレイアウトのファイルがパースに失敗したとき、`Engine#template`（したがって `#render`/`#render_with_layout`）から直接出され、インタープリターに捕まえられたり包み直されたりすることは決してありません。
- **`RuntimeError`** — 評価の最中に出ます。メッセージの形は同じですが、`<template>` は*そのときレンダリング中の*テンプレートです（`Interpreter#render` が `@name` を入れ替えます）— パーシャル自身のエラーは、呼び出し元ではなくパーシャルの名前と行を保ちます：`"posts/_row:1: undefined method 'bogus' for String"`。

ヘルパーや `FormBuilder`・独自オブジェクトのメソッド呼び出しから出た素の `StandardError`（素の `raise "text"`、`ArgumentError`、`KeyError`、さらにはネストした `render` からの `Cybertrain::Template::RuntimeError`）は捕まえられて「再配置」されます：`"<current template>:<current line>: <original message>"` に書き換えられます。ただし、それがすでに最後に再配置したメッセージとまったく同じ場合（ネストした `render` がすでに、より具体的な自分の位置を付けている場合）は、変更されずにそのまま通ります。ヘルパーが出した `Cybertrain::Template::SyntaxError`（レンダリング中にパースに失敗したパーシャル）は決して包み直されません — 自身の `"<partial>:<line>: ..."` のメッセージとクラスを保つので、壊れたパーシャルは常に、それをレンダリングした側についての `RuntimeError` ではなく、自分自身についての `SyntaxError` として報告されます。

`Cybertrain::Views::OutsideRequest` と `Cybertrain::Component::Unknown` も、包まれずにクラスを保ったまま伝わるので、`Views.render_partial` の呼び出し元はそれらを rescue できます。

`MissingTemplate`（`StandardError`、`engine.rb`）は、トップレベルの `Engine#template`/`#render`/`#render_with_layout` の呼び出し（例えば、存在しないアクションのテンプレートやレイアウトをレンダリングするコントローラー）からは、**包まれずに**、`template:line` の接頭辞なしで出されます：`"Missing template <path>"`。同じ例外でも、`render` ヘルパーのパーシャル検索によってテンプレートの*中で*出されたものは、代わりに再配置を経て `RuntimeError` として出てきます：`"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`。

## Rails の ERB との違い

| Rails の ERB | Cybertrain |
| --- | --- |
| Ruby のメソッドにコンパイルされる。どんな Ruby でも、どんなオブジェクトでも、どんなメソッドでも動く | 型ごとに固定されたディスパッチテーブルに対して解釈される。呼び出せるのは[型ごとのメソッドテーブル](#per-type-method-table)に挙げたものだけ |
| `ActiveSupport::SafeBuffer` は `String` のサブクラス | `SafeString` は独立したラッパークラス — 呼び出せるのは `to_s`/`html_safe?`/`size`/`length`/`empty?` だけ |
| ブロック：`each`、`{ }`、`map`、任意の Enumerable のメソッド | Array/Hash の決まったメソッド（`each_with_object`、`inject` はない）への `{ }` と `do...end`、`each`/`each_with_index`/`each_slice` のループ、ヘルパー呼び出し、`tag` |
| `xs.each { }` — ブロックパラメーターがゼロでもかまわない | `each`/`each_with_index` はブロックパラメーターを 1 つか 2 つ宣言する必要がある |
| `link_to text, path, method: :delete`（JS 駆動） | `link_to` に `method:` はない — GET 以外の本物のフォームには `button_to` を使う |
| strict locals は `name: default_expr` を受け付ける（Rails 7.1） | 素の `name:`（必須）だけ。デフォルト値付きのエントリーは `SyntaxError` |
| 未定義のインスタンス変数やローカル変数は Ruby やビューコンテキストのメソッドで解決される | `@x` は決して失敗しない単純な環境の参照。未定義の素のローカル変数は、明示的で閉じたヘルパー呼び出しの試み（一致しなければ `"undefined helper"`） |
| `===` による `case/when`（範囲、クラス、正規表現） | `==` だけによる `case/when`（数値は値で比較） |
| `and`/`or`/`not`、範囲、正規表現、多重代入がすべて動く | どれも存在しない。予約語は、一般的なパースエラーではなく、「not supported in templates」という専用のメッセージで失敗する |
| 数値リテラル：16 進、8 進、2 進、指数、有理数 | `_` の区切りを使える 10 進の整数と浮動小数点数だけ |
| `:"quoted symbol"`、`:+` の演算子シンボル | シンボルは識別子の文字だけ |
| `foo (x)`、`foo [x]`（空白は許容され、警告が出ることもある） | どちらも厳格な `SyntaxError` — 呼び出しの `(` やインデックスの `[` の前に空白は置けない |
| ネストした括弧なしの呼び出しは Ruby 自身のパーサーが解決する | 括弧なしの引数を取れるのは、式の中の最も外側の呼び出しだけ |
| 宣言されていない・綴りを間違えた属性は確実に `NoMethodError` を出す | 生成されたモデルは `"undefined method 'x' for Post"`（`Template::RuntimeError`）を出し、存在する `nil` の属性は空としてレンダリングする。`attribute_or_method?` をオーバーライドしていない手書きのモデルは、未知の名前を空としてレンダリングする |
| `1 / 0` と `1.0 / 0` はどちらも `ZeroDivisionError` を出す | `Integer` のゼロによる除算・剰余は `"divided by 0"` を出す。`Float` は IEEE-754 に従い（`Infinity`/`NaN`）、エラーにならない |
| `distance_of_time_in_words` や複数形化は i18n のロケールをサポートする | 英語のみで、ロケールのサポートはない |
| `app/helpers` のモジュールはすべて混ぜ込まれる。シグネチャは自由で、ヘルパーがフレームワークのものを上書きできる | モジュールはビルド時に走査され、生成された `case` になる：名前付きのパラメーターだけ、省略可能なものは 3 つまで、フレームワークのヘルパー名と `_path`/`_url` で終わる名前は不可（[アプリケーションのヘルパー](#application-helpers)） |
| ViewComponent：`render CardComponent.new(title: "x")`、`with_collection`、スロット | 名前による `render component: "card", title: "x"`、ブロックからの `content`、ただ一つの必須キーワードと同じ名前のコンポーネントには `collection:`。スロットはない（[コンポーネント](#components)、[コレクション](#collections)） |
| 後の `layout` の行が前のものを置き換える | 最初に当てはまった `layout` の宣言が勝つ（[コントローラーごとのレイアウト](#per-controller-layouts)） |
