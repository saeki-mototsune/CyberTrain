# Cybertrain Template Language Reference

Cybertrain views (`app/views/**/*.html.erb`) look like Rails ERB but are not Ruby: they are parsed at run time (from `app/views/` on disk in development and test; in a production binary from the string table `cybertrain build` embeds via `gen/views.rb`), tokenized and parsed into an AST, compiled once into a flat node tree, and walked by a tree-walking interpreter.

This document describes exactly what that pipeline accepts and executes. Where it disagrees with `docs/design.md` section 7 (the original spec draft) or with what a Rails developer would expect, the code wins, and this document says so (search for "**As built**").

## What is, and is not, Ruby here

Templates are **not** Ruby. Spinel (the Matz-Ruby AOT compiler cybertrain targets) has no `eval`, so "interpret the view's own Ruby at request time" was never on the table (D9 in `docs/design.md`); what runs instead is a small, closed grammar that only wears ERB/Ruby-looking syntax. There is no arbitrary Ruby inside a tag — only what `ExprParser` (`parser.rb`) recognizes as a statement or expression. There is no `eval`, `send`, `instance_eval`, method/class/module definitions, `require`, exceptions (`begin/rescue`), ranges, regexes, or multiple assignment. Blocks exist only where this document lists them: `each`/`each_with_index`/`each_slice` loops, a fixed set of Array and Hash methods (`map`, `select`, `sum`, `group_by` ... — see [Blocks](#blocks)), helper calls (`form_with(...) do |f| ... end`) and the `tag` builder. Every method call (`recv.name`) is resolved by hand-written `case` dispatch tables in `interpreter.rb`, keyed on the receiver's runtime Ruby class; a name missing from that type's table fails with a `RuntimeError` — there is no `method_missing`, no reflection, and (per `Interpreter#call_method`) Spinel's lack of `send` is exactly why this is a `case`, not a metaprogrammed lookup. A template can only do what this document describes.

<details><summary>Where this lives in the source — the eight files of the template pipeline</summary>

The pipeline lives in `cybertrain/template/`:

| File | Role |
| --- | --- |
| `lexer.rb` | Splits source into `<% %>`/`<%= %>`/`<%== %>`/`<%# %>` tags vs. plain text |
| `parser.rb` | `TreeBuilder` nests tags into an AST; `ExprParser` parses the expression grammar inside one tag |
| `ast.rb` | The AST node classes the parser produces |
| `inode.rb` | `Compile` flattens the AST into monomorphic `INode`s (an integer "kind" plus typed slots) for fast interpretation |
| `interpreter.rb` | Walks `INode`s against an `env` (`Hash<String, value>`); owns every per-type "what methods exist" table |
| `helpers.rb` | `link_to`, `form_with`, `render`, `pluralize`, ... — everything a template calls without a receiver |
| `form_builder.rb` | The `f` yielded by `form_with(...) do \|f\| ... end` |
| `engine.rb` | Loads `.html.erb` sources — from disk under a root, or from the embedded `gen/views.rb` table (`Engine.embedded`) — parses (and optionally caches) them, renders with a layout |

</details>

## Tags

| Tag | Meaning |
| --- | --- |
| `<% code %>` | Executes a statement; produces no output |
| `<%= expr %>` | Evaluates `expr` and prints it, HTML-escaped |
| `<%== expr %>` | Evaluates `expr` and prints it **without** escaping |
| `<%# comment %>` | Ignored (except the line-1 `locals:` form below) |

Whitespace control (`Lexer.tokenize`):

- A `<% %>`/`<%# %>` tag that is the **only** thing on its line (nothing but spaces/tabs on either side up to the newlines) silently swallows its own indentation and trailing newline, like Rails' ERB trim mode. `<%= %>`/`<%== %>` are **never** auto-trimmed this way, even alone on a line.
- `<%-` explicitly strips leading spaces/tabs before the tag, and `-%>` strips the one newline right after it — for any tag kind. Both are no-ops when something other than whitespace occupies that side of the line.
- `<%%` in text is a literal `<%`; `%%>` inside a tag is a literal `%>` that does not close the tag.
- `<% # a Ruby-style comment %>` (a code tag whose content starts with `#`) is ignored like `<%# %>`. A comment **after** real code in the same tag is not supported — `<% x = 1 # note %>` is a `SyntaxError`.
- Unterminated tags raise at lex time: `"posts/show:2: unterminated <% tag"`.

### The strict-locals comment

A comment tag whose content starts with `locals:` **and is the very first tag in the file, on line 1**, declares the only locals a template (almost always a partial) accepts:

```erb
<%# locals: (post:, comment:) %>
<%= post.title %>
```

- `<%# locals: () %>` (empty list) means "this partial takes no locals."
- Each entry must be a bare, lowercase `name:` (`Lexer.identifier?` accepts only `[a-z_][a-z0-9_]*`). **As built:** unlike Rails 7.1, entries cannot carry a default value — `<%# locals: (post:, comment: nil) %>`, the exact form Rails 7.1 supports, is a `SyntaxError`: `"t:1: bad strict locals entry 'comment: nil' (expected name:)"`, because `comment: nil` does not end in `:`. Every declared local is effectively required. A malformed spec (missing parens) raises `"t:1: bad strict locals comment (expected locals: (name:, ...))"`.
- **Without** this comment, a template declares no local list: `render` passes through whatever locals it is given, unchecked, and the template may also read anything already present in the caller's environment (see [Layouts, `yield`, `content_for`, partials](#layouts-yield-content_for-partials)).
- If anything precedes the comment on an earlier line (even one blank line), it is just an ordinary, inert comment, not a locals declaration.

## Expressions

### Literals

| Literal | Syntax | Notes |
| --- | --- | --- |
| Integer | `1`, `1_000` | underscores allowed; no hex/octal/binary/exponent |
| Float | `2.5`, `12_3.4_5` | a digit is required on both sides of `.`; no exponent form |
| String | `"..."`, `'...'` | double quotes interpolate and support escapes; single quotes only understand `\'` and `\\` |
| Symbol | `:title` | identifier characters only — no `:"quoted"`, no `:+`-style operator symbols |
| `nil` / `true` / `false` | | |
| Array | `[1, "a", :b]`, `[]` | elements are full expressions |
| Hash | `{ a: 1, b: "x" }`, `{}` | **symbol-style keys only**, same shape as keyword args; no `"key" => value` hashrocket |

Double-quoted strings interpolate `#{...}` (any full expression, nestable) and support `\n \t \r \0 \e \s`, `\"`, `\\`; any other escaped character passes through unchanged. A string with no `#{}` compiles to a plain literal; one with interpolation compiles to a sequence of literal pieces and expressions.

### Variables

- **`@ivar`** reads `env["ivar"]` directly — the `@` is only surface syntax; per D9, "post is both `@post` and the local `post`" in one environment Hash. A missing ivar is simply `nil`: `[<%= @missing %>]` renders `[]`, never an error.
- A **bare local name** (`post`, `title`) also reads `env["name"]`, but if the key does not exist **at all**, the interpreter treats it as a zero-argument helper call instead. If the key exists (even bound to `nil` — an unpassed-but-declared strict local, say), its value is returned with no helper fallback. This is why `<%= csrf_meta_tags %>` and `<%= flash %>` work with no parentheses, and why `<%= nope %>` fails with `"undefined helper 'nope'"` rather than a "no such local" error.
- Locals come from `each`/`each_with_index` block params, `form_with`'s block param, a partial's strict locals, and `<% name = expr %>`.

### Method calls

```erb
recv.method
recv.method(arg1, key: value)
recv&.method             # nil-safe: short-circuits to nil, args not evaluated, if recv is nil
method(arg1, key: value) # a helper call: no receiver
method arg1, key: value  # same call, no parentheses ("command" syntax)
```

- A parenthesis-free ("command") argument list is only opened for the **outermost** call in an expression: `link_to "Show", post_path(post)` works, but `link_to "Show", post_path post` is a `SyntaxError` — inner calls need their own parens.
- No space is allowed between a call target and its opening `(`: `link_to("x")` and `link_to "x"` both work; `link_to ("x")` is a `SyntaxError`.
- `yield` and `yield :key` are always parsed as calls (see [Layouts, `yield`, `content_for`, partials](#layouts-yield-content_for-partials)).
- A bare capitalized word is rejected outright — `"constants are not supported: 'Time'"` — templates cannot reach Ruby constants.
- These words are reserved and rejected with a dedicated message (`"'x' is not supported in templates"`) wherever an expression is expected: `and or not do end if unless elsif else then while until def class module begin rescue return`. `case` and `when` are statements of their own ([`case`](#case)); inside an expression (`<%= case x %>`) they are rejected the same way.

### Operators, precedence (low to high)

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

`&&`/`||` return the operand, not a coerced boolean (`nothing || title` evaluates to `title`, not `true`). Conditions test **truthiness**: only `nil` and `false` are falsy, as in Ruby — `0`, `""`, and empty arrays/hashes are truthy (`<% if 0 %>yes<% end %>` prints `yes`).

Indexing is `target[index]` with **no space** before `[` (`items [0]` is a syntax error, `items[0]` is not), and chains like any postfix: `h["k"].first`, `params[:id]`.

## Statements

A `<% %>` tag holds exactly one statement: an assignment, or an expression evaluated for its side effect (value discarded). `<%= %>`/`<%== %>` only ever hold an expression — `<%= x = 1 %>` is a `SyntaxError`.

### Conditionals

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` follow Ruby's rules; `elsif` after `else`, a stray `else`/`elsif`/`end`, or a block never closed by `end` are all `SyntaxError`s naming the opening line.

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

- The subject is evaluated once; each `when`'s values (one or more, separated by commas) are compared in order with the template's `==`, and the first branch with an equal value runs. Numbers compare by value (`1` matches `1.0`); Strings and Symbols by value and type (`"a"` does not match `:a`); records as `==` does (class and `id`); Arrays and Hashes as `==` does (by value, element by element); a `SafeString` and a `String` with the same text are equal. There is no `===`: no ranges, classes or regexes after `when`.
- `else` runs when no value matched; with no `else` and no match nothing is printed.
- Only blank text (indentation, newlines) may stand between `case` and its first `when`; it is dropped. Anything else there is a `SyntaxError` (`"text between 'case' and its first 'when'"`).
- `when` outside a `case` (`"'when' without 'case'"`), a `case` with no subject or no `when`, a `when` with no value or after `else`, and a `case` never closed by `end` are `SyntaxError`s naming the line. `then` stays reserved: `<% when :a then x %>` is a `SyntaxError`.
- A local first assigned inside a branch follows the block-local rule of the block it sits in, as with `if`.

### Loops

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` are recognized only as a suffix on the block head (`x.each do |...|`); the collection may be any expression, a block-taking call included (`<% items.group_by { |i| i.kind }.each do |kind, list| %>`). **As built**, both require declaring one or two block parameters — `xs.each do end` is a `SyntaxError` ("takes one or two block parameters"), where plain Ruby allows zero.
- `<% x.each_slice(n) do |slice| %>...<% end %>` iterates over the slices of `n` items (the last may be shorter), and also needs one or two parameters; with two a slice is taken apart (`do |a, b|`), the second `nil` when the slice is short.
- Array + one param: the item. Array + two params: an `Array` item is destructured (`a, b = item[0], item[1]`); otherwise the second is `nil`.
- `each_with_index` on an Array: `item, i`. On a Hash: the first param is a `[key, value]` pair, the second the index.
- `each` on a Hash with two params: `key, value` directly; with one param: a `[key, value]` pair.
- Iterating `nil`, a `Time`, or any scalar is a `RuntimeError` (`"undefined method 'each' for Time"`) — never a silent no-op.
- A block parameter shadows a same-named outer local only for the loop and is removed after (`refute env.key?("item")` once the loop ends). A variable that existed before the block is the *same* variable inside it (visible after the loop too); one **first assigned inside** the block is block-local — `nil` at the start of every iteration, gone afterward.

### Block calls (helpers)

`do ... end` is also how a receiverless helper call takes a block (for a call with a receiver, see [Blocks](#blocks)):

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

Whether the block's result is printed follows the tag: `<%= helper do |x| %>` prints it, `<% helper do |x| %>` discards it. Exactly one block parameter is ever bound; a helper block never gets an index or a second value.

### Blocks

A call with a receiver may take a block, `{ |x| expr }` or `do |x| ... end`, with zero, one or two parameters. Which methods accept one is fixed per type; a block anywhere else is a `SyntaxError` raised when the call runs (`"String#upcase takes no block"`), and a method the type does not have is the ordinary `"undefined method 'x' for Array"`, with or without a block.

| Receiver | Methods taking a block | The block's value is used as |
| --- | --- | --- |
| `Array` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | the mapped value, the test, the summand, the sort key, the group key |
| `Hash` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | the same, the block seeing `\|key, value\|` (one parameter gets the `[key, value]` pair); `select`/`reject` answer a Hash, the others what the Array method answers over the pairs |
| the `tag` builder | every element (`tag.div do ... end`) | its **output** is the element's content ([The tag builder](#the-tag-builder)) |

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

- **Value, not output.** For the Array and Hash methods the block's *value* counts: a `{ }` block's expression, or a `do` block's last statement, which must be an expression statement (`<% x * 2 %>`); `"map's block must end in a value"` otherwise (an assignment, or text). What the earlier statements of a `do` block print is discarded. A `do` block on such a method sits on its own tag, assigned (`<% total = items.sum do |li| %>`) or printed (`<%= items.map do |x| %>`).
- **No mutation.** Templates have no way to change an accumulator, so `each_with_object` and `inject` are not in the table (`"undefined method 'each_with_object' for Array"`): use `map`, `select`, `sum` or `group_by`.
- Two parameters take an Array item apart, as `each` does (`pairs.map { |a, b| a }`).
- `sum` of an empty Array is `0`; Integers sum to an Integer, a Float anywhere makes it a Float (added with the same compensation as Ruby's, so `[0.1, 0.2, 0.3].sum` is `0.6`); Strings are refused (`"sum: use join for Strings"`), as is anything that is not a number.
- `sort_by`, `min_by`, `max_by` (and blockless `sort`, `min`, `max`) compare as `<` does (numbers, Strings, Times; `"comparison of String with Integer failed"` otherwise). `sort_by` is stable: equal keys keep their order. `min_by`/`max_by` of an empty Array are `nil`.
- `group_by` answers a Hash from each key **as a String** (every template Hash is String-keyed: `:fruit` and `"fruit"` are one group) to the items with that key, in first-seen order.
- `each`, `each_with_index` and `each_slice` take their block in a `<% %>` tag ([Loops](#loops)); `items.each { |x| x }` is a `SyntaxError`.
- A block on a `FormBuilder` or `Page` method is refused the same way (`"FormBuilder#label takes no block"`), and the blockless Array methods take no arguments (`nums.sum(10)` is `"wrong number of arguments for 'sum'"`).
- If a block raises, its parameters and locals are restored before the error leaves the call.
- A `{ }` block needs a receiver: `shout { |x| x }` is a `SyntaxError` (helper calls take `do ... end`).
- Block parameters shadow outer names during the call and are restored after it; a local first assigned in a `do` block is block-local, as in `each`.

### Assignment

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

Only `name = expr` for one plain local — no `@ivar = ...`, no `arr[0] = ...`/`h[:k] = ...`, no `a, b = ...`. The same block-local rule from `each` applies to assignments inside `if`/`unless` nested in a block.

## Per-type method table

`nil?`, `present?`, and `blank?` are checked **before** per-type dispatch, so they work on every value, including models and helper-returned objects (`blank?` is `false` for anything but `nil`/`false`/an empty `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params`). Arithmetic (`+ - * / %`) and comparison (`== != < > <= >=`) exist only as **infix operators**, never `.method` calls — an operator glyph can never follow a `.` in this grammar.

| Type | Methods | Example |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` `sum` `min` `max` `sort` `uniq` `compact` `flatten` `take(n)` `drop(n)` `each_slice(n)` (an Array of Arrays) `zip(other)`, and the block methods of [Blocks](#blocks) | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values` `to_a` (the `[key, value]` pairs), plus `h[key]` and the block methods of [Blocks](#blocks) | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`, plus `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`, plus `params[key]` | `params[:id]` |
| `Page` (`Relation#page`) | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s` (returns `""`) | |

Indexing (`x[key]`) is a distinct grammar production ([Expressions](#expressions)), not a `.[]` call: `Array`/`String` take an integer index, `Hash` matches any key by its `to_s` (`h[:k]` and `h["k"]` are the same entry), `Errors` matches by symbol, `Params` by `to_s`.

Printing (`<%= %>`/interpolation) beyond `to_s` above: `Array` prints as an inspect-like list — `[1, "a", nil]` renders the text `[1, "a", nil]` (then gets escaped, so quotes become `&quot;`); `Hash` falls back to Ruby's own `Hash#to_s`; a `Cybertrain::Model` prints as `#<Post id: 7>` (never its attributes); anything else prints via its own `to_s`. An unlisted method on any of the above is a `RuntimeError` (`"undefined method 'first' for Time"`). `Integer` division/modulo by zero is `"divided by 0"`; `Float` follows IEEE-754 instead (`Infinity`/`NaN`, no error).

## Models in templates

A `Cybertrain::Model` subclass (a generated `Post`, `Note`, ...) resolves a bare name in this order (`Interpreter#model_method`):

1. Five built-ins, always available: `id`, `persisted?`, `new_record?`, `to_param` (`id.to_s`), `errors` (an `Errors`, [Per-type method table](#per-type-method-table)).
2. `read_attribute(:name)` — a generated column.
3. `read_association(:name)` — a generated `has_many`/`belongs_to`.
4. `call_view_method(:name)` — a hand-written, argument-less `def` the model generator found in `app/models/**/*.rb` (no arity, ever).

```erb
<%= post.title %>            <%# read_attribute %>
<% post.comments.each do |c| %>...<% end %>   <%# read_association %>
<%= post.summary %>          <%# call_view_method %>
<%= post.errors.full_messages.join(", ") %>
```

If all four answer `nil`, `attribute_or_method?(:name)` decides whether that was a legitimate name that just holds `nil` (returns the `nil`) or a typo (`"undefined method 'bogus' for Post"`).

**As built, a real gap the interpreter file itself flags** (see the `TODO(integrator)` comment above `class Model` in `interpreter.rb`): the *base* `Cybertrain::Model#attribute_or_method?` always returns `true`. Only a generated model overriding it with an explicit `case` (as the hand-written test models do) actually raises on a typo; without that override, a misspelled attribute or method silently renders empty instead of failing. Do not assume typos are caught unless you know the model overrides this hook.

Two models compare with `==` by class and `id` (`Model#==`), reachable as the ordinary `==` operator (native equality dispatch, not `call_method`).

## Helpers and the form builder

Every receiverless call goes to `Helpers#helper_call` (`helpers.rb`), which matches one of the built-ins below; inside a [component's](#components) template, then tries that component's view methods; treats a name ending in `_path`/`_url` as a generated route helper (via `Cybertrain::Views.url_resolver`, raising `"no routes"` until the app installs one); then tries the [application's helpers](#application-helpers); or raises `"undefined helper 'name'"`.

| Helper | Signature | Notes / example |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` escaped unless already `SafeString`; **no `method:`** — raises, telling you to use `button_to` (no rails-ujs/turbo faking of DELETE links) |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | one-button `<form class="button_to">`; hidden `_method` for any verb but `get`/`post`, plus the CSRF field when a session exists |
| `form_with` | `form_with(model:, url:, scope:, method:, class:, data:, multipart:, local:) do \|f\| ... end` | needs a block; `model:` new → collection route + POST, persisted → member route + PATCH; `[parent, child]` for a nested route, `[:admin, @article]` for a namespaced one; `url:`/`method:` override the derived action/verb; `scope: :q` names the fields `q[term]` (with `model:` it replaces the model's prefix); `data: { turbo_frame: "f" }` writes `data-` attributes; `local:` is accepted and changes nothing; `multipart: true` adds `enctype="multipart/form-data"` (required for `f.file_field`; it is never guessed from the block, and raises `ArgumentError` on a GET form) |
| `select_tag` | `select_tag(name, option_tags = nil, include_blank:, prompt:, multiple:)` | `select_tag "order", options_for_select([["Newest", "new"], ["Oldest", "old"]], "old")` → `<select name="order" id="order">...</select>`; `option_tags` that is not a `SafeString` is escaped; `multiple: true` names it `order[]`; other keywords are attributes |
| `options_for_select` | `options_for_select(choices, selected = nil)` | the `<option>` lines of `f.select`'s choices (below); `selected` is a value or an Array of them, compared as Strings |
| `options_from_collection_for_select` | `options_from_collection_for_select(records, :id, :name, selected = nil)` | one `<option>` per record, its value and text read as `f.collection_select` reads them |
| `label_tag`, `text_field_tag`, `hidden_field_tag`, `submit_tag` | `label_tag(name, text = nil)`, `text_field_tag(name, value = nil)`, `hidden_field_tag(name, value = nil)`, `submit_tag(value = "Save changes")` | the form tags without a model: `label_tag(:term)` → `<label for="term">Term</label>`; `hidden_field_tag` writes `autocomplete="off"`; `submit_tag` is named `commit`; other keywords are attributes (`id:` replaces the id taken from the name) |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` / `render partial: "comment", collection: @comments` / `render @comments` / `render component: "card", k: v` | see [Layouts, `yield`, `content_for`, partials](#layouts-yield-content_for-partials), [Collections](#collections) and [Components](#components) |
| `h`, `escape` | `h(text)` | escapes; a `SafeString` passes through unescaped |
| `raw` | `raw(text)` | wraps text in a `SafeString` (prints unescaped) |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`; `pluralize(2, "mouse")` → `"2 mice"` (Rails' default English inflections, via `Cybertrain::Inflector`; app-defined inflections are not supported); explicit third arg always wins |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n, delimiter: ",", separator: ".")` | `1234567` → `"1,234,567"`; `-1000` → `"-1,000"`; `1234.5` → `"1,234.5"` |
| `number_with_precision` | `number_with_precision(n, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false)` | `111.2345` → `"111.235"`; `precision: 0` → `"111"` |
| `number_to_human` | `number_to_human(n, precision: 3, units: {})` | `1234` → `"1.23 Thousand"`, `1234567` → `"1.23 Million"`; `units: { thousand: "K" }` replaces a unit's name (`unit`, `thousand` ... `quadrillion`) |
| `number_to_percentage` | `number_to_percentage(n, precision: 3)` | `100` → `"100.000%"` |
| `number_to_currency` | `number_to_currency(n, unit: "$", precision: 2, format: "%u%n")` | `1234.5` → `"$1,234.50"`; a negative number writes `-` before the format |
| `number_to_human_size` | `number_to_human_size(n)` | `1234` → `"1.21 KB"` (base 1024); `1` → `"1 Byte"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails-style buckets, no seconds precision: `"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`, `content_for(:key, "text")`, `content_for?(:key)` | see [Layouts, `yield`, `content_for`, partials](#layouts-yield-content_for-partials) |
| `csrf_meta_tags` / `csrf_token` | | empty / absent with no controller session |
| `csp_meta_tag` / `content_security_policy_nonce` | | `<meta name="csp-nonce" content="...">` / the nonce alone, this request's [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) nonce; `""` when no policy applies |
| `javascript_tag` | `javascript_tag(nonce: true) do ... end`, `javascript_tag(js)` | the content in a `<script>` (not escaped, as in Rails: never put request data in it), with the nonce when `nonce: true` and a policy applies; `id:`, `type:`, `data:` are attributes |
| `asset_path` | `asset_path("logo.svg")` | `/assets/logo-1a2b3c4d.svg` (see [Assets](assets.md#helpers)); a URL or a path starting with `/` comes back as given |
| `stylesheet_link_tag` | `stylesheet_link_tag("application", media:, nonce:)` | `<link rel="stylesheet" href="/assets/application-1a2b3c4d.css">` (`.css` added when missing) |
| `javascript_include_tag` | `javascript_include_tag("legacy", nonce:)` | `<script src="/assets/legacy-1a2b3c4d.js"></script>` (`.js` added when missing) |
| `image_tag` | `image_tag(source, alt:, size:, class:)` | `<img src="/assets/logo-1a2b3c4d.svg" alt="Logo" width="16" height="16">` for `size: "16x16"` (or `"16"`); no `alt` is made up, `alt: ""` is written |
| `javascript_importmap_tags` | `javascript_importmap_tags(entry = "application")` | the import map, a `modulepreload` link per preloaded pin and `import "application"`, each with the nonce when a policy applies ([Assets](assets.md#the-import-map)); needs a request |
| `flash` | | `Hash`-like: `flash[:notice]` |
| `params` | | the current `Cybertrain::Params` |
| `request_path` | | current path, `""` with no controller |
| `url_for` | `url_for(target, format:, anchor:, k: v)` | `String` as-is, `Model` → member route, `[parent, child]` → nested route, `[:admin, record]` → namespaced route; the keywords are appended as a path helper appends them (`url_for("/x", format: :csv)` → `/x.csv`) |
| `current_page?` | `current_page?(path)` | whether this GET or HEAD request is for `path` (a trailing slash aside; with a query in `path`, the query must match too); a record or an Array goes through `url_for`; false for any other method; needs a request |
| `paginate` | `paginate(page, path)` | `page` is a `Cybertrain::Page` (from `Relation#page`); renders `<nav class="pager">` with "Newer" (`rel="prev"`), `<span class="pager-current">Page N</span>` and "Older" (`rel="next"`), a link left out when there is no such page. Each link is `path` plus the current request's query string with `page` replaced (dropped for page 1), re-encoded and HTML-escaped; a `path` with its own `?query` uses that instead. A `Page` also answers `number`, `per`, `row_offset`, `next?`, `prev?`, `next_number`, `prev_number` in a template (`<% if @page.next? %>`) |
| `*_path` / `*_url` | e.g. `post_path(post)`, `posts_path(page: 2, format: :json)` | generated by the app, resolved via `Cybertrain::Views.url_resolver`; keywords go to the query string, `format:` adds the extension and `anchor:` the fragment ([Redirects and query strings](requests.md#redirects-and-query-strings)) |
| `tag` | `tag.div(content, attrs) do ... end` | the tag builder: see [The tag builder](#the-tag-builder) |
| `content_tag` | `content_tag(name, content = nil, attrs)`, or with a `do` block | `content_tag "p", "<i>", class: "n"` → `<p class="n">&lt;i&gt;</p>`; the same rules as `tag` |
| `safe_join` | `safe_join(array, sep = "")` (no keyword arguments) | joins into a `SafeString`, escaping every item and the separator that is not already a `SafeString`: `safe_join([tag.b("a"), "<"], " ")` → `<b>a</b> &lt;` |
| `class_names` | `class_names(*values)` | Rails' `class_names`/`token_list`: the words of Strings and Symbols, of Arrays (nested too) and of each Hash key whose value is truthy, each word once; keyword arguments are one more such Hash: `class_names("btn", active: @on, big: false)` → `"btn active"` |
| `dom_id` | `dom_id(record, prefix = "")` (the prefix is positional, as in Rails) | `"article_12"`, `"new_article"` for an unsaved record, `dom_id(@article, "edit")` → `"edit_article_12"` (`Cybertrain::Html.dom_id` in Ruby) |
| `turbo_stream_from` | `turbo_stream_from(*streams, ws: false)` | one `<turbo-stream-source>` subscribing the page to the streams (Strings, or records named `"articles:12"`); `ws: true` gives a `ws://`/`wss://` URL and needs a request. See [Realtime](realtime.md#turbo-streams) |
| `signed_stream_name` | `signed_stream_name(*streams)` | the signed token alone, for hand-written JavaScript |
| `stream_source_path` | `stream_source_path(*streams, mode: "json")` | the stream endpoint's path with the token and `mode=json` (or `"raw"`) |
| `turbo_frame_tag` | `turbo_frame_tag(id_or_record, src:, loading:, target:, class:, data:) do ... end` | `<turbo-frame id="article_3" src="...">...</turbo-frame>`; a record gives its `dom_id`; each attribute only when given |
| `turbo_stream` | `turbo_stream.replace(target, partial:, locals:)`, `.update(target, html:)`, `.append(target) do ... end`, `.prepend`, `.before`, `.after`, `.remove(target)` | one `<turbo-stream action="...">` element, for a `*.turbo_stream.erb` template; the target is a DOM id or a record; exactly one of a block, `partial:` (with `locals:`) and `html:` |
| `time_tag` | `time_tag(time, text = nil, format:, class:, id:, title:, data:)`, or with a block | `<time datetime="2026-11-10T12:00:00Z">Tue, 10 Nov 2026 12:00:00 +0000</time>`; a Date gives `2026-11-10`; `format:` is `:short`, `:long` or a strftime String (an unknown directive raises, and so does a width or flag strftime would read differently: `%6L`, use `%6N`; `:` only in `%:z`; no padding flag on `%F %T %D %R %r %c %x %X %v`; a width on a number replaces its padding, `%5e` gives `"    5"`) |

Every helper text argument follows one rule: a `SafeString` passes through unescaped, anything else is escaped — `link_to raw('<b>raw</b>'), post` prints the bold tag literally, but `link_to post.title, post` escapes it.

The six number helpers are `Cybertrain::NumberHelper`'s, which Ruby code calls as module functions with the same keywords (`Cybertrain::NumberHelper.number_to_currency(price, unit: "€")`). They take an Integer, a Float or a numeric String (decimal columns are Floats) and round half up on the digits of its decimal text, so the output is the same on both runtimes; anything else raises `ArgumentError` (`"number_with_delimiter: \"abc\" is not a number"`), as does a precision outside 0 to 100. In a template `nil` renders `""` (a nullable decimal column prints as empty, as in Rails); `Cybertrain::NumberHelper` called from Ruby still raises `ArgumentError` for `nil` (`"number_with_delimiter: nil is not a number"`). The formats are English.

### The tag builder

`tag` evaluates to a builder (`Cybertrain::Html::TagBuilder`); any method called on it is an element, rendered by `Cybertrain::Html.tag` (also callable from Ruby: `Html.tag("a", { href: "/x" }, "Go")`):

```erb
<%= tag.div(class: "card") do %>
  <%= tag.h2 @article.title, id: dom_id(@article) %>
<% end %>
<%= tag.input type: "text", name: "q", disabled: true %>   <%# <input type="text" name="q" disabled> %>
<%= tag.path d: "M0 0 L10 10" %>                         <%# SVG elements work %>
<%= tag.my_widget data: { turbo_frame: "f" } %>          <%# <my-widget data-turbo-frame="f"></my-widget> %>
```

- `<%= tag %>` alone prints nothing.
- The element name is the method name with `_` turned into `-`; it must match `[a-z][a-z0-9-]*` (`"invalid element name 'Div'"` otherwise, from `Html.tag`).
- Content is the one positional argument (escaped unless a `SafeString`, so `tag.script("alert(1)")` prints its text escaped) or the block's **output** (`do ... end`, or `{ expr }` whose value is printed escaped); the block wins. With neither, `tag.div` is `<div></div>`.
- Void elements (`area base br col embed hr img input link meta source track wbr`) render without a closing tag; content or a block for one is an error (`"br is a void element"`).
- Attributes are the keyword arguments, in order: `nil` and `false` drop the attribute, `true` renders it bare (`disabled`), an Array joins its non-`nil` items with spaces (`data: { ids: [1, 2] }` gives `data-ids="1 2"`, not Rails' JSON), `class:` takes what `class_names` takes (`class: ["btn", { active: @on }]`), `data:` and `aria:` Hashes nest to `data-key="v"` / `aria-key="v"` with underscores turned into dashes (and `true`/`false` written out there); any other Hash value is an error (`"attribute 'title' cannot be a Hash"`). Every value is escaped, a `SafeString` too. Attribute names must match `[a-zA-Z_:][-a-zA-Z0-9_:.]*` (`"invalid attribute name 'data-a b'"`); `onclick:` and the like are allowed, being the author's.

### FormBuilder (`f` in `form_with ... do |f|`)

Every method returns a `SafeString`; an unlisted one is a `RuntimeError` (`"undefined method 'color_wheel' for FormBuilder"`).

| Method | Renders |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — default text is the humanized attribute (`published_at` → "Published at", `author_id` → "Author"); explicit text is escaped unless a `SafeString` |
| `f.text_field :title` (also `email_field`, `password_field`, `number_field`, `date_field`, `datetime_local_field`, `time_field`, `range_field`, `color_field`, `search_field`, `telephone_field`, `url_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`; `password_field` never emits `value=`; `telephone_field` is `type="tel"`; a Time is written as the browser reads it (`2026-11-10`, `2026-11-10T12:00:00`, `12:00:00.000`) |
| `f.select :status, ["draft", "published"]` (also `include_blank:`, `prompt:`, `selected:`, `disabled:`, `multiple:`) | `<select name="post[status]" id="post_status">` with one `<option>` per choice, the current value selected; choices are values, `[text, value]` pairs, or a Hash or `[label, [choices]]` groups for `<optgroup>`; `multiple: true` names it `post[status][]` and writes a hidden empty input first |
| `f.collection_select :author_id, @authors, :id, :name` | a `<select>` with one `<option>` per record, its value and text read from the two methods |
| `f.radio_button :status, "draft"` | `<input type="radio" name="post[status]" id="post_status_draft" value="draft">`, checked when the value matches (`checked:` overrides) |
| `f.file_field :cover` (also `accept: "image/*"`, `required: true`) | `<input type="file" name="post[cover]" id="post_cover">` — never a `value=`, and the attribute need not be a column; the form must be `form_with ..., multipart: true`; `multiple: true` raises `ArgumentError` (one file per field) |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>` (leading `\n`, as Rails does — browsers eat the first newline) |
| `f.check_box :published` | hidden `value="0"` input then the real checkbox, so an unchecked box still submits `"0"`; `include_hidden: false` leaves the hidden input out |
| `f.submit` / `f.submit "Text"` | default text `"Create Post"`/`"Update Post"` (by `persisted?`), or `"Save changes"` with no model |

With a model, fields are named `post[title]`/`id="post_title"` (`Inflector.underscore(model.model_name)` as scope); `form_with(..., scope: :q)` uses `q[title]`/`id="q_title"` instead; with `form_with(url: ...)` and no model or scope, the bare attribute name is used for both. Every attribute value and option text is escaped once (a `SafeString` as it is). Extra keyword args become HTML attributes in order given: `true` → `attr="attr"`, `false`/`nil` dropped, anything else → `attr="value"` (escaped), underscores become hyphens (`data_confirm: "Sure?"` → `data-confirm="Sure?"`), and `class:` merges with the automatic `field_with_errors` class added when `model.errors.key?(attr)`.

## Application helpers

A module under `app/helpers/` is a helper module, as in Rails: every public method in it can be called from any template, without a receiver.

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

- **Generated dispatch.** Templates cannot `send`, so `spin run gen` reads `app/helpers/**/*.rb` as text and writes `gen/helpers.rb`: an `ApplicationHelpers` class that includes every module (and the route helpers) and a `case` over the helper names. Add or change a helper's signature, and the next build regenerates it (the development server does both). `cybertrain generate helper prices` writes an empty `PricesHelper` and a test.
- **What is a helper.** Public instance methods of a `module` (`def self.x`, setters and everything after `private` or `protected` are not), whatever their file. A template passes values by position or keyword, so every parameter is named: `*rest`, `**opts`, `...` are generator errors, as is a required parameter after an optional one. A helper takes at most three optional parameters (the generated `case` has one arm per combination given, so an omitted keyword gets the method's own default). A wrong call is an `ArgumentError` at render time: `"wrong number of arguments for 'price' (given 0, expected 1)"`, `"unknown keyword 'cur' for 'price' (known: unit, precision)"`.
- **Reserved names.** A helper may not be named like a framework helper (`link_to`, `render`, `tag`, `dom_id`, `params`, `content`, ...), like a method of `Cybertrain::Template::Helpers` (public or private: the `include` would replace it for the framework too), `yield`, or with a `_path` / `_url` ending (the route helpers answer those); the same name in two modules is an error as well. `spin run gen` stops with the file, the line and the reason.
- **Values.** Arguments arrive as the template's values (String, Integer, Float, `nil`, a record, an Array, a Hash); narrow them with `Cybertrain::Cast` (`Cast.str`, `Cast.int`, `Cast.float`) before arithmetic. What a helper returns is printed like any value: a `String` is escaped, a `SafeString` is not, so build HTML with `Cybertrain::Html.tag(name, attrs, content)`, `Html.safe_join`, `Html.class_names`, `Html.dom_id`, `Html.escape`, `Cybertrain::SafeString.of` or the Ruby forms of the link helpers, `link_to_path(text, path, attrs)` and `button_to_path(text, path, attrs)` (`method:` inside `attrs`).
- **Blocks.** A helper with a `&block` parameter takes a `do ... end` block; `yield` (no arguments) returns what the block printed, as a `SafeString`.

## Components

A component is a class with keyword arguments and a template beside it, in [ViewComponent](https://viewcomponent.org)'s shape:

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

- The template sees the component's instance variables as locals (`title`), its public methods without parameters by name (`value_text`), and `content`, what the `do` block printed (`""` without one). It renders without a layout, can render partials and other components, and counts toward `max_render_depth` like a partial. A partial it renders does not see the component's methods. A bare partial name in a component template (`render "chip"`) is looked up under `app/components/` (`app/components/_chip.html.erb`); a name with a directory (`render "shared/note"`) under `app/views/` as usual.
- A component is named by its snake-case name without `_component`, as a partial is named by its path: `"card"` for `CardComponent`, `"admin/user_row"` for `Admin::UserRowComponent` (`app/components/admin/user_row_component.rb`). Templates cannot name constants.
- `spin run gen` writes `gen/components.rb` from a lexical scan, as for helpers: the class line, the `@x =` assignments, the parameterless `def`s and the `initialize` keywords. `initialize` takes keywords only (at most three of them optional), and its template must exist; a missing keyword or an unknown one is an `ArgumentError` at render time. An unknown component is `Cybertrain::Component::Unknown`: `` "no component 'crad' (app/components/crad_component.rb, then `spin run gen`)" ``. `content` is reserved: an `initialize` keyword or an `@content` instance variable of that name would be overwritten by the block's output, so `spin run gen` refuses it, naming the file and line. `app/views/components/` stays a view directory like any other (a `ComponentsController`'s); only `app/views/__components/` is reserved, the names component templates are kept under.
- `cybertrain generate component card title value:integer` writes the class, its template and a test that renders it with `Cybertrain::Test.render_component`.

### Rendering outside a request

A broadcast, a job or a mail body renders without a request:

```ruby
html = Cybertrain::Views.render_partial("articles/article", article: article)   # app/views/articles/_article.html.erb
card = Cybertrain::Views.render_component(CardComponent.new(title: "Visitors", value: 12))
```

Both return the HTML as a String, with the application's helpers. Path helpers work (`article_path(article)`), strict locals are checked, and forms (`form_with`, `button_to`) render without the authenticity token (a Turbo page submits the one from `csrf_meta_tags`). A helper that needs a request raises `Cybertrain::Views::OutsideRequest` (`"csrf_token needs a request"`): `csrf_token`, `csrf_meta_tags`, `params`, `flash`, `request_path`, `current_page?`, `content_security_policy_nonce` (so `csp_meta_tag` and a tag helper given `nonce: true`), `javascript_importmap_tags`, any `*_url` helper and `turbo_stream_from ... ws: true`. `paginate` links carry only the path's own query string. (A bare `Cybertrain::Template::Helpers.new(nil)`, as a unit test might build, answers those with empty values instead.)

## Layouts, `yield`, `content_for`, partials

`Engine#render_with_layout(name, layout, env, helpers)` renders `name` into `env["__content"]` (a `SafeString`), then renders `layout` against the same `env`:

```erb
<title><%= yield :title %></title>
<%= yield %>
```

`yield` prints `env["__content"]`; `yield :key` prints `env["__content_key"]`, or nothing if unset. `yield` is special-cased directly in the interpreter and cannot be overridden as a helper. A page fills a slot with `content_for`, anywhere in its body (order relative to `yield` does not matter — the page fully renders before the layout does):

```erb
<% content_for :title do %>Post: <%= @post.title %><% end %>
<% content_for :title, " (draft)" %>   <%# appends: calls accumulate, they don't replace %>
```

### Per-controller layouts

An action renders inside `app/views/layouts/application.html.erb` (when it
exists) unless its controller, a parent or a concern it includes chooses
another:

```ruby
class AdminController < ApplicationController
  layout "print", only: [:receipt]      # app/views/layouts/print.html.erb
  layout :choose_layout                 # a method: a name, false for none, nil for the parent's

  private

  def choose_layout = request.header("Turbo-Frame").to_s.empty? ? "application" : "frame"
end
```

`layout "admin"` alone names one layout for every action. `spin run gen`
reads the `layout` lines (a quoted name, `false`, or a method's Symbol,
with `only:` / `except:`) and writes the controller's
`controller_layout(action)`. The declarations are tried in order and **the
first that applies wins** (Rails lets a later one replace an earlier one);
a concern's lines count at its `include`. `render layout: "x"` uses
`layouts/x` for one call and `render layout: false` none; a leading `layouts/`
is accepted (`layout "layouts/x"` is `layouts/x`). A `layout` line or
`render layout:` that names a layout that does not exist raises
`MissingTemplate`; only the default `application` layout is optional (an
action renders bare without it). Only html is
rendered in a layout; another format's template renders without one. Any
other `layout` argument (`nil`, a lambda, a constant) is refused by gen.

### Partials and `render`

```erb
<%= render "form", post: @post %>
<%= render partial: "form", locals: { post: @post } %>
<%= render "comments/comment", comment: c %>
```

- A bare name with no `/` resolves in the **current template's own directory** (via an env key the rendering machinery sets, `__template_dir`): `render "form"` from `posts/show` looks for `posts/_form.html.erb`. A name containing `/` is an explicit path; only its last segment gets the `_` prefix (`"comments/comment"` → `comments/_comment.html.erb`).
- The partial gets **a duplicate of the caller's entire environment** (ivars and any locals already in scope) plus the explicit locals given to `render` — it is not sandboxed to only what was passed. Strict locals only validate the names **explicitly given to that `render` call** against the declared list; they do not stop the partial from also reading some other name it inherits from the caller's environment.
- Only `content_for` keys (`__content_*`) copy back out of a partial's scope into the caller's; ordinary locals it assigns do not leak back.
- Missing/extra locals against a `<%# locals: %>` declaration are `RuntimeError`s: `"missing local 'post' for posts/_form.html.erb"`, `"unknown local 'extra' for posts/_form.html.erb"`.

### Collections

```erb
<%= render partial: "comment", collection: @comments, as: :comment, spacer_template: "divider" %>
<%= render @comments %>      <%# each record's comments/_comment.html.erb %>
<%= render @comment %>       <%# one record, no counter %>
<%= render component: "comment", collection: @comments %>
```

- `collection:` renders the partial once per item of an Array, as the local named by `as:` (the partial's own name by default), with `<as>_counter` counting from 0, the `locals:` given to each and `spacer_template:` (a partial) between items; an empty collection renders nothing. A partial with strict locals gets the counter only when it declares it, and the item wins over a local of the same name.
- `render @comments` picks each record's partial from its model, `<plural>/_<singular>` (`admin/notes/_note` for an `Admin::Note`), so a list may mix models.
- A component whose one required keyword is named after it (`CommentComponent` with `comment:`) gets `CommentComponent.with_collection(items)`, and `render component: "comment", collection: @comments` renders it once per item, passing `comment_counter:` when `initialize` declares it. `collection:` takes no other keyword (`render component: "comment", collection: @comments, extra: 1` is an error naming it); the block's content is not passed.

### File resolution (`engine.rb`)

`"posts/show"` and `"posts/show.html.erb"` name the same template. Development reads `app/views/` from disk with `cache: false` (a file is re-read and re-parsed whenever its mtime or size changes, and that re-parse writes the engine's cache, so the development server always serves with one worker and ignores `SPINEL_WORKERS`, saying so in its boot banner); the test environment reads from disk with `cache: true` (parsed once). A production binary never touches disk: `cybertrain build` runs `spin run gen -- --embed-views`, which writes every `*.erb` under `app/views/` (dotfiles and symlinked directories skipped) into `gen/views.rb`, and `Engine.embedded(sources)` parses every entry once, when the binary boots (error messages keep the same `posts/show.html.erb:12` shape), so a template with a syntax error stops the boot instead of failing its page; a binary whose table is empty refuses to boot in production. A missing template raises `Cybertrain::Template::MissingTemplate` — `"Missing template <full path>"` from disk, `"Missing template posts/nope.html.erb (embedded)"` from the table.

File lookups resolve the view root and template path through symlinks and only load regular files inside that root. Paths that escape it (including through symlinks) raise `MissingTemplate`; `exists?` returns false for those paths.

## Errors

Two exception classes, both in `ast.rb`'s `Cybertrain::Template` namespace (distinct from `::SyntaxError`/`::RuntimeError`):

- **`SyntaxError`** — raised while tokenizing/parsing, before any interpretation. Shape: `"<template>:<line>: <what>"`, e.g. `"posts/show:2: 'if' without 'end'"`, `"posts/show:1: unterminated <% tag"`, `"posts/show:1: unexpected ')' in 'foo(1))'"`. Raised directly by `Engine#template` (hence `#render`/`#render_with_layout`) when a page or layout file fails to parse — never caught or rewrapped by the interpreter.
- **`RuntimeError`** — raised while evaluating, same message shape, but `<template>` is whichever template is *currently rendering* (`Interpreter#render` swaps `@name` in and out) — a partial's own error keeps the partial's name and line, never the caller's: `"posts/_row:1: undefined method 'bogus' for String"`.

Any plain `StandardError` from a helper or `FormBuilder`/custom-object method call (a bare `raise "text"`, `ArgumentError`, `KeyError`, even a `Cybertrain::Template::RuntimeError` from a nested `render`) is caught and "relocated": rewritten to `"<current template>:<current line>: <original message>"`, unless it is already exactly the last-relocated message (a nested `render` already stamped its own, more specific location), in which case it passes through unchanged. A `Cybertrain::Template::SyntaxError` raised by a helper (a partial that fails to parse, mid-render) is never rewrapped — it keeps its own `"<partial>:<line>: ..."` message and class, so a broken partial is always reported as a `SyntaxError` about itself, not a `RuntimeError` about whoever rendered it.

`Cybertrain::Views::OutsideRequest` and `Cybertrain::Component::Unknown` also pass through unwrapped, keeping their class, so a caller of `Views.render_partial` can rescue them.

`MissingTemplate` (`StandardError`, `engine.rb`) is raised **unwrapped**, no `template:line` prefix, from a top-level `Engine#template`/`#render`/`#render_with_layout` call (e.g. a controller rendering a missing action template or layout): `"Missing template <path>"`. The same exception raised *inside* a template via the `render` helper's partial lookup goes through relocation instead and comes out a `RuntimeError`: `"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`.

## Differences from Rails ERB

| Rails ERB | Cybertrain |
| --- | --- |
| Compiled to a Ruby method; any Ruby, any object, any method works | Interpreted against fixed per-type dispatch tables; only what the [per-type method table](#per-type-method-table) lists is callable |
| `ActiveSupport::SafeBuffer` is a `String` subclass | `SafeString` is a separate wrapper class — only `to_s`/`html_safe?`/`size`/`length`/`empty?` are callable on it |
| Blocks: `each`, `{ }`, `map`, any Enumerable method | `{ }` and `do...end` on a fixed list of Array/Hash methods (no `each_with_object`, `inject`), `each`/`each_with_index`/`each_slice` loops, helper calls and `tag` |
| `xs.each { }` — zero block params is fine | `each`/`each_with_index` require declaring 1 or 2 block params |
| `link_to text, path, method: :delete` (JS-driven) | No `method:` on `link_to` — use `button_to` for a real non-GET form |
| Strict locals accept `name: default_expr` (Rails 7.1) | Only bare `name:` (required); a default-value entry is a `SyntaxError` |
| Undefined ivar/local resolves via Ruby / the view context's methods | `@x` is a plain, never-failing env lookup; a bare undefined local is an explicit, closed helper-call attempt (`"undefined helper"` if no match) |
| `case/when` with `===` (ranges, classes, regexes) | `case/when` with `==` only (numbers by value) |
| `and`/`or`/`not`, ranges, regexes, multiple assignment all work | None exist; the reserved words fail with a specific "not supported in templates" message, not a generic parse error |
| Numeric literals: hex, octal, binary, exponents, rationals | Only decimal integers/floats with optional `_` separators |
| `:"quoted symbol"`, `:+` operator symbols | Symbols are identifier characters only |
| `foo (x)`, `foo [x]` (space tolerated, sometimes with a warning) | Both are hard `SyntaxError`s — no space before a call's `(` or an index's `[` |
| Nested unparenthesized calls resolved by Ruby's own parser | Only the outermost call in an expression gets parenthesis-free arguments |
| An undeclared/misspelled attribute reliably raises `NoMethodError` | Silently renders blank unless the specific generated model overrides `attribute_or_method?` (tracked gap, not a guarantee) |
| `1 / 0` and `1.0 / 0` both raise `ZeroDivisionError` | `Integer` division/modulo by zero raises `"divided by 0"`; `Float` follows IEEE-754 (`Infinity`/`NaN`), no error |
| `distance_of_time_in_words`/pluralization support i18n locales | English-only, no locale support |
| Every module in `app/helpers` is mixed in; any signature; a helper may override a framework one | Modules are scanned at build time into a generated `case`: named parameters only, at most three optional, no framework helper name and no `_path`/`_url` ending ([Application helpers](#application-helpers)) |
| ViewComponent: `render CardComponent.new(title: "x")`, `with_collection`, slots | `render component: "card", title: "x"` by name, `content` from the block, `collection:` for a component named after its one required keyword; no slots ([Components](#components), [Collections](#collections)) |
| A later `layout` line replaces an earlier one | The first `layout` declaration that applies wins ([Per-controller layouts](#per-controller-layouts)) |
