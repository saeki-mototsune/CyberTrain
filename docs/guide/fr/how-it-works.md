---
source_sha256: 0b22d617a8f08f18b32c41e0dfd5bb3613626f655729e681ffcc6f36911c2f3a
---
# Fonctionnement

**Génération de code à la compilation.** `spin run gen` (`bin/gen.rb`) exécute
le DSL `create_table` de `db/schema.rb` et le DSL `Routes.draw` de
`config/routes.rb` pour obtenir les *données* des tables et des routes, et fait
séparément un **balayage lexical** (des regex, pas un parseur — Spinel n’en
expose aucun à l’exécution) de `app/controllers/**/*.rb` et
`app/models/**/*.rb` à la recherche des affectations `@ivar =`, des noms
`before_action`/`after_action`/`rescue_from ... with:` et des `def` sans
argument. À partir de cela, il écrit du Ruby simple et lisible sous `gen/`&nbsp;:
`gen/models/<name>.rb` (accesseurs, conversions, finders, associations déduites
des clés étrangères), `gen/routes.rb` (table des routes, dispatcher, helpers
`*_path`/`*_url`), `gen/controllers.rb` (`view_assigns` et `run_callback` par
contrôleur), `gen/migrations.rb`, `gen/views.rb` (la table des vues intégrées,
vide sauf lors d’une compilation pour le déploiement) et `gen/app.rb` (le
manifeste des `require_relative`). `gen/` est versionné, pas ignoré par git —
`spin build`/`spin test` n’ont pas de hook pour générer d’abord, donc la sortie
versionnée doit déjà être ce qui compile. La CI relance `spin run gen` et
échoue s’il y a un diff&nbsp;: du code généré périmé ne peut donc pas être
fusionné.

**Les vues sont interprétées, pas compilées.** Les fichiers
`app/views/**/*.html.erb` ressemblent à de l’ERB de Rails, mais sont analysés en
un AST au moment de la requête, puis parcourus par un interpréteur qui parcourt
l’arbre. L’origine du source dépend du mode&nbsp;: en développement (et en
test), le moteur lit `app/views/` depuis le disque, et en développement il
réanalyse un template quand celui-ci change, donc modifier une vue ne demande
pas de recompilation. `cybertrain build` lance `spin run gen -- --embed-views`,
qui écrit le source de chaque template dans `gen/views.rb` sous forme de table
de chaînes pour ce seul `spin
build`, puis relance `spin run gen` pour remettre la table vide versionnée&nbsp;;
le binaire de production ne rend que cette table (en analysant chaque template
une seule fois) et refuse de démarrer quand elle est vide (`error: views are not
embedded in this binary`). Spinel n’a pas d’`eval`, il s’agit donc d’une
grammaire fermée (littéraux, lectures de `@ivar`/variables locales, appels via
des tables de dispatch fixes par type, `if`/`unless`,
`each`/`each_with_index`/un bloc de helper), pas de vrai Ruby. Grammaire
complète, helpers et lacunes&nbsp;: [docs/guide/template-language.md](template-language.md).

**Le serveur HTTP.** `Cybertrain::Server` est un serveur HTTP/1.1 en Ruby
pur&nbsp;: `TCPServer#accept` plus un green thread Spinel par connexion
(ordonnancement M:N, pas de GVL), `Request`/`Response` typés, pas de couche
Rack. Il appelle un `HttpHandler` (`call(request) -> Response`)&nbsp;;
`ContextHandler` le relie à la pile de middlewares, de sorte que la couche HTTP
(`cybertrain/http/`, plus `Params` et `Logger`) ne dépend pas du reste du
framework&nbsp;; `script/check-http-layer` l’impose dans la CI. TLS/HTTP/2 sont
laissés à un reverse proxy. `SPINEL_WORKERS` vaut `1` par défaut — les spikes
ont montré que c’est plus rapide et sans blocage pour cette charge limitée par
les E/S à 100 connexions simultanées.

