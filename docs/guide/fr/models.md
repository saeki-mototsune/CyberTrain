---
source_sha256: 2e61a5d003a8cdf4e505fa9aa88b96424b88abb33047c541a8ddecaca5b1f59b
---
# Modèles et base de données

Ce que fait un modèle au-delà du scaffold&nbsp;: les migrations, les types de colonnes, les requêtes, les associations, les validations, les colonnes chiffrées, la pagination, les transactions, les règles que suivent sous Spinel les noms de colonnes et les clauses `order`, et la reprise d’une base de données créée par Rails.

## Migrations

Une migration dans `db/migrate/<version>_<name>.rb` est une sous-classe de
`Cybertrain::Migration::Base`. Son `change` enregistre des opérations de schéma
(`create_table`, `add_column`, `add_index`, `rename_column`, `add_reference`,
`remove_column`, `remove_index`, `drop_table`, et celles de [Modifier une
table](#changing-a-table))&nbsp;; `cybertrain db migrate`
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

### Index et clés étrangères

`add_index` accepte `where:` pour un index partiel&nbsp;; `t.references`
accepte `on_delete:` et `index: false`, et `add_reference` accepte
`on_delete:` et ajoute toujours l’index&nbsp;:

```ruby
create_table "comments" do |t|
  t.references :article, on_delete: :cascade   # ON DELETE CASCADE
  t.references :author, null: true, on_delete: :nullify, index: false
  t.text "body"
  t.timestamps
end
add_index "comments", ["body"], where: "body IS NOT NULL"
```

`on_delete:` vaut `:cascade`, `:nullify` (la colonne doit accepter NULL) ou
`:restrict`&nbsp;; par défaut aucune clause `ON DELETE` n’est écrite (le
`NO ACTION` de SQLite). [`dependent:` ou `on_delete:`](#dependent-or-on_delete)
dit lequel choisir. Un index d’expression (`LOWER(email)`) n’a pas d’assistant
de migration&nbsp;: créez-le avec
`execute "CREATE UNIQUE INDEX index_users_on_lower_email ON users (LOWER(email))"`.
`db/schema.rb` le restitue sous la forme `s.add_index "users", "LOWER(email)", unique:
true, name: "index_users_on_lower_email"`, et le dump garde aussi le `where:`
d’un index partiel.

### Modifier une table

```ruby
class TidyPosts < Cybertrain::Migration::Base
  def up
    rename_table :posts, :articles
    change_column :articles, :views, :bigint, null: false, default: "0"
    change_column_default :articles, :state, from: nil, to: "'draft'"
    change_column_null :articles, :title, false, "untitled"
    remove_reference :articles, :legacy_owner
    remove_foreign_key :articles, :authors
  end

  def down
    # write the reverse of each step
  end
end
```

- `rename_table` est un `ALTER TABLE ... RENAME TO`, et les clés étrangères
  qui pointent vers la table la suivent. Ses index gardent leur nom (Rails
  les renomme d’après la nouvelle table).
- Les cinq autres reconstruisent la table, car SQLite n’a pas
  d’`ALTER COLUMN`&nbsp;: une nouvelle table est créée à partir de la
  définition modifiée, les lignes sont copiées, l’ancienne table est supprimée
  et la nouvelle renommée, puis ses index, ses triggers et la marque haute de
  `AUTOINCREMENT` sont rétablis. Les vues et les triggers d’autres tables qui
  la nomment continuent de fonctionner.
- `change_column` redéclare la colonne&nbsp;: les options qu’on ne lui donne
  pas (une valeur par défaut, `null: false`) disparaissent, comme dans Rails.
- `change_column_default` exige `to:` (texte littéral SQL, `nil` pour retirer
  la valeur par défaut)&nbsp;; `from:` nomme la valeur précédente et rend
  l’opération réversible.
- Le quatrième argument de `change_column_null` est une valeur écrite dans
  les cellules NULL avant l’ajout de `NOT NULL`&nbsp;; elle ne devient jamais
  la valeur par défaut de la colonne.
- `remove_foreign_key :articles, :authors` supprime la clé et garde la
  colonne et son index (`column:` nomme une autre colonne que `author_id`).

`rename_table`, et `change_column_default` avec `from:`, s’inversent
d’eux-mêmes dans `change`&nbsp;; `change_column_null` aussi, sauf qu’annuler
un `null: true` demande le quatrième argument pour les cellules devenues NULL
depuis. `change_column`, `remove_reference` et `remove_foreign_key` sont
irréversibles dans `change`&nbsp;: écrivez `up` et `down`.

<details><summary>Ce qu’une reconstruction refuse, et les clés étrangères pendant ce temps — CHECK, COLLATE, colonnes générées et le reste</summary>

Une reconstruction déclare la table à partir de ce que `db/schema.rb` sait
dire. Avant de toucher une table, elle lit son texte `CREATE TABLE` et refuse
une table qui contient ce que le schéma ne modélise pas (`rebuilding posts
would drop a CHECK constraint: rewrite the migration with execute`), et la
version est annulée. Cela couvre une contrainte `CHECK` ou `UNIQUE` en ligne
(un index unique convient), `COLLATE`, une colonne générée, `ON UPDATE`,
`ON DELETE SET DEFAULT`, `DEFERRABLE`, une clé étrangère vers une autre
colonne que `id`, une colonne sans type, une clé primaire autre que `id`, et
les tables `WITHOUT ROWID` ou `STRICT`. La vérification cherche ces mots dans
le texte SQL, ce n’est pas un analyseur&nbsp;: lisez le schéma exporté d’une
table écrite à la main avant de la reconstruire. Un simple
`id INTEGER PRIMARY KEY` revient en `AUTOINCREMENT`, ce qui garde chaque
ligne et chaque id. Les orthographes exactes des types sont normalisées
(`datetime(6)` devient `DATETIME`).

Une version qui reconstruit s’exécute avec `PRAGMA foreign_keys` désactivé
(on ne peut pas le désactiver dans une transaction, le migrateur le fait donc
autour de la version) et lance `PRAGMA foreign_key_check` avant de valider&nbsp;:
une violation annule la version et nomme les lignes. La vérification couvre
toute la base, si bien qu’une violation déjà présente dans une autre table
arrête aussi la version, comme dans Rails.

</details>

### Étapes de données dans les deux sens&nbsp;: `reversible`

```ruby
class BackfillSlugs < Cybertrain::Migration::Base
  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = lower(title)" }
      dir.down { execute "UPDATE posts SET slug = NULL" }
    end
  end
end
```

Les instructions de `dir.up` s’exécutent à la migration et celles de
`dir.down` à l’annulation, chacune dans l’ordre écrit. Seul `execute` va dans
les blocs. Non disponibles&nbsp;: `create_join_table`, `change_table`,
`rename_index`, `add_timestamps`.

`cybertrain db status` liste chaque version&nbsp;; une version présente dans
`schema_migrations` sans fichier sous `db/migrate` (une base qu’un autre outil
a migrée) apparaît comme `applied (no file)`, et le migrateur ne l’exécute ni
ne l’annule. `cybertrain db schema` écrit `db/schema.rb` à partir de la base
sans migrer ([Reprendre une base de données créée par
Rails](#taking-over-a-database-rails-created)).

## Types de colonnes

| DSL du schéma | SQL | Attribut Ruby |
| --- | --- | --- |
| `t.string`, `t.text` | `VARCHAR(n)` / `VARCHAR`, `TEXT` | String |
| `t.integer`, `t.bigint`, `t.references` | `INTEGER`, `BIGINT` | Integer |
| `t.float` | `FLOAT` | Float |
| `t.decimal :price, precision: 18, scale: 8` | `DECIMAL(18,8)` | Float, arrondi à l’échelle à l’enregistrement |
| `t.boolean` | `BOOLEAN` | true / false |
| `t.datetime` | `DATETIME` | Time (UTC, microsecondes) |
| `t.date` | `DATE` | Date |
| `t.json :meta, default: "{}"` | `JSON` | Hash à clés String |
| `t.binary` | `BLOB` | String d’octets ([Colonnes binaires](#binary-columns)) |

L’attribut d’une colonne qui accepte NULL peut aussi valoir nil. `new`,
`update` et `write_attribute` convertissent ce qu’on leur donne (`"42"` dans
une colonne entière donne `42`, `"2026-10-05"` dans une colonne date donne une
Date)&nbsp;; le simple writer `post.price = ...` ne convertit pas. L’INTEGER
de SQLite fait 64 bits, donc `t.bigint` est une colonne entière sous un autre
nom. `t.datetime :x, precision: 6` est accepté&nbsp;; chaque datetime garde
les microsecondes.

### Les décimaux sont des Float

Rails lit une colonne `decimal` comme un BigDecimal&nbsp;; ici c’est un
Float, et le modèle généré l’arrondit à la `scale:` de la colonne chaque fois
qu’il est stocké (`save`, `update_columns`, `update_all`, les écritures en
masse), si bien que la valeur stockée est celle que Rails stockerait après
l’affectation. Le BigDecimal de Spinel ne peut pas encore être construit à
partir d’un Float ou d’une String, ni arrondi, et c’est la condition pour
revenir sur ce choix (`docs/design.md` D42). La virgule flottante binaire
dérive dans les longues sommes&nbsp;: arrondissez au bord (`total.round(2)`),
ou gardez l’argent en unités mineures dans une colonne entière
(`price_cents`).

### Colonnes JSON

Une colonne `json` contient un objet, lu comme un `Hash` (`{}` pour une
colonne NOT NULL dont le texte n’est pas un objet JSON, nil pour une colonne
qui accepte NULL) et écrit avec `JSON.generate`. Ses valeurs sont emballées,
comme toute valeur JSON analysée sous Spinel&nbsp;: lisez-les avec
`Cybertrain::Cast`&nbsp;:

```ruby
event.meta = { "attempts" => 2, "tags" => ["a", "b"] }
event.save
Cybertrain::Cast.int(event.meta["attempts"])   # => 2
Cybertrain::Cast.array(event.meta["tags"])     # => ["a", "b"]
```

Un texte affecté qui n’est pas du JSON valide devient `{}`. Un Array à la
racine n’est pas pris en charge&nbsp;: stockez-le dans une colonne `text` et
lisez-le avec `Cast.array`. `where` sur une colonne json lève
`ArgumentError`, et `pluck` répond son texte stocké.

### Dates-heures et `db normalize`

Une datetime est stockée comme Rails la stocke dans SQLite,
`2026-10-05 09:00:00.000000` (UTC, une espace, six chiffres de fraction), et
se lit avec un `T` ou une espace, n’importe quelle fraction, et `Z` ou un
décalage. Le JSON (`as_json`, `to_json`) écrit la forme d’affichage de Rails,
`2026-10-05T09:00:00.000Z`. En SQL écrit à la main,
`Cybertrain::Cast.sql_datetime(time)` donne le texte stocké et
`Cast.iso8601(time)` le texte d’affichage.

CyberTrain 0.4 stockait `2026-10-05T09:00:00Z`, qui se trie après toute
valeur au format Rails, quelle que soit la date. Une fois après la mise à
jour, réécrivez les anciennes cellules&nbsp;:

```console
$ cybertrain db normalize
normalized articles.created_at: 12 rows (0 unreadable left alone)
normalized articles.updated_at: 12 rows (0 unreadable left alone)
done
```

La commande réécrit chaque cellule de chaque colonne `DATETIME`
(`datetime(6)` compris) qui n’est pas déjà au format stocké, ligne par ligne
dans une seule transaction, et peut être lancée deux fois sans risque. Une
cellule qu’elle ne peut pas lire comme une heure (un texte en trop comme
` UTC`) est laissée telle quelle et comptée. Une table `WITHOUT ROWID`, ou
une table avec une colonne nommée `_rowid_`, est sautée&nbsp;; si elle
contient encore d’anciennes cellules, la commande affiche `skipped t.c:
without rowid (N rows still need normalization)` (ou `declares _rowid_`) et
sort avec 1&nbsp;: mettez ces lignes à jour à la main et relancez-la. Elle
demande SQLite 3.37.0 ou plus récent&nbsp;: CyberTrain lie la libsqlite3 du
système (`sqlite3 --version` l’affiche), et avec une version plus ancienne la
commande s’arrête sur `db normalize failed: ...` avant de lire quoi que ce
soit. En
production, lancez `./<app> db normalize` entre `migrate` et le démarrage des
nouveaux binaires ([déployer la mise à jour](../deploy.en.md#upgrading-the-framework)).

### Dates

Une colonne `date` est une `Date` (`Date.new(2026, 10, 5)`), stockée sous la
forme `2026-10-05`&nbsp;; `where(day: date)` la lie sous ce texte. Le texte
affecté doit être `YYYY-MM-DD`&nbsp;: tout le reste (ou un blanc) se relit
comme nil. Une colonne date NOT NULL reçoit une validation de présence
générée, si bien que `save` renvoie false avec «&nbsp;can't be blank&nbsp;»
au lieu que la base refuse la ligne&nbsp;; une colonne avec une valeur par
défaut commence avec celle-ci. `Cybertrain::Cast.date_or_nil(params[:from])`
lit un paramètre date de la même façon.

### Analyser des heures

`Time.iso8601(text)`, `Time.rfc2822(text)` et `Time.strptime(text, format)`
existent sous leurs noms Ruby, et chacun lève `ArgumentError` sur un texte
qu’il ne sait pas lire. `strptime` accepte `%Y %m %d %H %M %S %L %z %Z %b %B
%a %A %j %s %%` (`%Z` seulement `UTC`, `GMT` ou `Z`). `Time.at(ms / 1000.0)`
transforme une époque en millisecondes en Time.

## Conditions et recherches

Les méthodes de requête de la relation générée sont aussi des méthodes de
classe (toutes sauf `or`, `not`, `page` et `to_sql`, et les méthodes à la
manière d’un Array `to_a`, `each`, `size`, `empty?`), si bien que l’écriture
Rails fonctionne telle quelle&nbsp;: `Article.where.not(body: nil)`,
`Article.find_each { }`, `Article.pluck(:id, :title)`,
`Article.pluck_int(:id)`.

| Rails | CyberTrain |
| --- | --- |
| `where(views: 1..10)`, `where(views: 10..)` | La même chose, avec des bornes Integer seulement |
| `where(created_at: from..to)` | `where_between(:created_at, from, to)` (`exclude_end: true` pour `...`&nbsp;; nil pour une borne ouverte) |
| `where("views > ?", 10)` | La même chose |
| `where.not(state: "draft")`, `a.or(b)` | La même chose |
| `order(created_at: :desc)` | La même chose |
| `distinct`, `none`, `ids` | La même chose |
| `find_by!`, `find_or_create_by`, `find_or_initialize_by` | La même chose |
| `update_all`, `destroy_all`, `find_each(batch_size: 500)` | `update_all`, `destroy_all`, `find_each(batch: 500)` |
| `create!`, `record.update_columns(views: 0)` | La même chose |

- Une Range dans un Hash de `where` prend des bornes Integer&nbsp;: sous
  Spinel, une Range de Time ou de Date ne peut pas être construite, et une
  Range de Float ou de String n’est pas reconnue comme telle&nbsp;; ces bornes
  passent donc par `where_between`, dont les bornes Time et Date sont
  comparées comme le texte stocké (qui se trie comme l’instant).
- Une condition String est mise entre parenthèses, si bien qu’un `OR` qu’elle
  contient reste à l’intérieur. Ses binds sont des scalaires&nbsp;:
  `where("id IN (?)", ids)` lève une erreur&nbsp;; écrivez `where(id: ids)`.
- `a.or(b)` donne `((a) OR (b))`&nbsp;; les deux doivent avoir le même
  ordre, la même limite, le même offset et le même `distinct`.
- `where` sur une colonne json ou chiffrée lève `ArgumentError`.
- `distinct` fait renvoyer chaque valeur une seule fois aux lecteurs de
  colonnes et fait lire des entrées distinctes aux agrégats
  (`SUM(DISTINCT x)`)&nbsp;; `count` et `to_a` ne changent pas, puisque chaque
  ligne a son propre id.
- `update_all(hash)` convertit et arrondit comme `save` stocke, laisse
  `updated_at` tranquille et n’exécute aucun callback&nbsp;; `destroy_all`
  détruit chaque enregistrement, callbacks et `dependent:` compris.
- `find_each` parcourt par id en lots et ignore l’ordre, la limite et
  l’offset de la relation, comme Rails.
- `find_or_create_by` sur une relation restreinte crée l’enregistrement à
  partir du seul Hash qu’on lui donne&nbsp;; Rails prend aussi les conditions
  d’égalité de la relation. Passez chaque attribut dont le nouvel
  enregistrement a besoin.
- `update_columns` affecte les valeurs, puis exécute un seul UPDATE de ces
  colonnes&nbsp;: aucune validation, aucun callback, `updated_at` intact.

## Scopes

```ruby
# app/models/article.rb
class Article
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where("created_at > ?", time) }
end

Article.recent.since(Time.now - 86_400).limit(5).to_a
```

Le générateur lit chaque ligne `scope` comme du texte et recopie les
paramètres et le corps de la lambda dans une méthode de la relation du modèle
(`def since(time) = (where("created_at > ?", time))`) et dans une méthode de
classe qui lui délègue, si bien que les scopes s’enchaînent comme n’importe
quelle requête. Rien n’est évalué à la génération&nbsp;: un corps qui nomme
quelque chose que la relation n’a pas échoue quand Spinel compile
`gen/models`, à la ligne générée.

Un scope tient sur une ligne au niveau de la classe&nbsp;: une lambda `->`
avec des paramètres positionnels simples ou avec valeur par défaut, rien
après son `}` fermant (pas même un commentaire), et ni parenthèses ni
virgules dans une valeur par défaut. Un scope nommé comme une colonne, un
autre scope, une méthode de requête (`where`, `count`, `first`) ou une
méthode d’`Object` (`hash`, `then`, `raise`) arrête le générateur avec le
fichier, la ligne et la raison.

## Requêtes au-delà de `where`

Au-delà des conditions ci-dessus, les compteurs, les statistiques et les
champs de recherche dont la plupart des applications ont besoin sont des
méthodes typées (`docs/design.md` D22, D44, D45) plutôt qu’un constructeur de
requêtes&nbsp;; chacune prend des noms de colonnes SQL, vérifiés et mis entre
guillemets (tout le reste est une `ArgumentError`), et lie chaque valeur&nbsp;:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ... ; renvoie le nombre de lignes écrites
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1 (by: n for another step)
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
  et ne remplissent aucun horodatage&nbsp;; `upsert` convertit chaque valeur
  comme `save` la stocke.
- Les clés de `count_by` sont des String (via `Cast.str`), en ordre
  croissant&nbsp;; NULL et `""` partagent la clé `""`. Avec un `limit` /
  `offset`, `count_by`, `sum_*` et `increment` travaillent sur cette fenêtre,
  comme le font `count` et `delete_all` (par une sous-requête).
- `where_like` échappe `\`, `%` et `_` dans le texte pour vous, et recherche
  une sous-chaîne (sans tenir compte de la casse pour l’ASCII, comme le LIKE de
  SQLite). Une recherche par préfixe écrit son propre motif&nbsp;:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- Pour du SQL écrit à la main, `Cybertrain::Cast.binds(a, b, c)` construit
  l’Array de binds que prend `execute` (un Time au format datetime stocké, une
  Date en `YYYY-MM-DD`, les booléens en 1/0)&nbsp;:
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` restreignent une valeur JSON
  analysée à un Hash / un Array, ou à un nouveau conteneur vide quand elle n’en
  est pas un (un Time est vérifié d’abord, spikes/NOTES.md règle 8). Elles
  renvoient une copie superficielle typée, pas `v` lui-même&nbsp;;
  `Cast.empty_hash` / `Cast.empty_array` sont les conteneurs vides
  pré-typés.

### Plusieurs colonnes&nbsp;: `pluck` et `pick`

```ruby
Reading.order(:id).pluck(:observed_at, :value)   # => [[2026-10-01 09:00:00 UTC, 1.0], ...]
Reading.order(:id).pick(:id, :value)             # => [1, 1.0], or nil
```

`pluck` prend deux colonnes ou plus et répond un Array par ligne, chaque
cellule convertie selon le type de sa colonne&nbsp;: un Integer, un Float
(float et decimal), `true` / `false`, un Time UTC, une Date, une String (les
colonnes string, text, json et binary répondent le texte ou les octets
stockés&nbsp;; une colonne chiffrée sa charge chiffrée), ou nil. Une seule
colonne lève `ArgumentError` en renvoyant vers `pluck_str` / `pluck_int` /
`pluck_float` / `ids`&nbsp;: Rails répond un Array plat pour une colonne et
des Arrays imbriqués pour plusieurs, et une méthode ne peut pas renvoyer les
deux. `pick` est la première ligne (`LIMIT 1`) ou nil. Seuls des noms de
colonnes sont acceptés&nbsp;; une expression passe par `DB.with`.

### Agrégats

| Rails | CyberTrain |
| --- | --- |
| `minimum(:views)`, `maximum(:views)` | `minimum_int`, `maximum_int` (`Integer` ou nil) |
| `maximum(:price)` sur un float ou un decimal | `minimum_float`, `maximum_float` |
| `maximum(:created_at)` | `minimum_time`, `maximum_time` (un Time UTC ou nil) |
| `average(:value)` | `average(:value)` (un Float ou nil) |
| `group(:kind).sum(:value)` | `sum_float_by(:kind, :value)` (aussi `sum_int_by`) |
| `group(:kind).maximum(:created_at)` | `maximum_time_by(:kind, :created_at)`, et `_by` pour chaque lecteur ci-dessus |
| `sum("price * quantity")` | `sum_float_sql("price * quantity")`, aussi `minimum_float_sql`, `maximum_float_sql`, `average_sql` |
| `group(:kind).having("SUM(value) > ?", 2)` | `having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value)` |

- Les noms portent le type pour la même raison que `pluck_int`&nbsp;: le
  `maximum` de Rails répond un Integer pour une colonne et un Time pour une
  autre.
- Les lecteurs `_by` répondent un `Hash{String => T}` dont la clé est la
  valeur de la colonne de groupe en texte, en ordre croissant, comme
  `count_by`&nbsp;; NULL et `""` partagent la clé `""`.
- `having_sql` s’applique aux lecteurs groupés&nbsp;; tout autre lecteur
  d’une relation qui en a un lève une erreur, tout comme un lecteur groupé
  avec une limite ou un offset.
- Les expressions `_sql` et `having_sql` sont du SQL de confiance, comme
  `order_sql`.
- Sous `distinct`, les agrégats lisent des entrées distinctes
  (`AVG(DISTINCT x)`)&nbsp;; avec en plus une limite, la fenêtre est formée
  des n premières valeurs distinctes.
- Un agrégat sur une expression *et* un groupe, ou sur deux tables, s’écrit
  avec `DB.with`.

## Écritures en masse

```ruby
Article.insert_all([{ title: "One", body: "..." }, { title: "Two", body: "..." }]).size  # => 2
Article.insert_all!(rows)                                 # a duplicate raises
Article.upsert_all([{ id: 1, title: "Renamed" }])         # body keeps its value
Article.upsert_all(rows, unique_by: [:slug], update_only: [:title], returning: [:id, :title])
```

`insert_all` écrit de nombreuses lignes en instructions `INSERT` multi-lignes
avec `ON CONFLICT DO NOTHING`, en sautant une ligne qui entre en collision
avec une ligne existante&nbsp;; `insert_all!` lève une erreur à la
place&nbsp;; `upsert_all` met à jour la ligne en collision avec
`ON CONFLICT (unique_by) DO UPDATE`. Le résultat est l’ensemble des lignes de
`RETURNING` (par défaut `[{"id" => 3}, ...]`), converties selon leur type, si
bien que `.size` est le nombre de lignes écrites.

- Chaque ligne a les mêmes clés, sinon `ArgumentError` avant toute
  écriture&nbsp;; une colonne inconnue, ou des lignes sans clé (`[{}]`),
  lèvent de la même façon. Les colonnes
  qu’aucune ligne ne nomme prennent le DEFAULT de la table.
- Les valeurs reçoivent les conversions que leur donne `save` (un Time au
  format stocké, un Hash en JSON, un decimal arrondi à son échelle, une Date
  en texte).
- `upsert_all` met à jour les colonnes que fournissent les lignes, sauf `id`,
  les colonnes de `unique_by` et `created_at`&nbsp;; `update_only:` restreint
  cette liste, et un nom qu’elle contient mais que les lignes ne fournissent
  pas est ignoré.
- `returning:`, `unique_by:` et `update_only:` acceptent un Array ou un seul
  nom (`returning: :id`)&nbsp;; `false` n’en désigne aucun&nbsp;; toute autre
  valeur lève `ArgumentError`.
- `created_at` / `updated_at` reçoivent un seul `now` pour tout l’appel quand
  la table les a et que les lignes ne les donnent pas, sauf avec
  `record_timestamps: false`.
- Les instructions sont découpées selon la limite de binds de SQLite et
  s’exécutent dans une seule transaction (qui rejoint une transaction déjà
  ouverte), si bien qu’un échec ne laisse rien de l’appel&nbsp;; dans une
  transaction que vous avez ouverte, c’est votre rollback qui décide.
- Aucune validation, aucun callback ni chiffrement ne s’exécute&nbsp;: une
  colonne chiffrée dans une ligne lève `ArgumentError`. Comme dans Rails, un
  doublon sauté consomme quand même un id.
- `RETURNING` demande SQLite 3.35.0 ou plus récent (la bibliothèque du
  système que lie CyberTrain)&nbsp;; une version plus ancienne refuse
  l’instruction avec sa propre erreur de syntaxe (`Cybertrain::DB::Error`).

## Associations

Une clé étrangère donne une association aux deux côtés sans une ligne de code
(`t.references :article` donne `Comment#article` et `Article#comments`). Le
fichier du modèle peut aussi les déclarer, pour en renommer une ou ajouter
des options&nbsp;:

```ruby
# app/models/article.rb
class Article
  has_many :comments, dependent: :destroy
  has_one :cover, class_name: "Image", foreign_key: :article_id
end

# app/models/comment.rb
class Comment
  belongs_to :article
  belongs_to :author, class_name: "User", optional: true, counter_cache: true
end
```

- `has_many` renvoie la relation des enfants, qui s’enchaîne donc&nbsp;:
  `@article.comments.where(approved: true).count`,
  `@article.comments.find(params[:id])`. Ajoutez `.to_a` pour un Array&nbsp;;
  les templates l’itèrent comme tel.
- `has_one` lit un enfant (le premier par id quand il y en a plusieurs), nil
  quand il n’y en a pas&nbsp;; il remplace le `has_many` que donnerait la clé
  étrangère.
- `belongs_to` lit le parent et le garde jusqu’à ce que la clé étrangère
  change ou jusqu’à `reload`.
- Un `belongs_to` déclaré sans `optional: true` rend l’enregistrement
  invalide tant que sa clé est nil, vide ou 0 («&nbsp;can't be blank&nbsp;»
  sur `article_id`, le `validates_foreign_key :article_id` généré), si bien
  que `save` renvoie false avant que la base refuse la ligne. Les
  associations issues d’une clé étrangère seule n’ajoutent aucune validation.
- Les options sont des littéraux&nbsp;: `class_name:` (une String ou un
  Symbol), `foreign_key:`, `dependent:` (`has_many` et `has_one`),
  `optional:` et `counter_cache:` (`belongs_to`). Chaque macro est seule sur
  sa ligne, au niveau de la classe, sans commentaire à la fin&nbsp;; un
  modèle, une colonne ou une option qui n’existe pas arrête le générateur
  avec le fichier et la ligne.
- Non disponibles&nbsp;: `has_many :through`, les associations
  polymorphes, une lambda de scope sur `has_many` (enchaînez sur la relation
  qu’il renvoie), `inverse_of`, `dependent: :restrict_with_error`.

### `dependent:` ou `on_delete:`

`dependent:` s’exécute dans `destroy`, avant le DELETE du parent et dans la
même transaction&nbsp;: `:destroy` charge chaque enfant et le détruit (ses
callbacks et son propre `dependent:` s’exécutent), `:delete_all` exécute un
seul DELETE, `:nullify` un seul UPDATE qui met la clé à NULL. `on_delete:`
sur la clé étrangère ([Index et clés étrangères](#indexes-and-foreign-keys))
laisse SQLite le faire, quel que soit celui qui supprime la ligne. Utilisez
`dependent: :destroy` quand les enfants ont des callbacks, des compteurs ou
leurs propres enfants&nbsp;; utilisez `on_delete: :cascade` pour la vitesse,
et quand d’autres programmes écrivent dans la base. Sans l’un ni l’autre, la
clé étrangère refuse de supprimer un parent qui a encore des enfants.

### Compteurs en cache

`belongs_to :post, counter_cache: true` tient `posts.comments_count` (ou
`<nom du has_many>_count`) à jour&nbsp;: +1 après la création d’un enfant,
-1 après sa destruction, et les deux côtés quand un enfant passe à un autre
parent, chaque changement dans la transaction propre de l’enfant. La colonne
doit exister (un entier avec `default: "0"`). Le propre `save` du parent la
laisse hors de son UPDATE, puisque sa copie peut être périmée. Un parent
détruit avec `dependent: :destroy` se décrémente une fois par enfant avant de
disparaître, ce qui est sans conséquence.

### Précharger avec `includes`

```ruby
@articles = Article.recent.includes(:comments).to_a   # two queries
```

```erb
<% @articles.each do |article| %>
  <%= article.title %> (<%= article.comments.size %>)
<% end %>
```

`includes(*names)` (et `preload`, identique) exécute une requête de plus par
association au chargement des enregistrements
(`Comment.where(article_id: ids)` pour un `has_many` ou un `has_one`, les
parents par id pour un `belongs_to`), si bien qu’une boucle sur
`article.comments` ou `comment.article` n’exécute aucune requête à elle. Un
enregistrement sans enfant reçoit une liste vide et un parent manquant vaut
nil, sans autre requête. Sur un `has_many` préchargé, `to_a`, `each`,
`first`, `last`, `size` et `empty?` répondent depuis la mémoire (les enfants
dans l’ordre des id)&nbsp;; `count` et `exists?` interrogent toujours la
base, et une méthode de chaînage (`where`, `order`, ...) abandonne le
préchargement et interroge comme d’habitude. Un seul niveau
(`includes(comments: :author)` n’existe pas), et un enfant préchargé n’a pas
son parent renseigné (`comment.article` le lit). `eager_load` et `joins` ne
sont pas disponibles.

## Validations

```ruby
class Article
  validates :title, presence: true, length: { minimum: 3, maximum: 120 }, uniqueness: true
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create
  validates :summary, presence: true, if: :published?

  def published? = state == "published"
end
```

Les messages sont ceux de Rails en anglais&nbsp;: «&nbsp;can't be
blank&nbsp;», «&nbsp;is too short (minimum is 3 characters)&nbsp;», «&nbsp;is
the wrong length (should be 5 characters)&nbsp;», «&nbsp;is not included in
the list&nbsp;», «&nbsp;is reserved&nbsp;», «&nbsp;is invalid&nbsp;»,
«&nbsp;is not a number&nbsp;», «&nbsp;must be an integer&nbsp;», «&nbsp;must
be greater than or equal to 0&nbsp;», «&nbsp;has already been
taken&nbsp;». `message:` en remplace un, sur la ligne ou dans le Hash d’une
règle. La forme au singulier de Rails («&nbsp;1 character&nbsp;») n’existe
pas&nbsp;: une limite de 1 donne «&nbsp;1 characters&nbsp;».

- `length` accepte `minimum`, `maximum`, `is` et `in` (une Range d’Integer).
- `inclusion` et `exclusion` acceptent un Array, ou une Range d’Integer
  (Spinel ne construit pas d’autre Range)&nbsp;; `1...5` accepte 4.5 sur une
  colonne float, comme dans Rails.
- `numericality` analyse d’abord une String (`"12"` passe)&nbsp;; un Float
  échoue à `only_integer`, comme dans Rails.
- `uniqueness` demande à la base s’il existe une autre ligne avec la valeur
  (`LOWER(col) = LOWER(?)` avec `case_sensitive: false`, `IS NULL` pour
  nil), restreinte par `scope:`. Elle ne peut pas s’utiliser sur une colonne
  chiffrée.
- `allow_nil:` et `allow_blank:` sautent une valeur nil ou vide pour chaque
  règle de leur ligne, `presence` comprise&nbsp;; `on: :create` ou
  `on: :update` (un seul Symbol) n’exécute la ligne que pour un
  enregistrement nouveau ou déjà enregistré.
- Une option inconnue ou une valeur du mauvais type lève `ArgumentError` au
  chargement du modèle.

### Validations personnalisées et conditions

```ruby
class Booking
  validate :ends_after_start, on: :update, unless: :imported?

  def ends_after_start
    errors.add(:ends_on, "must be after the start") if ends_on < starts_on
  end

  def imported? = source == "import"
end
```

Les lignes `validate :method` s’exécutent après les règles `validates`, dans
l’ordre. `if:` et `unless:` (sur les deux) prennent un Symbol qui nomme une
méthode du modèle, une colonne ou une association&nbsp;; le générateur écrit
la table qui l’appelle, puisque Spinel n’a pas de `send`. Une lambda,
`:if => :x` et `"if": :x` arrêtent le générateur avec un message qui demande
de nommer une méthode, tout comme un nom de `validate` que le fichier du
modèle ne définit pas. `validates_with`, `validates_each`, `confirmation`,
`acceptance` et `valid?(context)` ne sont pas disponibles.

## Colonnes chiffrées

```ruby
# app/models/account.rb
class Account
  encrypts :api_key
end
```

`encrypts` nomme des colonnes string ou text (text est le meilleur choix&nbsp;:
la charge stockée est plus longue que le texte). Le modèle généré chiffre la
valeur quand il écrit la ligne et la déchiffre quand il en lit une, si bien
que `account.api_key` est le texte et que la table contient `1:` suivi du
Base64 d’un nonce aléatoire, du chiffré AES-256-GCM et de son tag. Deux
enregistrements d’une même valeur stockent des charges différentes, donc la
colonne ne peut pas être cherchée&nbsp;:

- `where`, `where_like`, `where_between`, `update_all`, `increment`,
  `upsert`, `uniqueness` et les écritures en masse la refusent (`ArgumentError`)&nbsp;; `pluck` répond la
  charge chiffrée.
- `to_json` et `as_json` incluent le texte déchiffré, comme dans
  Rails&nbsp;; laissez la colonne hors de ce qu’affiche une page.
- Une valeur stockée vide se lit `""`, si bien qu’une colonne NOT NULL
  ajoutée avec `default: "''"` reste lisible avant que ses lignes soient
  enregistrées à nouveau.
- Non disponibles&nbsp;: `deterministic: true`, et la lecture des charges de
  l’`ActiveRecord::Encryption` de Rails (sa dérivation de clé et son format
  diffèrent).

### Clés et rotation

Un modèle avec `encrypts` fait exiger openssl à l’application et fait échouer
le démarrage si `CYBERTRAIN_ENCRYPTION_KEY` ne contient pas 64 caractères
hexadécimaux (créez-en une avec `cybertrain secret --hex`&nbsp;; [les
variables](configuration.md#configuration-and-environment-variables)). La
clé n’est pas dérivée de `CYBERTRAIN_SECRET_KEY_BASE`, donc changer le secret
de session laisse les données lisibles&nbsp;; perdez la clé de chiffrement et
les données sont perdues. Pour la changer, mettez la nouvelle clé dans
`CYBERTRAIN_ENCRYPTION_KEY` et l’ancienne dans
`CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` (séparées par des virgules&nbsp;;
essayées pour la lecture seulement), puis réécrivez chaque
enregistrement&nbsp;:

```ruby
Account.find_each { |account| account.update_columns(api_key: account.api_key) }
```

Le code qui appelle lui-même `Cybertrain::Crypto.encrypt(text)` /
`Crypto.decrypt(payload)`, dans une application sans `encrypts`, ajoute
`require "cybertrain/encryptor"` à `bin/<app>.rb` et définit la clé.

### Chiffrer une colonne qui contient déjà du texte

Les lignes écrites avant l’ajout d’`encrypts` contiennent du texte en clair,
et en lire une lève `Cybertrain::Encryptor::Error`. Chiffrez-les une fois en
SQL, depuis une commande de l’application (`./<app> encrypt_api_keys`)&nbsp;:

```ruby
# bin/<app>.rb
Cybertrain::Main.command("encrypt_api_keys", "encrypt accounts.api_key written before encrypts") do |_argv|
  Cybertrain::DB.transaction do |c|
    c.execute("SELECT id, api_key FROM accounts WHERE api_key IS NOT NULL AND api_key NOT LIKE '1:%'").each do |row|
      payload = Cybertrain::Crypto.encrypt(Cybertrain::Cast.str(row["api_key"]))
      c.execute("UPDATE accounts SET api_key = ? WHERE id = ?", [payload, Cybertrain::Cast.int(row["id"])])
    end
  end
  0
end
```

Le `NOT LIKE '1:%'` empêche un second passage de chiffrer à nouveau une
charge&nbsp;; retirez-le si des valeurs en clair peuvent commencer par `1:`.
Les valeurs que Rails a chiffrées sont d’abord déchiffrées dans
l’application Rails, puis chiffrées ici de la même façon.

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
- Ne rattrapez pas une erreur de base de données dans le bloc pour continuer. Après «&nbsp;database or disk is full&nbsp;», une erreur d’E/S ou un délai d’attente de verrou dépassé, SQLite peut annuler toute la transaction de lui-même. Chaque instruction suivante du bloc lève alors `Cybertrain::DB::Error` («&nbsp;the enclosing transaction is no longer open&nbsp;») au lieu d’être validée seule, et la transaction lève une exception à la fin du bloc. Laissez l’erreur sortir du bloc et, si besoin, recommencez toute la transaction. Une transaction ouverte avec `c.exec_script("BEGIN")` est traitée de la même façon jusqu’à ce que `COMMIT`, `END` ou `ROLLBACK` la termine&nbsp;; ce `ROLLBACK` réussit alors sans rien faire, puisque SQLite a déjà annulé la transaction.

Le code qui doit garder son `rescue` dans une méthode simple utilise la forme sans bloc, `c.begin!(immediate: true)` ... `c.commit!`, avec `c.rollback!` dans le rescue.

## Noms de colonnes

Un nom de colonne doit être un identifiant ASCII (`[A-Za-z_][A-Za-z0-9_]*`), là où Rails accepte n’importe lequel. Un schéma avec un nom de colonne non ASCII (`名前`, `prénom`) se générait sous CRuby avant la PR #10, et `spin run gen` le refuse désormais&nbsp;; renommez donc la colonne lors de la mise à niveau (un nom comme `first-name` n’a jamais été un nom de méthode).

Une colonne nommée comme une méthode que la classe générée ou le framework appelle sur un enregistrement (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) ou comme un mot-clé Ruby (`end`, `class`, `begin`) est générée sous `<column>_column` (`hash_column`&nbsp;: lecteur, écrivain et ivar) avec une note dans le fichier généré. Ses deux noms s’utilisent ainsi&nbsp;:

- Son nom SQL continue de fonctionner dans `read_attribute`, les params et `attributes["hash"]`.
- Un template l’atteint sous l’un ou l’autre nom (`post.hash`, `post.hash_column`), sauf `errors` et `to_param`, qu’un template résout comme les méthodes du modèle&nbsp;: utilisez donc `post.errors_column` à cet endroit.
- L’API de requête (`where`, `order`, `find_by`) prend toujours le nom de colonne SQL (`Post.where(hash: 1)`)&nbsp;; le nom Ruby n’est que celui du lecteur/écrivain et du template.

Une colonne nommée comme une autre méthode d’Object (`display`, `tap`, `methods`) est générée sous son propre nom avec une note. `cybertrain generate scaffold` refuse les mots-clés et les noms réservés (il devrait appeler un lecteur renommé) et accepte un nom masquant avec une note, comme le générateur.

Une association dont le nom simple est déjà pris par une colonne, une autre association ou une méthode de `Model` (Rails en laisse une masquer `errors`) est émise sous un nom de repli, avec un commentaire dans le fichier généré&nbsp;: `<table>_as_<column stem>` pour un `has_many` (`comments_as_article`), `<stem>_as_<column>` pour un `belongs_to` (`author_as_author_id`).

## Colonnes binaires

`t.binary` crée une colonne `BLOB`, pour des octets qui ne sont pas du
texte&nbsp;: une vignette, un instantané compressé, une clé. L’attribut est
une String qui contient exactement les octets stockés, octets NUL et octets
au-dessus de 127 compris, ou `nil` pour un `NULL` (la colonne accepte NULL
sauf si elle est déclarée `null: false`&nbsp;: une photo enregistrée avant
l’ajout de la colonne n’a pas de vignette, vérifiez `nil` avant
`bytesize`)&nbsp;:

```ruby
# db/migrate/20261105090000_add_thumbnail_to_photos.rb
class AddThumbnailToPhotos < Cybertrain::Migration::Base
  def change
    add_column "photos", "thumbnail", :binary
  end
end
```

```ruby
photo.thumbnail = File.binread("thumb.webp")
photo.save
Photo.find(photo.id).thumbnail.bytesize   # les mêmes octets en retour
```

- Le modèle généré lie une colonne binaire comme un BLOB à
  l’enregistrement&nbsp;; toute autre String se lie toujours comme TEXT, qui
  s’arrête à un octet NUL. En SQL brut, enveloppez les octets dans
  `Cybertrain::DB::Blob.new(bytes)` pour les lier comme un BLOB
  (`c.execute("INSERT INTO photos (thumbnail) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`).
- Une cellule BLOB lue en SQL brut est une String de ses octets&nbsp;;
  `Cybertrain::Cast.binary(value)` la restreint (`""` pour `NULL`).
- `Photo.where(thumbnail: bytes)` lie aussi les octets comme un BLOB (un
  TEXT lié n’est jamais égal à un BLOB stocké).
- `db/schema.rb` réécrit la colonne sous la forme `t.binary`, et la console
  affiche une valeur binaire comme `<N bytes>`.
- Gardez les gros fichiers hors de la base&nbsp;: un envoi de fichier
  ([Ajouter un envoi de fichier](tutorial.md#attachments)) est un fichier
  sous `storage/uploads/`, alors qu’un BLOB est lu entièrement en mémoire
  avec sa ligne et grossit chaque sauvegarde et le WAL.

## Tri

Là où le `order` de Rails accepte n’importe quel SQL (`order("lower(title)")`, `order("posts.title")`, `order(params[:sort])`), `order` n’accepte ici que des listes `column [ASC|DESC]` (chaque colonne entre guillemets) et lève `ArgumentError` pour tout le reste&nbsp;: une 500, puisque la chaîne vient du développeur.

Les données de la requête doivent d’abord passer par une liste blanche, car un terme bien formé peut quand même nommer une colonne absente (une 500 venant de SQLite) ou une colonne par laquelle le client ne doit pas trier&nbsp;:

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

Le texte ORDER BY brut passe par `order_sql` (`Post.order_sql("lower(title)")`, aussi sur une relation), qui ne doit jamais voir de données de la requête.

## Reprendre une base de données créée par Rails

Un fichier SQLite créé par une application Rails 8 se lit tel quel&nbsp;:

1. Copiez-le au chemin de la base de l’application,
   `storage/development.sqlite3` par défaut (`storage/<env>.sqlite3`, ou là
   où pointe `CYBERTRAIN_DATABASE`).
2. Lancez `cybertrain db schema` (`./<app> db schema` avec un binaire
   construit). Il écrit `db/schema.rb` à partir de la base, avec le dumper
   qu’utilise `db migrate`, affiche `wrote .../db/schema.rb from <path>`, et
   ne fait rien d’autre. `cybertrain db migrate` ne trouve ensuite rien à
   appliquer et génère les modèles.
3. Ne copiez pas les `db/migrate/*.rb` de Rails&nbsp;: les nouvelles
   migrations partent d’ici. Les versions Rails déjà présentes dans
   `schema_migrations` (la même table des deux côtés) n’ont pas de fichier
   ici, donc le migrateur ne les exécute ni ne les annule, et `db status` les
   liste comme `applied (no file)`.
4. Ce qui ne demande aucune conversion&nbsp;: les dates-heures (le format de
   Rails est celui qui est stocké), les booléens (`1` / `0`, et les anciens
   `t` / `f`), les décimaux (Rails écrit des valeurs REAL&nbsp;; elles se
   lisent comme des Float), le json (TEXT, lu comme un Hash), et les noms de
   types qu’écrit Rails (`datetime(6)`, `decimal(18,8)`, `varchar`,
   `bigint`, `json`). Les index partiels et d’expression et les actions
   `ON DELETE` sont exportés aussi.
5. Limites&nbsp;: une table dont la clé primaire n’est pas une colonne `id`
   (une table de jointure) est exportée en `create_table "articles_tags",
   id: false` et n’a pas de modèle (`spin run gen` affiche `skipped
   articles_tags: no id column`)&nbsp;; atteignez-la avec `DB.with`&nbsp;; une
   clé primaire `id` qui n’est pas un entier (`id: :uuid` ou `id: :string`
   dans Rails) est exportée de la même façon, son `id` gardé comme une
   colonne ordinaire sans PRIMARY KEY&nbsp;;
   `ar_internal_metadata` est laissée telle quelle&nbsp;; une table dont le
   `CREATE TABLE` contient ce que le schéma ne modélise pas ne peut pas être
   modifiée avec les assistants qui reconstruisent ([Modifier une
   table](#changing-a-table))&nbsp;; les colonnes que Rails a chiffrées sont
   chiffrées à nouveau ([Chiffrer une colonne qui contient déjà du
   texte](#encrypting-a-column-that-already-holds-text)).

Écrivez ensuite `app/models/*.rb` avec les validations, les associations et
les scopes qu’avaient les modèles Rails, sous les formes que montre cette
page.

## Mettre à jour depuis 0.4

Chaque changement ci-dessous est une modification à faire en un passage dans
une application écrite pour CyberTrain 0.4&nbsp;:

1. Un lecteur `has_many` renvoie une relation, pas un Array&nbsp;: ajoutez
   `.to_a` avant une méthode propre aux Array (`map`, `select`, `[]`, `+`).
   Les templates ne changent pas.
2. Les dates-heures sont stockées au format de Rails&nbsp;: lancez
   `db normalize` une fois après la mise à jour ([Dates-heures et `db
   normalize`](#datetimes-and-db-normalize))&nbsp;; d’ici là, une colonne
   qui mélange les deux formats se trie par format.
3. `as_json` et `to_json` écrivent les heures sous la forme
   `2026-10-05T09:00:00.000Z` (c’était `2026-10-05T09:00:00Z`)&nbsp;: les
   snapshots JSON des tests changent.
4. Un attribut `t.date` est une `Date`, pas une String&nbsp;: `strftime`
   fonctionne toujours, la concaténation demande `to_s`. Une colonne date NOT
   NULL valide maintenant sa présence.
5. Un `belongs_to` déclaré sans `optional: true` valide sa clé
   étrangère&nbsp;; ceux qui ne sont pas déclarés ne changent pas.
6. `where(x: a..b)` avec des bornes Integer est une condition d’intervalle
   (c’était une égalité avec le texte de la Range, qui ne correspondait
   jamais)&nbsp;; les bornes Time et Date utilisent `where_between`.
7. `Cybertrain::Cast.iso8601` est le format d’affichage&nbsp;: le code qui
   s’en servait pour construire du texte SQL passe à `Cast.sql_datetime`, et
   `Cast.binds` lie un Time au format stocké.
8. `allow_blank: true` sur une ligne `validates` laisse aussi `presence` de
   cette ligne accepter une valeur vide, comme dans Rails (il ne s’appliquait
   qu’à `length`).
9. Une colonne nommée comme une méthode qu’a maintenant chaque modèle
   (`update_columns`, `destroy_dependents`, `run_custom_validations`, ...) est
   générée sous `<column>_column` ([Noms de colonnes](#column-names)).
10. Un lecteur `belongs_to` garde le parent qu’il a lu jusqu’à ce que la clé
    étrangère change (il le relisait à chaque appel)&nbsp;: appelez `reload`
    pour voir un changement fait par un autre processus.
