---
source_sha256: 9c348325e4945493aa6eeb42add294c7ce0b8bf34811b3014c18617dec0b0ef6
---
# Référence du langage de templates de Cybertrain

Les vues de Cybertrain (`app/views/**/*.html.erb`) ressemblent à de l’ERB de Rails, mais ne sont pas du Ruby&nbsp;: elles sont analysées à l’exécution (depuis `app/views/` sur le disque en développement et en test&nbsp;; dans un binaire de production, depuis la table de chaînes que `cybertrain build` intègre via `gen/views.rb`), découpées en lexèmes et analysées en un AST, compilées une fois en un arbre de nœuds plat, puis parcourues par un interpréteur qui parcourt l’arbre.

Ce document décrit exactement ce que ce pipeline accepte et exécute. Là où il diverge de la section 7 de `docs/design.md` (le projet de spécification initial) ou de ce qu’attendrait un développeur Rails, c’est le code qui a raison, et ce document le dit (cherchez «&nbsp;**Tel qu’implémenté**&nbsp;»).

## Ce qui est du Ruby ici, et ce qui n’en est pas

Les templates ne sont **pas** du Ruby. Spinel (le compilateur AOT de Ruby de Matz que vise cybertrain) n’a pas d’`eval`, donc «&nbsp;interpréter le Ruby propre à la vue au moment de la requête&nbsp;» n’a jamais été envisageable (D9 dans `docs/design.md`)&nbsp;; ce qui s’exécute à la place est une petite grammaire fermée qui ne fait qu’emprunter une syntaxe d’allure ERB/Ruby. Il n’y a pas de Ruby arbitraire dans une balise — seulement ce que `ExprParser` (`parser.rb`) reconnaît comme instruction ou expression. Il n’y a pas d’`eval`, de `send`, d’`instance_eval`, de définitions de méthodes/classes/modules, de `require`, d’exceptions (`begin/rescue`), de `case/when`, d’intervalles, de regex, ni d’affectation multiple. Les seuls blocs sont `each`, `each_with_index` et un appel à un helper (`form_with(...) do |f| ... end`) — pas de blocs `{ }`, pas de `map`/`select` ni d’autre méthode d’Enumerable avec bloc. Chaque appel de méthode (`recv.name`) est résolu par des tables de dispatch `case` écrites à la main dans `interpreter.rb`, indexées par la classe Ruby du receveur à l’exécution&nbsp;; un nom absent de la table de ce type échoue avec une `RuntimeError` — il n’y a pas de `method_missing`, pas de réflexion, et (d’après `Interpreter#call_method`) c’est précisément l’absence de `send` dans Spinel qui fait que c’est un `case` et non une recherche par métaprogrammation. Un template ne peut faire que ce que décrit ce document.

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
- **Sans** ce commentaire, un template ne déclare aucune liste de variables locales&nbsp;: `render` transmet toutes les variables locales qu’il reçoit, sans vérification, et le template peut aussi lire tout ce qui est déjà présent dans l’environnement de l’appelant (voir la section 8).
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
- `yield` et `yield :key` sont toujours analysés comme des appels (voir la section 8).
- Un mot nu commençant par une majuscule est rejeté d’emblée — `"constants are not supported: 'Time'"` — les templates ne peuvent pas atteindre les constantes Ruby.
- Ces mots sont réservés et rejetés avec un message dédié (`"'x' is not supported in templates"`)&nbsp;: `and or not do end if unless elsif else then while until case when def class module begin rescue return`.

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

### Boucles

```erb
<% @posts.each do |post| %>...<% end %>
<% @counts.each do |name, n| %>...<% end %>          <%# Hash: name=key, n=value %>
<% items.each_with_index do |item, i| %>...<% end %>
```

