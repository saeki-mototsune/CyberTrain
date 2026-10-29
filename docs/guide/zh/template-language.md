---
source_sha256: c62dd8a199df41e47d7f65f6dabf83f2b548e103d5f59b2bd807b7433590bd06
---
# Cybertrain 模板语言参考

Cybertrain 的视图（`app/views/**/*.html.erb`）看起来像 Rails 的 ERB，但并不是 Ruby：它们在运行时被解析（在开发和测试环境中从磁盘上的 `app/views/` 读取；在生产环境的二进制文件中则来自 `cybertrain build` 通过 `gen/views.rb` 嵌入的字符串表），经过分词并解析为 AST，一次性编译为扁平的节点树，再由一个遍历树的解释器执行。

本文档准确描述这条流水线接受和执行的内容。凡是它与 `docs/design.md` 第 7 节（最初的规格草案）或 Rails 开发者的预期不一致的地方，都以代码为准，本文档也会指出（搜索“**实际实现**”）。

## 这里什么是 Ruby，什么不是

模板**不是** Ruby。Spinel（cybertrain 所面向的 Matz-Ruby AOT 编译器）没有 `eval`，所以“在请求时解释视图自身的 Ruby 代码”从来就不在考虑之列（`docs/design.md` 中的 D9）；实际运行的是一套小巧、封闭的语法，只是披着 ERB/Ruby 风格的外衣。标签内不能写任意 Ruby——只能写 `ExprParser`（`parser.rb`）识别为语句或表达式的内容。没有 `eval`、`send`、`instance_eval`、方法/类/模块定义、`require`、异常（`begin/rescue`）、`case/when`、范围、正则表达式或多重赋值。仅有的块是 `each`、`each_with_index` 以及对辅助方法的调用（`form_with(...) do |f| ... end`）——没有 `{ }` 块，没有 `map`/`select`/其他任何带块的 Enumerable 方法。每个方法调用（`recv.name`）都由 `interpreter.rb` 中手写的 `case` 分派表解析，以接收者在运行时的 Ruby 类为键；不在该类型表中的名称会以 `RuntimeError` 失败——没有 `method_missing`，没有反射，并且（见 `Interpreter#call_method`）正是因为 Spinel 没有 `send`，这里才是一个 `case`，而不是元编程的查找。模板只能做本文档所描述的事情。

<details><summary>这些代码在源码中的位置 — 模板流水线的八个文件</summary>

这条流水线位于 `cybertrain/template/` 中：

| 文件 | 作用 |
| --- | --- |
| `lexer.rb` | 把源代码切分为 `<% %>`/`<%= %>`/`<%== %>`/`<%# %>` 标签和普通文本 |
| `parser.rb` | `TreeBuilder` 把标签嵌套为 AST；`ExprParser` 解析单个标签内的表达式语法 |
| `ast.rb` | 解析器生成的 AST 节点类 |
| `inode.rb` | `Compile` 把 AST 展平为单态的 `INode`（一个整数“种类”加上带类型的槽位），以便快速解释执行 |
| `interpreter.rb` | 针对一个 `env`（`Hash<String, value>`）遍历 `INode`；掌管每种类型“有哪些方法”的全部表格 |
| `helpers.rb` | `link_to`、`form_with`、`render`、`pluralize` 等——模板不带接收者调用的一切 |
| `form_builder.rb` | `form_with(...) do \|f\| ... end` 传给块的 `f` |
| `engine.rb` | 加载 `.html.erb` 源代码——从某个根目录下的磁盘，或从嵌入的 `gen/views.rb` 表（`Engine.embedded`）——解析它们（并可选择缓存），连同布局一起渲染 |

</details>

## 标签

| 标签 | 含义 |
| --- | --- |
| `<% code %>` | 执行一条语句；不产生输出 |
| `<%= expr %>` | 求值 `expr` 并输出，经过 HTML 转义 |
| `<%== expr %>` | 求值 `expr` 并输出，**不**转义 |
| `<%# comment %>` | 忽略（下文第 1 行的 `locals:` 形式除外） |

