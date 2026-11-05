---
source_sha256: 2a9e8e996256fc4501968bb672c57b50fbb1cda1f3f80d6640176de81db378d3
---
# Справочник по языку шаблонов Cybertrain

Представления Cybertrain (`app/views/**/*.html.erb`) выглядят как ERB из Rails, но не являются Ruby: они разбираются во время выполнения (в режиме разработки и в тестах — из `app/views/` на диске; в продакшен-бинарнике — из таблицы строк, которую `cybertrain build` встраивает через `gen/views.rb`), разбиваются на токены и разбираются в AST, один раз компилируются в плоское дерево узлов и обходятся интерпретатором, проходящим по дереву.

Этот документ описывает ровно то, что этот конвейер принимает и выполняет. Там, где он расходится с разделом 7 `docs/design.md` (исходным черновиком спецификации) или с ожиданиями разработчика на Rails, прав код, и этот документ об этом говорит (ищите «**As built**»).

## Что здесь является Ruby, а что нет

Шаблоны **не** являются Ruby. В Spinel (AOT-компиляторе Ruby от Matz, на который нацелен cybertrain) нет `eval`, поэтому вариант «интерпретировать собственный Ruby представления во время запроса» даже не рассматривался (D9 в `docs/design.md`); вместо этого выполняется небольшая замкнутая грамматика, которая лишь внешне похожа на синтаксис ERB/Ruby. Внутри тега нет произвольного Ruby — только то, что `ExprParser` (`parser.rb`) распознаёт как инструкцию или выражение. Нет `eval`, `send`, `instance_eval`, определений методов/классов/модулей, `require`, исключений (`begin/rescue`), диапазонов, регулярных выражений и множественного присваивания. Блоки есть только там, где их перечисляет этот документ: циклы `each`/`each_with_index`/`each_slice`, фиксированный набор методов Array и Hash (`map`, `select`, `sum`, `group_by` ... — см. [Блоки](#blocks)), вызовы хелперов (`form_with(...) do |f| ... end`) и построитель `tag`. Каждый вызов метода (`recv.name`) разрешается написанными вручную таблицами диспетчеризации `case` в `interpreter.rb` по классу Ruby получателя во время выполнения; имя, которого нет в таблице этого типа, приводит к `RuntimeError` — нет ни `method_missing`, ни рефлексии, и (согласно `Interpreter#call_method`) именно отсутствие `send` в Spinel объясняет, почему это `case`, а не поиск через метапрограммирование. Шаблон может делать только то, что описано в этом документе.

<details><summary>Где это находится в исходниках — восемь файлов конвейера шаблонов</summary>

Конвейер находится в `cybertrain/template/`:

| Файл | Роль |
| --- | --- |
| `lexer.rb` | Делит исходный текст на теги `<% %>`/`<%= %>`/`<%== %>`/`<%# %>` и обычный текст |
| `parser.rb` | `TreeBuilder` вкладывает теги в AST; `ExprParser` разбирает грамматику выражений внутри одного тега |
| `ast.rb` | Классы узлов AST, которые создаёт парсер |
| `inode.rb` | `Compile` уплощает AST в мономорфные `INode` (целочисленный «вид» плюс типизированные слоты) для быстрой интерпретации |
| `interpreter.rb` | Обходит `INode` по `env` (`Hash<String, value>`); содержит все таблицы «какие методы существуют» для каждого типа |
| `helpers.rb` | `link_to`, `form_with`, `render`, `pluralize`, ... — всё, что шаблон вызывает без получателя |
| `form_builder.rb` | `f`, передаваемый в `form_with(...) do \|f\| ... end` |
| `engine.rb` | Загружает исходники `.html.erb` — с диска из корневого каталога или из встроенной таблицы `gen/views.rb` (`Engine.embedded`), — разбирает их (и при необходимости кэширует), отрисовывает с макетом |

</details>

## Теги

| Тег | Значение |
| --- | --- |
| `<% code %>` | Выполняет инструкцию; ничего не выводит |
| `<%= expr %>` | Вычисляет `expr` и выводит его с HTML-экранированием |
| `<%== expr %>` | Вычисляет `expr` и выводит его **без** экранирования |
| `<%# comment %>` | Игнорируется (кроме формы `locals:` в строке 1, см. ниже) |

Управление пробельными символами (`Lexer.tokenize`):

- Тег `<% %>`/`<%# %>`, который является **единственным** содержимым своей строки (по обе стороны до переводов строки — только пробелы/табуляции), молча поглощает свой отступ и завершающий перевод строки, как режим обрезки ERB в Rails. `<%= %>`/`<%== %>` **никогда** не обрезаются так автоматически, даже если стоят на строке одни.
- `<%-` явно удаляет пробелы/табуляции перед тегом, а `-%>` удаляет один перевод строки сразу после него — для тега любого вида. Оба ничего не делают, если с этой стороны строки есть что-то кроме пробельных символов.
- `<%%` в тексте — буквальный `<%`; `%%>` внутри тега — буквальный `%>`, который не закрывает тег.
- `<% # a Ruby-style comment %>` (тег кода, содержимое которого начинается с `#`) игнорируется, как `<%# %>`. Комментарий **после** настоящего кода в том же теге не поддерживается — `<% x = 1 # note %>` даёт `SyntaxError`.
- Незакрытые теги вызывают ошибку на этапе лексического анализа: `"posts/show:2: unterminated <% tag"`.

### Комментарий строгих локальных переменных

Тег комментария, содержимое которого начинается с `locals:` **и который является самым первым тегом файла, в строке 1**, объявляет единственные локальные переменные, которые принимает шаблон (почти всегда партиал):

```erb
<%# locals: (post:, comment:) %>
<%= post.title %>
```

- `<%# locals: () %>` (пустой список) означает «этот партиал не принимает локальных переменных».
- Каждая запись должна быть голым `name:` в нижнем регистре (`Lexer.identifier?` принимает только `[a-z_][a-z0-9_]*`). **As built:** в отличие от Rails 7.1, записи не могут иметь значение по умолчанию — `<%# locals: (post:, comment: nil) %>`, ровно та форма, которую поддерживает Rails 7.1, даёт `SyntaxError`: `"t:1: bad strict locals entry 'comment: nil' (expected name:)"`, потому что `comment: nil` не оканчивается на `:`. Фактически каждая объявленная локальная переменная обязательна. Некорректная спецификация (без скобок) вызывает `"t:1: bad strict locals comment (expected locals: (name:, ...))"`.
- **Без** этого комментария шаблон не объявляет списка локальных переменных: `render` передаёт любые полученные локальные переменные без проверки, и шаблон может также читать всё, что уже есть в окружении вызывающего (см. [Макеты, `yield`, `content_for`, партиалы](#layouts-yield-content_for-partials)).
- Если перед комментарием на более ранней строке что-то есть (даже одна пустая строка), это просто обычный, ни на что не влияющий комментарий, а не объявление локальных переменных.

## Выражения

### Литералы

| Литерал | Синтаксис | Примечания |
| --- | --- | --- |
| Integer | `1`, `1_000` | подчёркивания разрешены; нет шестнадцатеричной/восьмеричной/двоичной записи и экспоненты |
| Float | `2.5`, `12_3.4_5` | цифра обязательна с обеих сторон `.`; экспоненциальной формы нет |
| String | `"..."`, `'...'` | двойные кавычки поддерживают интерполяцию и escape-последовательности; одинарные понимают только `\'` и `\\` |
| Symbol | `:title` | только символы идентификатора — нет `:"quoted"` и символов-операторов вроде `:+` |
| `nil` / `true` / `false` | | |
| Array | `[1, "a", :b]`, `[]` | элементы — полноценные выражения |
| Hash | `{ a: 1, b: "x" }`, `{}` | **только ключи в стиле символов**, той же формы, что и именованные аргументы; без `"key" => value` (hashrocket) |

Строки в двойных кавычках интерполируют `#{...}` (любое полноценное выражение, допускается вложение) и поддерживают `\n \t \r \0 \e \s`, `\"`, `\\`; любой другой экранированный символ проходит без изменений. Строка без `#{}` компилируется в простой литерал; строка с интерполяцией — в последовательность литеральных фрагментов и выражений.

### Переменные

- **`@ivar`** напрямую читает `env["ivar"]` — `@` лишь внешний синтаксис; согласно D9, «post — это и `@post`, и локальная `post`» в одном Hash окружения. Отсутствующая переменная экземпляра — просто `nil`: `[<%= @missing %>]` выводит `[]`, никогда не ошибку.
- **Голое имя локальной переменной** (`post`, `title`) тоже читает `env["name"]`, но если такого ключа **вовсе нет**, интерпретатор считает это вызовом хелпера без аргументов. Если ключ существует (даже привязанный к `nil` — скажем, объявленная, но не переданная строгая локальная переменная), возвращается его значение, без перехода к хелперу. Поэтому `<%= csrf_meta_tags %>` и `<%= flash %>` работают без скобок, а `<%= nope %>` завершается ошибкой `"undefined helper 'nope'"`, а не «нет такой локальной переменной».
- Локальные переменные берутся из параметров блоков `each`/`each_with_index`, параметра блока `form_with`, строгих локальных переменных партиала и `<% name = expr %>`.

### Вызовы методов

```erb
recv.method
recv.method(arg1, key: value)
recv&.method             # безопасно для nil: если recv равен nil, сразу даёт nil, аргументы не вычисляются
method(arg1, key: value) # вызов хелпера: без получателя
method arg1, key: value  # тот же вызов без скобок («командный» синтаксис)
```

- Список аргументов без скобок («командный») открывается только для **самого внешнего** вызова в выражении: `link_to "Show", post_path(post)` работает, а `link_to "Show", post_path post` даёт `SyntaxError` — внутренним вызовам нужны собственные скобки.
- Между целью вызова и её открывающей `(` пробел не допускается: работают и `link_to("x")`, и `link_to "x"`; `link_to ("x")` даёт `SyntaxError`.
- `yield` и `yield :key` всегда разбираются как вызовы (см. [Макеты, `yield`, `content_for`, партиалы](#layouts-yield-content_for-partials)).
- Голое слово с заглавной буквы сразу отвергается — `"constants are not supported: 'Time'"`: шаблоны не могут обращаться к константам Ruby.
- Эти слова зарезервированы и отвергаются с отдельным сообщением (`"'x' is not supported in templates"`) везде, где ожидается выражение: `and or not do end if unless elsif else then while until def class module begin rescue return`. `case` и `when` — самостоятельные инструкции ([`case`](#case)); внутри выражения (`<%= case x %>`) они отвергаются так же.

### Операторы, приоритет (от низкого к высокому)

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

`&&`/`||` возвращают операнд, а не приведённое булево значение (`nothing || title` вычисляется в `title`, а не в `true`). Условия проверяют **истинность**: ложны только `nil` и `false`, как в Ruby, — `0`, `""` и пустые массивы/хеши истинны (`<% if 0 %>yes<% end %>` выводит `yes`).

Индексирование — это `target[index]` **без пробела** перед `[` (`items [0]` — синтаксическая ошибка, `items[0]` — нет), и оно образует цепочки, как любой постфикс: `h["k"].first`, `params[:id]`.

## Инструкции

Тег `<% %>` содержит ровно одну инструкцию: присваивание или выражение, вычисляемое ради побочного эффекта (значение отбрасывается). `<%= %>`/`<%== %>` всегда содержат только выражение — `<%= x = 1 %>` даёт `SyntaxError`.

### Условия

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` следуют правилам Ruby; `elsif` после `else`, лишние `else`/`elsif`/`end` или блок, так и не закрытый `end`, — всё это `SyntaxError` с указанием строки открытия.

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

- Предмет вычисляется один раз; значения каждого `when` (одно или несколько, через запятую) по порядку сравниваются оператором `==` шаблона, и выполняется первая ветка с равным значением. Числа сравниваются по значению (`1` совпадает с `1.0`); String и Symbol — по значению и типу (`"a"` не совпадает с `:a`); записи — как это делает `==` (класс и `id`); Array и Hash — как это делает `==` (по значению, поэлементно); `SafeString` и `String` с одинаковым текстом равны. `===` нет: после `when` не бывает диапазонов, классов или регулярных выражений.
- `else` выполняется, когда ни одно значение не совпало; без `else` и без совпадения ничего не выводится.
- Между `case` и его первым `when` может стоять только пустой текст (отступы, переводы строк); он отбрасывается. Всё остальное там — `SyntaxError` (`"text between 'case' and its first 'when'"`).
- `when` вне `case` (`"'when' without 'case'"`), `case` без предмета или без `when`, `when` без значения или после `else`, а также `case`, так и не закрытый `end`, — это `SyntaxError` с номером строки. `then` по-прежнему зарезервировано: `<% when :a then x %>` — `SyntaxError`.
- Локальная переменная, впервые присвоенная внутри ветки, подчиняется правилу локальности того блока, в котором стоит, как и с `if`.

### Циклы

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` распознаются только как суффикс заголовка блока (`x.each do |...|`); коллекцией может быть любое выражение, в том числе вызов с блоком (`<% items.group_by { |i| i.kind }.each do |kind, list| %>`). **As built**: оба требуют объявить один или два параметра блока — `xs.each do end` даёт `SyntaxError` («takes one or two block parameters»), тогда как обычный Ruby допускает ноль.
- `<% x.each_slice(n) do |slice| %>...<% end %>` перебирает срезы по `n` элементов (последний может быть короче) и тоже требует одного или двух параметров; с двумя срез разбирается на части (`do |a, b|`), а второй равен `nil`, если срез короткий.
- Array + один параметр: элемент. Array + два параметра: элемент-`Array` деструктурируется (`a, b = item[0], item[1]`); иначе второй — `nil`.
- `each_with_index` на Array: `item, i`. На Hash: первый параметр — пара `[key, value]`, второй — индекс.
- `each` на Hash с двумя параметрами: непосредственно `key, value`; с одним параметром — пара `[key, value]`.
- Перебор `nil`, `Time` или любого скаляра — это `RuntimeError` (`"undefined method 'each' for Time"`), никогда не молчаливое бездействие.
- Параметр блока затеняет одноимённую внешнюю локальную переменную только на время цикла и после него удаляется (`refute env.key?("item")` после окончания цикла). Переменная, существовавшая до блока, внутри него — *та же самая* переменная (видна и после цикла); переменная, **впервые присвоенная внутри** блока, локальна для блока — `nil` в начале каждой итерации и исчезает после.

### Вызовы с блоком (хелперы)

`do ... end` — это также способ передать блок вызову хелпера без получателя (о вызове с получателем см. [Блоки](#blocks)):

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

Выводится ли результат блока, зависит от тега: `<%= helper do |x| %>` его выводит, `<% helper do |x| %>` отбрасывает. Привязывается всегда ровно один параметр блока; блок хелпера никогда не получает индекс или второе значение.

### Блоки

Вызов с получателем может принимать блок, `{ |x| expr }` или `do |x| ... end`, с нулём, одним или двумя параметрами. Какие методы его принимают, задано для каждого типа; блок в любом другом месте — это `SyntaxError`, возбуждаемый при выполнении вызова (`"String#upcase takes no block"`), а метод, которого у типа нет, — обычное `"undefined method 'x' for Array"`, с блоком или без.

| Получатель | Методы, принимающие блок | Значение блока используется как |
| --- | --- | --- |
| `Array` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | преобразованное значение, проверка, слагаемое, ключ сортировки, ключ группы |
| `Hash` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | то же самое, блок видит `|key, value|` (один параметр получает пару `[key, value]`); `select`/`reject` возвращают Hash, остальные — то, что метод Array возвращает для пар |
| построитель `tag` | каждый элемент (`tag.div do ... end`) | его **вывод** становится содержимым элемента ([Построитель tag](#the-tag-builder)) |

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

- **Значение, а не вывод.** Для методов Array и Hash важно *значение* блока: выражение блока `{ }` или последняя инструкция блока `do`, которая должна быть инструкцией-выражением (`<% x * 2 %>`); иначе — `"map's block must end in a value"` (присваивание или текст). То, что выводят предыдущие инструкции блока `do`, отбрасывается. Блок `do` у такого метода стоит в собственном теге, с присваиванием (`<% total = items.sum do |li| %>`) или с выводом (`<%= items.map do |x| %>`).
- **Никаких изменений.** У шаблонов нет способа изменить аккумулятор, поэтому `each_with_object` и `inject` в таблице нет (`"undefined method 'each_with_object' for Array"`): используйте `map`, `select`, `sum` или `group_by`.
- Два параметра разбирают элемент Array на части, как это делает `each` (`pairs.map { |a, b| a }`).
- `sum` пустого Array равна `0`; сумма Integer — Integer, Float где угодно делает её Float (складывается с той же компенсацией, что в Ruby, так что `[0.1, 0.2, 0.3].sum` равно `0.6`); String отвергаются (`"sum: use join for Strings"`), как и всё, что не число.
- `sort_by`, `min_by`, `max_by` (и `sort`, `min`, `max` без блока) сравнивают так же, как `<` (числа, String, Time; иначе `"comparison of String with Integer failed"`). `sort_by` устойчива: равные ключи сохраняют порядок. `min_by`/`max_by` пустого Array равны `nil`.
- `group_by` возвращает Hash из каждого ключа **в виде String** (у всех Hash шаблона ключи — String: `:fruit` и `"fruit"` — одна группа) в элементы с этим ключом, в порядке первого появления.
- `each`, `each_with_index` и `each_slice` принимают блок в теге `<% %>` ([Циклы](#loops)); `items.each { |x| x }` — `SyntaxError`.
- Блок у метода `FormBuilder` или `Page` отвергается так же (`"FormBuilder#label takes no block"`), а методы Array без блока не принимают аргументов (`nums.sum(10)` — `"wrong number of arguments for 'sum'"`).
- Если блок возбуждает исключение, его параметры и локальные переменные восстанавливаются до того, как ошибка покинет вызов.
- Блоку `{ }` нужен получатель: `shout { |x| x }` — `SyntaxError` (вызовы хелперов принимают `do ... end`).
- Параметры блока затеняют внешние имена на время вызова и восстанавливаются после него; локальная переменная, впервые присвоенная в блоке `do`, локальна для блока, как в `each`.

### Присваивание

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

Только `name = expr` для одной простой локальной переменной — нет `@ivar = ...`, нет `arr[0] = ...`/`h[:k] = ...`, нет `a, b = ...`. То же правило локальности для блока, что и у `each`, применяется к присваиваниям внутри `if`/`unless`, вложенных в блок.

## Таблица методов по типам

`nil?`, `present?` и `blank?` проверяются **до** диспетчеризации по типу, поэтому работают на любом значении, включая модели и объекты, возвращённые хелперами (`blank?` равен `false` для всего, кроме `nil`/`false`/пустых `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params`). Арифметика (`+ - * / %`) и сравнение (`== != < > <= >=`) существуют только как **инфиксные операторы**, никогда как вызовы `.method` — в этой грамматике символ оператора не может стоять после `.`.

| Тип | Методы | Пример |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` `sum` `min` `max` `sort` `uniq` `compact` `flatten` `take(n)` `drop(n)` `each_slice(n)` (Array из Array) `zip(other)`, а также методы с блоком из раздела [Блоки](#blocks) | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values` `to_a` (пары `[key, value]`), а также `h[key]` и методы с блоком из раздела [Блоки](#blocks) | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`, а также `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`, а также `params[key]` | `params[:id]` |
| `Page` (`Relation#page`) | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s` (возвращает `""`) | |

Индексирование (`x[key]`) — отдельное правило грамматики ([Выражения](#expressions)), а не вызов `.[]`: `Array`/`String` принимают целочисленный индекс, `Hash` сопоставляет любой ключ по его `to_s` (`h[:k]` и `h["k"]` — одна и та же запись), `Errors` — по символу, `Params` — по `to_s`.

Вывод (`<%= %>`/интерполяция) помимо `to_s` выше: `Array` выводится как список в духе inspect — `[1, "a", nil]` выводит текст `[1, "a", nil]` (затем экранируется, поэтому кавычки становятся `&quot;`); `Hash` откатывается к собственному `Hash#to_s` Ruby; `Cybertrain::Model` выводится как `#<Post id: 7>` (никогда не его атрибуты); всё остальное выводится через собственный `to_s`. Неперечисленный метод у любого из этих типов — это `RuntimeError` (`"undefined method 'first' for Time"`). Целочисленное деление или остаток от деления на ноль для `Integer` — `"divided by 0"`; `Float` вместо этого следует IEEE-754 (`Infinity`/`NaN`, без ошибки).

## Модели в шаблонах

Подкласс `Cybertrain::Model` (сгенерированный `Post`, `Note`, ...) разрешает голое имя в таком порядке (`Interpreter#model_method`):

1. Пять встроенных, доступных всегда: `id`, `persisted?`, `new_record?`, `to_param` (`id.to_s`), `errors` (`Errors`, [Таблица методов по типам](#per-type-method-table)).
2. `read_attribute(:name)` — сгенерированный столбец.
3. `read_association(:name)` — сгенерированная ассоциация `has_many`/`belongs_to`.
4. `call_view_method(:name)` — написанный вручную `def` без аргументов, который генератор моделей нашёл в `app/models/**/*.rb` (никогда с аргументами).

```erb
<%= post.title %>            <%# read_attribute %>
<% post.comments.each do |c| %>...<% end %>   <%# read_association %>
<%= post.summary %>          <%# call_view_method %>
<%= post.errors.full_messages.join(", ") %>
```

Если все четыре отвечают `nil`, `attribute_or_method?(:name)` решает, было ли это допустимым именем, которое просто содержит `nil` (возвращается `nil`), или опечаткой (`"undefined method 'bogus' for Post"`).

**As built — настоящий пробел, который отмечает сам файл интерпретатора** (см. комментарий `TODO(integrator)` над `class Model` в `interpreter.rb`): *базовый* `Cybertrain::Model#attribute_or_method?` всегда возвращает `true`. Только сгенерированная модель, переопределяющая его явным `case` (как это делают написанные вручную тестовые модели), действительно возбуждает ошибку при опечатке; без такого переопределения атрибут или метод с опечаткой молча выводится пустым вместо ошибки. Не рассчитывайте, что опечатки отлавливаются, если не знаете, что модель переопределяет этот хук.

Две модели сравниваются через `==` по классу и `id` (`Model#==`), доступному как обычный оператор `==` (встроенная диспетчеризация равенства, а не `call_method`).

## Хелперы и построитель форм

Каждый вызов без получателя идёт в `Helpers#helper_call` (`helpers.rb`), который сопоставляет его с одним из встроенных хелперов ниже; внутри шаблона [компонента](#components) затем пробует методы представления этого компонента; считает имя, оканчивающееся на `_path`/`_url`, сгенерированным хелпером маршрута (через `Cybertrain::Views.url_resolver`, возбуждая `"no routes"`, пока приложение его не установит); затем пробует [хелперы приложения](#application-helpers); или возбуждает `"undefined helper 'name'"`.

| Хелпер | Сигнатура | Примечания / пример |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` экранируется, если это ещё не `SafeString`; **нет `method:`** — возбуждает ошибку, предлагая использовать `button_to` (никакой имитации ссылок DELETE через rails-ujs/turbo) |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | `<form class="button_to">` с одной кнопкой; скрытый `_method` для любого глагола, кроме `get`/`post`, плюс поле CSRF, когда есть сессия |
| `form_with` | `form_with(model:, url:, method:, class:, multipart:) do \|f\| ... end` | нужен блок; новая `model:` → маршрут коллекции + POST, сохранённая → маршрут элемента + PATCH; `[parent, child]` для вложенного маршрута; `url:`/`method:` переопределяют выведенные действие/глагол; `multipart: true` добавляет `enctype="multipart/form-data"` (обязательно для `f.file_field`; никогда не угадывается по блоку и возбуждает `ArgumentError` на GET-форме) |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` / `render component: "card", k: v` | см. [Макеты, `yield`, `content_for`, партиалы](#layouts-yield-content_for-partials) и [Компоненты](#components) |
| `h`, `escape` | `h(text)` | экранирует; `SafeString` проходит без экранирования |
| `raw` | `raw(text)` | оборачивает текст в `SafeString` (выводится без экранирования) |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`; `pluralize(2, "mouse")` → `"2 mice"` (английские правила словоизменения Rails по умолчанию, через `Cybertrain::Inflector`; правила, определённые приложением, не поддерживаются); явный третий аргумент всегда побеждает |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n)` | `1234567` → `"1,234,567"`; `-1000` → `"-1,000"`; `1234.5` → `"1,234.5"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | интервалы в стиле Rails, без точности до секунд: `"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`, `content_for(:key, "text")`, `content_for?(:key)` | см. [Макеты, `yield`, `content_for`, партиалы](#layouts-yield-content_for-partials) |
| `csrf_meta_tags` / `csrf_token` | | пусто / отсутствует без сессии контроллера |
| `flash` | | похож на `Hash`: `flash[:notice]` |
| `params` | | текущие `Cybertrain::Params` |
| `request_path` | | текущий путь, `""` без контроллера |
| `url_for` | `url_for(target)` | `String` как есть, `Model` → маршрут элемента, `[parent, child]` → вложенный маршрут |
| `paginate` | `paginate(page, path)` | `page` — это `Cybertrain::Page` (из `Relation#page`); выводит `<nav class="pager">` с «Newer» (`rel="prev"`), `<span class="pager-current">Page N</span>` и «Older» (`rel="next"`); ссылка опускается, если такой страницы нет. Каждая ссылка — это `path` плюс строка запроса текущего запроса с заменённым `page` (для страницы 1 он убирается), заново закодированная и HTML-экранированная; `path` с собственным `?query` использует вместо этого его. `Page` в шаблоне также отвечает на `number`, `per`, `row_offset`, `next?`, `prev?`, `next_number`, `prev_number` (`<% if @page.next? %>`) |
| `*_path` / `*_url` | например, `post_path(post)` | генерируются приложением, разрешаются через `Cybertrain::Views.url_resolver` |
| `tag` | `tag.div(content, attrs) do ... end` | построитель tag: см. [Построитель tag](#the-tag-builder) |
| `content_tag` | `content_tag(name, content = nil, attrs)` или с блоком `do` | `content_tag "p", "<i>", class: "n"` → `<p class="n">&lt;i&gt;</p>`; те же правила, что у `tag` |
| `safe_join` | `safe_join(array, sep = "")` (без именованных аргументов) | соединяет в `SafeString`, экранируя каждый элемент и разделитель, которые ещё не `SafeString`: `safe_join([tag.b("a"), "<"], " ")` → `<b>a</b> &lt;` |
| `class_names` | `class_names(*values)` | `class_names`/`token_list` из Rails: слова из String и Symbol, из Array (в том числе вложенных) и из каждого ключа Hash с истинным значением, каждое слово один раз; именованные аргументы — ещё один такой Hash: `class_names("btn", active: @on, big: false)` → `"btn active"` |
| `dom_id` | `dom_id(record, prefix = "")` (префикс позиционный, как в Rails) | `"article_12"`, `"new_article"` для несохранённой записи, `dom_id(@article, "edit")` → `"edit_article_12"` (`Cybertrain::Html.dom_id` в Ruby) |
| `turbo_stream_from` | `turbo_stream_from(*streams, ws: false)` | один `<turbo-stream-source>`, подписывающий страницу на потоки (String или записи с именами вида `"articles:12"`); `ws: true` даёт URL `ws://`/`wss://` и требует запроса. См. [Реальное время](realtime.md#turbo-streams) |
| `signed_stream_name` | `signed_stream_name(*streams)` | только подписанный токен, для написанного вручную JavaScript |
| `stream_source_path` | `stream_source_path(*streams, mode: "json")` | путь точки входа потоков с токеном и `mode=json` (или `"raw"`) |

Каждый текстовый аргумент хелпера следует одному правилу: `SafeString` проходит без экранирования, всё остальное экранируется — `link_to raw('<b>raw</b>'), post` выводит тег жирного шрифта буквально, а `link_to post.title, post` его экранирует.

### Построитель tag

`tag` вычисляется в построитель (`Cybertrain::Html::TagBuilder`); любой вызванный у него метод — это элемент, который отрисовывает `Cybertrain::Html.tag` (его можно вызвать и из Ruby: `Html.tag("a", { href: "/x" }, "Go")`):

```erb
<%= tag.div(class: "card") do %>
  <%= tag.h2 @article.title, id: dom_id(@article) %>
<% end %>
<%= tag.input type: "text", name: "q", disabled: true %>   <%# <input type="text" name="q" disabled> %>
<%= tag.path d: "M0 0 L10 10" %>                         <%# SVG elements work %>
<%= tag.my_widget data: { turbo_frame: "f" } %>          <%# <my-widget data-turbo-frame="f"></my-widget> %>
```

- `<%= tag %>` сам по себе ничего не выводит.
- Имя элемента — имя метода с `_`, заменёнными на `-`; оно должно соответствовать `[a-z][a-z0-9-]*` (иначе `Html.tag` возбуждает `"invalid element name 'Div'"`).
- Содержимое — единственный позиционный аргумент (экранируется, если это не `SafeString`, так что `tag.script("alert(1)")` выводит свой текст экранированным) или **вывод** блока (`do ... end` или `{ expr }`, чьё значение выводится экранированным); блок побеждает. Без того и другого `tag.div` — это `<div></div>`.
- Пустые элементы (`area base br col embed hr img input link meta source track wbr`) отрисовываются без закрывающего тега; содержимое или блок для них — ошибка (`"br is a void element"`).
- Атрибуты — это именованные аргументы, по порядку: `nil` и `false` убирают атрибут, `true` отрисовывает его без значения (`disabled`), Array соединяет свои элементы, кроме `nil`, пробелами (`data: { ids: [1, 2] }` даёт `data-ids="1 2"`, а не JSON, как в Rails), `class:` принимает то же, что `class_names` (`class: ["btn", { active: @on }]`), Hash в `data:` и `aria:` раскрываются в `data-key="v"` / `aria-key="v"` с подчёркиваниями, заменёнными на дефисы (и `true`/`false` там записываются словами); любое другое значение-Hash — ошибка (`"attribute 'title' cannot be a Hash"`). Каждое значение экранируется, `SafeString` тоже. Имена атрибутов должны соответствовать `[a-zA-Z_:][-a-zA-Z0-9_:.]*` (`"invalid attribute name 'data-a b'"`); `onclick:` и подобные разрешены, раз их пишет автор.

### FormBuilder (`f` в `form_with ... do |f|`)

Каждый метод возвращает `SafeString`; неперечисленный — это `RuntimeError` (`"undefined method 'color_wheel' for FormBuilder"`).

| Метод | Выводит |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — текст по умолчанию — «очеловеченный» атрибут (`published_at` → «Published at», `author_id` → «Author»); явный текст экранируется, если это не `SafeString` |
| `f.text_field :title` (также `email_field`, `password_field`, `number_field`, `date_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`; `password_field` никогда не выводит `value=` |
| `f.file_field :cover` (также `accept: "image/*"`, `required: true`) | `<input type="file" name="post[cover]" id="post_cover">` — никогда не выводит `value=`, и атрибут не обязан быть столбцом; форма должна быть `form_with ..., multipart: true`; `multiple: true` возбуждает `ArgumentError` (один файл на поле) |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>` (ведущий `\n`, как в Rails, — браузеры съедают первый перевод строки) |
| `f.check_box :published` | скрытый input с `value="0"`, затем настоящий флажок, поэтому неотмеченный флажок всё равно отправляет `"0"` |
| `f.submit` / `f.submit "Text"` | текст по умолчанию `"Create Post"`/`"Update Post"` (по `persisted?`) или `"Save changes"` без модели |

С моделью поля называются `post[title]`/`id="post_title"` (`Inflector.underscore(model.model_name)` как область видимости); с `form_with(url: ...)` без модели для обоих используется голое имя атрибута. Дополнительные именованные аргументы становятся HTML-атрибутами в заданном порядке: `true` → `attr="attr"`, `false`/`nil` отбрасываются, всё остальное → `attr="value"` (с экранированием), подчёркивания становятся дефисами (`data_confirm: "Sure?"` → `data-confirm="Sure?"`), а `class:` объединяется с автоматическим классом `field_with_errors`, который добавляется, когда `model.errors.key?(attr)`.

## Хелперы приложения

Модуль в `app/helpers/` — это модуль хелперов, как в Rails: каждый его публичный метод можно вызвать из любого шаблона без получателя.

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

- **Сгенерированная диспетчеризация.** Шаблоны не умеют `send`, поэтому `spin run gen` читает `app/helpers/**/*.rb` как текст и пишет `gen/helpers.rb`: класс `ApplicationHelpers`, который включает каждый модуль (и хелперы маршрутов), и `case` по именам хелперов. Добавьте хелпер или измените его сигнатуру — и следующая сборка сгенерирует его заново (сервер разработки делает и то, и другое). `cybertrain generate helper prices` пишет пустой `PricesHelper` и тест.
- **Что считается хелпером.** Публичные методы экземпляра `module` (не `def self.x`, не сеттеры и не всё после `private` или `protected`), в каком бы файле они ни были. Шаблон передаёт значения по позиции или по ключу, поэтому каждый параметр именован: `*rest`, `**opts`, `...` — ошибки генератора, как и обязательный параметр после необязательного. У хелпера не больше трёх необязательных параметров (у сгенерированного `case` по ветке на каждое переданное сочетание, так что опущенный ключ получает значение по умолчанию самого метода). Неправильный вызов — это `ArgumentError` при отрисовке: `"wrong number of arguments for 'price' (given 0, expected 1)"`, `"unknown keyword 'cur' for 'price' (known: unit, precision)"`.
- **Зарезервированные имена.** Хелпер нельзя назвать как хелпер фреймворка (`link_to`, `render`, `tag`, `dom_id`, `params`, `content`, ...), как метод `Cybertrain::Template::Helpers` (публичный или приватный: `include` заменил бы его и для фреймворка), `yield` или с окончанием `_path` / `_url` (на них отвечают хелперы маршрутов); одно и то же имя в двух модулях — тоже ошибка. `spin run gen` останавливается, указывая файл, строку и причину.
- **Значения.** Аргументы приходят как значения шаблона (String, Integer, Float, `nil`, запись, Array, Hash); сужайте их через `Cybertrain::Cast` (`Cast.str`, `Cast.int`, `Cast.float`) перед арифметикой. То, что возвращает хелпер, выводится как любое значение: `String` экранируется, `SafeString` — нет, поэтому собирайте HTML с помощью `Cybertrain::Html.tag(name, attrs, content)`, `Html.safe_join`, `Html.class_names`, `Html.dom_id`, `Html.escape`, `Cybertrain::SafeString.of` или Ruby-форм хелперов ссылок, `link_to_path(text, path, attrs)` и `button_to_path(text, path, attrs)` (`method:` внутри `attrs`).
- **Блоки.** Хелпер с параметром `&block` принимает блок `do ... end`; `yield` (без аргументов) возвращает то, что вывел блок, в виде `SafeString`.

## Компоненты

Компонент — это класс с именованными аргументами и шаблон рядом с ним, в духе [ViewComponent](https://viewcomponent.org):

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

- Шаблон видит переменные экземпляра компонента как локальные (`title`), его публичные методы без параметров по имени (`value_text`) и `content` — то, что вывел блок `do` (`""` без него). Он отрисовывается без макета, может отрисовывать партиалы и другие компоненты и учитывается в `max_render_depth`, как партиал. Партиал, который он отрисовывает, методов компонента не видит. Имя партиала без каталога в шаблоне компонента (`render "chip"`) ищется в `app/components/` (`app/components/_chip.html.erb`); имя с каталогом (`render "shared/note"`) — в `app/views/`, как обычно.
- Компонент называют по его имени в snake_case без `_component`, как партиал называют по пути: `"card"` для `CardComponent`, `"admin/user_row"` для `Admin::UserRowComponent` (`app/components/admin/user_row_component.rb`). Шаблоны не могут называть константы.
- `spin run gen` пишет `gen/components.rb` по лексическому разбору, как для хелперов: строка класса, присваивания `@x =`, `def` без параметров и ключи `initialize`. `initialize` принимает только именованные аргументы (из них не больше трёх необязательных), и его шаблон должен существовать; отсутствующий или неизвестный ключ — это `ArgumentError` при отрисовке. Неизвестный компонент — `Cybertrain::Component::Unknown`: `` "no component 'crad' (app/components/crad_component.rb, then `spin run gen`)" ``.
- `cybertrain generate component card title value:integer` пишет класс, его шаблон и тест, который отрисовывает его через `Cybertrain::Test.render_component`.

### Отрисовка вне запроса

Рассылка, задача или тело письма отрисовываются без запроса:

```ruby
html = Cybertrain::Views.render_partial("articles/article", article: article)   # app/views/articles/_article.html.erb
card = Cybertrain::Views.render_component(CardComponent.new(title: "Visitors", value: 12))
```

Оба возвращают HTML в виде String, с хелперами приложения. Хелперы путей работают (`article_path(article)`), strict locals проверяются, а формы (`form_with`, `button_to`) отрисовываются без токена подлинности (страница с Turbo отправляет токен из `csrf_meta_tags`). Хелпер, которому нужен запрос, возбуждает `Cybertrain::Views::OutsideRequest` (`"csrf_token needs a request"`): `csrf_token`, `csrf_meta_tags`, `params`, `flash`, `request_path`, любой хелпер `*_url` и `turbo_stream_from ... ws: true`. Ссылки `paginate` несут только собственную строку запроса пути. (Голый `Cybertrain::Template::Helpers.new(nil)`, какой может построить модульный тест, вместо этого отвечает на них пустыми значениями.)

## Макеты, `yield`, `content_for`, партиалы

`Engine#render_with_layout(name, layout, env, helpers)` отрисовывает `name` в `env["__content"]` (`SafeString`), затем отрисовывает `layout` с тем же `env`:

```erb
<title><%= yield :title %></title>
<%= yield %>
```

`yield` выводит `env["__content"]`; `yield :key` выводит `env["__content_key"]` или ничего, если значение не задано. `yield` обрабатывается особо прямо в интерпретаторе и не может быть переопределён как хелпер. Страница заполняет слот через `content_for` в любом месте своего тела (порядок относительно `yield` не важен — страница полностью отрисовывается раньше макета):

```erb
<% content_for :title do %>Post: <%= @post.title %><% end %>
<% content_for :title, " (draft)" %>   <%# appends: calls accumulate, they don't replace %>
```

### Партиалы и `render`

```erb
<%= render "form", post: @post %>
<%= render partial: "form", locals: { post: @post } %>
<%= render "comments/comment", comment: c %>
```

- Голое имя без `/` разрешается в **собственном каталоге текущего шаблона** (через ключ окружения, который устанавливает механизм отрисовки, `__template_dir`): `render "form"` из `posts/show` ищет `posts/_form.html.erb`. Имя, содержащее `/`, — явный путь; префикс `_` получает только его последний сегмент (`"comments/comment"` → `comments/_comment.html.erb`).
- Партиал получает **копию всего окружения вызывающего** (переменные экземпляра и все локальные переменные, уже находящиеся в области видимости) плюс явные локальные переменные, переданные в `render`, — он не изолирован только тем, что было передано. Строгие локальные переменные проверяют по объявленному списку лишь имена, **явно переданные в этот вызов `render`**; они не мешают партиалу читать и какое-то другое имя, унаследованное из окружения вызывающего.
- Из области видимости партиала в область вызывающего копируются обратно только ключи `content_for` (`__content_*`); обычные локальные переменные, которые он присваивает, наружу не утекают.
- Отсутствующие или лишние локальные переменные относительно объявления `<%# locals: %>` — это `RuntimeError`: `"missing local 'post' for posts/_form.html.erb"`, `"unknown local 'extra' for posts/_form.html.erb"`.

### Разрешение файлов (`engine.rb`)

`"posts/show"` и `"posts/show.html.erb"` называют один и тот же шаблон. Режим разработки читает `app/views/` с диска с `cache: false` (файл перечитывается и заново разбирается, когда меняются его mtime или размер, и этот разбор пишет в кэш движка, поэтому сервер разработки всегда работает с одним воркером и игнорирует `SPINEL_WORKERS`, о чём сообщает в баннере при запуске); тестовое окружение читает с диска с `cache: true` (разбор один раз). Продакшен-бинарник никогда не обращается к диску: `cybertrain build` запускает `spin run gen -- --embed-views`, который записывает каждый `*.erb` из `app/views/` (скрытые файлы и каталоги-символические ссылки пропускаются) в `gen/views.rb`, а `Engine.embedded(sources)` разбирает каждую запись один раз, при запуске бинарника (сообщения об ошибках сохраняют ту же форму `posts/show.html.erb:12`), так что шаблон с синтаксической ошибкой останавливает запуск, а не ломает свою страницу; бинарный файл с пустой таблицей отказывается запускаться в production. Отсутствующий шаблон возбуждает `Cybertrain::Template::MissingTemplate` — `"Missing template <full path>"` с диска, `"Missing template posts/nope.html.erb (embedded)"` из таблицы.

Поиск файлов разрешает корень представлений и путь к шаблону через символические ссылки и загружает только обычные файлы внутри этого корня. Пути, выходящие за его пределы (в том числе через символические ссылки), возбуждают `MissingTemplate`; `exists?` возвращает для таких путей false.

## Ошибки

Два класса исключений, оба в пространстве имён `Cybertrain::Template` из `ast.rb` (отличны от `::SyntaxError`/`::RuntimeError`):

- **`SyntaxError`** — возбуждается при разбиении на токены и разборе, до какой-либо интерпретации. Форма: `"<template>:<line>: <what>"`, например `"posts/show:2: 'if' without 'end'"`, `"posts/show:1: unterminated <% tag"`, `"posts/show:1: unexpected ')' in 'foo(1))'"`. Возбуждается напрямую в `Engine#template` (а значит, в `#render`/`#render_with_layout`), когда файл страницы или макета не удаётся разобрать, — интерпретатор никогда его не перехватывает и не переоборачивает.
- **`RuntimeError`** — возбуждается при вычислении, та же форма сообщения, но `<template>` — это шаблон, который *отрисовывается в данный момент* (`Interpreter#render` подменяет `@name` на входе и выходе), — собственная ошибка партиала сохраняет имя и строку партиала, никогда не вызывающего: `"posts/_row:1: undefined method 'bogus' for String"`.

Любая обычная `StandardError` из вызова хелпера или метода `FormBuilder`/пользовательского объекта (голый `raise "text"`, `ArgumentError`, `KeyError`, даже `Cybertrain::Template::RuntimeError` из вложенного `render`) перехватывается и «перемещается»: переписывается в `"<current template>:<current line>: <original message>"`, если только это уже не в точности последнее перемещённое сообщение (вложенный `render` уже проставил своё, более точное место), — в этом случае оно проходит без изменений. `Cybertrain::Template::SyntaxError`, возбуждённая хелпером (партиал, который не удалось разобрать посреди отрисовки), никогда не переоборачивается — она сохраняет собственное сообщение `"<partial>:<line>: ..."` и класс, поэтому сломанный партиал всегда сообщается как `SyntaxError` о нём самом, а не как `RuntimeError` о том, кто его отрисовал.

`Cybertrain::Views::OutsideRequest` и `Cybertrain::Component::Unknown` тоже проходят без обёртки, сохраняя свой класс, так что вызывающий `Views.render_partial` может их перехватить.

`MissingTemplate` (`StandardError`, `engine.rb`) возбуждается **без обёртки**, без префикса `template:line`, из вызова верхнего уровня `Engine#template`/`#render`/`#render_with_layout` (например, когда контроллер отрисовывает отсутствующий шаблон действия или макет): `"Missing template <path>"`. То же исключение, возбуждённое *внутри* шаблона при поиске партиала хелпером `render`, проходит через перемещение и выходит как `RuntimeError`: `"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`.

## Отличия от ERB в Rails

| ERB в Rails | Cybertrain |
| --- | --- |
| Компилируется в метод Ruby; работает любой Ruby, любой объект, любой метод | Интерпретируется по фиксированным таблицам диспетчеризации для каждого типа; вызывать можно только то, что перечислено в [таблице методов по типам](#per-type-method-table) |
| `ActiveSupport::SafeBuffer` — подкласс `String` | `SafeString` — отдельный класс-обёртка: у него можно вызывать только `to_s`/`html_safe?`/`size`/`length`/`empty?` |
| Блоки: `each`, `{ }`, `map`, любой метод Enumerable | `{ }` и `do...end` у фиксированного списка методов Array/Hash (без `each_with_object`, `inject`), циклы `each`/`each_with_index`/`each_slice`, вызовы хелперов и `tag` |
| `xs.each { }` — ноль параметров блока допустим | `each`/`each_with_index` требуют объявить 1 или 2 параметра блока |
| `link_to text, path, method: :delete` (через JS) | У `link_to` нет `method:` — используйте `button_to` для настоящей не-GET формы |
| Строгие локальные переменные принимают `name: default_expr` (Rails 7.1) | Только голое `name:` (обязательное); запись со значением по умолчанию — `SyntaxError` |
| Неопределённая переменная экземпляра/локальная разрешается через Ruby / методы контекста представления | `@x` — простой, никогда не падающий поиск в окружении; голая неопределённая локальная — явная попытка вызова хелпера из замкнутого набора (`"undefined helper"`, если совпадения нет) |
| `case/when` с `===` (диапазоны, классы, регулярные выражения) | `case/when` только с `==` (числа по значению) |
| `and`/`or`/`not`, диапазоны, регулярные выражения, множественное присваивание — всё работает | Ничего этого нет; зарезервированные слова дают конкретное сообщение «not supported in templates», а не общую ошибку разбора |
| Числовые литералы: шестнадцатеричные, восьмеричные, двоичные, экспоненты, рациональные | Только десятичные целые/дробные с необязательными разделителями `_` |
| `:"quoted symbol"`, символы-операторы `:+` | Символы состоят только из символов идентификатора |
| `foo (x)`, `foo [x]` (пробел допускается, иногда с предупреждением) | Оба — жёсткие `SyntaxError`: никаких пробелов перед `(` вызова или `[` индекса |
| Вложенные вызовы без скобок разрешает собственный парсер Ruby | Аргументы без скобок получает только самый внешний вызов в выражении |
| Необъявленный атрибут или атрибут с опечаткой надёжно возбуждает `NoMethodError` | Молча выводится пустым, если конкретная сгенерированная модель не переопределяет `attribute_or_method?` (известный пробел, а не гарантия) |
| `1 / 0` и `1.0 / 0` оба возбуждают `ZeroDivisionError` | Целочисленное деление/остаток на ноль для `Integer` возбуждает `"divided by 0"`; `Float` следует IEEE-754 (`Infinity`/`NaN`), без ошибки |
| `distance_of_time_in_words`/плюрализация поддерживают локали i18n | Только английский, локали не поддерживаются |
| Каждый модуль из `app/helpers` подмешивается; любая сигнатура; хелпер может переопределить хелпер фреймворка | Модули разбираются при сборке в сгенерированный `case`: только именованные параметры, не больше трёх необязательных, никаких имён хелперов фреймворка и окончаний `_path`/`_url` ([Хелперы приложения](#application-helpers)) |
| ViewComponent: `render CardComponent.new(title: "x")`, `with_collection`, слоты | `render component: "card", title: "x"` по имени, `content` из блока; без коллекций и слотов ([Компоненты](#components)) |
