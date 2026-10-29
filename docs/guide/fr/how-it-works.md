---
source_sha256: e51e959017a031fc0c47aaef26b3c057773c2dc7b94c1fd7c634dd77767f06f2
description: Comment une application CyberTrain est construite et exécutée (génération de code à la compilation, vues interprétées, serveur HTTP, SQLite via FFI, boucle de développement) et les différences avec Rails.
---
# Fonctionnement

Cette page explique comment une application CyberTrain est construite et exécutée&nbsp;: le code généré à la compilation, les vues interprétées au moment de la requête, le serveur HTTP, SQLite via la FFI et la boucle de développement, puis un tableau des différences avec Rails. La [section performances](site:index.html#performance) de la page d’accueil compare le résultat avec le même blog écrit en Rails 8.1. La méthode, chaque chiffre et la façon de refaire la mesure se trouvent dans [docs/benchmark.md](../benchmark.md).

## Génération de code à la compilation

`spin run gen` (`bin/gen.rb`) exécute le DSL `create_table` de `db/schema.rb` et le DSL `Routes.draw` de `config/routes.rb` pour obtenir les *données* des tables et des routes. Il fait séparément un **balayage lexical** (des regex, pas un parseur — Spinel n’en expose aucun à l’exécution) de `app/controllers/**/*.rb` et `app/models/**/*.rb` à la recherche des affectations `@ivar =`, des noms `before_action`/`after_action`/`rescue_from ... with:` et des `def` sans argument.

À partir de cela, il écrit du Ruby simple et lisible sous `gen/`&nbsp;:

- `gen/models/<name>.rb`&nbsp;: accesseurs, conversions, finders, associations déduites des clés étrangères&nbsp;;
- `gen/routes.rb`&nbsp;: la table des routes, le dispatcher, les helpers `*_path`/`*_url`&nbsp;;
- `gen/controllers.rb`&nbsp;: `view_assigns` et `run_callback` par contrôleur&nbsp;;
- `gen/migrations.rb`&nbsp;;
- `gen/views.rb`&nbsp;: la table des vues intégrées, vide sauf lors d’une compilation pour le déploiement&nbsp;;
- `gen/app.rb`&nbsp;: le manifeste des `require_relative`.

`gen/` est versionné, pas ignoré par git&nbsp;: `spin build` et `spin test` n’ont pas de hook pour générer d’abord, donc la sortie versionnée doit déjà être ce qui compile. La CI relance `spin run gen` et échoue s’il y a un diff&nbsp;: du code généré périmé ne peut donc pas être fusionné.

## Les vues sont interprétées

Les fichiers `app/views/**/*.html.erb` ressemblent à de l’ERB de Rails, mais sont analysés en un AST au moment de la requête, puis parcourus par un interpréteur qui parcourt l’arbre. Spinel n’a pas d’`eval`, il s’agit donc d’une grammaire fermée (littéraux, lectures de `@ivar`/variables locales, appels via des tables de dispatch fixes par type, `if`/`unless`, `each`/`each_with_index`/un bloc de helper), pas de vrai Ruby. La grammaire complète, les helpers et les lacunes se trouvent dans la [référence du langage de templates](template-language.md).

L’origine du source dépend du mode&nbsp;:

- En développement (et en test), le moteur lit `app/views/` depuis le disque, et en développement il réanalyse un template quand celui-ci change, donc modifier une vue ne demande pas de recompilation.
- `cybertrain build` lance `spin run gen -- --embed-views`, qui écrit le source de chaque template dans `gen/views.rb` sous forme de table de chaînes pour ce seul `spin build`, puis relance `spin run gen` pour remettre la table vide versionnée.
- Le binaire de production ne rend que cette table (en analysant chaque template une seule fois) et refuse de démarrer quand elle est vide (`error: views are not embedded in this binary`).

## Le serveur HTTP

`Cybertrain::Server` est un serveur HTTP/1.1 en Ruby pur&nbsp;: `TCPServer#accept` plus un green thread Spinel par connexion (ordonnancement M:N, pas de GVL), `Request`/`Response` typés, pas de couche Rack. TLS/HTTP/2 sont laissés à un reverse proxy. `SPINEL_WORKERS` vaut `1` par défaut — les spikes ont montré que c’est plus rapide et sans blocage pour cette charge limitée par les E/S à 100 connexions simultanées.

Le serveur appelle un `HttpHandler` (`call(request) -> Response`)&nbsp;; `ContextHandler` le relie à la pile de middlewares, de sorte que la couche HTTP (`cybertrain/http/`, plus `Params` et `Logger`) ne dépend pas du reste du framework. `script/check-http-layer` l’impose dans la CI.

## SQLite via FFI

Les modèles parlent à SQLite directement via `ffi_func`/`ffi_lib` de Spinel — pas d’extension C, pas de gem. Chaque requête est paramétrée, jamais interpolée. C’est le seul adaptateur aujourd’hui (PostgreSQL via la FFI de `libpq` est noté comme travail futur possible).

Un pool (`SizedQueue`, 4 connexions par défaut) distribue des connexions avec&nbsp;:

- WAL&nbsp;;
- un délai d’attente sur verrou d’environ cinq secondes (un busy handler qui réessaie toutes les 100&nbsp;µs, là où le `busy_timeout` de SQLite dort une milliseconde ou plus)&nbsp;;
- jusqu’à 64 requêtes préparées en cache&nbsp;;
- les clés étrangères activées.

Comment une transaction emprunte l’une de ces connexions, et ce qui s’exécute dessus&nbsp;: [Transactions](models.md#transactions).

## La boucle de développement

`cybertrain server` (`spin run gen`, puis `spin run NAME`) en `development` (le `CYBERTRAIN_ENV` par défaut, sauf dans un binaire issu de `cybertrain build`) surveille aussi `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb` et `gen/**/*.rb` toutes les demi-secondes. Les vues sont exclues (le moteur les recharge lui-même), tout comme `gen/views.rb`, vide en développement.

Un changement lance `spin run gen && spin build NAME -- --incremental` en arrière-plan&nbsp;: la compilation incrémentale de Spinel, qui ne recompile que les unités C touchées par la modification. Une version de Spinel sans `--incremental` rejette l’option, et la boucle compile alors sans elle.

Un succès demande un redémarrage (le même indicateur qu’un `kill -HUP` externe)&nbsp;: un thread de surveillance arrête l’écoute et laisse se terminer les requêtes ouvertes, puis le thread principal fait `execv` du nouveau binaire sur le même port et le même PID, de façon invisible pour un client en pleine session. Une compilation échouée continue de servir l’ancien binaire et affiche la sortie du compilateur en bannière sur chaque réponse HTML. Les recompilations sont suspendues tant que `cybertrain build` détient `tmp/cybertrain-build.lock`. Rien de tout cela n’est chargé en production.

## Différences avec Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console` | Pas de console — Spinel n’a pas d’`eval` |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` dans `bin/<app>.rb`&nbsp;: `./<app> name ARGS` la lance avec la base de données connectée |
| Modifiez le code, l’application en cours d’exécution le prend en compte | Le Ruby demande une recompilation&nbsp;; en développement, `cybertrain server` s’en charge pour vous (recompilation, arrêt, `execv`) |
| Modifiez une vue, aucun rechargement nécessaire | Pareil — en développement, les vues sont analysées depuis le disque à chaque requête |
| `def new` | `def new_action` (`new` masquerait `Klass.new(ctx)`) |
| `before_action { do_thing }` (`self` implicite) | `before_action { \|c\| c.do_thing }` — pas d’`instance_exec` sur un bloc stocké, donc les callbacks reçoivent explicitement le contrôleur/l’enregistrement |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — les blocs imbriqués reçoivent le mapper explicitement |
| ERB est compilé en méthode&nbsp;; n’importe quel objet, n’importe quelle méthode | Interprété selon une grammaire/table de dispatch fixe ([Langage de templates](template-language.md)) |
| La session contient n’importe quel objet sérialisé (marshal) | Valeurs de session de type String uniquement, cookie signé HMAC |
| De nombreux adaptateurs de base de données | SQLite uniquement, via FFI |
| `Article.transaction { ... }` renvoie la valeur du bloc&nbsp;; `raise ActiveRecord::Rollback`&nbsp;; savepoints avec `requires_new: true` | `Article.transaction { \|c\| ... }` passe la connexion au bloc et renvoie nil&nbsp;; on en sort en levant une exception&nbsp;; les appels imbriqués rejoignent la transaction externe, pas de savepoints ([Transactions](models.md#transactions)) |
| `has_many :through`, `includes`, `dependent:`, enums, STI, associations polymorphes | Non implémenté&nbsp;; les associations viennent uniquement des clés étrangères du schéma |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Des variantes typées, car une méthode Spinel a un seul type de retour&nbsp;: `pluck_int` et ses semblables, `sum_int`, `count_by`, `upsert`, `increment(:col, by: n)`, `where_like` ([Requêtes au-delà de `where`](models.md#querying-beyond-where)) |
| N’importe quel nom de colonne&nbsp;; une association peut masquer `errors` | Des identifiants ASCII uniquement&nbsp;; une colonne nommée comme une méthode du framework ou un mot-clé Ruby est générée sous `<column>_column`, une association qui entre en conflit sous un nom de repli ([Noms de colonnes](models.md#column-names)) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Non implémenté — noms plats, `render json:` uniquement |
| `rescue StandardError` attrape un `JSON.parse` qui échoue | Sous Spinel, `JSON::ParserError` n’est pas une `StandardError`&nbsp;: le code de l’application doit faire `rescue JSON::ParserError, StandardError`. Le serveur l’attrape en dernier recours et répond 500 |
| `skip_forgery_protection` dans un contrôleur d’API | Le CSRF s’exécute avant le routage, donc une API est exemptée par chemin, `c.csrf_exempt_prefixes = ["/api/"]`, et authentifie elle-même ses appelants ([Configuration](configuration.md#configuration-and-environment-variables)) |
| Rack laisse un corps de requête gzip tel quel | Un corps `Content-Encoding: gzip` est `request.decoded_body`, décompressé sous un plafond de 10&nbsp;Mio&nbsp;; un corps corrompu ou trop gros donne une 400&nbsp;; `request.body` reste tel qu’envoyé ([Chaînes de requête et corps](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` n’accepte que des listes `column [ASC\|DESC]`&nbsp;; les données de la requête passent par une liste blanche, le SQL brut par `order_sql` ([Tri](models.md#ordering)). Des paramètres mal formés ou trop imbriqués donnent une 400 ([Chaînes de requête et corps](requests.md#query-strings-and-bodies)) |
| Backtrace complète lors d’une exception | Classe, message, ligne de requête, nom/ligne du template — Spinel n’expose pas de backtraces |
| Rack, ses middlewares, et n’importe quelle gem d’un `Gemfile` | Pas de compatibilité Rack&nbsp;; un petit ensemble fixe de middlewares&nbsp;; le `spin-index` propre à Spinel, limité à ce qui compile avec son sous-ensemble de Ruby |
| minitest / RSpec | `Cybertrain::Test` — les runners fondés sur la réflexion ne peuvent pas fonctionner avec une compilation AOT |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` écrit la même structure plus une page d’inscription&nbsp;; les mots de passe utilisent PBKDF2-HMAC-SHA256 (bcrypt demanderait une bibliothèque C&nbsp;; le `String#crypt` de macOS n’a pas bcrypt)&nbsp;; pas de réinitialisation du mot de passe ([Ajouter la connexion](tutorial.md#authentication)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` écrit cinq colonnes `cover_*` et les méthodes de modèle&nbsp;; les fichiers résident sur le disque local sous `storage/uploads/` et sont servis par `send_blob`&nbsp;; un fichier par champ, ni variantes ni envois directs ([Ajouter une image de couverture](tutorial.md#attachments)) |
| `skip_before_action :x` | Pareil, pour les callbacks before nommés (un callback sous forme de bloc n’a pas de nom à sauter)&nbsp;; pas de `skip_after_action` |
| `resource :session` | Les mêmes six routes vers `SessionsController`&nbsp;; pas d’imbrication en dessous |
| `get "/x"` puis `post "/x"` | Les deux sont acceptés&nbsp;: le nom déduit de la seconde route est déjà pris, elle reste donc sans nom, comme dans Rails&nbsp;; un `as:` en double reste une erreur |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, les données de fuseaux fournies avec ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` lit les fichiers TZif du système (`/usr/share/zoneinfo`, ou `TZDIR`) et convertit des secondes epoch Integer (`utc_offset_at`, `utc_to_local`, `local_to_utc`)&nbsp;; pas encore de `Time.zone` par requête ni de `l(time, zone:)` ([Fuseaux horaires](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` pour les webhooks et les API&nbsp;: chaque attente est bornée, les destinations non publiques sont refusées par défaut, ni redirections ni keep-alive (voir [HTTP sortant](external-services.md#outbound-http))&nbsp;; le `Net::HTTP` de Spinel bloque tout le serveur quand un pair ne répond plus |
| Action Mailer (`deliver_later`, classes de mailer, vues) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` envoie du texte brut en SMTP (STARTTLS, TLS implicite ou en clair vers le loopback&nbsp;; AUTH PLAIN&nbsp;; chaque attente bornée)&nbsp;; ni templates, ni HTML, ni pièces jointes, ni file d’attente (voir [Envoyer des e-mails](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, tâches récurrentes | `Cybertrain::Job.handle(kind)` et `Job.enqueue(kind, payload, run_at:)` (une charge utile String, réessayée avec un délai croissant), `Cybertrain::Scheduler.every(seconds, name)`&nbsp;; un thread dans le processus qui sert ([Tâches de fond](background-and-operations.md#background-work)) |
| Client ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` garde un flux connecté tant que le serveur tourne (reconnexions, pings, détection de silence)&nbsp;; `WebSocket::Client` pour une connexion synchrone unique&nbsp;; sortant uniquement ([Consommer des flux WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` est un Array de String comparées par sous-chaîne, sans tenir compte de la casse (ni Regexp ni lambdas)&nbsp;; il s’applique au journal des requêtes et à la page d’erreur de développement ([Paramètres filtrés](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (une route vers un contrôleur) | `GET /up` est intégré et reçoit sa réponse avant les fichiers statiques, la session et le routeur, donc aucun `before_action` ne s’exécute&nbsp;; il interroge la base de données et le worker, `200 ok` ou `503` ([Exploitation](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Tâches `bin/rails db:...` pour les sauvegardes (aucune intégrée) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renommé à sa place) et `./<app> db vacuum` |
| ActionCable (le serveur), asset pipeline, i18n | Non développé (hors des objectifs du MVP, `docs/design.md` §2.3) |

<!-- table-foot: Liste non exhaustive&nbsp;: `docs/design.md` §8 («&nbsp;What was deliberately left out&nbsp;») en est l’inventaire plus complet. -->