空白控制（`Lexer.tokenize`）：

- 如果 `<% %>`/`<%# %>` 标签是所在行中**唯一**的内容（两侧直到换行符之间只有空格/制表符），它会悄悄吞掉自己的缩进和末尾的换行符，类似 Rails ERB 的裁剪模式。`<%= %>`/`<%== %>` **从不**以这种方式自动裁剪，即使独占一行。
- `<%-` 会显式去掉标签前面的空格/制表符，`-%>` 会去掉紧随其后的那一个换行符——对任何种类的标签都适用。当行的那一侧有空白以外的内容时，两者都不起作用。
- 文本中的 `<%%` 是字面量 `<%`；标签内的 `%%>` 是字面量 `%>`，不会关闭标签。
- `<% # a Ruby-style comment %>`（内容以 `#` 开头的代码标签）与 `<%# %>` 一样被忽略。**不**支持在同一个标签中跟在真正代码**之后**的注释——`<% x = 1 # note %>` 是 `SyntaxError`。
- 未闭合的标签会在词法分析时抛出异常：`"posts/show:2: unterminated <% tag"`。

### 严格局部变量注释

如果一个注释标签的内容以 `locals:` 开头，**并且它是文件中的第一个标签、位于第 1 行**，它就声明了模板（几乎总是局部模板）所接受的全部局部变量：

```erb
<%# locals: (post:, comment:) %>
<%= post.title %>
```

- `<%# locals: () %>`（空列表）表示“这个局部模板不接收局部变量”。
- 每个条目都必须是不带修饰的小写 `name:`（`Lexer.identifier?` 只接受 `[a-z_][a-z0-9_]*`）。**实际实现**：与 Rails 7.1 不同，条目不能带默认值——`<%# locals: (post:, comment: nil) %>` 这种正是 Rails 7.1 所支持的写法，在这里是 `SyntaxError`：`"t:1: bad strict locals entry 'comment: nil' (expected name:)"`，因为 `comment: nil` 不是以 `:` 结尾。每个声明的局部变量实际上都是必需的。格式错误的声明（缺少括号）会抛出 `"t:1: bad strict locals comment (expected locals: (name:, ...))"`。
- **没有**这条注释时，模板不声明局部变量列表：`render` 会原样传入给它的任何局部变量，不做检查，模板还可以读取调用者环境中已有的任何内容（参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials)）。
- 如果注释之前的某一行有任何内容（哪怕只是一个空行），它就只是一条普通的、不起作用的注释，而不是局部变量声明。

## 表达式

### 字面量

| 字面量 | 语法 | 说明 |
| --- | --- | --- |
| Integer | `1`、`1_000` | 允许下划线；不支持十六进制/八进制/二进制/指数 |
| Float | `2.5`、`12_3.4_5` | `.` 两侧都必须有数字；不支持指数形式 |
| String | `"..."`、`'...'` | 双引号支持插值和转义；单引号只识别 `\'` 和 `\\` |
| Symbol | `:title` | 只能由标识符字符组成——没有 `:"quoted"`，也没有 `:+` 这样的运算符符号 |
| `nil` / `true` / `false` | | |
| Array | `[1, "a", :b]`、`[]` | 元素可以是完整的表达式 |
| Hash | `{ a: 1, b: "x" }`、`{}` | **只支持符号风格的键**，形式与关键字参数相同；不支持 `"key" => value` 哈希火箭写法 |

双引号字符串支持 `#{...}` 插值（任意完整表达式，可以嵌套），并支持 `\n \t \r \0 \e \s`、`\"`、`\\`；其他任何被转义的字符原样通过。不含 `#{}` 的字符串编译为普通字面量；含插值的字符串编译为一系列字面量片段和表达式。