- `each`/`each_with_index` ne sont reconnus que comme suffixe de l’en-tête du bloc (`x.each do |...|`). **Tel qu’implémenté**, les deux exigent de déclarer un ou deux paramètres de bloc — `xs.each do end` est une `SyntaxError` («&nbsp;takes one or two block parameters&nbsp;»), là où le Ruby ordinaire en accepte zéro.
- Array + un paramètre&nbsp;: l’élément. Array + deux paramètres&nbsp;: un élément `Array` est déstructuré (`a, b = item[0], item[1]`)&nbsp;; sinon, le second vaut `nil`.
- `each_with_index` sur un Array&nbsp;: `item, i`. Sur un Hash&nbsp;: le premier paramètre est une paire `[key, value]`, le second l’index.
- `each` sur un Hash avec deux paramètres&nbsp;: directement `key, value`&nbsp;; avec un paramètre&nbsp;: une paire `[key, value]`.
- Itérer sur `nil`, un `Time` ou n’importe quel scalaire est une `RuntimeError` (`"undefined method 'each' for Time"`) — jamais une absence d’effet silencieuse.
- Un paramètre de bloc masque une variable locale externe du même nom uniquement pendant la boucle, et est supprimé ensuite (`refute env.key?("item")` une fois la boucle terminée). Une variable qui existait avant le bloc est la *même* variable à l’intérieur (visible aussi après la boucle)&nbsp;; une variable **affectée pour la première fois dans** le bloc est locale au bloc — `nil` au début de chaque itération, disparue ensuite.

### Appels avec bloc (helpers)

`do ... end` est aussi la façon dont un appel de helper sans receveur prend un bloc — le seul autre usage légal d’un bloc, et seulement quand il n’y a pas de receveur (`f.each do |x| end` est refusé&nbsp;: «&nbsp;blocks are only supported on each, each_with_index and helper calls&nbsp;»)&nbsp;:

```erb
<%= form_with(model: @post) do |f| %>...<% end %>   <%# printed: form_with returns the <form> HTML %>
<% content_for :title do %>Hi<% end %>              <%# not printed: content_for returns "" %>
```

L’affichage ou non du résultat du bloc suit la balise&nbsp;: `<%= helper do |x| %>` l’affiche, `<% helper do |x| %>` l’ignore. Exactement un paramètre de bloc est lié, toujours&nbsp;; un bloc de helper ne reçoit jamais d’index ni de seconde valeur.

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
| `Array` | `size`/`length`/`count` `empty?` `any?` `first` `last` `reverse` `include?(x)` `join(sep)` `to_a` | `post.comments.any?` |
| `Hash` | `key?(k)` `fetch(k, default)` `size`/`length`/`count` `empty?` `any?` `keys` `values`, plus `h[key]` | `flash.key?(:notice)` |
| `Errors` | `any?` `empty?` `count`/`size` `full_messages` `key?(a)`/`include?(a)`, plus `errors[:attr]` | `post.errors.full_messages.join(', ')` |
| `Params` | `key?(k)` `empty?`, plus `params[key]` | `params[:id]` |
| `Page` (`Relation#page`) | `number` `per` `row_offset` `next?` `prev?` `next_number` `prev_number` | `@page.next?` |
| `true`/`false` | `to_s` | `published.to_s` |
| `nil` | `to_s` (renvoie `""`) | |

L’indexation (`x[key]`) est une production distincte de la grammaire (section 3), pas un appel `.[]`&nbsp;: `Array`/`String` prennent un index entier, `Hash` fait correspondre n’importe quelle clé par son `to_s` (`h[:k]` et `h["k"]` sont la même entrée), `Errors` par symbole, `Params` par `to_s`.

