---
source_sha256: 1f3299ce753f9ca949e912a5d2848b2b028f258f8ebdcef7a3be7a74894d6104
---
# Modèles et base de données

Ce que fait un modèle au-delà du scaffold&nbsp;: écrire des migrations, les requêtes qui vont plus loin que `where`, paginer une liste, les transactions, et les règles que suivent sous Spinel les noms de colonnes SQLite et les clauses `order`.

## Migrations

Une migration dans `db/migrate/<version>_<name>.rb` est une sous-classe de
`Cybertrain::Migration::Base`. Son `change` enregistre des opérations de schéma
(`create_table`, `add_column`, `add_index`, `rename_column`, `add_reference`,
`remove_column`, `remove_index`, `drop_table`)&nbsp;; `cybertrain db migrate`
applique chaque version en attente dans sa propre transaction et réécrit
`db/schema.rb` à partir de la base de données, et `cybertrain db rollback [N]`
exécute l’inverse de `change`. Quand `change` contient une opération sans
inverse automatique, écrivez `down` (et `up`).

Un changement de schéma qui a besoin d’une étape sur les données pour être sûr
utilise `execute(sql, binds =
[])`. Elle s’exécute à sa place dans la migration, sur la propre connexion du
migrateur et dans la même transaction que les opérations de schéma de la
version&nbsp;: la colonne ajoutée avant elle existe donc quand elle s’exécute,
et un échec annule toute la version&nbsp;:

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # les lignes existantes restent « pour toujours »
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

Sans binds, le SQL peut comporter plusieurs instructions séparées par
des `;`&nbsp;; avec binds, c’est une seule instruction avec des marqueurs `?`.
`execute` n’a pas d’inverse&nbsp;: annuler un `change` qui exécute du SQL, sans
`down` qui lui soit propre, s’arrête avec
`version N is irreversible: it executes SQL in change; write down` avant que
quoi que ce soit ne soit défait. Une instruction sur les données n’apparaît
jamais dans `db/schema.rb`, qui est extrait de la base de données. Enregistrer
une migration n’exécute rien, donc l’instruction s’exécute exactement une fois
par `migrate` de sa version.

## Requêtes au-delà de `where`