### 变量

- **`@ivar`** 直接读取 `env["ivar"]`——`@` 只是表面语法；按照 D9，在同一个环境 Hash 中，“post 既是 `@post`，也是局部变量 `post`”。不存在的实例变量就是 `nil`：`[<%= @missing %>]` 渲染为 `[]`，从不报错。
- **不带修饰的局部变量名**（`post`、`title`）同样读取 `env["name"]`，但如果这个键**根本**不存在，解释器就把它当作无参数的辅助方法调用。如果键存在（即使绑定的是 `nil`——比如已声明但未传入的严格局部变量），就返回它的值，不会退回到辅助方法。正因如此，`<%= csrf_meta_tags %>` 和 `<%= flash %>` 不加括号也能工作，而 `<%= nope %>` 会以 `"undefined helper 'nope'"` 失败，而不是“没有这个局部变量”的错误。
- 局部变量来自 `each`/`each_with_index` 的块参数、`form_with` 的块参数、局部模板的严格局部变量，以及 `<% name = expr %>`。

### 方法调用

```erb
recv.method
recv.method(arg1, key: value)
recv&.method             # nil 安全：recv 为 nil 时短路返回 nil，参数不会被求值
method(arg1, key: value) # 辅助方法调用：没有接收者
method arg1, key: value  # 同一个调用，不带括号（“命令”语法）
```

- 不带括号的（“命令”）参数列表只对表达式中**最外层**的调用开放：`link_to "Show", post_path(post)` 可以工作，但 `link_to "Show", post_path post` 是 `SyntaxError`——内层调用需要自己的括号。
- 调用目标与其左括号 `(` 之间不允许有空格：`link_to("x")` 和 `link_to "x"` 都可以；`link_to ("x")` 是 `SyntaxError`。
- `yield` 和 `yield :key` 总是被解析为调用（参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials)）。
- 不带修饰的大写开头单词会被直接拒绝——`"constants are not supported: 'Time'"`——模板无法访问 Ruby 常量。
- 以下单词是保留字，会以专门的消息（`"'x' is not supported in templates"`）被拒绝：`and or not do end if unless elsif else then while until case when def class module begin rescue return`。

### 运算符与优先级（从低到高）

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

`&&`/`||` 返回操作数本身，而不是强制转换后的布尔值（`nothing || title` 求值为 `title`，而不是 `true`）。条件检验的是**真值性**：与 Ruby 一样，只有 `nil` 和 `false` 为假——`0`、`""` 以及空数组/空 Hash 都为真（`<% if 0 %>yes<% end %>` 会输出 `yes`）。

索引写作 `target[index]`，`[` 之前**不能有空格**（`items [0]` 是语法错误，`items[0]` 不是），并且可以像任何后缀一样链式调用：`h["k"].first`、`params[:id]`。

## 语句

一个 `<% %>` 标签恰好容纳一条语句：一个赋值，或一个为其副作用而求值的表达式（值被丢弃）。`<%= %>`/`<%== %>` 只能容纳表达式——`<%= x = 1 %>` 是 `SyntaxError`。

### 条件

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` 遵循 Ruby 的规则；`else` 之后的 `elsif`、多余的 `else`/`elsif`/`end`，或从未被 `end` 关闭的块，都是 `SyntaxError`，并指出起始行。

### 循环

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` 只有作为块头的后缀（`x.each do |...|`）时才会被识别。**实际实现**：两者都要求声明一个或两个块参数——`xs.each do end` 是 `SyntaxError`（“takes one or two block parameters”），而普通的 Ruby 允许零个。
- Array 加一个参数：元素本身。Array 加两个参数：`Array` 类型的元素会被解构（`a, b = item[0], item[1]`）；否则第二个参数为 `nil`。
- Array 上的 `each_with_index`：`item, i`。Hash 上的：第一个参数是 `[key, value]` 对，第二个是索引。
- Hash 上带两个参数的 `each`：直接是 `key, value`；带一个参数时：是 `[key, value]` 对。
- 对 `nil`、`Time` 或任何标量进行迭代会引发 `RuntimeError`（`"undefined method 'each' for Time"`）——从不悄悄地什么都不做。
- 块参数只在循环期间遮蔽同名的外层局部变量，循环结束后即被移除（循环结束后 `refute env.key?("item")`）。块之前就已存在的变量在块内是*同一个*变量（循环之后也可见）；**首次在块内赋值**的变量是块局部变量——每次迭代开始时为 `nil`，之后消失。

