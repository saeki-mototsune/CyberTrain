# Cybertrain Template Language Reference

Cybertrain views (`app/views/**/*.html.erb`) look like Rails ERB but are not Ruby: they are parsed at run time (from `app/views/` on disk in development and test; in a production binary from the string table `cybertrain build` embeds via `gen/views.rb`), tokenized and parsed into an AST, compiled once into a flat node tree, and walked by a tree-walking interpreter. The pipeline lives in `cybertrain/template/`:

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

This document describes exactly what that pipeline accepts and executes. Where it disagrees with `docs/design.md` section 7 (the original spec draft) or with what a Rails developer would expect, the code wins, and this document says so (search for "**As built**").

## 1. What is, and is not, Ruby here

Templates are **not** Ruby. Spinel (the Matz-Ruby AOT compiler cybertrain targets) has no `eval`, so "interpret the view's own Ruby at request time" was never on the table (D9 in `docs/design.md`); what runs instead is a small, closed grammar that only wears ERB/Ruby-looking syntax. There is no arbitrary Ruby inside a tag — only what `ExprParser` (`parser.rb`) recognizes as a statement or expression. There is no `eval`, `send`, `instance_eval`, method/class/module definitions, `require`, exceptions (`begin/rescue`), `case/when`, ranges, regexes, or multiple assignment. The only blocks are `each`, `each_with_index`, and a call to a helper (`form_with(...) do |f| ... end`) — no `{ }` blocks, no `map`/`select`/any other Enumerable-with-a-block. Every method call (`recv.name`) is resolved by hand-written `case` dispatch tables in `interpreter.rb`, keyed on the receiver's runtime Ruby class; a name missing from that type's table fails with a `RuntimeError` — there is no `method_missing`, no reflection, and (per `Interpreter#call_method`) Spinel's lack of `send` is exactly why this is a `case`, not a metaprogrammed lookup. A template can only do what this document describes.

## 2. Tags

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
- **Without** this comment, a template declares no local list: `render` passes through whatever locals it is given, unchecked, and the template may also read anything already present in the caller's environment (see section 8).
- If anything precedes the comment on an earlier line (even one blank line), it is just an ordinary, inert comment, not a locals declaration.

## 3. Expressions

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
- `yield` and `yield :key` are always parsed as calls (see section 8).
- A bare capitalized word is rejected outright — `"constants are not supported: 'Time'"` — templates cannot reach Ruby constants.
- These words are reserved and rejected with a dedicated message (`"'x' is not supported in templates"`): `and or not do end if unless elsif else then while until case when def class module begin rescue return`.

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

## 4. Statements

A `<% %>` tag holds exactly one statement: an assignment, or an expression evaluated for its side effect (value discarded). `<%= %>`/`<%== %>` only ever hold an expression — `<%= x = 1 %>` is a `SyntaxError`.

### Conditionals

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` follow Ruby's rules; `elsif` after `else`, a stray `else`/`elsif`/`end`, or a block never closed by `end` are all `SyntaxError`s naming the opening line.

### Loops

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` are recognized only as a suffix on the block head (`x.each do |...|`). **As built**, both require declaring one or two block parameters — `xs.each do end` is a `SyntaxError` ("takes one or two block parameters"), where plain Ruby allows zero.
- Array + one param: the item. Array + two params: an `Array` item is destructured (`a, b = item[0], item[1]`); otherwise the second is `nil`.
- `each_with_index` on an Array: `item, i`. On a Hash: the first param is a `[key, value]` pair, the second the index.
- `each` on a Hash with two params: `key, value` directly; with one param: a `[key, value]` pair.
- Iterating `nil`, a `Time`, or any scalar is a `RuntimeError` (`"undefined method 'each' for Time"`) — never a silent no-op.
- A block parameter shadows a same-named outer local only for the loop and is removed after (`refute env.key?("item")` once the loop ends). A variable that existed before the block is the *same* variable inside it (visible after the loop too); one **first assigned inside** the block is block-local — `nil` at the start of every iteration, gone afterward.

### Block calls (helpers)

`do ... end` is also how a receiverless helper call takes a block — the only other legal use of a block, and only when there is no receiver (`f.each do |x| end` is refused: "blocks are only supported on each, each_with_index and helper calls"):

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

Whether the block's result is printed follows the tag: `<%= helper do |x| %>` prints it, `<% helper do |x| %>` discards it. Exactly one block parameter is ever bound; a helper block never gets an index or a second value.

### Assignment

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

Only `name = expr` for one plain local — no `@ivar = ...`, no `arr[0] = ...`/`h[:k] = ...`, no `a, b = ...`. The same block-local rule from `each` applies to assignments inside `if`/`unless` nested in a block.

## 5. Per-type method table

`nil?`, `present?`, and `blank?` are checked **before** per-type dispatch, so they work on every value, including models and helper-returned objects (`blank?` is `false` for anything but `nil`/`false`/an empty `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params`). Arithmetic (`+ - * / %`) and comparison (`== != < > <= >=`) exist only as **infix operators**, never `.method` calls — an operator glyph can never follow a `.` in this grammar.