Affichage (`<%= %>`/interpolation) au-delà du `to_s` ci-dessus&nbsp;: un `Array` s’affiche comme une liste à la manière d’inspect — `[1, "a", nil]` rend le texte `[1, "a", nil]` (puis est échappé, les guillemets deviennent donc `&quot;`)&nbsp;; un `Hash` se rabat sur le `Hash#to_s` de Ruby&nbsp;; un `Cybertrain::Model` s’affiche `#<Post id: 7>` (jamais ses attributs)&nbsp;; tout le reste s’affiche via son propre `to_s`. Une méthode non listée sur l’un de ces types est une `RuntimeError` (`"undefined method 'first' for Time"`). La division/le modulo d’un `Integer` par zéro donne `"divided by 0"`&nbsp;; `Float` suit plutôt l’IEEE-754 (`Infinity`/`NaN`, sans erreur).

## Les modèles dans les templates

Une sous-classe de `Cybertrain::Model` (un `Post`, un `Note` générés, ...) résout un nom nu dans cet ordre (`Interpreter#model_method`)&nbsp;:

1. Cinq méthodes intégrées, toujours disponibles&nbsp;: `id`, `persisted?`, `new_record?`, `to_param` (`id.to_s`), `errors` (un `Errors`, section 5).
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

Chaque appel sans receveur va à `Helpers#helper_call` (`helpers.rb`), qui fait correspondre l’une des méthodes intégrées ci-dessous, traite un nom finissant par `_path`/`_url` comme un helper de route généré (via `Cybertrain::Views.url_resolver`, qui lève `"no routes"` tant que l’application n’en a pas installé un), ou lève `"undefined helper 'name'"`.

| Helper | Signature | Remarques / exemple |
| --- | --- | --- |
| `link_to` | `link_to(text, href, class:, id:, data_confirm:, data: {})` | `text` est échappé sauf s’il est déjà une `SafeString`&nbsp;; **pas de `method:`** — lève une erreur qui vous dit d’utiliser `button_to` (pas de liens DELETE simulés à la rails-ujs/turbo) |
| `button_to` | `button_to(text, action, method: :post, class:, data: {})` | un `<form class="button_to">` à un seul bouton&nbsp;; un `_method` caché pour tout verbe autre que `get`/`post`, plus le champ CSRF quand une session existe |
| `form_with` | `form_with(model:, url:, method:, class:, multipart:) do \|f\| ... end` | exige un bloc&nbsp;; `model:` nouveau → route de collection + POST, persisté → route de membre + PATCH&nbsp;; `[parent, child]` pour une route imbriquée&nbsp;; `url:`/`method:` remplacent l’action/le verbe déduits&nbsp;; `multipart: true` ajoute `enctype="multipart/form-data"` (requis pour `f.file_field`&nbsp;; ce n’est jamais deviné à partir du bloc, et cela lève `ArgumentError` sur un formulaire GET) |
| `render` | `render "name"` / `render "name", k: v` / `render partial: "name", locals: { k: v }` | voir la section 8 |
| `h`, `escape` | `h(text)` | échappe&nbsp;; une `SafeString` passe sans être échappée |
| `raw` | `raw(text)` | enveloppe le texte dans une `SafeString` (affiché sans échappement) |
| `pluralize` | `pluralize(count, singular, plural = nil)` | `pluralize(1, "comment")` → `"1 comment"`&nbsp;; `pluralize(2, "mouse")` → `"2 mice"` (les inflexions anglaises par défaut de Rails, via `Cybertrain::Inflector`&nbsp;; les inflexions définies par l’application ne sont pas prises en charge)&nbsp;; un troisième argument explicite l’emporte toujours |
| `truncate` | `truncate(text, length: 30, omission: "...")` | `truncate("Hello world", length: 8)` → `"Hello..."` |
| `number_with_delimiter` | `number_with_delimiter(n)` | `1234567` → `"1,234,567"`&nbsp;; `-1000` → `"-1,000"`&nbsp;; `1234.5` → `"1,234.5"` |
| `time_ago_in_words` | `time_ago_in_words(time)` | Tranches à la Rails, sans précision à la seconde&nbsp;: `"less than a minute"` … `"about 1 hour"` … `"3 days"` … `"about 1 year"` |
| `content_for` / `content_for?` | `content_for(:key) do...end`, `content_for(:key, "text")`, `content_for?(:key)` | voir la section 8 |
| `csrf_meta_tags` / `csrf_token` | | vide / absent sans session de contrôleur |
| `flash` | | à la manière d’un `Hash`&nbsp;: `flash[:notice]` |
| `params` | | les `Cybertrain::Params` courants |
| `request_path` | | le chemin courant, `""` sans contrôleur |
| `url_for` | `url_for(target)` | `String` tel quel, `Model` → route de membre, `[parent, child]` → route imbriquée |
| `paginate` | `paginate(page, path)` | `page` est un `Cybertrain::Page` (issu de `Relation#page`)&nbsp;; rend `<nav class="pager">` avec «&nbsp;Newer&nbsp;» (`rel="prev"`), `<span class="pager-current">Page N</span>` et «&nbsp;Older&nbsp;» (`rel="next"`), un lien étant omis quand la page correspondante n’existe pas. Chaque lien est `path` plus la chaîne de requête de la requête courante avec `page` remplacé (supprimé pour la page 1), réencodée et échappée pour le HTML&nbsp;; un `path` avec sa propre `?query` utilise plutôt celle-ci. Un `Page` répond aussi à `number`, `per`, `row_offset`, `next?`, `prev?`, `next_number`, `prev_number` dans un template (`<% if @page.next? %>`) |
| `*_path` / `*_url` | par ex. `post_path(post)` | générés par l’application, résolus via `Cybertrain::Views.url_resolver` |