### 块调用（辅助方法）

`do ... end` 也是不带接收者的辅助方法调用接收块的方式——这是块唯一的另一种合法用法，并且只在没有接收者时可用（`f.each do |x| end` 会被拒绝：“blocks are only supported on each, each_with_index and helper calls”）：

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

块的结果是否输出取决于标签：`<%= helper do |x| %>` 会输出它，`<% helper do |x| %>` 会丢弃它。始终只绑定一个块参数；辅助方法的块永远不会得到索引或第二个值。

### 赋值

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

只支持对单个普通局部变量的 `name = expr`——没有 `@ivar = ...`，没有 `arr[0] = ...`/`h[:k] = ...`，也没有 `a, b = ...`。`each` 中的块局部规则同样适用于嵌套在块中的 `if`/`unless` 内部的赋值。

## 各类型的方法表

`nil?`、`present?` 和 `blank?` 在按类型分派**之前**检查，所以它们对每个值都有效，包括模型和辅助方法返回的对象（除了 `nil`/`false`/空的 `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params` 之外，`blank?` 对任何值都为 `false`）。算术运算（`+ - * / %`）和比较运算（`== != < > <= >=`）只以**中缀运算符**的形式存在，从不作为 `.method` 调用——在这套语法中，运算符符号永远不能跟在 `.` 之后。

| 类型 | 方法 | 示例 |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values`，以及 `h[key]` | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`，以及 `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`，以及 `params[key]` | `params[:id]` |
| `Page`（`Relation#page`） | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s`（返回 `""`） | |

索引（`x[key]`）是一条独立的语法产生式（[表达式](#expressions)），而不是 `.[]` 调用：`Array`/`String` 接收整数索引，`Hash` 按 `to_s` 匹配任意键（`h[:k]` 和 `h["k"]` 是同一个条目），`Errors` 按符号匹配，`Params` 按 `to_s` 匹配。

除上面的 `to_s` 之外的输出（`<%= %>`/插值）：`Array` 输出为类似 inspect 的列表——`[1, "a", nil]` 渲染为文本 `[1, "a", nil]`（然后被转义，所以引号会变成 `&quot;`）；`Hash` 退回到 Ruby 自己的 `Hash#to_s`；`Cybertrain::Model` 输出为 `#<Post id: 7>`（从不输出其属性）；其他任何对象通过自己的 `to_s` 输出。在上述任何类型上调用未列出的方法都会引发 `RuntimeError`（`"undefined method 'first' for Time"`）。`Integer` 除以零或对零取模为 `"divided by 0"`；`Float` 则遵循 IEEE-754（`Infinity`/`NaN`，不报错）。

## 模板中的模型

`Cybertrain::Model` 的子类（生成的 `Post`、`Note` 等）按以下顺序解析不带修饰的名称（`Interpreter#model_method`）：