| Type | Methods | Example |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values`, plus `h[key]` | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`, plus `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`, plus `params[key]` | `params[:id]` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s` (returns `""`) | |

Indexing (`x[key]`) is a distinct grammar production (section 3), not a `.[]` call: `Array`/`String` take an integer index, `Hash` matches any key by its `to_s` (`h[:k]` and `h["k"]` are the same entry), `Errors` matches by symbol, `Params` by `to_s`.

Printing (`<%= %>`/interpolation) beyond `to_s` above: `Array` prints as an inspect-like list — `[1, "a", nil]` renders the text `[1, "a", nil]` (then gets escaped, so quotes become `&quot;`); `Hash` falls back to Ruby's own `Hash#to_s`; a `Cybertrain::Model` prints as `#<Post id: 7>` (never its attributes); anything else prints via its own `to_s`. An unlisted method on any of the above is a `RuntimeError` (`"undefined method 'first' for Time"`). `Integer` division/modulo by zero is `"divided by 0"`; `Float` follows IEEE-754 instead (`Infinity`/`NaN`, no error).

## 6. Models in templates

A `Cybertrain::Model` subclass (a generated `Post`, `Note`, ...) resolves a bare name in this order (`Interpreter#model_method`):

1. Five built-ins, always available: `id`, `persisted?`, `new_record?`, `to_param` (`id.to_s`), `errors` (an `Errors`, section 5).
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

## 7. Helpers and the form builder

Every receiverless call goes to `Helpers#helper_call` (`helpers.rb`), which matches one of the built-ins below, treats a name ending in `_path`/`_url` as a generated route helper (via `Cybertrain::Views.url_resolver`, raising `"no routes"` until the app installs one), or raises `"undefined helper 'name'"`.

| Helper | Signature | Notes / example |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` escaped unless already `SafeString`; **no `method:`** — raises, telling you to use `button_to` (no rails-ujs/turbo faking of DELETE links) |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | one-button `<form class="button_to">`; hidden `_method` for any verb but `get`/`post`, plus the CSRF field when a session exists |
| `form_with` | `form_with(model:, url:, method:, class:) do \|f\| ... end` | needs a block; `model:` new → collection route + POST, persisted → member route + PATCH; `[parent, child]` for a nested route; `url:`/`method:` override the derived action/verb |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` | see section 8 |
| `h`, `escape` | `h(text)` | escapes; a `SafeString` passes through unescaped |
| `raw` | `raw(text)` | wraps text in a `SafeString` (prints unescaped) |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`; `pluralize(2, "mouse")` → `"2 mice"` (built-in irregulars); explicit third arg always wins |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n)` | `1234567` → `"1,234,567"`; `-1000` → `"-1,000"`; `1234.5` → `"1,234.5"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Rails-style buckets, no seconds precision: `"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`, `content_for(:key, "text")`, `content_for?(:key)` | see section 8 |
| `csrf_meta_tags` / `csrf_token` | | empty / absent with no controller session |
| `flash` | | `Hash`-like: `flash[:notice]` |
| `params` | | the current `Cybertrain::Params` |
| `request_path` | | current path, `""` with no controller |
| `url_for` | `url_for(target)` | `String` as-is, `Model` → member route, `[parent, child]` → nested route |
| `*_path` / `*_url` | e.g. `post_path(post)` | generated by the app, resolved via `Cybertrain::Views.url_resolver` |

Every helper text argument follows one rule: a `SafeString` passes through unescaped, anything else is escaped — `link_to raw('<b>raw</b>'), post` prints the bold tag literally, but `link_to post.title, post` escapes it.

### FormBuilder (`f` in `form_with ... do |f|`)

Every method returns a `SafeString`; an unlisted one is a `RuntimeError` (`"undefined method 'color_wheel' for FormBuilder"`).