Les relations générées couvrent `where` / `where_sql` / `order` / `limit` /
`offset` / `count` / `exists?` / `delete_all`. Pour les compteurs, les
statistiques et les champs de recherche dont la plupart des applications ont
aussi besoin, il existe des ajouts typés (issue #74, `docs/design.md` D22)
plutôt qu’un constructeur de requêtes&nbsp;; chacun prend des noms de colonnes
SQL, vérifiés et mis entre guillemets (tout le reste est une `ArgumentError`),
et lie chaque valeur&nbsp;:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ... ; renvoie le nombre de lignes écrites
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   (existent aussi : pluck_str, pluck_float)
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # regroupement par heure
Stat.where(project_id: 1).sum_int(:calls)                 # existe aussi : sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- Chacune est typée, car une méthode Spinel a un seul type de retour&nbsp;:
  `pluck_str` / `pluck_int` / `pluck_float` ne lisent qu’une seule colonne,
  `sum_int` / `sum_float` en additionnent une, et `count_by` renvoie un
  `Hash{String => Integer}`.
- Les valeurs `update` d’`upsert` et l’expression de `count_by_sql` sont du
  texte SQL, comme `order_sql`&nbsp;: ne les construisez jamais à partir de
  données de la requête. Un `update` vide donne `DO NOTHING`. `upsert` et
  `increment` ne chargent aucun modèle, n’exécutent ni validation ni callback,
  et ne remplissent aucun horodatage.
- Les clés de `count_by` sont des String (via `Cast.str`), en ordre
  croissant&nbsp;; NULL et `""` partagent la clé `""`. Avec un `limit` /
  `offset`, `count_by`, `sum_*` et `increment` travaillent sur cette fenêtre,
  comme le font `count` et `delete_all` (par une sous-requête).
- `where_like` échappe `\`, `%` et `_` dans le texte pour vous, et recherche
  une sous-chaîne (sans tenir compte de la casse pour l’ASCII, comme le LIKE de
  SQLite). Une recherche par préfixe écrit son propre motif&nbsp;:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- Pour du SQL écrit à la main, `Cybertrain::Cast.binds(a, b, c)` construit
  l’Array de binds que prend `execute` (un Time en texte ISO 8601 UTC, les
  booléens en 1/0)&nbsp;:
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` restreignent une valeur JSON
  analysée à un Hash / un Array, ou à un nouveau conteneur vide quand elle n’en
  est pas un (un Time est vérifié d’abord, spikes/NOTES.md règle 8). Elles
  renvoient une copie superficielle typée, pas `v` lui-même&nbsp;;
  `Cast.empty_hash` / `Cast.empty_array` sont les conteneurs vides
  pré-typés.

## Pagination

Une page de liste lit le numéro de page dans `?page=N`, restreint la relation à
une fenêtre et affiche les liens&nbsp;:

```ruby
# app/controllers/articles_controller.rb
def index
  @articles = Article.all.order("created_at DESC")
  @page = @articles.page(params.page_number, per: 20)
end
```

```erb
<%# app/views/articles/index.html.erb %>
<% @articles.each do |article| %>
  <p><%= link_to article.title, article %></p>
<% end %>
<%= paginate @page, articles_path %>
```

`params.page_number` est le paramètre `page`, numéroté à partir de 1, qui vaut
1 quand il est absent ou n’est pas un nombre, et est borné à `1..max_page`
(`config.max_page`, 10000 par défaut, `CYBERTRAIN_MAX_PAGE`)&nbsp;; il ne passe
jamais de texte non borné à `String#to_i`, qui lève `RangeError` au-delà de
2**63-1 sous Spinel. `params.int(:per, default: 20,
min: 1, max: 100)` est la même lecture bornée pour n’importe quelle clé (un `-`
facultatif et au plus 18 chiffres, sinon la valeur par défaut&nbsp;; borné à
`min..max`).

`relation.page(n, per: 50)` applique
`LIMIT per OFFSET (n - 1) * per` à la relation (en remplaçant un `limit`/`offset`
antérieur&nbsp;: appelez-la donc en dernier), borne `n` de la même façon, de
sorte que l’offset ne dépasse jamais `(max_page - 1) * per`, et renvoie un
`Cybertrain::Page`&nbsp;: `number`, `per`, `row_offset`, `next?` (déterminé par
un seul `SELECT 1 ... LIMIT per + 1` sur la fenêtre, sans `COUNT(*)`), `prev?`,
`next_number`, `prev_number`. Les lignes restent sur la relation, donc
`@articles.each` produit des `Article` typés&nbsp;; un `per` hors de 1..1000 est
une `ArgumentError`.

`paginate @page, path` rend `<nav class="pager">` avec un
lien «&nbsp;Newer&nbsp;» (`rel="prev"`), «&nbsp;Page N&nbsp;» et un lien
«&nbsp;Older&nbsp;» (`rel="next"`), chacun omis quand la page correspondante
n’existe pas&nbsp;; les liens conservent la chaîne de requête courante en
remplaçant `page` (la page 1 le supprime), réencodée et échappée, de sorte
qu’une recherche ou un filtre survit à la pagination, et un chemin avec sa
propre chaîne de requête (`"/search?q=x"`) utilise plutôt celle-ci.

Pagination
par offset uniquement&nbsp;: la pagination par clé (`after: id`) pour les très
grandes tables n’est pas encore développée. La vue index du scaffold liste tous
les enregistrements&nbsp;; ajoutez les trois lignes ci-dessus pour la paginer.

## Transactions

`Cybertrain::DB.transaction { |c| ... }` (ou `Article.transaction`, la même chose sous le nom de Rails) emprunte une connexion, lance `BEGIN`, passe la connexion au bloc, fait `COMMIT` quand le bloc se termine, et annule puis relève l’exception quand il en lève une. `immediate: true` lance `BEGIN IMMEDIATE`, qui prend le verrou d’écriture de SQLite dès le début&nbsp;: utilisez-le pour une transaction qui lit puis écrit, pour qu’un écrivain concurrent la fasse attendre à `BEGIN` plutôt qu’échouer avec «&nbsp;database is locked&nbsp;» à sa première écriture. Pendant l’exécution du bloc, tout ce qui, sur ce thread, passe par le pool (`save`, `update`, `destroy`, les requêtes Relation, `DB.with`) utilise la connexion de la transaction, et fait donc partie de la transaction&nbsp;:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

En quoi elle diffère du `transaction` de Rails, et ce qu’il faut éviter&nbsp;:

- Elle renvoie nil plutôt que la valeur du bloc.
- On en sort en levant une exception, qui est relevée après l’annulation (Rails en sort avec `raise ActiveRecord::Rollback`).
- Un `DB.transaction` imbriqué dans le bloc rejoint la transaction externe&nbsp;: seule la plus externe fait le commit, une exception n’importe où annule tout, et il n’y a pas de savepoints (pas de `requires_new: true`).
- `c.transaction { }` ne peut pas être appelé sur le `c` passé au bloc sous Spinel&nbsp;: imbriquez `DB.transaction`, ou utilisez la forme sans bloc ci-dessous.
- Un `DB.transaction` appelé dans un bloc `DB.with` (qui n’est pas une transaction) emprunte une seconde connexion&nbsp;: avec un pool d’une seule connexion (`:memory:` compris), il attend alors indéfiniment. Ouvrez d’abord la transaction et faites le travail à l’intérieur.

Le code qui doit garder son `rescue` dans une méthode simple utilise la forme sans bloc, `c.begin!(immediate: true)` ... `c.commit!`, avec `c.rollback!` dans le rescue.

## Noms de colonnes

Un nom de colonne doit être un identifiant ASCII (`[A-Za-z_][A-Za-z0-9_]*`), là où Rails accepte n’importe lequel. Un schéma avec un nom de colonne non ASCII (`名前`, `prénom`) se générait sous CRuby avant la PR #10, et `spin run gen` le refuse désormais&nbsp;; renommez donc la colonne lors de la mise à niveau (un nom comme `first-name` n’a jamais été un nom de méthode).

Une colonne nommée comme une méthode que la classe générée ou le framework appelle sur un enregistrement (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) ou comme un mot-clé Ruby (`end`, `class`, `begin`) est générée sous `<column>_column` (`hash_column`&nbsp;: lecteur, écrivain et ivar) avec une note dans le fichier généré. Ses deux noms s’utilisent ainsi&nbsp;:

- Son nom SQL continue de fonctionner dans `read_attribute`, les params et `attributes["hash"]`.
- Un template l’atteint sous l’un ou l’autre nom (`post.hash`, `post.hash_column`), sauf `errors` et `to_param`, qu’un template résout comme les méthodes du modèle&nbsp;: utilisez donc `post.errors_column` à cet endroit.
- L’API de requête (`where`, `order`, `find_by`) prend toujours le nom de colonne SQL (`Post.where(hash: 1)`)&nbsp;; le nom Ruby n’est que celui du lecteur/écrivain et du template.

Une colonne nommée comme une autre méthode d’Object (`display`, `tap`, `methods`) est générée sous son propre nom avec une note. `cybertrain generate scaffold` refuse les mots-clés et les noms réservés (il devrait appeler un lecteur renommé) et accepte un nom masquant avec une note, comme le générateur.

Là où Rails laisse une association masquer `errors`, une association dont le nom simple est déjà pris par une colonne, une autre association ou une méthode de `Model` est émise sous un nom de repli, avec un commentaire dans le fichier généré&nbsp;: `<table>_as_<column stem>` pour un `has_many` (`comments_as_article`), `<stem>_as_<column>` pour un `belongs_to` (`author_as_author_id`).

## Tri

Là où le `order` de Rails accepte n’importe quel SQL (`order("lower(title)")`, `order("posts.title")`, `order(params[:sort])`), `order` n’accepte ici que des listes `column [ASC|DESC]` (chaque colonne entre guillemets) et lève `ArgumentError` pour tout le reste&nbsp;: une 500, puisque la chaîne vient du développeur.

Les données de la requête doivent d’abord passer par une liste blanche, car un terme bien formé peut quand même nommer une colonne absente (une 500 venant de SQLite) ou une colonne par laquelle le client ne doit pas trier&nbsp;:

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

Le texte ORDER BY brut passe par `order_sql` (`Post.order_sql("lower(title)")`, aussi sur une relation), qui ne doit jamais voir de données de la requête.