1. 五个内置方法，始终可用：`id`、`persisted?`、`new_record?`、`to_param`（`id.to_s`）、`errors`（一个 `Errors`，见[各类型的方法表](#per-type-method-table)）。
2. `read_attribute(:name)`——生成的列。
3. `read_association(:name)`——生成的 `has_many`/`belongs_to`。
4. `call_view_method(:name)`——模型生成器在 `app/models/**/*.rb` 中找到的手写的、无参数的 `def`（永远不带参数）。

```erb
<%= post.title %>            <%# read_attribute %>
<% post.comments.each do |c| %>...<% end %>   <%# read_association %>
<%= post.summary %>          <%# call_view_method %>
<%= post.errors.full_messages.join(", ") %>
```

如果四者都返回 `nil`，就由 `attribute_or_method?(:name)` 判断这是一个只是值为 `nil` 的合法名称（返回 `nil`），还是一个拼写错误（`"undefined method 'bogus' for Post"`）。

**实际实现中有一个真正的缺口，解释器文件本身也标注了它**（参见 `interpreter.rb` 中 `class Model` 上方的 `TODO(integrator)` 注释）：*基类* `Cybertrain::Model#attribute_or_method?` 总是返回 `true`。只有用显式的 `case` 覆盖了它的生成模型（就像手写的测试模型那样）才会在拼写错误时真正抛出异常；没有这个覆盖时，拼错的属性或方法会悄悄地渲染为空，而不是失败。除非你知道模型覆盖了这个钩子，否则不要假定拼写错误会被捕获。

两个模型用 `==` 按类和 `id` 比较（`Model#==`），通过普通的 `==` 运算符即可使用（原生的相等分派，而不是 `call_method`）。

## 辅助方法与表单构建器

每个不带接收者的调用都交给 `Helpers#helper_call`（`helpers.rb`），它要么匹配下面的某个内置辅助方法，要么把以 `_path`/`_url` 结尾的名称当作生成的路由辅助方法（通过 `Cybertrain::Views.url_resolver`，在应用安装解析器之前会抛出 `"no routes"`），否则抛出 `"undefined helper 'name'"`。

| 辅助方法 | 签名 | 说明 / 示例 |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` 会被转义，除非它已经是 `SafeString`；**没有 `method:`**——使用它会抛出异常，提示你改用 `button_to`（不用 rails-ujs/turbo 伪造 DELETE 链接） |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | 只有一个按钮的 `<form class="button_to">`；`get`/`post` 以外的任何动词都带隐藏的 `_method`，存在会话时还带 CSRF 字段 |
| `form_with` | `form_with(model:, url:, method:, class:, multipart:) do \|f\| ... end` | 需要一个块；`model:` 为新记录 → 集合路由 + POST，已持久化 → 成员路由 + PATCH；嵌套路由用 `[parent, child]`；`url:`/`method:` 会覆盖推导出的动作/动词；`multipart: true` 会加上 `enctype="multipart/form-data"`（`f.file_field` 需要它；它从不根据块推断，在 GET 表单上会抛出 `ArgumentError`） |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` | 参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials) |
| `h`、`escape` | `h(text)` | 进行转义；`SafeString` 不经转义直接通过 |
| `raw` | `raw(text)` | 把文本包装为 `SafeString`（不转义输出） |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`；`pluralize(2, "mouse")` → `"2 mice"`（Rails 默认的英语词形变化规则，经由 `Cybertrain::Inflector`；不支持应用自定义的词形变化）；显式给出的第三个参数总是优先 |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n)` | `1234567` → `"1,234,567"`；`-1000` → `"-1,000"`；`1234.5` → `"1,234.5"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails 风格的区间，不精确到秒：`"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`、`content_for(:key, "text")`、`content_for?(:key)` | 参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials) |
| `csrf_meta_tags` / `csrf_token` | | 没有控制器会话时为空 / 不存在 |
| `flash` | | 类似 `Hash`：`flash[:notice]` |
| `params` | | 当前的 `Cybertrain::Params` |
| `request_path` | | 当前路径，没有控制器时为 `""` |
| `url_for` | `url_for(target)` | `String` 原样返回，`Model` → 成员路由，`[parent, child]` → 嵌套路由 |
| `paginate` | `paginate(page, path)` | `page` 是一个 `Cybertrain::Page`（来自 `Relation#page`）；渲染 `<nav class="pager">`，其中有 “Newer”（`rel="prev"`）、`<span class="pager-current">Page N</span>` 和 “Older”（`rel="next"`），没有对应页面时省略相应链接。每个链接都是 `path` 加上当前请求的查询字符串，其中 `page` 被替换（第 1 页时去掉），并重新编码和进行 HTML 转义；带有自己 `?query` 的 `path` 则改用它自己的查询字符串。在模板中，`Page` 还响应 `number`、`per`、`row_offset`、`next?`、`prev?`、`next_number`、`prev_number`（`<% if @page.next? %>`） |
| `*_path` / `*_url` | 例如 `post_path(post)` | 由应用生成，通过 `Cybertrain::Views.url_resolver` 解析 |