Chaque argument texte d’un helper suit une seule règle&nbsp;: une `SafeString` passe sans être échappée, tout le reste est échappé — `link_to raw('<b>raw</b>'), post` affiche la balise gras littéralement, mais `link_to post.title, post` l’échappe.

### FormBuilder (`f` dans `form_with ... do |f|`)

Chaque méthode renvoie une `SafeString`&nbsp;; une méthode non listée est une `RuntimeError` (`"undefined method 'color_wheel' for FormBuilder"`).

| Méthode | Rendu |
| --- | --- |
| `f.label :title` / `f.label :title, "Text"` | `<label for="post_title">Title</label>` — le texte par défaut est l’attribut humanisé (`published_at` → «&nbsp;Published at&nbsp;», `author_id` → «&nbsp;Author&nbsp;»)&nbsp;; un texte explicite est échappé sauf s’il est une `SafeString` |
| `f.text_field :title` (aussi `email_field`, `password_field`, `number_field`, `date_field`, `hidden_field`) | `<input type="..." name="post[title]" id="post_title" value="...">`&nbsp;; `password_field` n’émet jamais `value=` |
| `f.file_field :cover` (aussi `accept: "image/*"`, `required: true`) | `<input type="file" name="post[cover]" id="post_cover">` — jamais de `value=`, et l’attribut n’a pas besoin d’être une colonne&nbsp;; le formulaire doit être `form_with ..., multipart: true`&nbsp;; `multiple: true` lève `ArgumentError` (un fichier par champ) |
| `f.text_area :body` | `<textarea name="post[body]" id="post_body">\n...</textarea>` (`\n` initial, comme le fait Rails — les navigateurs absorbent le premier saut de ligne) |
| `f.check_box :published` | un input caché `value="0"` puis la vraie case à cocher, de sorte qu’une case non cochée envoie quand même `"0"` |
| `f.submit` / `f.submit "Text"` | texte par défaut `"Create Post"`/`"Update Post"` (selon `persisted?`), ou `"Save changes"` sans modèle |

