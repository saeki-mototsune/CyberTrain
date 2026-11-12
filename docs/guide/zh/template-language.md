---
source_sha256: 2f2c328fde36b079acea86515c42f22d3af9b2c18510dfd6025c30023d98325b
---
# Cybertrain 模板语言参考

Cybertrain 的视图（`app/views/**/*.html.erb`）看起来像 Rails 的 ERB，但并不是 Ruby：它们在运行时被解析（在开发和测试环境中从磁盘上的 `app/views/` 读取；在生产环境的二进制文件中则来自 `cybertrain build` 通过 `gen/views.rb` 嵌入的字符串表），经过分词并解析为 AST，一次性编译为扁平的节点树，再由一个遍历树的解释器执行。

本文档准确描述这条流水线接受和执行的内容。凡是它与 `docs/design.md` 第 7 节（最初的规格草案）或 Rails 开发者的预期不一致的地方，都以代码为准，本文档也会指出（搜索“**实际实现**”）。

## 这里什么是 Ruby，什么不是

模板**不是** Ruby。Spinel（cybertrain 所面向的 Matz-Ruby AOT 编译器）没有 `eval`，所以“在请求时解释视图自身的 Ruby 代码”从来就不在考虑之列（`docs/design.md` 中的 D9）；实际运行的是一套小巧、封闭的语法，只是披着 ERB/Ruby 风格的外衣。标签内不能写任意 Ruby——只能写 `ExprParser`（`parser.rb`）识别为语句或表达式的内容。没有 `eval`、`send`、`instance_eval`、方法/类/模块定义、`require`、异常（`begin/rescue`）、范围、正则表达式或多重赋值。块只出现在本文档列出的地方：`each`/`each_with_index`/`each_slice` 循环、Array 和 Hash 的一组固定方法（`map`、`select`、`sum`、`group_by` ……——参见[块](#blocks)）、辅助方法调用（`form_with(...) do |f| ... end`）以及 `tag` 构建器。每个方法调用（`recv.name`）都由 `interpreter.rb` 中手写的 `case` 分派表解析，以接收者在运行时的 Ruby 类为键；不在该类型表中的名称会以 `RuntimeError` 失败——没有 `method_missing`，没有反射，并且（见 `Interpreter#call_method`）正是因为 Spinel 没有 `send`，这里才是一个 `case`，而不是元编程的查找。模板只能做本文档所描述的事情。

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
- 以下单词是保留字，在任何需要表达式的地方都会以专门的消息（`"'x' is not supported in templates"`）被拒绝：`and or not do end if unless elsif else then while until def class module begin rescue return`。`case` 和 `when` 是独立的语句（[`case`](#case)）；在表达式内部（`<%= case x %>`）它们同样会被拒绝。

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

- 主体只求值一次；每个 `when` 的值（一个或多个，用逗号分隔）按顺序用模板的 `==` 比较，第一个值相等的分支运行。数字按值比较（`1` 匹配 `1.0`）；String 和 Symbol 按值和类型比较（`"a"` 不匹配 `:a`）；记录按 `==` 的方式比较（类和 `id`）；Array 和 Hash 也按 `==` 的方式比较（按值，逐个元素）；文本相同的 `SafeString` 和 `String` 相等。没有 `===`：`when` 之后不能写范围、类或正则表达式。
- 没有值匹配时运行 `else`；既没有 `else` 也没有匹配时，什么都不输出。
- `case` 与其第一个 `when` 之间只能有空白文本（缩进、换行），它会被丢弃。那里出现其他任何内容都是 `SyntaxError`（`"text between 'case' and its first 'when'"`）。
- `case` 之外的 `when`（`"'when' without 'case'"`）、没有主体或没有 `when` 的 `case`、没有值或位于 `else` 之后的 `when`，以及始终没有用 `end` 关闭的 `case`，都是指明行号的 `SyntaxError`。`then` 仍是保留字：`<% when :a then x %>` 是 `SyntaxError`。
- 在分支中首次赋值的局部变量，与 `if` 一样，遵循它所在块的块局部规则。

### 循环

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` 只有作为块头的后缀（`x.each do |...|`）时才会被识别；集合可以是任意表达式，包括带块的调用（`<% items.group_by { |i| i.kind }.each do |kind, list| %>`）。**实际实现**：两者都要求声明一个或两个块参数——`xs.each do end` 是 `SyntaxError`（“takes one or two block parameters”），而普通的 Ruby 允许零个。
- `<% x.each_slice(n) do |slice| %>...<% end %>` 依次遍历每 `n` 个元素的切片（最后一片可能更短），同样需要一个或两个参数；有两个参数时切片会被拆开（`do |a, b|`），切片不够长时第二个为 `nil`。
- Array 加一个参数：元素本身。Array 加两个参数：`Array` 类型的元素会被解构（`a, b = item[0], item[1]`）；否则第二个参数为 `nil`。
- Array 上的 `each_with_index`：`item, i`。Hash 上的：第一个参数是 `[key, value]` 对，第二个是索引。
- Hash 上带两个参数的 `each`：直接是 `key, value`；带一个参数时：是 `[key, value]` 对。
- 对 `nil`、`Time` 或任何标量进行迭代会引发 `RuntimeError`（`"undefined method 'each' for Time"`）——从不悄悄地什么都不做。
- 块参数只在循环期间遮蔽同名的外层局部变量，循环结束后即被移除（循环结束后 `refute env.key?("item")`）。块之前就已存在的变量在块内是*同一个*变量（循环之后也可见）；**首次在块内赋值**的变量是块局部变量——每次迭代开始时为 `nil`，之后消失。

### 块调用（辅助方法）

`do ... end` 也是不带接收者的辅助方法调用接收块的方式（带接收者的调用参见[块](#blocks)）：

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

块的结果是否输出取决于标签：`<%= helper do |x| %>` 会输出它，`<% helper do |x| %>` 会丢弃它。始终只绑定一个块参数；辅助方法的块永远不会得到索引或第二个值。

### 块

带接收者的调用可以接收一个块，`{ |x| expr }` 或 `do |x| ... end`，带零个、一个或两个参数。哪些方法接受块是按类型固定的；其他任何地方的块都是在调用运行时抛出的 `SyntaxError`（`"String#upcase takes no block"`），而类型没有的方法，无论带不带块，都是通常的 `"undefined method 'x' for Array"`。

| 接收者 | 接受块的方法 | 块的值用作 |
| --- | --- | --- |
| `Array` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | 映射后的值、判断条件、被加数、排序键、分组键 |
| `Hash` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | 同上，块看到的是 `\|key, value\|`（一个参数时得到 `[key, value]` 对）；`select`/`reject` 返回 Hash，其他方法返回 Array 的方法对这些键值对返回的结果 |
| `tag` 构建器 | 每个元素（`tag.div do ... end`） | 它的**输出**就是元素的内容（[tag 构建器](#the-tag-builder)） |

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

- **是值，不是输出。** 对 Array 和 Hash 的方法来说，起作用的是块的*值*：`{ }` 块的表达式，或 `do` 块的最后一条语句，它必须是表达式语句（`<% x * 2 %>`）；否则（赋值或文本）就是 `"map's block must end in a value"`。`do` 块前面的语句输出的内容会被丢弃。这类方法上的 `do` 块独占一个标签，要么赋值（`<% total = items.sum do |li| %>`），要么输出（`<%= items.map do |x| %>`）。
- **不能修改。** 模板无法改变累加器，所以 `each_with_object` 和 `inject` 不在表中（`"undefined method 'each_with_object' for Array"`）：请使用 `map`、`select`、`sum` 或 `group_by`。
- 两个参数会像 `each` 那样拆开 Array 的元素（`pairs.map { |a, b| a }`）。
- 空 Array 的 `sum` 是 `0`；Integer 相加得到 Integer，只要有一个 Float 就得到 Float（使用与 Ruby 相同的补偿算法相加，所以 `[0.1, 0.2, 0.3].sum` 是 `0.6`）；String 会被拒绝（`"sum: use join for Strings"`），任何不是数字的值也一样。
- `sort_by`、`min_by`、`max_by`（以及不带块的 `sort`、`min`、`max`）按 `<` 的方式比较（数字、String、Time；否则为 `"comparison of String with Integer failed"`）。`sort_by` 是稳定的：相等的键保持原有顺序。空 Array 的 `min_by`/`max_by` 为 `nil`。
- `group_by` 返回一个 Hash，从每个**转为 String 的**键（模板中的 Hash 一律以 String 为键：`:fruit` 和 `"fruit"` 是同一组）映射到具有该键的元素，按首次出现的顺序排列。
- `each`、`each_with_index` 和 `each_slice` 在 `<% %>` 标签中接收块（[循环](#loops)）；`items.each { |x| x }` 是 `SyntaxError`。
- `FormBuilder` 或 `Page` 方法上的块同样会被拒绝（`"FormBuilder#label takes no block"`），不带块的 Array 方法不接受参数（`nums.sum(10)` 是 `"wrong number of arguments for 'sum'"`）。
- 如果块抛出异常，在错误离开调用之前，它的参数和局部变量会被恢复。
- `{ }` 块需要接收者：`shout { |x| x }` 是 `SyntaxError`（辅助方法调用接收 `do ... end`）。
- 块参数在调用期间遮蔽外部同名变量，调用之后恢复；在 `do` 块中首次赋值的局部变量是块局部的，与 `each` 中一样。

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
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` `sum` `min` `max` `sort` `uniq` `compact` `flatten` `take(n)` `drop(n)` `each_slice(n)`（由 Array 组成的 Array） `zip(other)`，以及[块](#blocks)中带块的方法 | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values` `to_a`（`[key, value]` 对），以及 `h[key]` 和[块](#blocks)中带块的方法 | `flash.key?(:notice)` |
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

每个不带接收者的调用都交给 `Helpers#helper_call`（`helpers.rb`），它先匹配下面的内置辅助方法；在[组件](#components)的模板中，接着尝试该组件的视图方法；把以 `_path`/`_url` 结尾的名称当作生成的路由辅助方法（通过 `Cybertrain::Views.url_resolver`，在应用安装解析器之前会抛出 `"no routes"`）；然后尝试[应用的辅助方法](#application-helpers)；否则抛出 `"undefined helper 'name'"`。

| 辅助方法 | 签名 | 说明 / 示例 |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` 会被转义，除非它已经是 `SafeString`；**没有 `method:`**——使用它会抛出异常，提示你改用 `button_to`（不用 rails-ujs/turbo 伪造 DELETE 链接） |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | 只有一个按钮的 `<form class="button_to">`；`get`/`post` 以外的任何动词都带隐藏的 `_method`，存在会话时还带 CSRF 字段 |
| `form_with` | `form_with(model:, url:, scope:, method:, class:, data:, multipart:, local:) do \|f\| ... end` | 需要一个块；`model:` 为新记录 → 集合路由 + POST，已持久化 → 成员路由 + PATCH；嵌套路由用 `[parent, child]`，命名空间路由用 `[:admin, @article]`；`url:`/`method:` 会覆盖推导出的动作/动词；`scope: :q` 把字段命名为 `q[term]`（与 `model:` 一起使用时替换模型的前缀）；`data: { turbo_frame: "f" }` 写出 `data-` 属性；`local:` 会被接受但不起作用；`multipart: true` 会加上 `enctype="multipart/form-data"`（`f.file_field` 需要它；它从不根据块推断，在 GET 表单上会抛出 `ArgumentError`） |
| `select_tag` | `select_tag(name, option_tags = nil, include_blank:, prompt:, multiple:)` | `select_tag "order", options_for_select([["Newest", "new"], ["Oldest", "old"]], "old")` → `<select name="order" id="order">...</select>`；不是 `SafeString` 的 `option_tags` 会被转义；`multiple: true` 把名称变为 `order[]`；其他关键字作为属性 |
| `options_for_select` | `options_for_select(choices, selected = nil)` | `f.select` 选项（见下文）的 `<option>` 行；`selected` 是一个值或值的 Array，按 String 比较 |
| `options_from_collection_for_select` | `options_from_collection_for_select(records, :id, :name, selected = nil)` | 每条记录一个 `<option>`，其值和文本的读取方式与 `f.collection_select` 相同 |
| `t`, `translate` | `t(key, default:, count:, locale:, name: value)` | 请求语言区域中 `key` 的文本，经过转义；`posts/index.html.erb` 中的 `t(".title")` 读取 `posts.index.title`，局部模板 `posts/_form.html.erb` 中读取 `posts.form.title`；以 `_html` 结尾的键输出其 HTML 并转义值（[国际化](i18n.md#looking-up-text)） |
| `l`, `localize` | `l(time_or_date, format: :short, locale:)` | 语言区域的 `time.formats` / `date.formats`，或使用语言区域星期名和月份名的 strftime 模式（[日期和时间](i18n.md#dates-and-times)） |
| `label_tag`, `text_field_tag`, `hidden_field_tag`, `submit_tag` | `label_tag(name, text = nil)`, `text_field_tag(name, value = nil)`, `hidden_field_tag(name, value = nil)`, `submit_tag(value = "Save changes")` | 不带模型的表单标签：`label_tag(:term)` → `<label for="term">Term</label>`；`hidden_field_tag` 写出 `autocomplete="off"`；`submit_tag` 的名称是 `commit`；其他关键字作为属性（`id:` 替换由名称得到的 id） |
| `check_box_tag` | `check_box_tag(name, value = "1", checked = false)` | 没有模型也没有隐藏字段的复选框，不勾选时什么都不发送：`check_box_tag :remember_me` → `<input type="checkbox" name="remember_me" id="remember_me" value="1">`；其他关键字参数是属性 |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` / `render partial: "comment", collection: @comments` / `render @comments` / `render component: "card", k: v` | 参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials)、[集合](#collections)和[组件](#components) |
| `h`、`escape` | `h(text)` | 进行转义；`SafeString` 不经转义直接通过 |
| `raw` | `raw(text)` | 把文本包装为 `SafeString`（不转义输出） |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`；`pluralize(2, "mouse")` → `"2 mice"`（Rails 默认的英语词形变化规则，经由 `Cybertrain::Inflector`，仅在英语页面中：其他语言区域中词保持不变；不支持应用自定义的词形变化）；显式给出的第三个参数总是优先 |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n, delimiter: ",", separator: ".")` | `1234567` → `"1,234,567"`； `-1000` → `"-1,000"`； `1234.5` → `"1,234.5"` |
| `number_with_precision` | `number_with_precision(n, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false)` | `111.2345` → `"111.235"`； `precision: 0` → `"111"` |
| `number_to_human` | `number_to_human(n, precision: 3, units: {})` | `1234` → `"1.23 Thousand"`, `1234567` → `"1.23 Million"`； `units: { thousand: "K" }` 替换单位的名称（`unit`、`thousand` … `quadrillion`） |
| `number_to_percentage` | `number_to_percentage(n, precision: 3)` | `100` → `"100.000%"` |
| `number_to_currency` | `number_to_currency(n, unit: "$", precision: 2, format: "%u%n")` | `1234.5` → `"$1,234.50"`； 负数会在格式前写出 `-` |
| `number_to_human_size` | `number_to_human_size(n)` | `1234` → `"1.21 KB"` (以 1024 为底)； `1` → `"1 Byte"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails 风格的区间，不精确到秒：`"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"`，取自语言区域的 `datetime.distance_in_words`（日语为 `"2分"`） |
| `content_for` / `content_for?` | `content_for(:key) do...end`、`content_for(:key, "text")`、`content_for?(:key)` | 参见[布局、`yield`、`content_for`、局部模板](#layouts-yield-content_for-partials) |
| `csrf_meta_tags` / `csrf_token` | | 没有控制器会话时为空 / 不存在 |
| `csp_meta_tag` / `content_security_policy_nonce` | | `<meta name="csp-nonce" content="...">` / 只有 nonce，即本次请求的 [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) nonce；没有策略生效时为 `""` |
| `javascript_tag` | `javascript_tag(nonce: true) do ... end`, `javascript_tag(js)` | 把内容放进 `<script>`（与 Rails 一样不转义：绝不要把请求数据放进去），`nonce: true` 且有策略生效时带上 nonce；`id:`、`type:`、`data:` 是属性 |
| `asset_path` | `asset_path("logo.svg")` | `/assets/logo-1a2b3c4d.svg`（参见[资源](assets.md#helpers)）；URL 或以 `/` 开头的路径原样返回 |
| `stylesheet_link_tag` | `stylesheet_link_tag("application", media:, nonce:)` | `<link rel="stylesheet" href="/assets/application-1a2b3c4d.css">`（缺少时加上 `.css`） |
| `javascript_include_tag` | `javascript_include_tag("legacy", nonce:)` | `<script src="/assets/legacy-1a2b3c4d.js"></script>`（缺少时加上 `.js`） |
| `image_tag` | `image_tag(source, alt:, size:, class:)` | `size: "16x16"`（或 `"16"`）时为 `<img src="/assets/logo-1a2b3c4d.svg" alt="Logo" width="16" height="16">`；不会自行生成 `alt`，`alt: ""` 会被写出 |
| `javascript_importmap_tags` | `javascript_importmap_tags(entry = "application")` | import map、每个预加载 pin 的 `modulepreload` 链接以及 `import "application"`，有策略生效时每个都带 nonce（[资源](assets.md#the-import-map)）；需要请求 |
| `flash` | | 类似 `Hash`：`flash[:notice]` |
| `params` | | 当前的 `Cybertrain::Params` |
| `request_path` | | 当前路径，没有控制器时为 `""` |
| `url_for` | `url_for(target, format:, anchor:, k: v)` | `String` 原样返回，`Model` → 成员路由，`[parent, child]` → 嵌套路由，`[:admin, record]` → 命名空间路由；关键字按路径辅助方法的方式附加（`url_for("/x", format: :csv)` → `/x.csv`） |
| `current_page?` | `current_page?(path)` | 这个 GET 或 HEAD 请求是否针对 `path`（不计末尾的斜杠；`path` 中有查询时，查询也必须一致）；记录或 Array 会经过 `url_for`；其他方法一律为 false；需要请求 |
| `paginate` | `paginate(page, path)` | `page` 是一个 `Cybertrain::Page`（来自 `Relation#page`）；渲染 `<nav class="pager">`，其中有 “Newer”（`rel="prev"`）、`<span class="pager-current">Page N</span>` 和 “Older”（`rel="next"`），没有对应页面时省略相应链接。每个链接都是 `path` 加上当前请求的查询字符串，其中 `page` 被替换（第 1 页时去掉），并重新编码和进行 HTML 转义；带有自己 `?query` 的 `path` 则改用它自己的查询字符串。在模板中，`Page` 还响应 `number`、`per`、`row_offset`、`next?`、`prev?`、`next_number`、`prev_number`（`<% if @page.next? %>`） |
| `*_path` / `*_url` | 例如 `post_path(post)`, `posts_path(page: 2, format: :json)` | 由应用生成，通过 `Cybertrain::Views.url_resolver` 解析；关键字进入查询字符串，`format:` 添加扩展名，`anchor:` 添加片段（[重定向与查询字符串](requests.md#redirects-and-query-strings)） |
| `tag` | `tag.div(content, attrs) do ... end` | tag 构建器：参见[tag 构建器](#the-tag-builder) |
| `content_tag` | `content_tag(name, content = nil, attrs)`，或带 `do` 块 | `content_tag "p", "<i>", class: "n"` → `<p class="n">&lt;i&gt;</p>`；规则与 `tag` 相同 |
| `safe_join` | `safe_join(array, sep = "")`（没有关键字参数） | 连接成一个 `SafeString`，转义每个尚不是 `SafeString` 的元素和分隔符：`safe_join([tag.b("a"), "<"], " ")` → `<b>a</b> &lt;` |
| `class_names` | `class_names(*values)` | Rails 的 `class_names`/`token_list`：String 和 Symbol 中的单词、Array（包括嵌套的）中的单词，以及值为真的每个 Hash 键的单词，每个单词只出现一次；关键字参数相当于再多一个这样的 Hash：`class_names("btn", active: @on, big: false)` → `"btn active"` |
| `dom_id` | `dom_id(record, prefix = "")`（前缀是位置参数，与 Rails 相同） | `"article_12"`，未保存的记录为 `"new_article"`，`dom_id(@article, "edit")` → `"edit_article_12"`（Ruby 中为 `Cybertrain::Html.dom_id`） |
| `turbo_stream_from` | `turbo_stream_from(*streams, ws: false)` | 一个让页面订阅这些流（String，或名为 `"articles:12"` 这样的记录）的 `<turbo-stream-source>`；`ws: true` 给出 `ws://`/`wss://` URL，并且需要请求。参见[实时](realtime.md#turbo-streams) |
| `signed_stream_name` | `signed_stream_name(*streams)` | 只有签名令牌，供手写的 JavaScript 使用 |
| `stream_source_path` | `stream_source_path(*streams, mode: "json")` | 带令牌和 `mode=json`（或 `"raw"`）的流端点路径 |
| `turbo_frame_tag` | `turbo_frame_tag(id_or_record, src:, loading:, target:, class:, data:) do ... end` | `<turbo-frame id="article_3" src="...">...</turbo-frame>`；记录会给出它的 `dom_id`；每个属性只在给出时写出 |
| `turbo_stream` | `turbo_stream.replace(target, partial:, locals:)`, `.update(target, html:)`, `.append(target) do ... end`, `.prepend`, `.before`, `.after`, `.remove(target)` | 一个 `<turbo-stream action="...">` 元素，用于 `*.turbo_stream.erb` 模板；目标是 DOM id 或记录；块、`partial:`（带 `locals:`）和 `html:` 恰好其一 |
| `time_tag` | `time_tag(time, text = nil, format:, class:, id:, title:, data:)`，或带块 | `<time datetime="2026-11-10T12:00:00Z">Tue, 10 Nov 2026 12:00:00 +0000</time>`；Date 给出 `2026-11-10`；没有 `format:` 时文本是语言区域的 `:default` 格式；`format:` 是格式名（`:short`、`:long` 或词典中的任何其他格式，由 `l` 按请求的语言区域格式化），或 strftime 的 String（使用英语的星期名和月份名；未知的指令会抛出异常，strftime 会读成别的意思的宽度或标志也一样：`%6L`，请用 `%6N`；`:` 只能用在 `%:z` 中；`%F %T %D %R %r %c %x %X %v` 不能带填充标志；数字上的宽度会替换它的填充，`%5e` 得到 `"    5"`） |

每个辅助方法的文本参数都遵循同一条规则：`SafeString` 不经转义直接通过，其他任何内容都会被转义——`link_to raw('<b>raw</b>'), post` 会原样输出加粗标签，而 `link_to post.title, post` 会转义它。

六个数字辅助方法来自 `Cybertrain::NumberHelper`，Ruby 代码可以用相同的关键字把它们作为模块函数调用（`Cybertrain::NumberHelper.number_to_currency(price, unit: "€")`）。它们接受 Integer、Float 或数字 String（decimal 列是 Float），并按其十进制文本的数字四舍五入，所以两种运行时的结果相同；其他任何值都会抛出 `ArgumentError`（`"number_with_delimiter: \"abc\" is not a number"`），超出 0 到 100 的精度也一样。在模板中，`nil` 渲染为 `""`（可为空的 decimal 列显示为空，和 Rails 一样）；从 Ruby 调用的 `Cybertrain::NumberHelper` 对 `nil` 仍会抛出 `ArgumentError`（`"number_with_delimiter: nil is not a number"`）。在模板中，默认值来自请求的语言区域（词典中的 `number.*`：日语的 `number_to_currency(1234)` 是 `"1,234円"`），给出的关键字参数优先；从 Ruby 调用时则是上面所示的英语默认值。

### tag 构建器

`tag` 求值为一个构建器（`Cybertrain::Html::TagBuilder`）；对它调用的任何方法都是一个元素，由 `Cybertrain::Html.tag` 渲染（也可以在 Ruby 中调用：`Html.tag("a", { href: "/x" }, "Go")`）：

```erb
<%= tag.div(class: "card") do %>
  <%= tag.h2 @article.title, id: dom_id(@article) %>
<% end %>
<%= tag.input type: "text", name: "q", disabled: true %>   <%# <input type="text" name="q" disabled> %>
<%= tag.path d: "M0 0 L10 10" %>                         <%# SVG elements work %>
<%= tag.my_widget data: { turbo_frame: "f" } %>          <%# <my-widget data-turbo-frame="f"></my-widget> %>
```

- 单独的 `<%= tag %>` 什么都不输出。
- 元素名是把方法名中的 `_` 换成 `-` 后的名称；它必须匹配 `[a-z][a-z0-9-]*`（否则 `Html.tag` 抛出 `"invalid element name 'Div'"`）。
- 内容是唯一的位置参数（除非是 `SafeString`，否则会被转义，所以 `tag.script("alert(1)")` 输出的是转义后的文本），或块的**输出**（`do ... end`，或值会被转义输出的 `{ expr }`）；块优先。两者都没有时，`tag.div` 为 `<div></div>`。
- 空元素（`area base br col embed hr img input link meta source track wbr`）渲染时没有结束标签；给它们内容或块是错误（`"br is a void element"`）。
- 属性就是关键字参数，按顺序：`nil` 和 `false` 去掉该属性，`true` 把它渲染为无值属性（`disabled`），Array 用空格连接其非 `nil` 的元素（`data: { ids: [1, 2] }` 得到 `data-ids="1 2"`，而不是 Rails 的 JSON），`class:` 接受 `class_names` 所接受的内容（`class: ["btn", { active: @on }]`），`data:` 和 `aria:` 的 Hash 展开为 `data-key="v"` / `aria-key="v"`，下划线变为连字符（在那里 `true`/`false` 也会写成文字）；其他任何 Hash 值都是错误（`"attribute 'title' cannot be a Hash"`）。每个值都会被转义，`SafeString` 也一样。属性名必须匹配 `[a-zA-Z_:][-a-zA-Z0-9_:.]*`（`"invalid attribute name 'data-a b'"`）；`onclick:` 之类是允许的，因为它们出自作者之手。

### FormBuilder（`form_with ... do |f|` 中的 `f`）

每个方法都返回 `SafeString`；未列出的方法会引发 `RuntimeError`（`"undefined method 'color_wheel' for FormBuilder"`）。

| 方法 | 渲染结果 |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>`——默认文本是人性化后的属性名（`published_at` → “Published at”，`author_id` → “Author”）；显式给出的文本会被转义，除非它是 `SafeString` |
| `f.text_field :title` (还有  `email_field`, `password_field`, `number_field`, `date_field`, `datetime_local_field`, `time_field`, `range_field`, `color_field`, `search_field`, `telephone_field`, `url_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`；`password_field` 从不输出 `value=`；`telephone_field` 是 `type="tel"`；Time 按浏览器读取的格式写出（`2026-11-10`、`2026-11-10T12:00:00`、`12:00:00.000`） |
| `f.select :status, ["draft", "published"]` (还有  `include_blank:`, `prompt:`, `selected:`, `disabled:`, `multiple:`) | `<select name="post[status]" id="post_status">`，每个选项一个 `<option>`，当前值被选中；选项可以是值、`[text, value]` 对，或用于 `<optgroup>` 的 Hash 或 `[label, [choices]]` 分组；`multiple: true` 把名称变为 `post[status][]` 并先写出一个空的隐藏输入框 |
| `f.collection_select :author_id, @authors, :id, :name` | 一个 `<select>`，每条记录一个 `<option>`，其值和文本从两个方法读取 |
| `f.radio_button :status, "draft"` | `<input type="radio" name="post[status]" id="post_status_draft" value="draft">`，值一致时被勾选（`checked:` 优先） |
| `f.file_field :cover`（还可以加 `accept: "image/*"`、`required: true`） | `<input type="file" name="post[cover]" id="post_cover">`——从不输出 `value=`，属性也不必是列；表单必须是 `form_with ..., multipart: true`；`multiple: true` 会抛出 `ArgumentError`（每个字段一个文件） |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>`（开头有 `\n`，与 Rails 一样——浏览器会吞掉第一个换行符） |
| `f.check_box :published` | 先是隐藏的 `value="0"` 输入框，然后是真正的复选框，所以未勾选的复选框仍会提交 `"0"`；`include_hidden: false` 不写出隐藏输入框 |
| `f.submit` / `f.submit "Text"` | 默认文本为 `"Create Post"`/`"Update Post"`（根据 `persisted?`），没有模型时为 `"Save changes"` |

有模型时，字段命名为 `post[title]`/`id="post_title"`（以 `Inflector.underscore(model.model_name)` 作为作用域）；`form_with(..., scope: :q)` 则改用 `q[title]`/`id="q_title"`；使用 `form_with(url: ...)` 且没有模型和作用域时，两者都直接使用属性名。每个属性值和选项文本都只转义一次（`SafeString` 原样使用）。额外的关键字参数按给出的顺序变为 HTML 属性：`true` → `attr="attr"`，`false`/`nil` 被丢弃，其他任何值 → `attr="value"`（经过转义），下划线变为连字符（`data_confirm: "Sure?"` → `data-confirm="Sure?"`），并且 `class:` 会与 `model.errors.key?(attr)` 时自动添加的 `field_with_errors` 类合并。

## 应用的辅助方法

`app/helpers/` 下的模块就是辅助方法模块，与 Rails 相同：其中的每个公开方法都可以在任何模板中不带接收者地调用。

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

- **生成的分派。** 模板不能 `send`，所以 `spin run gen` 把 `app/helpers/**/*.rb` 当作文本读取，并写出 `gen/helpers.rb`：一个 include 了每个模块（以及路由辅助方法）的 `ApplicationHelpers` 类，和一个按辅助方法名称分派的 `case`。添加辅助方法或修改其签名后，下一次构建会重新生成它（开发服务器两件事都会做）。`cybertrain generate helper prices` 会写出一个空的 `PricesHelper` 和一个测试。
- **什么是辅助方法。** `module` 的公开实例方法（`def self.x`、setter 以及 `private` 或 `protected` 之后的一切都不算），不论在哪个文件中。模板按位置或关键字传值，所以每个参数都必须有名称：`*rest`、`**opts`、`...` 是生成器错误，可选参数之后的必需参数也是。一个辅助方法最多有三个可选参数（生成的 `case` 对每种给出的组合有一个分支，因此省略的关键字会得到方法自身的默认值）。错误的调用在渲染时是 `ArgumentError`：`"wrong number of arguments for 'price' (given 0, expected 1)"`、`"unknown keyword 'cur' for 'price' (known: unit, precision)"`。
- **保留的名称。** 辅助方法不能使用框架辅助方法的名称（`link_to`、`render`、`tag`、`dom_id`、`params`、`content` 等）、`Cybertrain::Template::Helpers` 的方法名（无论公开还是私有：`include` 会连框架的那个方法也一起替换掉）、`yield`，也不能以 `_path` / `_url` 结尾（这些由路由辅助方法回答）；同一个名称出现在两个模块中也是错误。`spin run gen` 会停下来，指出文件、行号和原因。
- **值。** 参数以模板中的值（String、Integer、Float、`nil`、记录、Array、Hash）传入；做算术之前，请用 `Cybertrain::Cast`（`Cast.str`、`Cast.int`、`Cast.float`）收窄类型。辅助方法的返回值像其他值一样输出：`String` 会被转义，`SafeString` 不会，因此请用 `Cybertrain::Html.tag(name, attrs, content)`、`Html.safe_join`、`Html.class_names`、`Html.dom_id`、`Html.escape`、`Cybertrain::SafeString.of`，或链接辅助方法的 Ruby 形式 `link_to_path(text, path, attrs)` 和 `button_to_path(text, path, attrs)`（`method:` 放在 `attrs` 中）构造 HTML。
- **块。** 带 `&block` 参数的辅助方法接收一个 `do ... end` 块；`yield`（不带参数）以 `SafeString` 的形式返回块输出的内容。

## 组件

组件是一个接收关键字参数的类，旁边配一个模板，采用 [ViewComponent](https://viewcomponent.org) 的形式：

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

- 模板把组件的实例变量看作局部变量（`title`），按名称看到它不带参数的公开方法（`value_text`），以及 `content`，即 `do` 块输出的内容（没有块时为 `""`）。它在没有布局的情况下渲染，可以渲染局部模板和其他组件，并像局部模板一样计入 `max_render_depth`。它渲染的局部模板看不到组件的方法。组件模板中不带目录的局部模板名（`render "chip"`）在 `app/components/` 下查找（`app/components/_chip.html.erb`）；带目录的名字（`render "shared/note"`）照常在 `app/views/` 下查找。
- 组件用去掉 `_component` 的 snake_case 名称来指定，就像局部模板用路径来指定一样：`CardComponent` 为 `"card"`，`Admin::UserRowComponent`（`app/components/admin/user_row_component.rb`）为 `"admin/user_row"`。模板不能指名常量。
- `spin run gen` 像处理辅助方法一样，通过词法扫描写出 `gen/components.rb`：类定义行、`@x =` 赋值、不带参数的 `def`，以及 `initialize` 的关键字。`initialize` 只接受关键字参数（其中最多三个可选），并且它的模板必须存在；缺少关键字或出现未知关键字在渲染时是 `ArgumentError`。未知的组件是 `Cybertrain::Component::Unknown`：`` "no component 'crad' (app/components/crad_component.rb, then `spin run gen`)" ``。`content` 是保留名：同名的 `initialize` 关键字或 `@content` 实例变量会被块的输出覆盖，所以 `spin run gen` 会拒绝它，并指出文件和行号。`app/views/components/` 仍然是和其他目录一样的视图目录（属于 `ComponentsController`）；只有 `app/views/__components/` 是保留的，组件模板就存放在这个名称下。
- `cybertrain generate component card title value:integer` 会写出这个类、它的模板，以及一个用 `Cybertrain::Test.render_component` 渲染它的测试。

### 在请求之外渲染

广播、作业或邮件正文在没有请求的情况下渲染：

```ruby
html = Cybertrain::Views.render_partial("articles/article", article: article)   # app/views/articles/_article.html.erb
card = Cybertrain::Views.render_component(CardComponent.new(title: "Visitors", value: 12))
```

两者都会使用应用的辅助方法，以 String 返回 HTML。路径辅助方法可以使用（`article_path(article)`），strict locals 会被检查，表单（`form_with`、`button_to`）渲染时不带真实性令牌（Turbo 页面会提交来自 `csrf_meta_tags` 的令牌）。需要请求的辅助方法会抛出 `Cybertrain::Views::OutsideRequest`（`"csrf_token needs a request"`）：`csrf_token`、`csrf_meta_tags`、`params`、`flash`、`request_path`、`current_page?`、`content_security_policy_nonce`（因此还有 `csp_meta_tag` 和传入 `nonce: true` 的标签辅助方法）、`javascript_importmap_tags`、任何 `*_url` 辅助方法，以及 `turbo_stream_from ... ws: true`。`paginate` 的链接只带路径自身的查询字符串。（单元测试可能构造的裸 `Cybertrain::Template::Helpers.new(nil)` 则对它们返回空值。）

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

### 按控制器的布局

动作在 `app/views/layouts/application.html.erb`（存在时）中渲染，除非它的控制器、父类或包含的 concern 选择了另一个：

```ruby
class AdminController < ApplicationController
  layout "print", only: [:receipt]      # app/views/layouts/print.html.erb
  layout :choose_layout                 # 一个方法：名称，false 表示不用，nil 表示父类的

  private

  def choose_layout = request.header("Turbo-Frame").to_s.empty? ? "application" : "frame"
end
```

单独的 `layout "admin"` 为所有动作指定一个布局。`spin run gen` 读取 `layout` 行（带引号的名称、`false` 或方法的 Symbol，可带 `only:` / `except:`），并写出控制器的 `controller_layout(action)`。声明按顺序尝试，**第一个适用的胜出**（Rails 中后面的声明会替换前面的）；concern 的行在其 `include` 处计入。`render layout: "x"` 在一次调用中使用 `layouts/x`，`render layout: false` 则不用布局；开头的 `layouts/` 是被接受的（`layout "layouts/x"` 就是 `layouts/x`）。指向不存在布局的 `layout` 行或 `render layout:` 会抛出 `MissingTemplate`；只有默认的 `application` 布局是可选的（此时动作不带布局渲染）。只有 html 在布局中渲染；其他格式的模板不带布局渲染。其他任何 `layout` 参数（`nil`、lambda、常量）都会被 gen 拒绝。

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

### 集合

```erb
<%= render partial: "comment", collection: @comments, as: :comment, spacer_template: "divider" %>
<%= render @comments %>      <%# each record's comments/_comment.html.erb %>
<%= render @comment %>       <%# one record, no counter %>
<%= render component: "comment", collection: @comments %>
```

- `collection:` 对 Array 的每个元素渲染一次局部模板，元素作为 `as:` 指定的局部变量（默认是局部模板自己的名称），`<as>_counter` 从 0 开始计数，`locals:` 传给每一次，`spacer_template:`（一个局部模板）放在元素之间；空集合什么都不渲染。使用严格局部变量的局部模板只有声明了计数器才会得到它，并且元素优先于同名的局部变量。
- `render @comments` 根据每条记录的模型选择局部模板：`<plural>/_<singular>`（`Admin::Note` 对应 `admin/notes/_note`），所以列表可以混合不同的模型。
- 唯一必需关键字以自身命名的组件（带 `comment:` 的 `CommentComponent`）会得到 `CommentComponent.with_collection(items)`，`render component: "comment", collection: @comments` 会为每个元素渲染一次，在 `initialize` 声明了 `comment_counter:` 时传入它。`collection:` 不接受其他关键字（`render component: "comment", collection: @comments, extra: 1` 是一个点出该关键字的错误）；块的内容不会被传入。

### 文件解析（`engine.rb`）

`"posts/show"` 和 `"posts/show.html.erb"` 指的是同一个模板。开发环境以 `cache: false` 从磁盘读取 `app/views/`（文件的 mtime 或大小一旦变化，就重新读取并重新解析；这次重新解析会写入引擎的缓存，所以开发服务器总是只用一个 worker 运行，忽略 `SPINEL_WORKERS`，并在启动横幅中说明这一点）；测试环境以 `cache: true` 从磁盘读取（只解析一次）。生产环境的二进制文件从不访问磁盘：`cybertrain build` 运行 `spin run gen -- --embed-views`，它把 `app/views/` 下的每个 `*.erb`（跳过点文件和符号链接目录）写入 `gen/views.rb`，`Engine.embedded(sources)` 在二进制文件启动时把每个条目解析一次（错误消息保持同样的 `posts/show.html.erb:12` 形式），因此有语法错误的模板会让启动失败，而不是让它的页面失败；表为空的二进制文件在生产环境中拒绝启动。缺失的模板会引发 `Cybertrain::Template::MissingTemplate`——来自磁盘时为 `"Missing template <full path>"`，来自表时为 `"Missing template posts/nope.html.erb (embedded)"`。

文件查找会通过符号链接解析视图根目录和模板路径，并且只加载该根目录内的普通文件。逃出该目录的路径（包括通过符号链接）会引发 `MissingTemplate`；对于这些路径，`exists?` 返回 false。

## 错误

有两个异常类，都位于 `ast.rb` 的 `Cybertrain::Template` 命名空间中（与 `::SyntaxError`/`::RuntimeError` 不同）：

- **`SyntaxError`**——在分词/解析期间、任何解释执行之前抛出。形式：`"<template>:<line>: <what>"`，例如 `"posts/show:2: 'if' without 'end'"`、`"posts/show:1: unterminated <% tag"`、`"posts/show:1: unexpected ')' in 'foo(1))'"`。当页面或布局文件解析失败时，由 `Engine#template`（因而也由 `#render`/`#render_with_layout`）直接抛出——从不被解释器捕获或重新包装。
- **`RuntimeError`**——在求值期间抛出，消息形式相同，但 `<template>` 是*当前正在渲染*的那个模板（`Interpreter#render` 会切换 `@name`）——局部模板自己的错误保留局部模板的名称和行号，而不是调用者的：`"posts/_row:1: undefined method 'bogus' for String"`。

来自辅助方法或 `FormBuilder`/自定义对象方法调用的任何普通 `StandardError`（单纯的 `raise "text"`、`ArgumentError`、`KeyError`，甚至来自嵌套 `render` 的 `Cybertrain::Template::RuntimeError`）都会被捕获并“重新定位”：改写为 `"<current template>:<current line>: <original message>"`，除非它恰好已经是上一次重新定位的消息（嵌套的 `render` 已经标上了它自己更具体的位置），这种情况下它原样通过。由辅助方法抛出的 `Cybertrain::Template::SyntaxError`（在渲染中途解析失败的局部模板）从不被重新包装——它保留自己的 `"<partial>:<line>: ..."` 消息和类，所以损坏的局部模板总是被报告为关于它自身的 `SyntaxError`，而不是关于渲染它的那个模板的 `RuntimeError`。

`Cybertrain::Views::OutsideRequest` 和 `Cybertrain::Component::Unknown` 同样不经包装、保留各自的类传递出去，所以 `Views.render_partial` 的调用者可以 rescue 它们。

`MissingTemplate`（`StandardError`，`engine.rb`）从顶层的 `Engine#template`/`#render`/`#render_with_layout` 调用中（例如控制器渲染缺失的动作模板或布局）**不经包装**地抛出，不带 `template:line` 前缀：`"Missing template <path>"`。同一个异常如果是在模板*内部*通过 `render` 辅助方法查找局部模板时抛出的，则会经过重新定位，最终成为 `RuntimeError`：`"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`。

## 与 Rails ERB 的差异

| Rails ERB | Cybertrain |
| --- | --- |
| 编译为 Ruby 方法；任何 Ruby、任何对象、任何方法都可以 | 按固定的、按类型划分的分派表解释执行；只能调用[各类型的方法表](#per-type-method-table)列出的内容 |
| `ActiveSupport::SafeBuffer` 是 `String` 的子类 | `SafeString` 是一个独立的包装类——在它上面只能调用 `to_s`/`html_safe?`/`size`/`length`/`empty?` |
| 块：`each`、`{ }`、`map`、任何 Enumerable 方法 | 在一组固定的 Array/Hash 方法上使用 `{ }` 和 `do...end`（没有 `each_with_object`、`inject`），`each`/`each_with_index`/`each_slice` 循环，辅助方法调用和 `tag` |
| `xs.each { }`——零个块参数没有问题 | `each`/`each_with_index` 要求声明 1 个或 2 个块参数 |
| `link_to text, path, method: :delete`（由 JS 驱动） | `link_to` 上没有 `method:`——要发出真正的非 GET 表单请使用 `button_to` |
| 严格局部变量接受 `name: default_expr`（Rails 7.1） | 只能写不带修饰的 `name:`（必需）；带默认值的条目是 `SyntaxError` |
| 未定义的实例变量/局部变量通过 Ruby / 视图上下文的方法解析 | `@x` 是简单的、从不失败的 env 查找；未定义的裸局部变量是一次显式的、封闭的辅助方法调用尝试（找不到时为 `"undefined helper"`） |
| 使用 `===` 的 `case/when`（范围、类、正则表达式） | 只使用 `==` 的 `case/when`（数字按值比较） |
| `and`/`or`/`not`、范围、正则表达式、多重赋值都可以使用 | 这些都不存在；保留字会以专门的 “not supported in templates” 消息失败，而不是一般的解析错误 |
| 数字字面量：十六进制、八进制、二进制、指数、有理数 | 只有十进制整数/浮点数，可以用 `_` 作分隔符 |
| `:"quoted symbol"`、`:+` 运算符符号 | 符号只能由标识符字符组成 |
| `foo (x)`、`foo [x]`（允许空格，有时会给出警告） | 两者都是硬性的 `SyntaxError`——调用的 `(` 或索引的 `[` 之前不能有空格 |
| 嵌套的无括号调用由 Ruby 自己的解析器解析 | 只有表达式中最外层的调用可以使用无括号参数 |
| 未声明/拼错的属性必定会抛出 `NoMethodError` | 会悄悄地渲染为空，除非特定的生成模型覆盖了 `attribute_or_method?`（已记录的缺口，并非保证） |
| `1 / 0` 和 `1.0 / 0` 都会抛出 `ZeroDivisionError` | `Integer` 除以零或对零取模会抛出 `"divided by 0"`；`Float` 遵循 IEEE-754（`Infinity`/`NaN`），不报错 |
| `distance_of_time_in_words`/复数化支持 i18n 语言区域 | `time_ago_in_words`、`distance_of_time_in_words`、数字辅助方法和 `time_tag` 读取语言区域的词典；`pluralize` 只做英语的词形变化（[国际化](i18n.md#helpers-that-follow-the-locale)） |
| `app/helpers` 中的每个模块都会被混入；签名任意；辅助方法可以覆盖框架的辅助方法 | 模块在构建时被扫描为生成的 `case`：只能用具名参数，最多三个可选参数，不能使用框架辅助方法的名称，也不能以 `_path`/`_url` 结尾（[应用的辅助方法](#application-helpers)） |
| ViewComponent：`render CardComponent.new(title: "x")`、`with_collection`、插槽 | 按名称 `render component: "card", title: "x"`，`content` 来自块，以唯一必需关键字命名的组件可用 `collection:`；没有插槽（[组件](#components)、[集合](#collections)） |
| 后面的 `layout` 行替换前面的 | 第一个适用的 `layout` 声明胜出（[按控制器的布局](#per-controller-layouts)） |
