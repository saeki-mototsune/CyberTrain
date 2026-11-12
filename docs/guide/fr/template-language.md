---
source_sha256: 2f2c328fde36b079acea86515c42f22d3af9b2c18510dfd6025c30023d98325b
---
# Référence du langage de templates de Cybertrain

Les vues de Cybertrain (`app/views/**/*.html.erb`) ressemblent à de l’ERB de Rails, mais ne sont pas du Ruby&nbsp;: elles sont analysées à l’exécution (depuis `app/views/` sur le disque en développement et en test&nbsp;; dans un binaire de production, depuis la table de chaînes que `cybertrain build` intègre via `gen/views.rb`), découpées en lexèmes et analysées en un AST, compilées une fois en un arbre de nœuds plat, puis parcourues par un interpréteur qui parcourt l’arbre.

Ce document décrit exactement ce que ce pipeline accepte et exécute. Là où il diverge de la section 7 de `docs/design.md` (le projet de spécification initial) ou de ce qu’attendrait un développeur Rails, c’est le code qui a raison, et ce document le dit (cherchez «&nbsp;**Tel qu’implémenté**&nbsp;»).

## Ce qui est du Ruby ici, et ce qui n’en est pas

Les templates ne sont **pas** du Ruby. Spinel (le compilateur AOT de Ruby de Matz que vise cybertrain) n’a pas d’`eval`, donc «&nbsp;interpréter le Ruby propre à la vue au moment de la requête&nbsp;» n’a jamais été envisageable (D9 dans `docs/design.md`)&nbsp;; ce qui s’exécute à la place est une petite grammaire fermée qui ne fait qu’emprunter une syntaxe d’allure ERB/Ruby. Il n’y a pas de Ruby arbitraire dans une balise — seulement ce que `ExprParser` (`parser.rb`) reconnaît comme instruction ou expression. Il n’y a pas d’`eval`, de `send`, d’`instance_eval`, de définitions de méthodes/classes/modules, de `require`, d’exceptions (`begin/rescue`), d’intervalles, de regex, ni d’affectation multiple. Les blocs n’existent que là où ce document les énumère&nbsp;: les boucles `each`/`each_with_index`/`each_slice`, un ensemble fixe de méthodes d’Array et de Hash (`map`, `select`, `sum`, `group_by`... — voir [Blocs](#blocks)), les appels de helpers (`form_with(...) do |f| ... end`) et le constructeur `tag`. Chaque appel de méthode (`recv.name`) est résolu par des tables de dispatch `case` écrites à la main dans `interpreter.rb`, indexées par la classe Ruby du receveur à l’exécution&nbsp;; un nom absent de la table de ce type échoue avec une `RuntimeError` — il n’y a pas de `method_missing`, pas de réflexion, et (d’après `Interpreter#call_method`) c’est précisément l’absence de `send` dans Spinel qui fait que c’est un `case` et non une recherche par métaprogrammation. Un template ne peut faire que ce que décrit ce document.

<details><summary>Où cela se trouve dans le source — les huit fichiers du pipeline de templates</summary>

Le pipeline se trouve dans `cybertrain/template/`&nbsp;:

| Fichier | Rôle |
| --- | --- |
| `lexer.rb` | Sépare le source en balises `<% %>`/`<%= %>`/`<%== %>`/`<%# %>` et en texte brut |
| `parser.rb` | `TreeBuilder` imbrique les balises en un AST&nbsp;; `ExprParser` analyse la grammaire des expressions à l’intérieur d’une balise |
| `ast.rb` | Les classes de nœuds de l’AST que produit le parseur |
| `inode.rb` | `Compile` aplatit l’AST en `INode` monomorphes (un «&nbsp;kind&nbsp;» entier plus des emplacements typés) pour une interprétation rapide |
| `interpreter.rb` | Parcourt les `INode` dans un `env` (`Hash<String, value>`)&nbsp;; détient toutes les tables par type de «&nbsp;quelles méthodes existent&nbsp;» |
| `helpers.rb` | `link_to`, `form_with`, `render`, `pluralize`, ... — tout ce qu’un template appelle sans receveur |
| `form_builder.rb` | Le `f` passé par `form_with(...) do \|f\| ... end` |
| `engine.rb` | Charge les sources `.html.erb` — depuis le disque sous une racine, ou depuis la table intégrée `gen/views.rb` (`Engine.embedded`) —, les analyse (et éventuellement les met en cache), et les rend avec un layout |

</details>

## Balises

| Balise | Signification |
| --- | --- |
| `<% code %>` | Exécute une instruction&nbsp;; ne produit aucune sortie |
| `<%= expr %>` | Évalue `expr` et l’affiche, échappé pour le HTML |
| `<%== expr %>` | Évalue `expr` et l’affiche **sans** échappement |
| `<%# comment %>` | Ignoré (sauf la forme `locals:` de la ligne 1, ci-dessous) |

Contrôle des espaces (`Lexer.tokenize`)&nbsp;:

- Une balise `<% %>`/`<%# %>` qui est la **seule** chose sur sa ligne (rien que des espaces/tabulations de part et d’autre jusqu’aux sauts de ligne) avale silencieusement sa propre indentation et son saut de ligne final, comme le mode trim de l’ERB de Rails. `<%= %>`/`<%== %>` ne sont **jamais** rognées automatiquement de cette façon, même seules sur une ligne.
- `<%-` supprime explicitement les espaces/tabulations qui précèdent la balise, et `-%>` supprime le saut de ligne qui la suit immédiatement — pour tout type de balise. Les deux sont sans effet quand autre chose que des espaces occupe ce côté de la ligne.
- `<%%` dans le texte est un `<%` littéral&nbsp;; `%%>` dans une balise est un `%>` littéral qui ne ferme pas la balise.
- `<% # a Ruby-style comment %>` (une balise de code dont le contenu commence par `#`) est ignorée comme `<%# %>`. Un commentaire **après** du vrai code dans la même balise n’est pas pris en charge — `<% x = 1 # note %>` est une `SyntaxError`.
- Les balises non terminées lèvent une erreur dès l’analyse lexicale&nbsp;: `"posts/show:2: unterminated <% tag"`.

### Le commentaire de locals stricts

Une balise de commentaire dont le contenu commence par `locals:` **et qui est la toute première balise du fichier, sur la ligne 1**, déclare les seules variables locales qu’accepte un template (presque toujours un partiel)&nbsp;:

```erb
<%# locals: (post:, comment:) %>
<%= post.title %>
```

- `<%# locals: () %>` (liste vide) signifie «&nbsp;ce partiel ne prend aucune variable locale&nbsp;».
- Chaque entrée doit être un simple `name:` en minuscules (`Lexer.identifier?` n’accepte que `[a-z_][a-z0-9_]*`). **Tel qu’implémenté&nbsp;:** contrairement à Rails 7.1, les entrées ne peuvent pas porter de valeur par défaut — `<%# locals: (post:, comment: nil) %>`, la forme exacte que prend en charge Rails 7.1, est une `SyntaxError`&nbsp;: `"t:1: bad strict locals entry 'comment: nil' (expected name:)"`, car `comment: nil` ne se termine pas par `:`. Chaque variable locale déclarée est de fait obligatoire. Une spécification mal formée (parenthèses manquantes) lève `"t:1: bad strict locals comment (expected locals: (name:, ...))"`.
- **Sans** ce commentaire, un template ne déclare aucune liste de variables locales&nbsp;: `render` transmet toutes les variables locales qu’il reçoit, sans vérification, et le template peut aussi lire tout ce qui est déjà présent dans l’environnement de l’appelant (voir [Layouts, `yield`, `content_for`, partiels](#layouts-yield-content_for-partials)).
- Si quoi que ce soit précède le commentaire sur une ligne antérieure (ne serait-ce qu’une ligne vide), ce n’est qu’un commentaire ordinaire et inerte, pas une déclaration de locals.

## Expressions

### Littéraux

| Littéral | Syntaxe | Remarques |
| --- | --- | --- |
| Integer | `1`, `1_000` | tirets bas autorisés&nbsp;; ni hexadécimal, ni octal, ni binaire, ni exposant |
| Float | `2.5`, `12_3.4_5` | un chiffre est requis de chaque côté du `.`&nbsp;; pas de forme à exposant |
| String | `"..."`, `'...'` | les guillemets doubles interpolent et acceptent les échappements&nbsp;; les guillemets simples ne comprennent que `\'` et `\\` |
| Symbol | `:title` | caractères d’identifiant uniquement — pas de `:"quoted"`, pas de symboles d’opérateur à la `:+` |
| `nil` / `true` / `false` | | |
| Array | `[1, "a", :b]`, `[]` | les éléments sont des expressions complètes |
| Hash | `{ a: 1, b: "x" }`, `{}` | **clés de style symbole uniquement**, même forme que les arguments nommés&nbsp;; pas de hashrocket `"key" => value` |

Les chaînes entre guillemets doubles interpolent `#{...}` (n’importe quelle expression complète, imbricable) et acceptent `\n \t \r \0 \e \s`, `\"`, `\\`&nbsp;; tout autre caractère échappé passe tel quel. Une chaîne sans `#{}` se compile en un littéral simple&nbsp;; une chaîne avec interpolation se compile en une séquence de morceaux littéraux et d’expressions.

### Variables

- **`@ivar`** lit directement `env["ivar"]` — le `@` n’est que de la syntaxe de surface&nbsp;; selon D9, «&nbsp;post est à la fois `@post` et la variable locale `post`&nbsp;» dans un seul Hash d’environnement. Une ivar absente vaut simplement `nil`&nbsp;: `[<%= @missing %>]` rend `[]`, jamais une erreur.
- Un **nom local nu** (`post`, `title`) lit aussi `env["name"]`, mais si la clé n’existe **pas du tout**, l’interpréteur le traite plutôt comme un appel de helper sans argument. Si la clé existe (même liée à `nil` — une variable locale stricte déclarée mais non passée, par exemple), sa valeur est renvoyée sans repli sur un helper. C’est pourquoi `<%= csrf_meta_tags %>` et `<%= flash %>` fonctionnent sans parenthèses, et pourquoi `<%= nope %>` échoue avec `"undefined helper 'nope'"` plutôt qu’avec une erreur «&nbsp;pas de telle variable locale&nbsp;».
- Les variables locales viennent des paramètres de bloc de `each`/`each_with_index`, du paramètre de bloc de `form_with`, des locals stricts d’un partiel et de `<% name = expr %>`.

### Appels de méthode

```erb
recv.method
recv.method(arg1, key: value)
recv&.method             # sûr face à nil : court-circuite vers nil, arguments non évalués, si recv vaut nil
method(arg1, key: value) # un appel de helper : pas de receveur
method arg1, key: value  # même appel, sans parenthèses (syntaxe « commande »)
```

- Une liste d’arguments sans parenthèses («&nbsp;commande&nbsp;») n’est ouverte que pour l’appel **le plus externe** d’une expression&nbsp;: `link_to "Show", post_path(post)` fonctionne, mais `link_to "Show", post_path post` est une `SyntaxError` — les appels internes ont besoin de leurs propres parenthèses.
- Aucun espace n’est autorisé entre la cible d’un appel et sa `(` ouvrante&nbsp;: `link_to("x")` et `link_to "x"` fonctionnent tous deux&nbsp;; `link_to ("x")` est une `SyntaxError`.
- `yield` et `yield :key` sont toujours analysés comme des appels (voir [Layouts, `yield`, `content_for`, partiels](#layouts-yield-content_for-partials)).
- Un mot nu commençant par une majuscule est rejeté d’emblée — `"constants are not supported: 'Time'"` — les templates ne peuvent pas atteindre les constantes Ruby.
- Ces mots sont réservés et rejetés avec un message dédié (`"'x' is not supported in templates"`) partout où une expression est attendue&nbsp;: `and or not do end if unless elsif else then while until def class module begin rescue return`. `case` et `when` sont des instructions à part entière ([`case`](#case))&nbsp;; à l’intérieur d’une expression (`<%= case x %>`), ils sont rejetés de la même façon.

### Opérateurs, priorité (de la plus faible à la plus forte)

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

`&&`/`||` renvoient l’opérande, pas un booléen converti (`nothing || title` s’évalue en `title`, pas en `true`). Les conditions testent la **véracité**&nbsp;: seuls `nil` et `false` sont faux, comme en Ruby — `0`, `""` et les tableaux/hashs vides sont vrais (`<% if 0 %>yes<% end %>` affiche `yes`).

L’indexation s’écrit `target[index]` **sans espace** avant `[` (`items [0]` est une erreur de syntaxe, `items[0]` non), et s’enchaîne comme tout suffixe&nbsp;: `h["k"].first`, `params[:id]`.

## Instructions

Une balise `<% %>` contient exactement une instruction&nbsp;: une affectation, ou une expression évaluée pour son effet de bord (valeur ignorée). `<%= %>`/`<%== %>` ne contiennent jamais qu’une expression — `<%= x = 1 %>` est une `SyntaxError`.

### Conditions

```erb
<% if cond %>...<% elsif other %>...<% else %>...<% end %>
<% unless cond %>...<% else %>...<% end %>
```

`unless`/`else`/`elsif` suivent les règles de Ruby&nbsp;; un `elsif` après `else`, un `else`/`elsif`/`end` isolé, ou un bloc jamais fermé par `end` sont tous des `SyntaxError` qui nomment la ligne d’ouverture.

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

- Le sujet est évalué une fois&nbsp;; les valeurs de chaque `when` (une ou plusieurs, séparées par des virgules) sont comparées dans l’ordre avec le `==` du template, et la première branche qui a une valeur égale s’exécute. Les nombres se comparent par valeur (`1` correspond à `1.0`)&nbsp;; les Strings et les Symbols par valeur et par type (`"a"` ne correspond pas à `:a`)&nbsp;; les enregistrements comme le fait `==` (classe et `id`)&nbsp;; les Arrays et les Hashs comme le fait `==` (par valeur, élément par élément)&nbsp;; une `SafeString` et une `String` de même texte sont égales. Il n’y a pas de `===`&nbsp;: ni intervalles, ni classes, ni regex après `when`.
- `else` s’exécute quand aucune valeur n’a correspondu&nbsp;; sans `else` et sans correspondance, rien n’est affiché.
- Seul du texte blanc (indentation, retours à la ligne) peut se trouver entre `case` et son premier `when`&nbsp;; il est ignoré. Tout autre chose à cet endroit est une `SyntaxError` (`"text between 'case' and its first 'when'"`).
- Un `when` hors d’un `case` (`"'when' without 'case'"`), un `case` sans sujet ou sans `when`, un `when` sans valeur ou après `else`, et un `case` jamais fermé par `end` sont des `SyntaxError` qui nomment la ligne. `then` reste réservé&nbsp;: `<% when :a then x %>` est une `SyntaxError`.
- Une variable locale affectée pour la première fois dans une branche suit la règle de localité au bloc du bloc où elle se trouve, comme avec `if`.

### Boucles

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` ne sont reconnus que comme suffixe de l’en-tête du bloc (`x.each do |...|`)&nbsp;; la collection peut être n’importe quelle expression, y compris un appel qui prend un bloc (`<% items.group_by { |i| i.kind }.each do |kind, list| %>`). **Tel qu’implémenté**, les deux exigent de déclarer un ou deux paramètres de bloc — `xs.each do end` est une `SyntaxError` («&nbsp;takes one or two block parameters&nbsp;»), là où le Ruby ordinaire en accepte zéro.
- `<% x.each_slice(n) do |slice| %>...<% end %>` parcourt les tranches de `n` éléments (la dernière peut être plus courte), et exige lui aussi un ou deux paramètres&nbsp;; avec deux, une tranche est déstructurée (`do |a, b|`), le second valant `nil` quand la tranche est courte.
- Array + un paramètre&nbsp;: l’élément. Array + deux paramètres&nbsp;: un élément `Array` est déstructuré (`a, b = item[0], item[1]`)&nbsp;; sinon, le second vaut `nil`.
- `each_with_index` sur un Array&nbsp;: `item, i`. Sur un Hash&nbsp;: le premier paramètre est une paire `[key, value]`, le second l’index.
- `each` sur un Hash avec deux paramètres&nbsp;: directement `key, value`&nbsp;; avec un paramètre&nbsp;: une paire `[key, value]`.
- Itérer sur `nil`, un `Time` ou n’importe quel scalaire est une `RuntimeError` (`"undefined method 'each' for Time"`) — jamais une absence d’effet silencieuse.
- Un paramètre de bloc masque une variable locale externe du même nom uniquement pendant la boucle, et est supprimé ensuite (`refute env.key?("item")` une fois la boucle terminée). Une variable qui existait avant le bloc est la *même* variable à l’intérieur (visible aussi après la boucle)&nbsp;; une variable **affectée pour la première fois dans** le bloc est locale au bloc — `nil` au début de chaque itération, disparue ensuite.

### Appels avec bloc (helpers)

`do ... end` est aussi la façon dont un appel de helper sans receveur prend un bloc (pour un appel avec receveur, voir [Blocs](#blocks))&nbsp;:

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

L’affichage ou non du résultat du bloc suit la balise&nbsp;: `<%= helper do |x| %>` l’affiche, `<% helper do |x| %>` l’ignore. Exactement un paramètre de bloc est lié, toujours&nbsp;; un bloc de helper ne reçoit jamais d’index ni de seconde valeur.

### Blocs

Un appel avec receveur peut prendre un bloc, `{ |x| expr }` ou `do |x| ... end`, avec zéro, un ou deux paramètres. Les méthodes qui en acceptent un sont fixées par type&nbsp;; un bloc ailleurs est une `SyntaxError` levée à l’exécution de l’appel (`"String#upcase takes no block"`), et une méthode que le type n’a pas donne l’habituel `"undefined method 'x' for Array"`, avec ou sans bloc.

| Receveur | Méthodes qui prennent un bloc | La valeur du bloc sert de |
| --- | --- | --- |
| `Array` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | valeur transformée, test, terme de la somme, clé de tri, clé de groupe |
| `Hash` | `map` `select` `reject` `find` `any?` `all?` `none?` `count` `sum` `sort_by` `min_by` `max_by` `group_by` | la même chose, le bloc voyant `\|key, value\|` (un seul paramètre reçoit la paire `[key, value]`)&nbsp;; `select`/`reject` renvoient un Hash, les autres ce que la méthode d’Array renvoie sur les paires |
| le constructeur `tag` | chaque élément (`tag.div do ... end`) | sa **sortie** est le contenu de l’élément ([Le constructeur tag](#the-tag-builder)) |

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

- **La valeur, pas la sortie.** Pour les méthodes d’Array et de Hash, c’est la *valeur* du bloc qui compte&nbsp;: l’expression d’un bloc `{ }`, ou la dernière instruction d’un bloc `do`, qui doit être une instruction-expression (`<% x * 2 %>`)&nbsp;; sinon `"map's block must end in a value"` (une affectation, ou du texte). Ce qu’affichent les instructions précédentes d’un bloc `do` est ignoré. Un bloc `do` sur une telle méthode occupe sa propre balise, affecté (`<% total = items.sum do |li| %>`) ou affiché (`<%= items.map do |x| %>`).
- **Pas de mutation.** Les templates n’ont aucun moyen de modifier un accumulateur, donc `each_with_object` et `inject` ne sont pas dans la table (`"undefined method 'each_with_object' for Array"`)&nbsp;: utilisez `map`, `select`, `sum` ou `group_by`.
- Deux paramètres déstructurent un élément d’Array, comme le fait `each` (`pairs.map { |a, b| a }`).
- La `sum` d’un Array vide vaut `0`&nbsp;; des Integers donnent un Integer, un Float n’importe où donne un Float (additionné avec la même compensation que Ruby, donc `[0.1, 0.2, 0.3].sum` vaut `0.6`)&nbsp;; les Strings sont refusées (`"sum: use join for Strings"`), comme tout ce qui n’est pas un nombre.
- `sort_by`, `min_by`, `max_by` (et `sort`, `min`, `max` sans bloc) comparent comme `<` (nombres, Strings, Times&nbsp;; `"comparison of String with Integer failed"` sinon). `sort_by` est stable&nbsp;: les clés égales gardent leur ordre. `min_by`/`max_by` d’un Array vide valent `nil`.
- `group_by` renvoie un Hash de chaque clé **sous forme de String** (tout Hash de template a des clés String&nbsp;: `:fruit` et `"fruit"` forment un seul groupe) vers les éléments qui ont cette clé, dans l’ordre de première apparition.
- `each`, `each_with_index` et `each_slice` prennent leur bloc dans une balise `<% %>` ([Boucles](#loops))&nbsp;; `items.each { |x| x }` est une `SyntaxError`.
- Un bloc sur une méthode de `FormBuilder` ou de `Page` est refusé de la même façon (`"FormBuilder#label takes no block"`), et les méthodes d’Array sans bloc ne prennent pas d’argument (`nums.sum(10)` donne `"wrong number of arguments for 'sum'"`).
- Si un bloc lève une exception, ses paramètres et ses variables locales sont restaurés avant que l’erreur ne quitte l’appel.
- Un bloc `{ }` a besoin d’un receveur&nbsp;: `shout { |x| x }` est une `SyntaxError` (les appels de helpers prennent `do ... end`).
- Les paramètres de bloc masquent les noms externes pendant l’appel et sont restaurés ensuite&nbsp;; une variable locale affectée pour la première fois dans un bloc `do` est locale au bloc, comme dans `each`.

### Affectation

```erb
<% total = 0 %><% total = total + 2 %><%= total %>   <%# => 2 %>
```

Uniquement `name = expr` pour une seule variable locale simple — pas de `@ivar = ...`, pas de `arr[0] = ...`/`h[:k] = ...`, pas de `a, b = ...`. La même règle de localité au bloc que pour `each` s’applique aux affectations dans des `if`/`unless` imbriqués dans un bloc.

## Table des méthodes par type

`nil?`, `present?` et `blank?` sont vérifiés **avant** le dispatch par type, ils fonctionnent donc sur toutes les valeurs, y compris les modèles et les objets renvoyés par des helpers (`blank?` vaut `false` pour tout sauf `nil`/`false`/une `SafeString`/`String`/`Array`/`Hash`/`Errors`/`Params` vide). L’arithmétique (`+ - * / %`) et la comparaison (`== != < > <= >=`) n’existent que comme **opérateurs infixes**, jamais comme appels `.method` — un symbole d’opérateur ne peut jamais suivre un `.` dans cette grammaire.

| Type | Méthodes | Exemple |
| --- | --- | --- |
| `SafeString` | `to_s` `html_safe?` `size`/`length` `empty?` | `raw('<b>').size` |
| `String` | `upcase` `downcase` `capitalize` `strip` `size`/`length` `empty?` `to_s` `to_i` `html_safe` `html_safe?` `include?(s)` `start_with?(s)` `end_with?(s)` | `title.strip.upcase` |
| `Integer` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` | `post.comments.size.zero?` |
| `Float` | `to_s` `to_i` `to_f` `zero?` `positive?` `negative?` `abs` `round` `round(n)` `floor` `ceil` | `price.round(2)` |
| `Time` | `year` `month` `day` `hour` `min` `sec` `strftime(fmt)` `to_s` `to_i` | `post.created_at.strftime('%Y-%m-%d')` |
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` `sum` `min` `max` `sort` `uniq` `compact` `flatten` `take(n)` `drop(n)` `each_slice(n)` (un Array d’Arrays) `zip(other)`, et les méthodes à bloc de [Blocs](#blocks) | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values` `to_a` (les paires `[key, value]`), plus `h[key]` et les méthodes à bloc de [Blocs](#blocks) | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`, plus `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`, plus `params[key]` | `params[:id]` |
| `Page` (`Relation#page`) | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s` (renvoie `""`) | |

L’indexation (`x[key]`) est une production distincte de la grammaire ([Expressions](#expressions)), pas un appel `.[]`&nbsp;: `Array`/`String` prennent un index entier, `Hash` fait correspondre n’importe quelle clé par son `to_s` (`h[:k]` et `h["k"]` sont la même entrée), `Errors` par symbole, `Params` par `to_s`.

Affichage (`<%= %>`/interpolation) au-delà du `to_s` ci-dessus&nbsp;: un `Array` s’affiche comme une liste à la manière d’inspect — `[1, "a", nil]` rend le texte `[1, "a", nil]` (puis est échappé, les guillemets deviennent donc `&quot;`)&nbsp;; un `Hash` se rabat sur le `Hash#to_s` de Ruby&nbsp;; un `Cybertrain::Model` s’affiche `#<Post id: 7>` (jamais ses attributs)&nbsp;; tout le reste s’affiche via son propre `to_s`. Une méthode non listée sur l’un de ces types est une `RuntimeError` (`"undefined method 'first' for Time"`). La division/le modulo d’un `Integer` par zéro donne `"divided by 0"`&nbsp;; `Float` suit plutôt l’IEEE-754 (`Infinity`/`NaN`, sans erreur).

## Les modèles dans les templates

Une sous-classe de `Cybertrain::Model` (un `Post`, un `Note` générés, ...) résout un nom nu dans cet ordre (`Interpreter#model_method`)&nbsp;:

1. Cinq méthodes intégrées, toujours disponibles&nbsp;: `id`, `persisted?`, `new_record?`, `to_param` (`id.to_s`), `errors` (un `Errors`, [Table des méthodes par type](#per-type-method-table)).
2. `read_attribute(:name)` — une colonne générée.
3. `read_association(:name)` — un `has_many`/`belongs_to` généré.
4. `call_view_method(:name)` — un `def` sans argument écrit à la main que le générateur de modèles a trouvé dans `app/models/**/*.rb` (jamais d’arité).

```erb
<%= post.title %>            <%# read_attribute %>
<% post.comments.each do |c| %>...<% end %>   <%# read_association %>
<%= post.summary %>          <%# call_view_method %>
<%= post.errors.full_messages.join(", ") %>
```

Si les quatre répondent `nil`, `attribute_or_method?(:name)` décide s’il s’agissait d’un nom légitime qui contient simplement `nil` (renvoie le `nil`) ou d’une faute de frappe (`"undefined method 'bogus' for Post"`).

**Tel qu’implémenté, une vraie lacune que signale le fichier de l’interpréteur lui-même** (voir le commentaire `TODO(integrator)` au-dessus de `class Model` dans `interpreter.rb`)&nbsp;: le `Cybertrain::Model#attribute_or_method?` *de base* renvoie toujours `true`. Seul un modèle généré qui le redéfinit avec un `case` explicite (comme le font les modèles de test écrits à la main) lève réellement une erreur sur une faute de frappe&nbsp;; sans cette redéfinition, un attribut ou une méthode mal orthographié s’affiche silencieusement vide au lieu d’échouer. Ne supposez pas que les fautes de frappe sont détectées, sauf si vous savez que le modèle redéfinit ce hook.

Deux modèles se comparent avec `==` par classe et par `id` (`Model#==`), accessible via l’opérateur `==` ordinaire (dispatch natif de l’égalité, pas `call_method`).

## Helpers et constructeur de formulaires

Chaque appel sans receveur va à `Helpers#helper_call` (`helpers.rb`), qui fait correspondre l’une des méthodes intégrées ci-dessous&nbsp;; dans le template d’un [composant](#components), essaie ensuite les méthodes de vue de ce composant&nbsp;; traite un nom finissant par `_path`/`_url` comme un helper de route généré (via `Cybertrain::Views.url_resolver`, qui lève `"no routes"` tant que l’application n’en a pas installé un)&nbsp;; essaie ensuite les [helpers de l’application](#application-helpers)&nbsp;; ou lève `"undefined helper 'name'"`.

| Helper | Signature | Remarques / exemple |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` est échappé sauf s’il est déjà une `SafeString`&nbsp;; **pas de `method:`** — lève une erreur qui vous dit d’utiliser `button_to` (pas de liens DELETE simulés à la rails-ujs/turbo) |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | un `<form class="button_to">` à un seul bouton&nbsp;; un `_method` caché pour tout verbe autre que `get`/`post`, plus le champ CSRF quand une session existe |
| `form_with` | `form_with(model:, url:, scope:, method:, class:, data:, multipart:, local:) do \|f\| ... end` | exige un bloc&nbsp;; `model:` nouveau → route de collection + POST, persisté → route de membre + PATCH&nbsp;; `[parent, child]` pour une route imbriquée, `[:admin, @article]` pour une route dans un namespace&nbsp;; `url:`/`method:` remplacent l’action/le verbe déduits&nbsp;; `scope: :q` nomme les champs `q[term]` (avec `model:`, il remplace le préfixe du modèle)&nbsp;; `data: { turbo_frame: "f" }` écrit des attributs `data-`&nbsp;; `local:` est accepté et ne change rien&nbsp;; `multipart: true` ajoute `enctype="multipart/form-data"` (requis pour `f.file_field`&nbsp;; ce n’est jamais deviné à partir du bloc, et cela lève `ArgumentError` sur un formulaire GET) |
| `select_tag` | `select_tag(name, option_tags = nil, include_blank:, prompt:, multiple:)` | `select_tag "order", options_for_select([["Newest", "new"], ["Oldest", "old"]], "old")` → `<select name="order" id="order">...</select>`&nbsp;; un `option_tags` qui n’est pas une `SafeString` est échappé&nbsp;; `multiple: true` le nomme `order[]`&nbsp;; les autres mots-clés sont des attributs |
| `options_for_select` | `options_for_select(choices, selected = nil)` | les lignes `<option>` des choix de `f.select` (ci-dessous)&nbsp;; `selected` est une valeur ou un Array de valeurs, comparées comme des String |
| `options_from_collection_for_select` | `options_from_collection_for_select(records, :id, :name, selected = nil)` | une `<option>` par enregistrement, sa valeur et son texte lus comme les lit `f.collection_select` |
| `t`, `translate` | `t(key, default:, count:, locale:, name: value)` | le texte de `key` dans la locale de la requête, échappé&nbsp;; `t(".title")` dans `posts/index.html.erb` lit `posts.index.title`, dans le partial `posts/_form.html.erb` `posts.form.title`&nbsp;; une clé en `_html` écrit son HTML et échappe les valeurs ([Internationalisation](i18n.md#looking-up-text)) |
| `l`, `localize` | `l(time_or_date, format: :short, locale:)` | les `time.formats` / `date.formats` de la locale, ou un motif strftime avec les noms des jours et des mois de la locale ([Dates et heures](i18n.md#dates-and-times)) |
| `label_tag`, `text_field_tag`, `hidden_field_tag`, `submit_tag` | `label_tag(name, text = nil)`, `text_field_tag(name, value = nil)`, `hidden_field_tag(name, value = nil)`, `submit_tag(value = "Save changes")` | les balises de formulaire sans modèle&nbsp;: `label_tag(:term)` → `<label for="term">Term</label>`&nbsp;; `hidden_field_tag` écrit `autocomplete="off"`&nbsp;; `submit_tag` s’appelle `commit`&nbsp;; les autres mots-clés sont des attributs (`id:` remplace l’id tiré du nom) |
| `check_box_tag` | `check_box_tag(name, value = "1", checked = false)` | une case à cocher sans modèle ni champ caché, si bien qu’une case non cochée n’envoie rien&nbsp;: `check_box_tag :remember_me` → `<input type="checkbox" name="remember_me" id="remember_me" value="1">`&nbsp;; les autres mots-clés sont des attributs |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` / `render partial: "comment", collection: @comments` / `render @comments` / `render component: "card", k: v` | voir [Layouts, `yield`, `content_for`, partiels](#layouts-yield-content_for-partials), [Collections](#collections) et [Composants](#components) |
| `h`, `escape` | `h(text)` | échappe&nbsp;; une `SafeString` passe sans être échappée |
| `raw` | `raw(text)` | enveloppe le texte dans une `SafeString` (affiché sans échappement) |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`&nbsp;; `pluralize(2, "mouse")` → `"2 mice"` (les inflexions anglaises par défaut de Rails, via `Cybertrain::Inflector`, dans une page en anglais seulement&nbsp;: dans une autre locale le mot reste tel quel&nbsp;; les inflexions définies par l’application ne sont pas prises en charge)&nbsp;; un troisième argument explicite l’emporte toujours |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n, delimiter: ",", separator: ".")` | `1234567` → `"1,234,567"`&nbsp;; `-1000` → `"-1,000"`&nbsp;; `1234.5` → `"1,234.5"` |
| `number_with_precision` | `number_with_precision(n, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false)` | `111.2345` → `"111.235"`&nbsp;; `precision: 0` → `"111"` |
| `number_to_human` | `number_to_human(n, precision: 3, units: {})` | `1234` → `"1.23 Thousand"`, `1234567` → `"1.23 Million"`&nbsp;; `units: { thousand: "K" }` remplace le nom d’une unité (`unit`, `thousand` … `quadrillion`) |
| `number_to_percentage` | `number_to_percentage(n, precision: 3)` | `100` → `"100.000%"` |
| `number_to_currency` | `number_to_currency(n, unit: "$", precision: 2, format: "%u%n")` | `1234.5` → `"$1,234.50"`&nbsp;; un nombre négatif écrit `-` avant le format |
| `number_to_human_size` | `number_to_human_size(n)` | `1234` → `"1.21 KB"` (base 1024)&nbsp;; `1` → `"1 Byte"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Tranches à la Rails, sans précision à la seconde&nbsp;: `"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"`, tirées du `datetime.distance_in_words` de la locale (en japonais `"2分"`) |
| `content_for` / `content_for?` | `content_for(:key) do...end`, `content_for(:key, "text")`, `content_for?(:key)` | voir [Layouts, `yield`, `content_for`, partiels](#layouts-yield-content_for-partials) |
| `csrf_meta_tags` / `csrf_token` | | vide / absent sans session de contrôleur |
| `csp_meta_tag` / `content_security_policy_nonce` | | `<meta name="csp-nonce" content="...">` / le nonce seul, le nonce de la [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) de cette requête&nbsp;; `""` quand aucune politique ne s’applique |
| `javascript_tag` | `javascript_tag(nonce: true) do ... end`, `javascript_tag(js)` | le contenu dans un `<script>` (non échappé, comme dans Rails&nbsp;: n’y mettez jamais de données de la requête), avec le nonce quand `nonce: true` et qu’une politique s’applique&nbsp;; `id:`, `type:`, `data:` sont des attributs |
| `asset_path` | `asset_path("logo.svg")` | `/assets/logo-1a2b3c4d.svg` (voir [Assets](assets.md#helpers))&nbsp;; une URL ou un chemin commençant par `/` est renvoyé tel quel |
| `stylesheet_link_tag` | `stylesheet_link_tag("application", media:, nonce:)` | `<link rel="stylesheet" href="/assets/application-1a2b3c4d.css">` (`.css` ajouté s’il manque) |
| `javascript_include_tag` | `javascript_include_tag("legacy", nonce:)` | `<script src="/assets/legacy-1a2b3c4d.js"></script>` (`.js` ajouté s’il manque) |
| `image_tag` | `image_tag(source, alt:, size:, class:)` | `<img src="/assets/logo-1a2b3c4d.svg" alt="Logo" width="16" height="16">` pour `size: "16x16"` (ou `"16"`)&nbsp;; aucun `alt` n’est inventé, `alt: ""` est écrit |
| `javascript_importmap_tags` | `javascript_importmap_tags(entry = "application")` | l’import map, un lien `modulepreload` par pin préchargé et `import "application"`, chacun avec le nonce quand une politique s’applique ([Assets](assets.md#the-import-map))&nbsp;; a besoin d’une requête |
| `flash` | | à la manière d’un `Hash`&nbsp;: `flash[:notice]` |
| `params` | | les `Cybertrain::Params` courants |
| `request_path` | | le chemin courant, `""` sans contrôleur |
| `url_for` | `url_for(target, format:, anchor:, k: v)` | `String` tel quel, `Model` → route de membre, `[parent, child]` → route imbriquée, `[:admin, record]` → route dans un namespace&nbsp;; les mots-clés sont ajoutés comme un helper de chemin les ajoute (`url_for("/x", format: :csv)` → `/x.csv`) |
| `current_page?` | `current_page?(path)` | si cette requête GET ou HEAD vise `path` (à une barre oblique finale près&nbsp;; avec une query dans `path`, la query doit aussi correspondre)&nbsp;; un enregistrement ou un Array passe par `url_for`&nbsp;; faux pour toute autre méthode&nbsp;; a besoin d’une requête |
| `paginate` | `paginate(page, path)` | `page` est un `Cybertrain::Page` (issu de `Relation#page`)&nbsp;; rend `<nav class="pager">` avec «&nbsp;Newer&nbsp;» (`rel="prev"`), `<span class="pager-current">Page N</span>` et «&nbsp;Older&nbsp;» (`rel="next"`), un lien étant omis quand la page correspondante n’existe pas. Chaque lien est `path` plus la chaîne de requête de la requête courante avec `page` remplacé (supprimé pour la page 1), réencodée et échappée pour le HTML&nbsp;; un `path` avec sa propre `?query` utilise plutôt celle-ci. Un `Page` répond aussi à `number`, `per`, `row_offset`, `next?`, `prev?`, `next_number`, `prev_number` dans un template (`<% if @page.next? %>`) |
| `*_path` / `*_url` | par ex. `post_path(post)`, `posts_path(page: 2, format: :json)` | générés par l’application, résolus via `Cybertrain::Views.url_resolver`&nbsp;; les mots-clés vont dans la chaîne de requête, `format:` ajoute l’extension et `anchor:` le fragment ([Redirections et chaînes de requête](requests.md#redirects-and-query-strings)) |
| `tag` | `tag.div(content, attrs) do ... end` | le constructeur tag&nbsp;: voir [Le constructeur tag](#the-tag-builder) |
| `content_tag` | `content_tag(name, content = nil, attrs)`, ou avec un bloc `do` | `content_tag "p", "<i>", class: "n"` → `<p class="n">&lt;i&gt;</p>`&nbsp;; les mêmes règles que `tag` |
| `safe_join` | `safe_join(array, sep = "")` (sans arguments nommés) | joint en une `SafeString`, en échappant chaque élément et le séparateur qui ne sont pas déjà des `SafeString`&nbsp;: `safe_join([tag.b("a"), "<"], " ")` → `<b>a</b> &lt;` |
| `class_names` | `class_names(*values)` | `class_names`/`token_list` de Rails&nbsp;: les mots des Strings et des Symbols, des Arrays (imbriqués aussi) et de chaque clé de Hash dont la valeur est vraie, chaque mot une fois&nbsp;; les arguments nommés forment un Hash de plus&nbsp;: `class_names("btn", active: @on, big: false)` → `"btn active"` |
| `dom_id` | `dom_id(record, prefix = "")` (le préfixe est positionnel, comme dans Rails) | `"article_12"`, `"new_article"` pour un enregistrement non sauvegardé, `dom_id(@article, "edit")` → `"edit_article_12"` (`Cybertrain::Html.dom_id` en Ruby) |
| `turbo_stream_from` | `turbo_stream_from(*streams, ws: false)` | un `<turbo-stream-source>` qui abonne la page aux flux (des Strings, ou des enregistrements nommés `"articles:12"`)&nbsp;; `ws: true` donne une URL `ws://`/`wss://` et exige une requête. Voir [Temps réel](realtime.md#turbo-streams) |
| `signed_stream_name` | `signed_stream_name(*streams)` | le jeton signé seul, pour du JavaScript écrit à la main |
| `stream_source_path` | `stream_source_path(*streams, mode: "json")` | le chemin du point d’entrée des flux avec le jeton et `mode=json` (ou `"raw"`) |
| `turbo_frame_tag` | `turbo_frame_tag(id_or_record, src:, loading:, target:, class:, data:) do ... end` | `<turbo-frame id="article_3" src="...">...</turbo-frame>`&nbsp;; un enregistrement donne son `dom_id`&nbsp;; chaque attribut seulement s’il est fourni |
| `turbo_stream` | `turbo_stream.replace(target, partial:, locals:)`, `.update(target, html:)`, `.append(target) do ... end`, `.prepend`, `.before`, `.after`, `.remove(target)` | un élément `<turbo-stream action="...">`, pour un template `*.turbo_stream.erb`&nbsp;; la cible est un id DOM ou un enregistrement&nbsp;; exactement un parmi un bloc, `partial:` (avec `locals:`) et `html:` |
| `time_tag` | `time_tag(time, text = nil, format:, class:, id:, title:, data:)`, ou avec un bloc | `<time datetime="2026-11-10T12:00:00Z">Tue, 10 Nov 2026 12:00:00 +0000</time>`&nbsp;; une Date donne `2026-11-10`&nbsp;; sans `format:`, le texte est le format `:default` de la locale&nbsp;; `format:` est un nom de format (`:short`, `:long` ou tout autre que contiennent les dictionnaires), formaté par `l` dans la locale de la requête, ou une String strftime (avec les noms anglais des jours et des mois&nbsp;; une directive inconnue lève une erreur, de même qu’une largeur ou un drapeau que strftime lirait autrement&nbsp;: `%6L`, utilisez `%6N`&nbsp;; `:` seulement dans `%:z`&nbsp;; pas de drapeau de remplissage sur `%F %T %D %R %r %c %x %X %v`&nbsp;; une largeur sur un nombre remplace son remplissage, `%5e` donne `"    5"`) |

Chaque argument texte d’un helper suit une seule règle&nbsp;: une `SafeString` passe sans être échappée, tout le reste est échappé — `link_to raw('<b>raw</b>'), post` affiche la balise gras littéralement, mais `link_to post.title, post` l’échappe.

Les six helpers numériques sont ceux de `Cybertrain::NumberHelper`, que le code Ruby appelle comme des fonctions de module avec les mêmes mots-clés (`Cybertrain::NumberHelper.number_to_currency(price, unit: "€")`). Ils prennent un Integer, un Float ou une String numérique (les colonnes décimales sont des Float) et arrondissent au demi supérieur sur les chiffres de son texte décimal, si bien que le résultat est le même sur les deux runtimes&nbsp;; toute autre valeur lève `ArgumentError` (`"number_with_delimiter: \"abc\" is not a number"`), tout comme une précision hors de 0 à 100. Dans un template, `nil` donne `""` (une colonne décimale nullable s’affiche vide, comme dans Rails)&nbsp;; `Cybertrain::NumberHelper` appelé depuis Ruby lève toujours `ArgumentError` pour `nil` (`"number_with_delimiter: nil is not a number"`). Dans un template, les valeurs par défaut viennent de la locale de la requête (`number.*` dans les dictionnaires&nbsp;: le `number_to_currency(1234)` japonais donne `"1,234円"`), et un mot-clé donné l’emporte&nbsp;; depuis Ruby ce sont les valeurs anglaises montrées plus haut.

### Le constructeur tag

`tag` s’évalue en un constructeur (`Cybertrain::Html::TagBuilder`)&nbsp;; toute méthode appelée dessus est un élément, rendu par `Cybertrain::Html.tag` (appelable aussi depuis Ruby&nbsp;: `Html.tag("a", { href: "/x" }, "Go")`)&nbsp;:

```erb
<%= tag.div(class: "card") do %>
  <%= tag.h2 @article.title, id: dom_id(@article) %>
<% end %>
<%= tag.input type: "text", name: "q", disabled: true %>   <%# <input type="text" name="q" disabled> %>
<%= tag.path d: "M0 0 L10 10" %>                         <%# SVG elements work %>
<%= tag.my_widget data: { turbo_frame: "f" } %>          <%# <my-widget data-turbo-frame="f"></my-widget> %>
```

- `<%= tag %>` seul n’affiche rien.
- Le nom de l’élément est le nom de la méthode avec `_` changé en `-`&nbsp;; il doit correspondre à `[a-z][a-z0-9-]*` (sinon `"invalid element name 'Div'"`, levé par `Html.tag`).
- Le contenu est l’unique argument positionnel (échappé sauf s’il s’agit d’une `SafeString`, donc `tag.script("alert(1)")` affiche son texte échappé) ou la **sortie** du bloc (`do ... end`, ou `{ expr }` dont la valeur est affichée échappée)&nbsp;; le bloc l’emporte. Sans l’un ni l’autre, `tag.div` donne `<div></div>`.
- Les éléments vides (`area base br col embed hr img input link meta source track wbr`) se rendent sans balise fermante&nbsp;; leur donner un contenu ou un bloc est une erreur (`"br is a void element"`).
- Les attributs sont les arguments nommés, dans l’ordre&nbsp;: `nil` et `false` suppriment l’attribut, `true` le rend nu (`disabled`), un Array joint ses éléments non `nil` par des espaces (`data: { ids: [1, 2] }` donne `data-ids="1 2"`, pas le JSON de Rails), `class:` prend ce que prend `class_names` (`class: ["btn", { active: @on }]`), les Hashs `data:` et `aria:` s’imbriquent en `data-key="v"` / `aria-key="v"` avec les tirets bas changés en tirets (et `true`/`false` écrits en toutes lettres)&nbsp;; toute autre valeur Hash est une erreur (`"attribute 'title' cannot be a Hash"`). Chaque valeur est échappée, une `SafeString` aussi. Les noms d’attributs doivent correspondre à `[a-zA-Z_:][-a-zA-Z0-9_:.]*` (`"invalid attribute name 'data-a b'"`)&nbsp;; `onclick:` et consorts sont permis, puisqu’ils viennent de l’auteur.

### FormBuilder (`f` dans `form_with ... do |f|`)

Chaque méthode renvoie une `SafeString`&nbsp;; une méthode non listée est une `RuntimeError` (`"undefined method 'color_wheel' for FormBuilder"`).

| Méthode | Rendu |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — le texte par défaut est l’attribut humanisé (`published_at` → «&nbsp;Published at&nbsp;», `author_id` → «&nbsp;Author&nbsp;»)&nbsp;; un texte explicite est échappé sauf s’il est une `SafeString` |
| `f.text_field :title` (aussi  `email_field`, `password_field`, `number_field`, `date_field`, `datetime_local_field`, `time_field`, `range_field`, `color_field`, `search_field`, `telephone_field`, `url_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`&nbsp;; `password_field` n’émet jamais `value=`&nbsp;; `telephone_field` est `type="tel"`&nbsp;; un Time est écrit comme le lit le navigateur (`2026-11-10`, `2026-11-10T12:00:00`, `12:00:00.000`) |
| `f.select :status, ["draft", "published"]` (aussi  `include_blank:`, `prompt:`, `selected:`, `disabled:`, `multiple:`) | `<select name="post[status]" id="post_status">` avec une `<option>` par choix, la valeur actuelle sélectionnée&nbsp;; les choix sont des valeurs, des paires `[text, value]`, ou un Hash ou des groupes `[label, [choices]]` pour `<optgroup>`&nbsp;; `multiple: true` le nomme `post[status][]` et écrit d’abord un input caché vide |
| `f.collection_select :author_id, @authors, :id, :name` | un `<select>` avec une `<option>` par enregistrement, sa valeur et son texte lus depuis les deux méthodes |
| `f.radio_button :status, "draft"` | `<input type="radio" name="post[status]" id="post_status_draft" value="draft">`, coché quand la valeur correspond (`checked:` prend le dessus) |
| `f.file_field :cover` (aussi `accept: "image/*"`, `required: true`) | `<input type="file" name="post[cover]" id="post_cover">` — jamais de `value=`, et l’attribut n’a pas besoin d’être une colonne&nbsp;; le formulaire doit être `form_with ..., multipart: true`&nbsp;; `multiple: true` lève `ArgumentError` (un fichier par champ) |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>` (`\n` initial, comme le fait Rails — les navigateurs absorbent le premier saut de ligne) |
| `f.check_box :published` | un input caché `value="0"` puis la vraie case à cocher, de sorte qu’une case non cochée envoie quand même `"0"`&nbsp;; `include_hidden: false` omet l’input caché |
| `f.submit` / `f.submit "Text"` | texte par défaut `"Create Post"`/`"Update Post"` (selon `persisted?`), ou `"Save changes"` sans modèle |

Avec un modèle, les champs sont nommés `post[title]`/`id="post_title"` (avec `Inflector.underscore(model.model_name)` comme portée)&nbsp;; `form_with(..., scope: :q)` utilise plutôt `q[title]`/`id="q_title"`&nbsp;; avec `form_with(url: ...)` et sans modèle ni portée, le nom d’attribut nu est utilisé pour les deux. Chaque valeur d’attribut et chaque texte d’option est échappé une fois (une `SafeString` telle quelle). Les arguments nommés supplémentaires deviennent des attributs HTML dans l’ordre donné&nbsp;: `true` → `attr="attr"`, `false`/`nil` omis, tout le reste → `attr="value"` (échappé), les tirets bas deviennent des traits d’union (`data_confirm: "Sure?"` → `data-confirm="Sure?"`), et `class:` est fusionné avec la classe automatique `field_with_errors` ajoutée quand `model.errors.key?(attr)`.

## Helpers de l’application

Un module sous `app/helpers/` est un module de helpers, comme dans Rails&nbsp;: chacune de ses méthodes publiques peut être appelée depuis n’importe quel template, sans receveur.

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

- **Dispatch généré.** Les templates ne peuvent pas faire de `send`, donc `spin run gen` lit `app/helpers/**/*.rb` comme du texte et écrit `gen/helpers.rb`&nbsp;: une classe `ApplicationHelpers` qui inclut chaque module (et les helpers de route) et un `case` sur les noms des helpers. Ajoutez un helper ou changez sa signature, et la compilation suivante le régénère (le serveur de développement fait les deux). `cybertrain generate helper prices` écrit un `PricesHelper` vide et un test.
- **Ce qui est un helper.** Les méthodes d’instance publiques d’un `module` (pas `def self.x`, ni les setters, ni tout ce qui suit `private` ou `protected`), quel que soit leur fichier. Un template passe des valeurs par position ou par mot-clé, donc chaque paramètre est nommé&nbsp;: `*rest`, `**opts`, `...` sont des erreurs du générateur, comme un paramètre obligatoire après un paramètre optionnel. Un helper prend au plus trois paramètres optionnels (le `case` généré a une branche par combinaison donnée, si bien qu’un mot-clé omis prend la valeur par défaut de la méthode elle-même). Un mauvais appel est une `ArgumentError` au rendu&nbsp;: `"wrong number of arguments for 'price' (given 0, expected 1)"`, `"unknown keyword 'cur' for 'price' (known: unit, precision)"`.
- **Noms réservés.** Un helper ne peut pas porter le nom d’un helper du framework (`link_to`, `render`, `tag`, `dom_id`, `params`, `content`, ...), d’une méthode de `Cybertrain::Template::Helpers` (publique ou privée&nbsp;: l’`include` la remplacerait aussi pour le framework), `yield`, ni finir par `_path` / `_url` (ce sont les helpers de route qui y répondent)&nbsp;; le même nom dans deux modules est aussi une erreur. `spin run gen` s’arrête en indiquant le fichier, la ligne et la raison.
- **Valeurs.** Les arguments arrivent comme des valeurs du template (String, Integer, Float, `nil`, un enregistrement, un Array, un Hash)&nbsp;; restreignez-les avec `Cybertrain::Cast` (`Cast.str`, `Cast.int`, `Cast.float`) avant tout calcul. Ce que renvoie un helper est affiché comme toute valeur&nbsp;: une `String` est échappée, une `SafeString` non, donc construisez le HTML avec `Cybertrain::Html.tag(name, attrs, content)`, `Html.safe_join`, `Html.class_names`, `Html.dom_id`, `Html.escape`, `Cybertrain::SafeString.of` ou les formes Ruby des helpers de lien, `link_to_path(text, path, attrs)` et `button_to_path(text, path, attrs)` (`method:` dans `attrs`).
- **Blocs.** Un helper avec un paramètre `&block` prend un bloc `do ... end`&nbsp;; `yield` (sans argument) renvoie ce que le bloc a affiché, sous forme de `SafeString`.

## Composants

Un composant est une classe à arguments nommés avec un template à côté, sur le modèle de [ViewComponent](https://viewcomponent.org)&nbsp;:

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

- Le template voit les variables d’instance du composant comme des variables locales (`title`), ses méthodes publiques sans paramètre par leur nom (`value_text`), et `content`, ce qu’a affiché le bloc `do` (`""` sans bloc). Il se rend sans layout, peut rendre des partiels et d’autres composants, et compte pour `max_render_depth` comme un partiel. Un partiel qu’il rend ne voit pas les méthodes du composant. Un nom de partiel sans répertoire dans le template d’un composant (`render "chip"`) est cherché sous `app/components/` (`app/components/_chip.html.erb`) ; un nom avec répertoire (`render "shared/note"`) sous `app/views/`, comme d’habitude.
- Un composant est désigné par son nom en snake_case sans `_component`, comme un partiel l’est par son chemin&nbsp;: `"card"` pour `CardComponent`, `"admin/user_row"` pour `Admin::UserRowComponent` (`app/components/admin/user_row_component.rb`). Les templates ne peuvent pas nommer de constantes.
- `spin run gen` écrit `gen/components.rb` à partir d’une analyse lexicale, comme pour les helpers&nbsp;: la ligne de classe, les affectations `@x =`, les `def` sans paramètre et les mots-clés d’`initialize`. `initialize` ne prend que des mots-clés (au plus trois optionnels), et son template doit exister&nbsp;; un mot-clé manquant ou inconnu est une `ArgumentError` au rendu. Un composant inconnu est un `Cybertrain::Component::Unknown`&nbsp;: `` "no component 'crad' (app/components/crad_component.rb, then `spin run gen`)" ``. `content` est réservé&nbsp;: un mot-clé d’`initialize` ou une variable d’instance `@content` de ce nom serait écrasé par la sortie du bloc, donc `spin run gen` le refuse en nommant le fichier et la ligne. `app/views/components/` reste un répertoire de vues comme un autre (celui d’un `ComponentsController`)&nbsp;; seul `app/views/__components/` est réservé, les noms sous lesquels sont rangés les templates des composants.
- `cybertrain generate component card title value:integer` écrit la classe, son template et un test qui le rend avec `Cybertrain::Test.render_component`.

### Rendre hors d’une requête

Une diffusion, un job ou un corps de mail se rendent sans requête&nbsp;:

```ruby
html = Cybertrain::Views.render_partial("articles/article", article: article)   # app/views/articles/_article.html.erb
card = Cybertrain::Views.render_component(CardComponent.new(title: "Visitors", value: 12))
```

Les deux renvoient le HTML sous forme de String, avec les helpers de l’application. Les helpers de chemin fonctionnent (`article_path(article)`), les strict locals sont vérifiés, et les formulaires (`form_with`, `button_to`) se rendent sans le jeton d’authenticité (une page Turbo soumet celui de `csrf_meta_tags`). Un helper qui a besoin d’une requête lève `Cybertrain::Views::OutsideRequest` (`"csrf_token needs a request"`)&nbsp;: `csrf_token`, `csrf_meta_tags`, `params`, `flash`, `request_path`, `current_page?`, `content_security_policy_nonce` (donc `csp_meta_tag` et un helper de balise auquel on passe `nonce: true`), `javascript_importmap_tags`, tout helper `*_url` et `turbo_stream_from ... ws: true`. Les liens de `paginate` ne portent que la query string propre au chemin. (Un `Cybertrain::Template::Helpers.new(nil)` nu, tel qu’un test unitaire peut en construire, y répond plutôt par des valeurs vides.)

## Layouts, `yield`, `content_for`, partiels

`Engine#render_with_layout(name, layout, env, helpers)` rend `name` dans `env["__content"]` (une `SafeString`), puis rend `layout` avec le même `env`&nbsp;:

```erb
<title><%= yield :title %></title>
<%= yield %>
```

`yield` affiche `env["__content"]`&nbsp;; `yield :key` affiche `env["__content_key"]`, ou rien s’il n’est pas défini. `yield` est traité à part directement dans l’interpréteur et ne peut pas être redéfini comme helper. Une page remplit un emplacement avec `content_for`, n’importe où dans son corps (l’ordre par rapport à `yield` n’a pas d’importance — la page est entièrement rendue avant le layout)&nbsp;:

```erb
<% content_for :title do %>Post: <%= @post.title %><% end %>
<% content_for :title, " (draft)" %>   <%# appends: calls accumulate, they don't replace %>
```

### Layouts par contrôleur

Une action se rend dans `app/views/layouts/application.html.erb` (quand il existe) sauf si son contrôleur, un parent ou un concern qu’il inclut en choisit un autre&nbsp;:

```ruby
class AdminController < ApplicationController
  layout "print", only: [:receipt]      # app/views/layouts/print.html.erb
  layout :choose_layout                 # une méthode : un nom, false pour aucun, nil pour celui du parent

  private

  def choose_layout = request.header("Turbo-Frame").to_s.empty? ? "application" : "frame"
end
```

`layout "admin"` seul nomme un layout pour toutes les actions. `spin run gen` lit les lignes `layout` (un nom entre guillemets, `false`, ou le Symbol d’une méthode, avec `only:` / `except:`) et écrit le `controller_layout(action)` du contrôleur. Les déclarations sont essayées dans l’ordre et **la première qui s’applique l’emporte** (Rails laisse une déclaration ultérieure remplacer une antérieure)&nbsp;; les lignes d’un concern comptent à son `include`. `render layout: "x"` utilise `layouts/x` pour un appel et `render layout: false` aucun&nbsp;; un `layouts/` initial est accepté (`layout "layouts/x"` vaut `layouts/x`). Une ligne `layout` ou un `render layout:` qui nomme un layout inexistant lève `MissingTemplate`&nbsp;; seul le layout `application` par défaut est facultatif (l’action se rend alors sans layout). Seul le html est rendu dans un layout&nbsp;; le template d’un autre format se rend sans. Tout autre argument de `layout` (`nil`, une lambda, une constante) est refusé par gen.

### Partiels et `render`

```erb
<%= render "form", post: @post %>
<%= render partial: "form", locals: { post: @post } %>
<%= render "comments/comment", comment: c %>
```

- Un nom nu sans `/` se résout dans le **propre répertoire du template courant** (via une clé d’env que définit la mécanique de rendu, `__template_dir`)&nbsp;: `render "form"` depuis `posts/show` cherche `posts/_form.html.erb`. Un nom contenant `/` est un chemin explicite&nbsp;; seul son dernier segment reçoit le préfixe `_` (`"comments/comment"` → `comments/_comment.html.erb`).
- Le partiel reçoit **une copie de tout l’environnement de l’appelant** (ivars et toutes les variables locales déjà visibles) plus les variables locales explicitement passées à `render` — il n’est pas cloisonné à ce qui lui a été passé. Les locals stricts ne valident que les noms **explicitement passés à cet appel de `render`** par rapport à la liste déclarée&nbsp;; ils n’empêchent pas le partiel de lire aussi un autre nom qu’il hérite de l’environnement de l’appelant.
- Seules les clés de `content_for` (`__content_*`) sont recopiées de la portée d’un partiel vers celle de l’appelant&nbsp;; les variables locales ordinaires qu’il affecte ne remontent pas.
- Des variables locales manquantes/en trop par rapport à une déclaration `<%# locals: %>` sont des `RuntimeError`&nbsp;: `"missing local 'post' for posts/_form.html.erb"`, `"unknown local 'extra' for posts/_form.html.erb"`.

### Collections

```erb
<%= render partial: "comment", collection: @comments, as: :comment, spacer_template: "divider" %>
<%= render @comments %>      <%# each record's comments/_comment.html.erb %>
<%= render @comment %>       <%# one record, no counter %>
<%= render component: "comment", collection: @comments %>
```

- `collection:` rend le partiel une fois par élément d’un Array, sous la variable locale nommée par `as:` (par défaut le nom du partiel), avec `<as>_counter` qui compte à partir de 0, les `locals:` donnés à chacun et `spacer_template:` (un partiel) entre les éléments&nbsp;; une collection vide ne rend rien. Un partiel à locals stricts ne reçoit le compteur que s’il le déclare, et l’élément l’emporte sur une variable locale du même nom.
- `render @comments` choisit le partiel de chaque enregistrement d’après son modèle, `<plural>/_<singular>` (`admin/notes/_note` pour un `Admin::Note`), si bien qu’une liste peut mêler des modèles.
- Un composant dont l’unique mot-clé requis porte son nom (`CommentComponent` avec `comment:`) reçoit `CommentComponent.with_collection(items)`, et `render component: "comment", collection: @comments` le rend une fois par élément, en passant `comment_counter:` quand `initialize` le déclare. `collection:` n’accepte aucun autre mot-clé (`render component: "comment", collection: @comments, extra: 1` est une erreur qui le nomme)&nbsp;; le contenu du bloc n’est pas transmis.

### Résolution des fichiers (`engine.rb`)

`"posts/show"` et `"posts/show.html.erb"` désignent le même template. Le développement lit `app/views/` depuis le disque avec `cache: false` (un fichier est relu et réanalysé chaque fois que son mtime ou sa taille change, et cette réanalyse écrit dans le cache du moteur, si bien que le serveur de développement tourne toujours avec un seul worker et ignore `SPINEL_WORKERS`, ce que dit sa bannière de démarrage)&nbsp;; l’environnement de test lit depuis le disque avec `cache: true` (analysé une fois). Un binaire de production ne touche jamais au disque&nbsp;: `cybertrain build` lance `spin run gen -- --embed-views`, qui écrit chaque `*.erb` de `app/views/` (fichiers cachés et répertoires liés symboliquement exclus) dans `gen/views.rb`, et `Engine.embedded(sources)` analyse chaque entrée une fois, au démarrage du binaire (les messages d’erreur gardent la même forme `posts/show.html.erb:12`), si bien qu’un template avec une erreur de syntaxe arrête le démarrage au lieu de faire échouer sa page&nbsp;; un binaire dont la table est vide refuse de démarrer en production. Un template absent lève `Cybertrain::Template::MissingTemplate` — `"Missing template <full path>"` depuis le disque, `"Missing template posts/nope.html.erb (embedded)"` depuis la table.

Les recherches de fichiers résolvent la racine des vues et le chemin du template à travers les liens symboliques, et ne chargent que des fichiers ordinaires situés dans cette racine. Les chemins qui en sortent (y compris via des liens symboliques) lèvent `MissingTemplate`&nbsp;; `exists?` renvoie false pour ces chemins.

## Erreurs

Deux classes d’exception, toutes deux dans l’espace de noms `Cybertrain::Template` de `ast.rb` (distinctes de `::SyntaxError`/`::RuntimeError`)&nbsp;:

- **`SyntaxError`** — levée pendant le découpage en lexèmes/l’analyse, avant toute interprétation. Forme&nbsp;: `"<template>:<line>: <what>"`, par ex. `"posts/show:2: 'if' without 'end'"`, `"posts/show:1: unterminated <% tag"`, `"posts/show:1: unexpected ')' in 'foo(1))'"`. Levée directement par `Engine#template` (et donc par `#render`/`#render_with_layout`) quand un fichier de page ou de layout ne s’analyse pas — jamais attrapée ni réemballée par l’interpréteur.
- **`RuntimeError`** — levée pendant l’évaluation, même forme de message, mais `<template>` est le template *en cours de rendu* (`Interpreter#render` permute `@name` à l’entrée et à la sortie) — l’erreur propre à un partiel garde le nom et la ligne du partiel, jamais ceux de l’appelant&nbsp;: `"posts/_row:1: undefined method 'bogus' for String"`.

Toute `StandardError` ordinaire venant d’un helper ou d’un appel de méthode de `FormBuilder`/d’objet personnalisé (un simple `raise "text"`, `ArgumentError`, `KeyError`, voire une `Cybertrain::Template::RuntimeError` venant d’un `render` imbriqué) est attrapée et «&nbsp;relocalisée&nbsp;»&nbsp;: réécrite en `"<current template>:<current line>: <original message>"`, sauf si c’est déjà exactement le dernier message relocalisé (un `render` imbriqué a déjà apposé sa propre localisation, plus précise), auquel cas elle passe inchangée. Une `Cybertrain::Template::SyntaxError` levée par un helper (un partiel qui ne s’analyse pas, en plein rendu) n’est jamais réemballée — elle garde son propre message `"<partial>:<line>: ..."` et sa classe, de sorte qu’un partiel cassé est toujours signalé comme une `SyntaxError` le concernant, et non comme une `RuntimeError` concernant celui qui l’a rendu.

`Cybertrain::Views::OutsideRequest` et `Cybertrain::Component::Unknown` passent aussi sans être enveloppées, en gardant leur classe, pour que l’appelant de `Views.render_partial` puisse les rattraper.

`MissingTemplate` (`StandardError`, `engine.rb`) est levée **sans emballage**, sans préfixe `template:line`, depuis un appel de premier niveau à `Engine#template`/`#render`/`#render_with_layout` (par ex. un contrôleur qui rend un template d’action ou un layout absent)&nbsp;: `"Missing template <path>"`. La même exception levée *à l’intérieur* d’un template via la recherche de partiel du helper `render` passe au contraire par la relocalisation et en ressort comme une `RuntimeError`&nbsp;: `"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`.

## Différences avec l’ERB de Rails

| ERB de Rails | Cybertrain |
| --- | --- |
| Compilé en méthode Ruby&nbsp;; n’importe quel Ruby, n’importe quel objet, n’importe quelle méthode fonctionne | Interprété selon des tables de dispatch fixes par type&nbsp;; seul ce que liste la [table des méthodes par type](#per-type-method-table) peut être appelé |
| `ActiveSupport::SafeBuffer` est une sous-classe de `String` | `SafeString` est une classe d’enveloppe distincte — seuls `to_s`/`html_safe?`/`size`/`length`/`empty?` peuvent être appelés dessus |
| Blocs&nbsp;: `each`, `{ }`, `map`, n’importe quelle méthode d’Enumerable | `{ }` et `do...end` sur une liste fixe de méthodes d’Array/Hash (pas `each_with_object`, `inject`), les boucles `each`/`each_with_index`/`each_slice`, les appels de helpers et `tag` |
| `xs.each { }` — zéro paramètre de bloc, c’est permis | `each`/`each_with_index` exigent de déclarer 1 ou 2 paramètres de bloc |
| `link_to text, path, method: :delete` (piloté par JS) | Pas de `method:` sur `link_to` — utilisez `button_to` pour un vrai formulaire autre que GET |
| Les locals stricts acceptent `name: default_expr` (Rails 7.1) | Uniquement un `name:` nu (obligatoire)&nbsp;; une entrée avec valeur par défaut est une `SyntaxError` |
| Une ivar/variable locale non définie se résout via Ruby / les méthodes du contexte de vue | `@x` est une simple lecture de l’env qui n’échoue jamais&nbsp;; une variable locale nue non définie est une tentative explicite et fermée d’appel de helper (`"undefined helper"` en l’absence de correspondance) |
| `case/when` avec `===` (intervalles, classes, regex) | `case/when` avec `==` seulement (les nombres par valeur) |
| `and`/`or`/`not`, intervalles, regex, affectation multiple fonctionnent tous | Rien de tout cela n’existe&nbsp;; les mots réservés échouent avec un message spécifique «&nbsp;not supported in templates&nbsp;», pas une erreur d’analyse générique |
| Littéraux numériques&nbsp;: hexadécimal, octal, binaire, exposants, rationnels | Uniquement des entiers/flottants décimaux avec des séparateurs `_` facultatifs |
| `:"quoted symbol"`, symboles d’opérateur `:+` | Les symboles ne contiennent que des caractères d’identifiant |
| `foo (x)`, `foo [x]` (espace toléré, parfois avec un avertissement) | Les deux sont des `SyntaxError` franches — pas d’espace avant la `(` d’un appel ni le `[` d’une indexation |
| Appels imbriqués sans parenthèses résolus par le propre parseur de Ruby | Seul l’appel le plus externe d’une expression reçoit des arguments sans parenthèses |
| Un attribut non déclaré/mal orthographié lève de façon fiable `NoMethodError` | S’affiche silencieusement vide, sauf si le modèle généré concerné redéfinit `attribute_or_method?` (lacune connue, pas une garantie) |
| `1 / 0` et `1.0 / 0` lèvent tous deux `ZeroDivisionError` | La division/le modulo d’un `Integer` par zéro lève `"divided by 0"`&nbsp;; `Float` suit l’IEEE-754 (`Infinity`/`NaN`), sans erreur |
| `distance_of_time_in_words`/la pluralisation prennent en charge les locales i18n | `time_ago_in_words`, `distance_of_time_in_words`, les helpers de nombres et `time_tag` lisent le dictionnaire de la locale&nbsp;; `pluralize` n’infléchit que l’anglais ([Internationalisation](i18n.md#helpers-that-follow-the-locale)) |
| Chaque module de `app/helpers` est mélangé dans la vue&nbsp;; n’importe quelle signature&nbsp;; un helper peut en remplacer un du framework | Les modules sont analysés à la compilation en un `case` généré&nbsp;: paramètres nommés seulement, au plus trois optionnels, aucun nom de helper du framework et pas de terminaison `_path`/`_url` ([Helpers de l’application](#application-helpers)) |
| ViewComponent&nbsp;: `render CardComponent.new(title: "x")`, `with_collection`, slots | `render component: "card", title: "x"` par nom, `content` venant du bloc, `collection:` pour un composant qui porte le nom de son unique mot-clé requis&nbsp;; pas de slots ([Composants](#components), [Collections](#collections)) |
| Une ligne `layout` ultérieure remplace une antérieure | La première déclaration `layout` qui s’applique l’emporte ([Layouts par contrôleur](#per-controller-layouts)) |