**SQLite via FFI.** Les modèles parlent à SQLite directement via
`ffi_func`/`ffi_lib` de Spinel — pas d’extension C, pas de gem. Un pool
(`SizedQueue`, 4 connexions par défaut) distribue des connexions avec WAL, un
délai d’attente sur verrou d’environ cinq secondes (un busy handler qui réessaie
toutes les 100&nbsp;µs, là où le `busy_timeout` de SQLite dort une milliseconde
ou plus), jusqu’à 64 requêtes préparées en cache et les clés étrangères
activées&nbsp;; chaque requête est paramétrée, jamais interpolée. C’est le seul
adaptateur aujourd’hui (PostgreSQL via la FFI de `libpq` est noté comme travail
futur possible).

**Transactions.** `Cybertrain::DB.transaction { |c| ... }` (ou
`Article.transaction`, la même chose sous le nom de Rails) emprunte une
connexion, lance `BEGIN`, passe la connexion au bloc, fait `COMMIT` quand le
bloc se termine, et annule puis relève l’exception quand il en lève une.
`immediate: true` lance `BEGIN IMMEDIATE`, qui prend le verrou d’écriture de
SQLite dès le début&nbsp;: utilisez-le pour une transaction qui lit puis écrit,
pour qu’un écrivain concurrent la fasse attendre à `BEGIN` plutôt qu’échouer
avec «&nbsp;database is locked&nbsp;» à sa première écriture. Pendant
l’exécution du bloc, tout ce qui, sur ce thread, passe par le pool (`save`,
`update`, `destroy`, les requêtes Relation, `DB.with`) utilise la connexion de
la transaction, et fait donc partie de la transaction&nbsp;:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

Un `DB.transaction` imbriqué dans le bloc rejoint la transaction externe (seule
la plus externe fait le commit&nbsp;; une exception n’importe où annule
tout&nbsp;; pas de savepoints). Le code qui doit garder son `rescue` dans une
méthode simple utilise la forme sans bloc, `c.begin!(immediate: true)` ...
`c.commit!`, avec `c.rollback!` dans le rescue. Elle renvoie nil plutôt que la
valeur du bloc, et un `DB.transaction` appelé dans un bloc `DB.with` (qui n’est
pas une transaction) emprunte une seconde connexion&nbsp;: avec un pool d’une
seule connexion (`:memory:` compris), il attend alors indéfiniment. Ouvrez
d’abord la transaction et faites le travail à l’intérieur.

**La boucle de développement.** `cybertrain server` (`spin run gen`, puis
`spin run NAME`) en `development` (le `CYBERTRAIN_ENV` par défaut, sauf dans un
binaire issu de `cybertrain build`) surveille aussi `app/**/*.rb`,
`config/**/*.rb`, `db/schema.rb` et `gen/**/*.rb` toutes les demi-secondes (les
vues sont exclues — le moteur les recharge lui-même —, tout comme
`gen/views.rb`, vide en développement). Un changement lance
`spin run gen && spin build NAME -- --incremental` en arrière-plan (la
compilation incrémentale de Spinel, qui ne recompile que les unités C touchées
par la modification&nbsp;; une version de Spinel sans `--incremental` rejette
l’option, et la boucle compile alors sans elle)&nbsp;; un succès demande un
redémarrage (le même indicateur qu’un `kill -HUP` externe)&nbsp;: un thread de
surveillance arrête l’écoute et laisse se terminer les requêtes ouvertes, puis
le thread principal fait `execv` du nouveau binaire sur le même port et le même
PID, de façon invisible pour un client en pleine session. Une compilation
échouée continue de servir l’ancien binaire et affiche la sortie du compilateur
en bannière sur chaque réponse HTML. Rien de tout cela n’est chargé en
production.


## Différences avec Rails