每个辅助方法的文本参数都遵循同一条规则：`SafeString` 不经转义直接通过，其他任何内容都会被转义——`link_to raw('<b>raw</b>'), post` 会原样输出加粗标签，而 `link_to post.title, post` 会转义它。

### FormBuilder（`form_with ... do |f|` 中的 `f`）

每个方法都返回 `SafeString`；未列出的方法会引发 `RuntimeError`（`"undefined method 'color_wheel' for FormBuilder"`）。

| 方法 | 渲染结果 |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>`——默认文本是人性化后的属性名（`published_at` → “Published at”，`author_id` → “Author”）；显式给出的文本会被转义，除非它是 `SafeString` |
| `f.text_field :title`（还有 `email_field`、`password_field`、`number_field`、`date_field`、`hidden_field`） | `<input type="..." name="post[title]" id="post_title" value="...">`；`password_field` 从不输出 `value=` |
| `f.file_field :cover`（还可以加 `accept: "image/*"`、`required: true`） | `<input type="file" name="post[cover]" id="post_cover">`——从不输出 `value=`，属性也不必是列；表单必须是 `form_with ..., multipart: true`；`multiple: true` 会抛出 `ArgumentError`（每个字段一个文件） |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>`（开头有 `\n`，与 Rails 一样——浏览器会吞掉第一个换行符） |
| `f.check_box :published` | 先是隐藏的 `value="0"` 输入框，然后是真正的复选框，所以未勾选的复选框仍会提交 `"0"` |
| `f.submit` / `f.submit "Text"` | 默认文本为 `"Create Post"`/`"Update Post"`（根据 `persisted?`），没有模型时为 `"Save changes"` |

有模型时，字段命名为 `post[title]`/`id="post_title"`（以 `Inflector.underscore(model.model_name)` 作为作用域）；使用 `form_with(url: ...)` 且没有模型时，两者都直接使用属性名。额外的关键字参数按给出的顺序变为 HTML 属性：`true` → `attr="attr"`，`false`/`nil` 被丢弃，其他任何值 → `attr="value"`（经过转义），下划线变为连字符（`data_confirm: "Sure?"` → `data-confirm="Sure?"`），并且 `class:` 会与 `model.errors.key?(attr)` 时自动添加的 `field_with_errors` 类合并。

## 布局、`yield`、`content_for`、局部模板

`Engine#render_with_layout(name, layout, env, helpers)` 把 `name` 渲染到 `env["__content"]`（一个 `SafeString`）中，然后用同一个 `env` 渲染 `layout`：

```erb
<title><%= yield :title %></title>
<%= yield %>
```

`yield` 输出 `env["__content"]`；`yield :key` 输出 `env["__content_key"]`，未设置时什么都不输出。`yield` 在解释器中被直接特殊处理，不能作为辅助方法被覆盖。页面用 `content_for` 填充一个槽位，可以写在页面主体的任何位置（相对于 `yield` 的顺序无关紧要——页面会在布局之前完整渲染）：