Avec un modèle, les champs sont nommés `post[title]`/`id="post_title"` (avec `Inflector.underscore(model.model_name)` comme portée)&nbsp;; avec `form_with(url: ...)` et sans modèle, le nom d’attribut nu est utilisé pour les deux. Les arguments nommés supplémentaires deviennent des attributs HTML dans l’ordre donné&nbsp;: `true` → `attr="attr"`, `false`/`nil` omis, tout le reste → `attr="value"` (échappé), les tirets bas deviennent des traits d’union (`data_confirm: "Sure?"` → `data-confirm="Sure?"`), et `class:` est fusionné avec la classe automatique `field_with_errors` ajoutée quand `model.errors.key?(attr)`.

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

### Résolution des fichiers (`engine.rb`)

`"posts/show"` et `"posts/show.html.erb"` désignent le même template. Le développement lit `app/views/` depuis le disque avec `cache: false` (un fichier est relu et réanalysé chaque fois que son mtime ou sa taille change)&nbsp;; l’environnement de test lit depuis le disque avec `cache: true` (analysé une fois). Un binaire de production ne touche jamais au disque&nbsp;: `cybertrain build` lance `spin run gen -- --embed-views`, qui écrit chaque `*.erb` de `app/views/` (fichiers cachés et répertoires liés symboliquement exclus) dans `gen/views.rb`, et `Engine.embedded(sources)` analyse chaque entrée une fois (les messages d’erreur gardent la même forme `posts/show.html.erb:12`)&nbsp;; un binaire dont la table est vide refuse de démarrer en production. Un template absent lève `Cybertrain::Template::MissingTemplate` — `"Missing template <full path>"` depuis le disque, `"Missing template posts/nope.html.erb (embedded)"` depuis la table.

Les recherches de fichiers résolvent la racine des vues et le chemin du template à travers les liens symboliques, et ne chargent que des fichiers ordinaires situés dans cette racine. Les chemins qui en sortent (y compris via des liens symboliques) lèvent `MissingTemplate`&nbsp;; `exists?` renvoie false pour ces chemins.

## Erreurs

Deux classes d’exception, toutes deux dans l’espace de noms `Cybertrain::Template` de `ast.rb` (distinctes de `::SyntaxError`/`::RuntimeError`)&nbsp;:

- **`SyntaxError`** — levée pendant le découpage en lexèmes/l’analyse, avant toute interprétation. Forme&nbsp;: `"<template>:<line>: <what>"`, par ex. `"posts/show:2: 'if' without 'end'"`, `"posts/show:1: unterminated <% tag"`, `"posts/show:1: unexpected ')' in 'foo(1))'"`. Levée directement par `Engine#template` (et donc par `#render`/`#render_with_layout`) quand un fichier de page ou de layout ne s’analyse pas — jamais attrapée ni réemballée par l’interpréteur.
- **`RuntimeError`** — levée pendant l’évaluation, même forme de message, mais `<template>` est le template *en cours de rendu* (`Interpreter#render` permute `@name` à l’entrée et à la sortie) — l’erreur propre à un partiel garde le nom et la ligne du partiel, jamais ceux de l’appelant&nbsp;: `"posts/_row:1: undefined method 'bogus' for String"`.

Toute `StandardError` ordinaire venant d’un helper ou d’un appel de méthode de `FormBuilder`/d’objet personnalisé (un simple `raise "text"`, `ArgumentError`, `KeyError`, voire une `Cybertrain::Template::RuntimeError` venant d’un `render` imbriqué) est attrapée et «&nbsp;relocalisée&nbsp;»&nbsp;: réécrite en `"<current template>:<current line>: <original message>"`, sauf si c’est déjà exactement le dernier message relocalisé (un `render` imbriqué a déjà apposé sa propre localisation, plus précise), auquel cas elle passe inchangée. Une `Cybertrain::Template::SyntaxError` levée par un helper (un partiel qui ne s’analyse pas, en plein rendu) n’est jamais réemballée — elle garde son propre message `"<partial>:<line>: ..."` et sa classe, de sorte qu’un partiel cassé est toujours signalé comme une `SyntaxError` le concernant, et non comme une `RuntimeError` concernant celui qui l’a rendu.