| Rails | cybertrain |
| --- | --- |
| `rails console` | Pas de console — Spinel n’a pas d’`eval` |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` dans `bin/<app>.rb`&nbsp;: `./<app> name ARGS` la lance avec la base de données connectée |
| Modifiez le code, l’application en cours d’exécution le prend en compte | Le Ruby demande une recompilation&nbsp;; en développement, `cybertrain server` s’en charge pour vous (recompilation, arrêt, `execv`) |
| Modifiez une vue, aucun rechargement nécessaire | Pareil — en développement, les vues sont analysées depuis le disque à chaque requête |
| `def new` | `def new_action` (`new` masquerait `Klass.new(ctx)`) |
| `before_action { do_thing }` (`self` implicite) | `before_action { \|c\| c.do_thing }` — pas d’`instance_exec` sur un bloc stocké, donc les callbacks reçoivent explicitement le contrôleur/l’enregistrement |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — les blocs imbriqués reçoivent le mapper explicitement |
| ERB est compilé en méthode&nbsp;; n’importe quel objet, n’importe quelle méthode | Interprété selon une grammaire/table de dispatch fixe — [docs/guide/template-language.md](template-language.md) |
| La session contient n’importe quel objet sérialisé (marshal) | Valeurs de session de type String uniquement, cookie signé HMAC |
| De nombreux adaptateurs de base de données | SQLite uniquement, via FFI |
| `Article.transaction { ... }` renvoie la valeur du bloc&nbsp;; `raise ActiveRecord::Rollback`&nbsp;; savepoints avec `requires_new: true` | `Article.transaction { \|c\| ... }` (= `Cybertrain::DB.transaction`) passe la connexion au bloc et renvoie nil&nbsp;; on en sort en levant une exception (elle est relevée après l’annulation)&nbsp;; les appels imbriqués rejoignent la transaction externe, pas de savepoints. `immediate: true` pour le `BEGIN IMMEDIATE` de SQLite. `c.transaction { }` ne peut pas être appelé sur le `c` passé au bloc sous Spinel&nbsp;: imbriquez `DB.transaction`, ou utilisez `c.begin!` / `c.commit!` / `c.rollback!` |
| `has_many :through`, `includes`, `dependent:`, enums, STI, associations polymorphes | Non implémenté&nbsp;; les associations viennent uniquement des clés étrangères du schéma |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Des variantes typées à une colonne, car une méthode Spinel a un seul type de retour&nbsp;: `pluck_str` / `pluck_int` / `pluck_float` (une seule colonne), `sum_int` / `sum_float`, `count_by(:a)` (un `Hash{String => Integer}`) et `count_by_sql(expr)` pour les expressions&nbsp;; `Model.upsert(attrs, conflict:, update:)` prend les expressions `DO UPDATE SET` sous forme de texte SQL et n’exécute ni validations, ni callbacks, ni horodatages&nbsp;; `relation.increment(:col, by: n)`&nbsp;; `where_like(:col, text)` échappe `\`, `%` et `_` pour vous. Voir [Requêtes au-delà de `where`](models.md#querying-beyond-where) |
| N’importe quel nom de colonne&nbsp;; une association peut masquer `errors` | Un nom de colonne doit être un identifiant ASCII (`[A-Za-z_][A-Za-z0-9_]*`)&nbsp;: un schéma avec un nom de colonne non ASCII (`名前`, `prénom`) se générait sous CRuby avant la PR #10, et `spin run gen` le refuse désormais&nbsp;; renommez donc la colonne lors de la mise à niveau (un nom comme `first-name` n’a jamais été un nom de méthode). Une colonne nommée comme une méthode que la classe générée ou le framework appelle sur un enregistrement (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) ou comme un mot-clé Ruby (`end`, `class`, `begin`) est générée sous `<column>_column` (`hash_column`, lecteur, écrivain et ivar) avec une note dans le fichier généré&nbsp;; son nom SQL continue de fonctionner dans `read_attribute`, les params et `attributes["hash"]`, et un template l’atteint sous l’un ou l’autre nom (`post.hash`, `post.hash_column`), sauf `errors` et `to_param`, qu’un template résout comme les méthodes du modèle&nbsp;: utilisez donc `post.errors_column` à cet endroit&nbsp;; l’API de requête (`where`, `order`, `find_by`) prend toujours le nom de colonne SQL (`Post.where(hash: 1)`), le nom Ruby n’étant que celui du lecteur/écrivain et du template. Une colonne nommée comme une autre méthode d’Object (`display`, `tap`, `methods`) est générée sous son propre nom avec une note. `cybertrain generate scaffold` refuse les mots-clés et les noms réservés (il devrait appeler un lecteur renommé) et accepte un nom masquant avec une note, comme le générateur. Une association dont le nom simple est déjà pris par une colonne, une autre association ou une méthode de `Model` est émise sous un nom de repli avec un commentaire dans le fichier généré&nbsp;: `<table>_as_<column stem>` pour un `has_many` (`comments_as_article`), `<stem>_as_<column>` pour un `belongs_to` (`author_as_author_id`) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Non implémenté — noms plats, `render json:` uniquement |
| `rescue StandardError` attrape un `JSON.parse` qui échoue | Sous Spinel, `JSON::ParserError` n’est pas une `StandardError`&nbsp;: le code de l’application doit faire `rescue JSON::ParserError, StandardError`. Le serveur l’attrape en dernier recours et répond 500 |
| `skip_forgery_protection` dans un contrôleur d’API | Le CSRF est un middleware qui s’exécute avant le routage, donc une API est exemptée par chemin&nbsp;: `c.csrf_exempt_prefixes = ["/api/"]` dans `config/app.rb`. Le contrôleur doit alors authentifier lui-même ses appelants (une clé d’API dans un en-tête), et aucune route authentifiée par session ne doit correspondre sous ce préfixe |
| Rack laisse un corps de requête gzip tel quel | Un corps envoyé avec `Content-Encoding: gzip` (un SDK ou un client d’API au-delà de quelques kilo-octets) est `request.decoded_body`, décompressé une fois via la zlib du système sous un plafond de taille de sortie (10&nbsp;Mio par défaut&nbsp;; un point d’accès qui attend davantage passe le sien, `request.decoded_body(limit)`)&nbsp;: un corps corrompu ou un encodage autre que gzip/identity donne `Cybertrain::BodyUndecodable`, un corps qui dépasserait la limite une fois décompressé `Cybertrain::BodyTooLarge`, deux `QueryInvalid` auxquelles il est répondu 400&nbsp;; `request.body` reste les octets tels qu’envoyés |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` n’accepte que des listes `column [ASC\|DESC]` (chaque colonne entre guillemets) et lève `ArgumentError` (une 500&nbsp;: la chaîne vient du développeur) pour tout le reste&nbsp;; les données de la requête doivent d’abord passer par une liste blanche, par exemple `SORTS = { "title" => "title", "newest" => "created_at DESC" }` et `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`, car un terme bien formé peut quand même nommer une colonne absente (une 500 venant de SQLite) ou une colonne par laquelle le client ne doit pas trier&nbsp;; le texte ORDER BY brut passe par `order_sql` (`Post.order_sql("lower(title)")`, aussi sur une relation), qui ne doit jamais voir de données de la requête. Un `limit`/`offset` sur `delete_all` est respecté (une sous-requête), et les paramètres de requête s’imbriquent sur 32 niveaux / 4096 paires au plus (400 au-delà). `Query.parse`, `Query.value_of`, `Query.decode` et `request.form_value` / `query_value` lèvent `Cybertrain::QueryMalformed` (une `StandardError` sous `Cybertrain::QueryInvalid`, pas une `ArgumentError`) sur un échappement pourcent mal formé, sur les deux runtimes (`Cookies.parse` garde toujours la valeur brute). Ils la lèvent aussi sur une séquence d’octets UTF-8 invalide, brute (quel que soit le tag de la String) ou encodée en pourcent (Rails répond de même 400 pour un encodage de paramètre invalide), et de même pour un octet brut que seul un échappement compléterait (`a=\xC3%A9`)&nbsp;; `Cookies.parse` garde une telle valeur brute, et un chemin avec une séquence invalide (brute, ou décodée depuis le pourcent dans un segment) donne aussi une 400 (`request.path_segments`&nbsp;; un échappement mal formé dans un chemin reste littéral, une 404 faute de correspondance). Le code d’application qui faisait `rescue ArgumentError` autour d’eux doit plutôt faire `rescue Cybertrain::QueryInvalid` (note de mise à niveau). La requête ne garde pas d’arbre de paramètres à elle (le Router construit `params`, le middleware lit une seule clé)&nbsp;; une application qui veut l’arbre entier l’analyse elle-même, `Query.parse(request.utf8_query_string)`, et possède le résultat |
| Backtrace complète lors d’une exception | Classe, message, ligne de requête, nom/ligne du template — Spinel n’expose pas de backtraces |
| Rack, ses middlewares, et n’importe quelle gem d’un `Gemfile` | Pas de compatibilité Rack&nbsp;; un petit ensemble fixe de middlewares&nbsp;; le `spin-index` propre à Spinel, limité à ce qui compile avec son sous-ensemble de Ruby |
| minitest / RSpec | `Cybertrain::Test` — les runners fondés sur la réflexion ne peuvent pas fonctionner avec une compilation AOT |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` écrit la même structure (User, Session, SessionsController, le before_action), plus une page d’inscription, faute de console où créer un utilisateur&nbsp;; `has_secure_password` est écrit en toutes lettres sous forme de méthodes du modèle User au-dessus de `Cybertrain::Password` (PBKDF2-HMAC-SHA256 en Ruby&nbsp;: bcrypt demanderait une bibliothèque C liée au binaire, et `String#crypt` n’a pas de bcrypt sous macOS). Pas de réinitialisation du mot de passe (pas de mailers)&nbsp;; les tentatives de connexion sont limitées par `rate_limit` (comptées par processus&nbsp;; voir [Limitation du débit](requests.md#rate-limiting-and-the-client-address)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment post cover` écrit cinq colonnes `cover_*` dans la table propriétaire et les méthodes de modèle (`cover_file=`, `cover_url`, ...) dans l’application&nbsp;; les fichiers résident sur le disque sous `storage/uploads/` et sont servis par une action générée via `send_blob`. Un fichier par champ, disque local uniquement, ni variantes ni envois directs |
| `skip_before_action :x` | Pareil, pour les callbacks before nommés (un callback sous forme de bloc n’a pas de nom à sauter)&nbsp;; pas de `skip_after_action` |
| `resource :session` | Les mêmes six routes vers `SessionsController`&nbsp;; pas d’imbrication en dessous |
| `get "/x"` puis `post "/x"` | Les deux sont acceptés&nbsp;: le nom déduit de la seconde route est déjà pris, elle reste donc sans nom, comme dans Rails&nbsp;; un `as:` en double reste une erreur |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, les données de fuseaux fournies avec ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` lit les fichiers TZif du système (`/usr/share/zoneinfo`, ou `TZDIR`) et convertit des secondes epoch Integer (`utc_offset_at`, `utc_to_local`, `local_to_utc`)&nbsp;; pas encore de `Time.zone` par requête ni de `l(time, zone:)` ([Fuseaux horaires](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` pour les webhooks et les API&nbsp;: chaque attente est bornée, les destinations non publiques sont refusées par défaut, ni redirections ni keep-alive (voir [HTTP sortant](external-services.md#outbound-http))&nbsp;; le `Net::HTTP` de Spinel bloque tout le serveur quand un pair ne répond plus |
| Action Mailer (`deliver_later`, classes de mailer, vues) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` envoie du texte brut en SMTP (STARTTLS, TLS implicite ou en clair vers le loopback&nbsp;; AUTH PLAIN&nbsp;; chaque attente bornée)&nbsp;; ni templates, ni HTML, ni pièces jointes, ni file d’attente (voir [Envoyer des e-mails](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, tâches récurrentes | `Cybertrain::Job.handle(kind) { \|payload\| ... }` et `Job.enqueue(kind, payload, run_at:)` (une charge utile String dans une table `cybertrain_jobs`, réessayée avec un délai croissant, puis `failed`), `Cybertrain::Scheduler.every(seconds, name) { ... }`&nbsp;; un thread dans le processus qui sert, `CYBERTRAIN_WORKER=0` ailleurs ([Tâches de fond](background-and-operations.md#background-work)) |
| Client ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url).on_message { \|conn, data\| ... }` garde un flux connecté tant que le serveur tourne (reconnexions, pings, détection de silence), `Cybertrain::WebSocket::Client` pour une connexion synchrone unique&nbsp;; sortant uniquement, chaque attente bornée (voir [Consommer des flux WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` est un Array de String comparées par sous-chaîne, sans tenir compte de la casse (ni Regexp ni lambdas)&nbsp;; il s’applique au journal des requêtes et à la page d’erreur de développement ([Paramètres filtrés](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (une route vers un contrôleur) | `GET /up` est intégré et reçoit sa réponse avant les fichiers statiques, la session et le routeur, donc aucun `before_action` ne s’exécute&nbsp;; il interroge la base de données et le dernier tick du worker de fond, `200 ok` ou `503` ([Exploitation](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Tâches `bin/rails db:...` pour les sauvegardes (aucune intégrée) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renommé à sa place) et `./<app> db vacuum` |
| ActionCable (le serveur), asset pipeline, i18n | Non développé (hors des objectifs du MVP, `docs/design.md` §2.3) |

Liste non exhaustive — `docs/design.md` §8 («&nbsp;What was deliberately left out&nbsp;») en est l’inventaire plus complet.

## Performances

[docs/benchmark.md](../benchmark.md) mesure examples/blog face au même blog
écrit en Rails 8.1, [bench/rails_blog](../../bench/rails_blog) (les mêmes vues,
routes, modèles et schéma), tous deux en mode production, chaque serveur étant
épinglé sur les mêmes cœurs CPU d’une VM cloud à 4 vCPU et chargé par wrk depuis
deux autres. Médianes de trois exécutions de 10&nbsp;secondes, enregistrées le
2026-10-09&nbsp;:

| 1 cœur CPU, 16 connexions | CyberTrain 0.2.1 | Rails 8.1.4 (YJIT, Puma) | |
| --- | --: | --: | --: |
| `GET /articles` (30 articles) | 2&nbsp;641 req/s | 468 req/s | 5,6x |
| `GET /articles/1` (10 commentaires, 12 formulaires) | 2&nbsp;450 req/s | 201 req/s | 12,2x |
| `POST /articles/2/comments` | 1&nbsp;507 req/s | 390 req/s | 3,9x |
| `GET /style.css` | 13&nbsp;300 req/s | 5&nbsp;127 req/s | 2,6x |
| Mémoire après la charge (RSS) | 10,6 Mo | 126 Mo | |
| Du lancement à la première réponse | 0,02 s | 1,3 s | |
| Ce dont le serveur a besoin | 2,5 Mo (un binaire) | 109 Mo (Ruby, 69 gems, l’application) | |

Avec jemalloc des deux côtés (`allocator = "jemalloc"` dans spin.toml&nbsp;;
l’image de production de Rails le précharge), les rapports vont de 2,8 à 14,6.
Sur deux cœurs, l’avance se réduit à 2,0 à 5,5&nbsp;: un second worker Puma
double Rails, tandis que `SPINEL_WORKERS=2` ajoute 9 à 58&nbsp;% à CyberTrain
(réglez-le sur le nombre de cœurs sur un serveur multicœur&nbsp;; il vaut 1 par
défaut). Le binaire doit aussi être compilé (`cybertrain build` a pris environ
trois minutes sur cette machine). docs/benchmark.md donne la latence, chaque
configuration, la méthode et ce qui a été optimisé pour en arriver là&nbsp;;
`bench/run` refait la mesure et `bench/report` en affiche les tableaux.