```erb
<% content_for :title do %>Post: <%= @post.title %><% end %>
<% content_for :title, " (draft)" %>   <%# appends: calls accumulate, they don't replace %>
```

### 局部模板与 `render`

```erb
<%= render "form", post: @post %>
<%= render partial: "form", locals: { post: @post } %>
<%= render "comments/comment", comment: c %>
```

- 不含 `/` 的名称在**当前模板自己的目录**中解析（通过渲染机制设置的一个 env 键 `__template_dir`）：在 `posts/show` 中 `render "form"` 会查找 `posts/_form.html.erb`。含有 `/` 的名称是显式路径；只有它的最后一段会加上 `_` 前缀（`"comments/comment"` → `comments/_comment.html.erb`）。
- 局部模板得到的是**调用者整个环境的副本**（实例变量以及作用域中已有的任何局部变量），再加上传给 `render` 的显式局部变量——它并没有被隔离到只能访问传入的内容。严格局部变量只会根据声明的列表校验**显式传给那次 `render` 调用的名称**；它们并不阻止局部模板读取从调用者环境继承来的其他名称。
- 只有 `content_for` 的键（`__content_*`）会从局部模板的作用域复制回调用者的作用域；它所赋值的普通局部变量不会泄漏回去。
- 相对于 `<%# locals: %>` 声明缺少或多出的局部变量会引发 `RuntimeError`：`"missing local 'post' for posts/_form.html.erb"`、`"unknown local 'extra' for posts/_form.html.erb"`。

### 文件解析（`engine.rb`）

`"posts/show"` 和 `"posts/show.html.erb"` 指的是同一个模板。开发环境以 `cache: false` 从磁盘读取 `app/views/`（文件的 mtime 或大小一旦变化，就重新读取并重新解析）；测试环境以 `cache: true` 从磁盘读取（只解析一次）。生产环境的二进制文件从不访问磁盘：`cybertrain build` 运行 `spin run gen -- --embed-views`，它把 `app/views/` 下的每个 `*.erb`（跳过点文件和符号链接目录）写入 `gen/views.rb`，`Engine.embedded(sources)` 对每个条目解析一次（错误消息保持同样的 `posts/show.html.erb:12` 形式）；表为空的二进制文件在生产环境中拒绝启动。缺失的模板会引发 `Cybertrain::Template::MissingTemplate`——来自磁盘时为 `"Missing template <full path>"`，来自表时为 `"Missing template posts/nope.html.erb (embedded)"`。

文件查找会通过符号链接解析视图根目录和模板路径，并且只加载该根目录内的普通文件。逃出该目录的路径（包括通过符号链接）会引发 `MissingTemplate`；对于这些路径，`exists?` 返回 false。

## 错误

有两个异常类，都位于 `ast.rb` 的 `Cybertrain::Template` 命名空间中（与 `::SyntaxError`/`::RuntimeError` 不同）：

- **`SyntaxError`**——在分词/解析期间、任何解释执行之前抛出。形式：`"<template>:<line>: <what>"`，例如 `"posts/show:2: 'if' without 'end'"`、`"posts/show:1: unterminated <% tag"`、`"posts/show:1: unexpected ')' in 'foo(1))'"`。当页面或布局文件解析失败时，由 `Engine#template`（因而也由 `#render`/`#render_with_layout`）直接抛出——从不被解释器捕获或重新包装。
- **`RuntimeError`**——在求值期间抛出，消息形式相同，但 `<template>` 是*当前正在渲染*的那个模板（`Interpreter#render` 会切换 `@name`）——局部模板自己的错误保留局部模板的名称和行号，而不是调用者的：`"posts/_row:1: undefined method 'bogus' for String"`。