`MissingTemplate` (`StandardError`, `engine.rb`) est levée **sans emballage**, sans préfixe `template:line`, depuis un appel de premier niveau à `Engine#template`/`#render`/`#render_with_layout` (par ex. un contrôleur qui rend un template d’action ou un layout absent)&nbsp;: `"Missing template <path>"`. La même exception levée *à l’intérieur* d’un template via la recherche de partiel du helper `render` passe au contraire par la relocalisation et en ressort comme une `RuntimeError`&nbsp;: `"posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb"`.

## Différences avec l’ERB de Rails

| ERB de Rails | Cybertrain |
| --- | --- |
| Compilé en méthode Ruby&nbsp;; n’importe quel Ruby, n’importe quel objet, n’importe quelle méthode fonctionne | Interprété selon des tables de dispatch fixes par type&nbsp;; seul ce que liste la section 5 peut être appelé |
| `ActiveSupport::SafeBuffer` est une sous-classe de `String` | `SafeString` est une classe d’enveloppe distincte — seuls `to_s`/`html_safe?`/`size`/`length`/`empty?` peuvent être appelés dessus |
| Blocs&nbsp;: `each`, `{ }`, `map`, n’importe quelle méthode d’Enumerable | Uniquement `do...end`, et uniquement sur `each`/`each_with_index`/un appel de helper |
| `xs.each { }` — zéro paramètre de bloc, c’est permis | `each`/`each_with_index` exigent de déclarer 1 ou 2 paramètres de bloc |
| `link_to text, path, method: :delete` (piloté par JS) | Pas de `method:` sur `link_to` — utilisez `button_to` pour un vrai formulaire autre que GET |
| Les locals stricts acceptent `name: default_expr` (Rails 7.1) | Uniquement un `name:` nu (obligatoire)&nbsp;; une entrée avec valeur par défaut est une `SyntaxError` |
| Une ivar/variable locale non définie se résout via Ruby / les méthodes du contexte de vue | `@x` est une simple lecture de l’env qui n’échoue jamais&nbsp;; une variable locale nue non définie est une tentative explicite et fermée d’appel de helper (`"undefined helper"` en l’absence de correspondance) |
| `and`/`or`/`not`, `case/when`, intervalles, regex, affectation multiple fonctionnent tous | Rien de tout cela n’existe&nbsp;; les mots réservés échouent avec un message spécifique «&nbsp;not supported in templates&nbsp;», pas une erreur d’analyse générique |
| Littéraux numériques&nbsp;: hexadécimal, octal, binaire, exposants, rationnels | Uniquement des entiers/flottants décimaux avec des séparateurs `_` facultatifs |
| `:"quoted symbol"`, symboles d’opérateur `:+` | Les symboles ne contiennent que des caractères d’identifiant |
| `foo (x)`, `foo [x]` (espace toléré, parfois avec un avertissement) | Les deux sont des `SyntaxError` franches — pas d’espace avant la `(` d’un appel ni le `[` d’une indexation |
| Appels imbriqués sans parenthèses résolus par le propre parseur de Ruby | Seul l’appel le plus externe d’une expression reçoit des arguments sans parenthèses |
| Un attribut non déclaré/mal orthographié lève de façon fiable `NoMethodError` | S’affiche silencieusement vide, sauf si le modèle généré concerné redéfinit `attribute_or_method?` (lacune connue, pas une garantie) |
| `1 / 0` et `1.0 / 0` lèvent tous deux `ZeroDivisionError` | La division/le modulo d’un `Integer` par zéro lève `"divided by 0"`&nbsp;; `Float` suit l’IEEE-754 (`Infinity`/`NaN`), sans erreur |
| `distance_of_time_in_words`/la pluralisation prennent en charge les locales i18n | Anglais uniquement, pas de prise en charge des locales |