| Method | Renders |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — default text is the humanized attribute (`published_at` → "Published at", `author_id` → "Author"); explicit text is escaped unless a `SafeString` |
| `f.text_field :title` (also `email_field`, `password_field`, `number_field`, `date_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`; `password_field` never emits `value=` |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>` (leading `\n`, as Rails does — browsers eat the first newline) |
| `f.check_box :published` | hidden `value="0"` input then the real checkbox, so an unchecked box still submits `"0"` |
| `f.submit` / `f.submit "Text"` | default text `"Create Post"`/`"Update Post"` (by `persisted?`), or `"Save changes"` with no model |

With a model, fields are named `post[title]`/`id="post_title"` (`Inflector.underscore(model.model_name)` as scope); with `form_with(url: ...)` and no model, the bare attribute name is used for both. Extra keyword args become HTML attributes in order given: `true` → `attr="attr"`, `false`/`nil` dropped, anything else → `attr="value"` (escaped), underscores become hyphens (`data_confirm: "Sure?"` → `data-confirm="Sure?"`), and `class:` merges with the automatic `field_with_errors` class added when `model.errors.key?(attr)`.

## 8. Layouts, `yield`, `content_for`, partials

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

### File resolution (`engine.rb`)

`"posts/show"` and `"posts/show.html.erb"` name the same template. Development reads `app/views/` from disk with `cache: false` (a file is re-read and re-parsed whenever its mtime or size changes); the test environment reads from disk with `cache: true` (parsed once). A production binary never touches disk: `cybertrain build` runs `spin run gen -- --embed-views`, which writes every `*.erb` under `app/views/` (dotfiles and symlinked directories skipped) into `gen/views.rb`, and `Engine.embedded(sources)` parses each entry once (error messages keep the same `posts/show.html.erb:12` shape); a binary whose table is empty refuses to boot in production. A missing template raises `Cybertrain::Template::MissingTemplate` — `"Missing template <full path>"` from disk, `"Missing template posts/nope.html.erb (embedded)"` from the table.

## 9. Errors

Two exception classes, both in `ast.rb`'s `Cybertrain::Template` namespace (distinct from `::SyntaxError`/`::RuntimeError`):

- **`SyntaxError`** — raised while tokenizing/parsing, before any interpretation. Shape: `"<template>:<line>: <what>"`, e.g. `"posts/show:2: 'if' without 'end'"`, `"posts/show:1: unterminated <% tag"`, `"posts/show:1: unexpected ')' in 'foo(1))'"`. Raised directly by `Engine#template` (hence `#render`/`#render_with_layout`) when a page or layout file fails to parse — never caught or rewrapped by the interpreter.
- **`RuntimeError`** — raised while evaluating, same message shape, but `<template>` is whichever template is *currently rendering* (`Interpreter#render` swaps `@name` in and out) — a partial's own error keeps the partial's name and line, never the caller's: `"posts/_row:1: undefined method 'bogus' for String"`.

Any plain `StandardError` from a helper or `FormBuilder`/custom-object method call (a bare `raise "text"`, `ArgumentError`, `KeyError`, even a `Cybertrain::Template::RuntimeError` from a nested `render`) is caught and "relocated": rewritten to `"<current template>:<current line>: <original message>"`, unless it is already exactly the last-relocated message (a nested `render` already stamped its own, more specific location), in which case it passes through unchanged. A `Cybertrain::Template::SyntaxError` raised by a helper (a partial that fails to parse, mid-render) is never rewrapped — it keeps its own `"<partial>:<line>: ..."` message and class, so a broken partial is always reported as a `SyntaxError` about itself, not a `RuntimeError` about whoever rendered it.

`MissingTemplate` (`StandardError`, `engine.rb`) is raised **unwrapped**, no `template:line` prefix, from a top-level `Engine#template`/`#render`/`#render_with_layout` call (e.g. a controller rendering a missing action template or layout): `"Missing template <path>"`. The same exception raised *inside* a template via the `render` helper's partial lookup goes through relocation instead and comes out a `RuntimeError`: `"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`.

## 10. Differences from Rails ERB

| Rails ERB | Cybertrain |
| --- | --- |
| Compiled to a Ruby method; any Ruby, any object, any method works | Interpreted against fixed per-type dispatch tables; only what section 5 lists is callable |
| `ActiveSupport::SafeBuffer` is a `String` subclass | `SafeString` is a separate wrapper class — only `to_s`/`html_safe?`/`size`/`length`/`empty?` are callable on it |
| Blocks: `each`, `{ }`, `map`, any Enumerable method | Only `do...end`, and only on `each`/`each_with_index`/a helper call |
| `xs.each { }` — zero block params is fine | `each`/`each_with_index` require declaring 1 or 2 block params |
| `link_to text, path, method: :delete` (JS-driven) | No `method:` on `link_to` — use `button_to` for a real non-GET form |
| Strict locals accept `name: default_expr` (Rails 7.1) | Only bare `name:` (required); a default-value entry is a `SyntaxError` |
| Undefined ivar/local resolves via Ruby / the view context's methods | `@x` is a plain, never-failing env lookup; a bare undefined local is an explicit, closed helper-call attempt (`"undefined helper"` if no match) |
| `and`/`or`/`not`, `case/when`, ranges, regexes, multiple assignment all work | None exist; the reserved words fail with a specific "not supported in templates" message, not a generic parse error |
| Numeric literals: hex, octal, binary, exponents, rationals | Only decimal integers/floats with optional `_` separators |
| `:"quoted symbol"`, `:+` operator symbols | Symbols are identifier characters only |
| `foo (x)`, `foo [x]` (space tolerated, sometimes with a warning) | Both are hard `SyntaxError`s — no space before a call's `(` or an index's `[` |
| Nested unparenthesized calls resolved by Ruby's own parser | Only the outermost call in an expression gets parenthesis-free arguments |
| An undeclared/misspelled attribute reliably raises `NoMethodError` | Silently renders blank unless the specific generated model overrides `attribute_or_method?` (tracked gap, not a guarantee) |
| `1 / 0` and `1.0 / 0` both raise `ZeroDivisionError` | `Integer` division/modulo by zero raises `"divided by 0"`; `Float` follows IEEE-754 (`Infinity`/`NaN`), no error |
| `distance_of_time_in_words`/pluralization support i18n locales | English-only, no locale support |