来自辅助方法或 `FormBuilder`/自定义对象方法调用的任何普通 `StandardError`（单纯的 `raise "text"`、`ArgumentError`、`KeyError`，甚至来自嵌套 `render` 的 `Cybertrain::Template::RuntimeError`）都会被捕获并“重新定位”：改写为 `"<current template>:<current line>: <original message>"`，除非它恰好已经是上一次重新定位的消息（嵌套的 `render` 已经标上了它自己更具体的位置），这种情况下它原样通过。由辅助方法抛出的 `Cybertrain::Template::SyntaxError`（在渲染中途解析失败的局部模板）从不被重新包装——它保留自己的 `"<partial>:<line>: ..."` 消息和类，所以损坏的局部模板总是被报告为关于它自身的 `SyntaxError`，而不是关于渲染它的那个模板的 `RuntimeError`。

`MissingTemplate`（`StandardError`，`engine.rb`）从顶层的 `Engine#template`/`#render`/`#render_with_layout` 调用中（例如控制器渲染缺失的动作模板或布局）**不经包装**地抛出，不带 `template:line` 前缀：`"Missing template <path>"`。同一个异常如果是在模板*内部*通过 `render` 辅助方法查找局部模板时抛出的，则会经过重新定位，最终成为 `RuntimeError`：`"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`。

## 与 Rails ERB 的差异

| Rails ERB | Cybertrain |
| --- | --- |
| 编译为 Ruby 方法；任何 Ruby、任何对象、任何方法都可以 | 按固定的、按类型划分的分派表解释执行；只能调用[各类型的方法表](#per-type-method-table)列出的内容 |
| `ActiveSupport::SafeBuffer` 是 `String` 的子类 | `SafeString` 是一个独立的包装类——在它上面只能调用 `to_s`/`html_safe?`/`size`/`length`/`empty?` |
| 块：`each`、`{ }`、`map`、任何 Enumerable 方法 | 只有 `do...end`，并且只能用于 `each`/`each_with_index`/辅助方法调用 |
| `xs.each { }`——零个块参数没有问题 | `each`/`each_with_index` 要求声明 1 个或 2 个块参数 |
| `link_to text, path, method: :delete`（由 JS 驱动） | `link_to` 上没有 `method:`——要发出真正的非 GET 表单请使用 `button_to` |
| 严格局部变量接受 `name: default_expr`（Rails 7.1） | 只能写不带修饰的 `name:`（必需）；带默认值的条目是 `SyntaxError` |
| 未定义的实例变量/局部变量通过 Ruby / 视图上下文的方法解析 | `@x` 是简单的、从不失败的 env 查找；未定义的裸局部变量是一次显式的、封闭的辅助方法调用尝试（找不到时为 `"undefined helper"`） |
| `and`/`or`/`not`、`case/when`、范围、正则表达式、多重赋值都可以使用 | 这些都不存在；保留字会以专门的 “not supported in templates” 消息失败，而不是一般的解析错误 |
| 数字字面量：十六进制、八进制、二进制、指数、有理数 | 只有十进制整数/浮点数，可以用 `_` 作分隔符 |
| `:"quoted symbol"`、`:+` 运算符符号 | 符号只能由标识符字符组成 |
| `foo (x)`、`foo [x]`（允许空格，有时会给出警告） | 两者都是硬性的 `SyntaxError`——调用的 `(` 或索引的 `[` 之前不能有空格 |
| 嵌套的无括号调用由 Ruby 自己的解析器解析 | 只有表达式中最外层的调用可以使用无括号参数 |
| 未声明/拼错的属性必定会抛出 `NoMethodError` | 会悄悄地渲染为空，除非特定的生成模型覆盖了 `attribute_or_method?`（已记录的缺口，并非保证） |
| `1 / 0` 和 `1.0 / 0` 都会抛出 `ZeroDivisionError` | `Integer` 除以零或对零取模会抛出 `"divided by 0"`；`Float` 遵循 IEEE-754（`Infinity`/`NaN`），不报错 |
| `distance_of_time_in_words`/复数化支持 i18n 语言区域 | 仅限英语，不支持语言区域 |
