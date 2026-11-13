---
source_sha256: 3afaba04187570028acd5c6feda8dd927352b70fddf98ffa89c3b6712460f196
description: Comment une application CyberTrain est construite et exécutée (génération de code à la compilation, vues interprétées, serveur HTTP, SQLite via FFI, boucle de développement) et les différences avec Rails.
---
# Fonctionnement

Cette page explique comment une application CyberTrain est construite et exécutée&nbsp;: le code généré à la compilation, les vues interprétées au moment de la requête, le serveur HTTP, SQLite via la FFI et la boucle de développement, puis un tableau des différences avec Rails. La [section performances](site:index.html#performance) de la page d’accueil compare le résultat avec le même blog écrit en Rails 8.1. La méthode, chaque chiffre et la façon de refaire la mesure se trouvent dans [docs/benchmark.md](../benchmark.md).

## Génération de code à la compilation

`spin run gen` (`bin/gen.rb`) exécute le DSL `create_table` de `db/schema.rb` et le DSL `Routes.draw` de `config/routes.rb` pour obtenir les *données* des tables et des routes. Il fait séparément un **balayage lexical** (des regex, pas un parseur — Spinel n’en expose aucun à l’exécution) de `app/controllers/**/*.rb` et `app/models/**/*.rb` à la recherche des affectations `@ivar =`, des noms `before_action`/`after_action`/`rescue_from ... with:`, des lignes `helper_method`, `layout` et `rate_limit`, des `include` de concerns et des `def` sans argument. Il met une empreinte sur les fichiers de `app/assets/`, `app/javascript/` et `vendor/javascript/` lit `config/importmap.rb` comme du texte, et lit les dictionnaires de `config/locales/` avec un lecteur YAML à lui.

À partir de cela, il écrit du Ruby simple et lisible sous `gen/`&nbsp;:

- `gen/models/<name>.rb`&nbsp;: accesseurs, conversions, finders, associations déduites des clés étrangères&nbsp;;
- `gen/routes.rb`&nbsp;: la table des routes, le dispatcher, les helpers `*_path`/`*_url`&nbsp;;
- `gen/controllers.rb`&nbsp;: `view_assigns`, `run_callback`, la table de `helper_method` et `controller_layout` par contrôleur&nbsp;;
- `gen/concerns.rb` et `gen/concerns/**`&nbsp;: les blocs `included` des concerns insérés dans chaque classe qui les inclut, et les modules des concerns avec ces blocs vidés ([Concerns](requests.md#concerns-and-helper_method))&nbsp;;
- `gen/assets.rb`&nbsp;: les chemins des assets avec empreinte et l’import map ([Assets](assets.md)), avec les fichiers à empreinte dans `public/assets/`&nbsp;;
- `gen/locales.rb`&nbsp;: les dictionnaires de l’application en deux Hash, que lit `I18n.t` ([Internationalisation](i18n.md#dictionaries))&nbsp;;
- `gen/migrations.rb`&nbsp;;
- `gen/views.rb`&nbsp;: la table des vues intégrées, vide sauf lors d’une compilation pour le déploiement&nbsp;;
- `gen/app.rb`&nbsp;: le manifeste des `require_relative`&nbsp;;
- `gen/tests.rb` et `gen/test/**`&nbsp;: tous les tests de `test/` en un seul programme,
  chaque classe de test réécrite en méthodes, et `gen/test/data.rb`, les
  tables et les fixtures ([Tester une application](testing.md#running-the-tests)).

`gen/` est versionné, pas ignoré par git&nbsp;: `spin build` et `spin test` n’ont pas de hook pour générer d’abord, donc la sortie versionnée doit déjà être ce qui compile. La CI relance `spin run gen` et échoue s’il y a un diff&nbsp;: du code généré périmé ne peut donc pas être fusionné.

## Les vues sont interprétées

Les fichiers `app/views/**/*.html.erb` ressemblent à de l’ERB de Rails, mais sont analysés en un AST au moment de la requête, puis parcourus par un interpréteur qui parcourt l’arbre. Spinel n’a pas d’`eval`, il s’agit donc d’une grammaire fermée (littéraux, lectures de `@ivar`/variables locales, appels via des tables de dispatch fixes par type, `if`/`unless`, `each`/`each_with_index`/un bloc de helper), pas de vrai Ruby. La grammaire complète, les helpers et les lacunes se trouvent dans la [référence du langage de templates](template-language.md).

L’origine du source dépend du mode&nbsp;:

- En développement (et en test), le moteur lit `app/views/` depuis le disque, et en développement il réanalyse un template quand celui-ci change, donc modifier une vue ne demande pas de recompilation.
- `cybertrain build` lance `SPIN_DEBUG=1 spin run gen -- --embed-views`, qui écrit le source de chaque template dans `gen/views.rb` sous forme de table de chaînes pour ce seul `spin build`, puis relance `SPIN_DEBUG=1 spin run gen` pour remettre la table vide versionnée.
- Le binaire de production ne rend que cette table (en analysant chaque template une seule fois) et refuse de démarrer quand elle est vide (`error: views are not embedded in this binary`).

## Le serveur HTTP

`Cybertrain::Server` est un serveur HTTP/1.1 en Ruby pur&nbsp;: `TCPServer#accept` plus un green thread Spinel par connexion (ordonnancement M:N, pas de GVL), `Request`/`Response` typés, pas de couche Rack. TLS/HTTP/2 sont laissés à un reverse proxy. `SPINEL_WORKERS` vaut `1` par défaut — les spikes ont montré que c’est plus rapide et sans blocage pour cette charge limitée par les E/S à 100 connexions simultanées.

Le serveur appelle un `HttpHandler` (`call(request) -> Response`)&nbsp;; `ContextHandler` le relie à la pile de middlewares, de sorte que la couche HTTP (`cybertrain/http/`, plus `Params` et `Logger`) ne dépend pas du reste du framework. `script/check-http-layer` l’impose dans la CI.

## SQLite via FFI

Les modèles parlent à SQLite directement via `ffi_func`/`ffi_lib` de Spinel — pas d’extension C, pas de gem. Chaque requête est paramétrée, jamais interpolée. C’est le seul adaptateur aujourd’hui (PostgreSQL via la FFI de `libpq` est noté comme travail futur possible).

Un pool (`SizedQueue`, 4 connexions par défaut) distribue des connexions avec&nbsp;:

- WAL&nbsp;;
- un délai d’attente sur verrou d’environ cinq secondes, attendu dans un `sleep` de green thread (100&nbsp;µs d’abord, puis jusqu’à 1&nbsp;ms) pour que la connexion qui tient le verrou continue de tourner même avec un seul worker&nbsp;; un script de schéma attend dans SQLite (dont le `busy_timeout` dort une milliseconde ou plus)&nbsp;;
- jusqu’à 64 requêtes préparées en cache&nbsp;;
- les clés étrangères activées.

Comment une transaction emprunte l’une de ces connexions, et ce qui s’exécute dessus&nbsp;: [Transactions](models.md#transactions).

## La boucle de développement

`cybertrain server` en `development` (le `CYBERTRAIN_ENV` par défaut, sauf dans un binaire issu de `cybertrain build`) est un superviseur. Il tourne sous CRuby, le Ruby qui exécute la commande `cybertrain`, garde lui-même la socket d’écoute et y fait tourner un seul processus enfant à la fois&nbsp;: l’application sous CRuby juste après un changement, puis le binaire compilé dès que Spinel l’a construit en arrière-plan. Une modification Ruby reçoit tout de suite la réponse de l’aperçu CRuby (en moins d’une seconde sur examples/blog), et le programme compilé reprend le port sans que vous ayez rien à faire.

Au démarrage, le superviseur lance gen sous CRuby (`ruby bin/gen.rb`, qui écrit le même `gen/` que `spin run gen`), démarre l’application sous CRuby (`ruby -r cybertrain/preview bin/NAME.rb`) et lance la compilation. Les deux tournent avec le `ruby` du `PATH`, celui dont `cybertrain doctor` vérifie qu’il charge `fiddle`, qui peut être un autre Ruby que celui qui exécute la commande `cybertrain`. L’aperçu fournit au framework son FFI (SQLite, zlib) par une couche au-dessus de `fiddle`, la bibliothèque de Ruby, qui compile une seule fois dans `tmp/cybertrain-dev/ffi/` le même C que celui du binaire. La première compilation est `spin build NAME`&nbsp;: une application qui n’a pas changé depuis la construction de son binaire ne compile rien, et le binaire répond en moins d’une seconde. Une première compilation sur un binaire plus ancien qu’un fichier Ruby, et toutes les suivantes, sont `spin build NAME -- --incremental`&nbsp;: la compilation incrémentale de Spinel, qui ne recompile que les unités C touchées par la modification. Une version de Spinel sans `--incremental` rejette l’option, et la compilation se fait alors sans elle. La sortie va dans `tmp/rebuild.log`.

Le superviseur surveille `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`, `gen/**/*.rb` et les racines des assets (`app/assets/**`, `app/javascript/**`, `vendor/javascript/**`) dix fois par seconde. Les vues sont exclues (les deux environnements d’exécution les relisent sur le disque), tout comme `gen/views.rb`, vide en développement. Un changement annule la compilation en cours, lance gen sous CRuby, remplace l’enfant par un nouvel enfant CRuby et lance une nouvelle compilation. Quand une compilation réussit et que rien n’a changé entre-temps, le superviseur arrête l’enfant CRuby et démarre `build/bin/NAME` sur la même socket&nbsp;: d’abord l’arrêt, puis le démarrage, la socket restant ouverte entre les deux, si bien qu’une requête arrivée pendant le changement attend un instant puis reçoit sa réponse. Aucune n’est refusée.

Chaque réponse de l’application porte `X-Cybertrain-Runtime: cruby` ou `spinel`, et chaque page HTML une ligne discrète dans son coin inférieur droit&nbsp;:

- `CRuby preview · Spinel building…`&nbsp;: CRuby a rendu la page pendant la compilation.
- `Spinel ready — reload`&nbsp;: le binaire compilé répond désormais&nbsp;; rechargez pour voir sa page.
- `CRuby preview · Spinel build failed`&nbsp;: CRuby continue de répondre, et la page affiche la sortie du compilateur en bannière.
- `CRuby preview · Spinel binary failed`&nbsp;: le binaire n’a pas démarré, ou s’est arrêté&nbsp;; CRuby répond de nouveau, la bannière montre ce que le binaire a signalé, et le changement suivant le recompile et l’essaie de nouveau.
- `Spinel`&nbsp;: le binaire compilé a rendu la page.
- `Source changed — reload`&nbsp;: un fichier a changé après le rendu de la page.
- `CRuby preview`&nbsp;: CRuby a rendu la page et aucun des cas ci-dessus ne s’applique.

La ligne se tient à jour d’elle-même&nbsp;; les pages de l’application ne se rechargent jamais toutes seules, si bien qu’un formulaire en cours de saisie n’est pas perdu. Quand gen échoue, ou que l’application ne peut pas démarrer sous CRuby (une `SyntaxError`, par exemple), le superviseur répond lui-même à chaque requête par une page 503 qui montre l’erreur et ce qu’il attend&nbsp;; cette page, celle du superviseur lui-même, se recharge toute seule toutes les 2&nbsp;s jusqu’à ce qu’un enfant puisse répondre, et l’enregistrement qui corrige l’erreur ramène l’application. Tant que `cybertrain build` détient `tmp/cybertrain-build.lock`, rien n’est régénéré ni redémarré&nbsp;; le serveur rattrape son retard une fois le verrou levé. Le superviseur range ses fichiers dans `tmp/cybertrain-dev/`&nbsp;; un seul tourne par application, et Ctrl-C arrête la compilation, l’enfant et le serveur.

Ce que l’aperçu ne montre pas&nbsp;:

- Si le code compile. La compilation en arrière-plan le dit quand elle se termine.
- Les différences d’exécution consignées dans [spikes/NOTES.md](../../spikes/NOTES.md) (la hiérarchie des exceptions, l’encodage des String sur les sockets, `Float#round` sur un Float restreint, et le reste). Elles apparaissent dès que le binaire répond.
- Le temps et la concurrence&nbsp;: CRuby a un GVL et des threads du système, et `SPINEL_WORKERS` n’a aucun sens pour lui.

Le travail en arrière-plan (les jobs, le planificateur, le poller des flux, les flux WebSocket) tourne dans l’enfant qui répond, si bien qu’une modification le redémarre deux fois, sous CRuby puis dans le binaire, et que les clients Server-Sent Events et WebSocket se reconnectent deux fois. Une page qui fonctionne dans l’aperçu n’est terminée qu’une fois que le binaire la sert aussi, et seuls les tests compilés (`spin test`) comptent.

`cybertrain server --spinel` lance à la place la boucle compilée, comme le font `spin run NAME` tapé directement et la CLI native que construit `spin install`&nbsp;: `SPIN_DEBUG=1 spin run gen`&nbsp;; `spin build NAME -- --incremental` si un fichier Ruby est plus récent que `build/bin/NAME`&nbsp;; puis `spin run NAME`. Le binaire surveille lui-même les mêmes fichiers toutes les demi-secondes, lance `SPIN_DEBUG=1 spin run gen && spin build NAME -- --incremental` en arrière-plan à chaque changement et, en cas de succès, arrête l’écoute, laisse se terminer les requêtes ouvertes et fait `execv` du nouveau binaire sur le même port et le même PID&nbsp;; une compilation échouée continue de servir l’ancien binaire et affiche la sortie du compilateur en bannière sur chaque réponse HTML, et les recompilations sont suspendues tant que `cybertrain build` détient son verrou. La CLI et cette boucle compilent gen, et la CLI `bin/db.rb`, dans le mode debug de spin (`SPIN_DEBUG=1`, `-O0`)&nbsp;: ils ne tournent que quelques millisecondes, et gen se compile en une fraction du temps que prend `-O2`&nbsp;; l’application est toujours compilée en mode release. Quand l’aperçu ne peut pas tourner, `cybertrain server` affiche une ligne commençant par `preview unavailable:` et lance la boucle compilée. C’est le cas quand `CYBERTRAIN_ENV` désigne un autre environnement que `development`, quand le framework de l’application est plus ancien que l’aperçu (il n’a pas `cybertrain/preview.rb` ou `cybertrain/dev/supervision.rb`), quand il n’y a pas de `ruby` dans le `PATH`, ou quand ce `ruby` ne peut pas être lancé, ne répond pas en 10&nbsp;s ou ne peut pas charger `fiddle` (`cybertrain doctor` le vérifie). Rien de tout cela n’est chargé en production.

## Différences avec Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`, `rails dbconsole` | `./<app> console` évalue le langage d’expressions des templates sur les modèles (Spinel n’a pas d’`eval`, donc pas de Ruby)&nbsp;; `./<app> dbconsole` ouvre `sqlite3` ([La console](background-and-operations.md#the-console)) |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` dans `bin/<app>.rb`&nbsp;: `./<app> name ARGS` la lance avec la base de données connectée |
| Modifiez le code, l’application en cours d’exécution le prend en compte | Les modifications Ruby apparaissent tout de suite grâce à un aperçu CRuby&nbsp;; le binaire compilé reprend le port quand sa compilation se termine (`cybertrain server`) |
| Modifiez une vue, aucun rechargement nécessaire | Pareil — en développement, les vues sont analysées depuis le disque à chaque requête |
| `def new` | `def new_action` (`new` masquerait `Klass.new(ctx)`) |
| `before_action { do_thing }` (`self` implicite) | `before_action { \|c\| c.do_thing }` — pas d’`instance_exec` sur un bloc stocké, donc les callbacks reçoivent explicitement le contrôleur/l’enregistrement |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — les blocs imbriqués reçoivent le mapper explicitement |
| ERB est compilé en méthode&nbsp;; n’importe quel objet, n’importe quelle méthode | Interprété selon une grammaire/table de dispatch fixe ([Langage de templates](template-language.md)) |
| La session contient n’importe quel objet sérialisé (marshal) | Valeurs de session de type String uniquement, dans un cookie chiffré en AES-256-GCM, comme le cookie store de Rails ([Cookies et session](requests.md#cookies-and-the-session)) |
| De nombreux adaptateurs de base de données | SQLite uniquement, via FFI |
| `Article.transaction { ... }` renvoie la valeur du bloc&nbsp;; `raise ActiveRecord::Rollback`&nbsp;; savepoints avec `requires_new: true` | `Article.transaction { \|c\| ... }` passe la connexion au bloc et renvoie nil&nbsp;; on en sort en levant une exception&nbsp;; les appels imbriqués rejoignent la transaction externe, pas de savepoints ([Transactions](models.md#transactions)) |
| `has_many :through`, enums, STI, associations polymorphes | Non implémenté&nbsp;; `has_many`, `has_one` et `belongs_to` viennent des clés étrangères ou de déclarations d’une ligne, avec `dependent:`, `counter_cache:` et un niveau d’`includes` ([Associations](models.md#associations)) |
| `pluck(:a)`, `maximum(:a)`, `group(:a).sum(:b)`, `upsert`, `update_counters`, `where(created_at: t1..t2)` | Des variantes typées, car une méthode Spinel a un seul type de retour&nbsp;: `pluck_int` et ses semblables, `maximum_int`, `sum_float_by`, `upsert`, `increment(:col, by: n)`&nbsp;; un intervalle de Time s’écrit `where_between` ([Requêtes au-delà de `where`](models.md#querying-beyond-where)) |
| N’importe quel nom de colonne&nbsp;; une association peut masquer `errors` | Des identifiants ASCII uniquement&nbsp;; une colonne nommée comme une méthode du framework ou un mot-clé Ruby est générée sous `<column>_column`, une association qui entre en conflit sous un nom de repli ([Noms de colonnes](models.md#column-names)) |
| `namespace`, `scope`, formats et `respond_to` | Pareil ([Routage](requests.md#routing), [Formats](requests.md#formats-and-respond_to))&nbsp;; on répond en JSON avec `render json:` (pas de templates jbuilder) |
| `constraints`, `mount`, segments glob | Non implémenté |
| `ActiveSupport::Concern` inclus à l’exécution | Concerns dans `app/controllers/concerns` et `app/models/concerns`, développés par `spin run gen` dans les classes qui les incluent&nbsp;; un `include` nomme un concern, et une méthode de `class_methods` ne peut pas porter le nom d’une méthode d’instance ([Concerns](requests.md#concerns-and-helper_method)) |
| `rescue StandardError` attrape un `JSON.parse` qui échoue | Sous Spinel, `JSON::ParserError` n’est pas une `StandardError`&nbsp;: le code de l’application doit faire `rescue JSON::ParserError, StandardError`. Le serveur l’attrape en dernier recours et répond 500 |
| `skip_forgery_protection` dans un contrôleur d’API | Le CSRF s’exécute avant le routage, donc une API est exemptée par chemin, `c.csrf_exempt_prefixes = ["/api/"]`, et authentifie elle-même ses appelants ([Configuration](configuration.md#configuration-and-environment-variables)) |
| Rack laisse un corps de requête gzip tel quel | Un corps `Content-Encoding: gzip` est `request.decoded_body`, décompressé sous un plafond de 10&nbsp;Mio&nbsp;; un corps corrompu ou trop gros donne une 400&nbsp;; `request.body` reste tel qu’envoyé ([Chaînes de requête et corps](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` n’accepte que des listes `column [ASC\|DESC]`&nbsp;; les données de la requête passent par une liste blanche, le SQL brut par `order_sql` ([Tri](models.md#ordering)). Des paramètres mal formés ou trop imbriqués donnent une 400 ([Chaînes de requête et corps](requests.md#query-strings-and-bodies)) |
| Backtrace complète lors d’une exception | Classe, message, ligne de requête, nom/ligne du template — Spinel n’expose pas de backtraces |
| Rack, ses middlewares, et n’importe quelle gem d’un `Gemfile` | Pas de compatibilité Rack&nbsp;; un petit ensemble fixe de middlewares&nbsp;; le `spin-index` propre à Spinel, limité à ce qui compile avec son sous-ensemble de Ruby |
| minitest / RSpec | Des classes de test à la Rails (`ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`) et des fixtures, que `spin run gen` réécrit en un seul programme que `cybertrain test` compile et exécute&nbsp;; les runners fondés sur la réflexion ne peuvent pas fonctionner avec une compilation AOT ([Tester une application](testing.md)) |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` écrit la même structure plus une page d’inscription&nbsp;; les mots de passe utilisent PBKDF2-HMAC-SHA256 (bcrypt demanderait une bibliothèque C&nbsp;; le `String#crypt` de macOS n’a pas bcrypt)&nbsp;; la réinitialisation du mot de passe, la confirmation, le verrouillage et «&nbsp;rester connecté&nbsp;» sont générés aussi, comme les ajouterait Devise ([Authentification](authentication.md)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` écrit cinq colonnes `cover_*` et les méthodes de modèle&nbsp;; les fichiers résident sur le disque local sous `storage/uploads/` et sont servis par `send_blob`&nbsp;; un fichier par champ, ni variantes ni envois directs ([Ajouter une image de couverture](tutorial.md#attachments)) |
| `skip_before_action :x` | Pareil, pour les callbacks before nommés (un callback sous forme de bloc n’a pas de nom à sauter)&nbsp;; pas de `skip_after_action` |
| `resource :session` | Les mêmes six routes vers `SessionsController`&nbsp;; pas d’imbrication en dessous |
| `get "/x"` puis `post "/x"` | Les deux sont acceptés&nbsp;: le nom déduit de la seconde route est déjà pris, elle reste donc sans nom, comme dans Rails&nbsp;; un `as:` en double reste une erreur |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, les données de fuseaux fournies avec ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` lit les fichiers TZif du système (`/usr/share/zoneinfo`, ou `TZDIR`) et convertit des secondes epoch Integer (`utc_offset_at`, `utc_to_local`, `local_to_utc`)&nbsp;; `c.time_zone` fixe `Time.zone` pour toute l’application, `in_time_zone` renvoie une petite valeur avec les champs muraux, et un Time reste un instant UTC (pas de TimeWithZone, `time.hour` est en UTC) ([Fuseaux horaires](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` pour les webhooks et les API&nbsp;: chaque attente est bornée, les destinations non publiques sont refusées par défaut, redirections seulement sur demande, réponses en flux et gzip, un parseur de Server-Sent Events, pas de keep-alive (voir [HTTP sortant](external-services.md#outbound-http))&nbsp;; le `Net::HTTP` de Spinel bloque tout le serveur quand un pair ne répond plus |
| Action Mailer (`deliver_later`, classes de mailer, vues) | `Cybertrain::Mailer.deliver(to:, subject:, body:, html:)` envoie du texte brut, ou du `multipart/alternative` avec une partie HTML rendue depuis un partiel (`Views.render_mail`), en SMTP (STARTTLS, TLS implicite ou en clair vers le loopback&nbsp;; AUTH PLAIN&nbsp;; chaque attente bornée)&nbsp;; `Mailer.deliver_later` l’envoie depuis un job intégré&nbsp;; un mailer est un module de `app/mailers` dont les méthodes renvoient un `Cybertrain::MailMessage` (`deliver_later`, `deliver_now`), comme le `PasswordsMailer` généré&nbsp;; pas de pièces jointes (voir [Envoyer des e-mails](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, tâches récurrentes, Mission Control | Des classes de job dans `app/jobs` (`< Cybertrain::Job::Base`, `perform(args)` avec un Hash de valeurs JSON, `perform_later`, `retry_on`, `discard_on`, `limits_concurrency` avec une clé), `Job.handle(kind)` comme forme courte&nbsp;; `Scheduler.every` et `Scheduler.cron` avec un fuseau horaire et un calendrier conservé dans la base&nbsp;; une page des jobs (`jobs_page` dans les routes) et `./<app> jobs`&nbsp;; `job_threads` threads par processus, dans le serveur ou dans des processus `./<app> worker`, livrés au moins une fois ([Tâches de fond](background-and-operations.md#background-work)) |
| `Rails.cache.fetch(key, expires_in:, race_condition_ttl:)` | `Cybertrain::Cache.fetch` dans la base SQLite de l’application, avec les mêmes options&nbsp;; les valeurs sont des Strings, avec `fetch_hash`, `fetch_array` et `fetch_int` pour le reste&nbsp;; pas de stockage en mémoire ni Redis ([Le cache](background-and-operations.md#the-cache-store)) |
| Client ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` garde un flux connecté tant que le serveur tourne (reconnexions, pings, détection de silence)&nbsp;; `WebSocket::Client` pour une connexion synchrone unique&nbsp;; sortant uniquement ([Consommer des flux WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` est un Array de String comparées par sous-chaîne, sans tenir compte de la casse (ni Regexp ni lambdas)&nbsp;; il s’applique au journal des requêtes et à la page d’erreur de développement ([Paramètres filtrés](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (une route vers un contrôleur) | `GET /up` est intégré et reçoit sa réponse avant les fichiers statiques, la session et le routeur, donc aucun `before_action` ne s’exécute&nbsp;; il interroge la base de données, le worker et les flux WebSocket, `200 ok` ou `503` ([Exploitation](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Tâches `bin/rails db:...` pour les sauvegardes (aucune intégrée) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renommé à sa place) et `./<app> db vacuum` |
| Action Cable, `turbo_stream_from`, `broadcast_append_to` | Les mêmes noms de helpers sur des flux signés, livrés en Server-Sent Events ou en WebSocket depuis une seule table SQLite&nbsp;; pas de classes de canaux ([Temps réel](realtime.md)) |
| Propshaft, importmap-rails | La même organisation (`app/assets`, `app/javascript`, `vendor/javascript`, `config/importmap.rb`), avec empreinte par `spin run gen` dans `public/assets/`&nbsp;; pas de `bin/importmap pin`, Turbo non fourni ([Assets](assets.md)) |
| L’i18n de Rails, les dictionnaires de rails-i18n, `I18n.t`, `t(".title")` | La même API et les mêmes clés, l’anglais et le japonais fournis&nbsp;; `config/locales/*.yml` compilés dans le programme par `spin run gen` depuis un sous-ensemble de YAML (sans ancres, alias ni tags), les listes par `I18n.translate_list` ([Internationalisation](i18n.md)) |

<!-- table-foot: Liste non exhaustive&nbsp;: `docs/design.md` §8 («&nbsp;What was deliberately left out&nbsp;») en est l’inventaire plus complet. -->
