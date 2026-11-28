---
source_sha256: 38b2745b3e9c1e93575660937aec807790dc13d9a4938710a2328faeae6eaf6f
---
# Configuration

## Configuration et variables d’environnement

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

`Cybertrain::Config` lit d’abord l’environnement&nbsp;; `config/app.rb` a le
dernier mot&nbsp;:

| Variable | Attribut | Par défaut |
| --- | --- | --- |
| `CYBERTRAIN_ENV` | `env` | `"development"`&nbsp;; `"production"` dans un binaire issu de `cybertrain build` (aussi `"test"`). Définissez la variable, pas `c.env`&nbsp;: `database_path`, `session_secure` et la valeur par défaut de `mail_delivery_method` en sont dérivés avant que `config/app.rb` s’exécute |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `DATABASE_URL` | `database_url` | `""`&nbsp;; MySQL seulement&nbsp;: la base à laquelle se connecte une application compilée avec `cybertrain/mysql`, `mysql://USER:PASSWORD@HOST:3306/NAME` (voir [MySQL](#mysql))&nbsp;; le démarrage échoue si elle est vide ou mal formée |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | requis en production&nbsp;; en dev/test, un secret est généré automatiquement dans `tmp/secret_key` |
| `CYBERTRAIN_ENCRYPTION_KEY` | `encryption_key` | `""`&nbsp;; 64 caractères hexadécimaux (`cybertrain secret --hex`), la clé des colonnes qu’un modèle chiffre avec `encrypts`. Le démarrage échoue si elle est mal formée, ou vide dès qu’un modèle déclare `encrypts` (voir [Colonnes chiffrées](models.md#encrypted-columns)) |
| `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` | `encryption_keys_previous` | `[]`&nbsp;; d’anciennes clés séparées par des virgules, essayées pour le déchiffrement seulement, pour changer de clé en réenregistrant les enregistrements&nbsp;; une entrée mal formée arrête le démarrage |
| `SPINEL_WORKERS` | `workers` | `1`&nbsp;; le serveur de développement l’ignore et tourne toujours avec un seul worker ([pourquoi](template-language.md#file-resolution-enginerb)) |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`&nbsp;; `0.0.0.0` écoute sur toutes les interfaces (conteneurs) |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | Le développement accepte `localhost`, `127.0.0.1`, `[::1]`&nbsp;; des noms d’hôte exacts séparés par des virgules étendent cette liste (sans schéma, port ni joker). Les autres hôtes reçoivent une 403 avant les fichiers statiques, les sessions, le routage ou les diagnostics. C’est distinct de l’adresse d’écoute&nbsp;; la production et le test n’appliquent cette liste qu’une fois que `CYBERTRAIN_HOSTS` y active le contrôle |
| `CYBERTRAIN_HOSTS` | `hosts_from_env` (ajouté à `allowed_hosts`) | `[]`&nbsp;; des noms d’hôte exacts séparés par des virgules (une adresse IPv6 entre crochets&nbsp;; sans schéma, chemin, port ni joker, sinon le démarrage échoue), ajoutés après les noms du loopback dans tous les environnements. Définis, ils activent le contrôle des hôtes en production et en test aussi&nbsp;: un autre `Host` reçoit une 403 `Blocked host` et est journalisé. Un GET ou HEAD du chemin de santé passe quel que soit le Host (voir [Hôtes](requests.md#content-security-policy-force_ssl-and-hosts)) |
| `CYBERTRAIN_FORCE_SSL` | `force_ssl` | `false`&nbsp;; `1` ou `true` redirige http vers https (301 pour GET et HEAD, 307 sinon&nbsp;; d’après `X-Forwarded-Proto` derrière un proxy), envoie `Strict-Transport-Security: max-age=63072000; includeSubDomains` et écrit tous les cookies `Secure`&nbsp;; le chemin de santé n’est jamais redirigé. Toute autre valeur que `1`, `true`, `0`, `false` ou vide arrête le démarrage. Derrière un proxy, définissez aussi `CYBERTRAIN_TRUSTED_PROXY` ou `CYBERTRAIN_TRUSTED_PROXIES`, sinon les URL que l’application construit restent en http |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`&nbsp;; aussi `Strict` ou `None` (`None` ajoute toujours `Secure`)&nbsp;; toute autre valeur arrête le serveur au démarrage |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`&nbsp;; `1` ou `true` ajoute `Partitioned` (et `Secure`) |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`&nbsp;; `1` ou `true` fait de `request.client_ip` (ce que compte `rate_limit`) la dernière adresse de `X-Forwarded-For` d’une connexion venant du loopback, pour un reverse proxy sur le même hôte (voir [Limitation du débit](requests.md#rate-limiting-and-the-client-address))&nbsp;; raccourci de `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`&nbsp;; des adresses IPv4/IPv6 ou des CIDR séparés par des virgules (`172.16.0.0/12,10.0.0.0/8`) dont les connexions ont leur `request.client_ip` tiré de la dernière adresse de `X-Forwarded-For`, pour un proxy atteint par un réseau, comme kamal-proxy dans son conteneur&nbsp;; une entrée invalide arrête le serveur au démarrage |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`&nbsp;: la plus grande page que donne `params.page_number` et qu’accepte `Relation#page` (voir [Pagination](models.md#pagination))&nbsp;; une valeur qui n’est pas un nombre d’au plus 18 chiffres, ou inférieure à 1, donne la valeur par défaut |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`&nbsp;; des noms séparés par des virgules remplacent la liste. Un paramètre dont le nom contient l’un d’eux (sans tenir compte de la casse ASCII&nbsp;: `password` correspond aussi à `user[password]`) voit sa valeur écrite `[FILTERED]` dans le journal des requêtes et sur la page d’erreur de développement&nbsp;; `[]` dans `config/app.rb` désactive ce filtrage |
| `CYBERTRAIN_LOG_LEVEL` | `log_level` | `:info`&nbsp;: le niveau le moins important écrit, `debug`, `info`, `warn`, `error`, `fatal` ou `none` (en majuscules ou minuscules&nbsp;; `none` coupe le journal des requêtes et écrit toujours les lignes d’erreur)&nbsp;; toute autre valeur arrête le démarrage (voir [Journaux](logs-and-errors.md#logs)). `cybertrain test` utilise `:none` sauf si `config/app.rb` le fixe |
| `CYBERTRAIN_LOG_FORMAT` | `log_format` | `:text`&nbsp;; `json` écrit un objet JSON par ligne, pour un collecteur de journaux&nbsp;; toute autre valeur arrête le démarrage. `cybertrain test` garde des lignes de texte sauf si `config/app.rb` le fixe, quoi que dise la variable |
| `CYBERTRAIN_SENTRY_DSN` | `sentry_dsn` | `""`&nbsp;: rien n’est envoyé. Un DSN Sentry ou GlitchTip y envoie chaque rapport d’erreur (voir [Signalement des erreurs](logs-and-errors.md#error-reporting))&nbsp;; il demande `require "cybertrain/error_reporter/sentry"` (ou `require "cybertrain"`) dans `bin/<app>.rb`, faute de quoi le démarrage est refusé. Un DSN illisible arrête le démarrage en nommant la partie fautive, jamais la clé. `cybertrain test` le vide sauf si `config/app.rb` l’affecte |
| `CYBERTRAIN_ERROR_SAMPLE_RATE` | `error_sample_rate` | `1.0`&nbsp;: la part des rapports d’erreur envoyés à Sentry, de 0.0 à 1.0, écrite en chiffres avec un `.chiffres` facultatif&nbsp;; les abonnés voient chaque rapport&nbsp;; toute autre valeur arrête le démarrage |
| `CYBERTRAIN_RELEASE` | `release` | `""`&nbsp;: la version ou le commit envoyé avec chaque rapport d’erreur |
| `CYBERTRAIN_WORKER` | `worker` | `true`&nbsp;; `0` ou `false` empêche un processus `server` d’exécuter les tâches planifiées, les jobs et les flux WebSocket (voir [Rôles des processus](background-and-operations.md#process-roles))&nbsp;; `./<app> worker` et `feeds` l’ignorent |
| `CYBERTRAIN_JOB_THREADS` | `job_threads` | `3`&nbsp;: le nombre de jobs qu’un processus exécute en même temps (voir [Tâches de fond](background-and-operations.md#background-work))&nbsp;; au moins 1 |
| `CYBERTRAIN_TIME_ZONE` | `time_zone` | `"UTC"`&nbsp;: le fuseau de l’application, un nom IANA comme `Asia/Tokyo`, pour `Time.zone`, les limites des jours et des mois, `Date.current`, `l` et `time_tag` (voir [Fuseaux horaires](#time-zones))&nbsp;; un fuseau absent du zoneinfo du système arrête le démarrage |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | `time_zone` quand il n’est pas réglé&nbsp;: le fuseau dans lequel se lit une tâche `Scheduler.cron` sans `tz:`, un nom IANA (voir [Fuseaux horaires](#time-zones))&nbsp;; un fuseau absent du zoneinfo du système arrête le démarrage |
| `CYBERTRAIN_JOBS_PAGE_PER_PAGE` | `jobs_page_per_page` | `50`&nbsp;: lignes par liste sur la [page des jobs](background-and-operations.md#the-jobs-page-and-the-jobs-command)&nbsp;; au moins 1 |
| `CYBERTRAIN_CACHE_PRUNE_INTERVAL` | `cache_prune_interval` | `300`&nbsp;: secondes entre deux purges des lignes expirées du [cache](background-and-operations.md#the-cache-store)&nbsp;; au moins 1. Avec `cybertrain/jobs`, il est lu une seule fois, quand la purge planifiée est enregistrée, c’est-à-dire au chargement des deux et avant que `config/app.rb` s’exécute&nbsp;: définissez donc la variable. Sans les jobs, il est lu à chaque écriture dans le cache, et `c.cache_prune_interval` fonctionne aussi |
| `CYBERTRAIN_FEED_STATUS_INTERVAL` | `feed_status_interval` | `10`&nbsp;: secondes entre deux écritures de la ligne d’état de chaque flux WebSocket (voir [Santé des flux](realtime.md#feed-health))&nbsp;; au moins 1 |
| `CYBERTRAIN_FEED_RESTART_LIMIT` | `feed_restart_limit` | `10`&nbsp;: redémarrages du thread d’un flux dans la fenêtre au-delà desquels un processus `feeds` se termine avec le statut 1 quand le flux meurt encore (voir [Consommer des flux WebSocket](external-services.md#consuming-websocket-feeds))&nbsp;; au moins 1 |
| `CYBERTRAIN_FEED_RESTART_WINDOW` | `feed_restart_window` | `600`&nbsp;: cette fenêtre, en secondes&nbsp;; au moins 1 |
| `CYBERTRAIN_STREAM_PATH` | `stream_path` | `"/cybertrain/stream"`&nbsp;: le point d’entrée temps réel (voir [Temps réel](realtime.md#limits-and-settings))&nbsp;; une valeur vide désactive les flux&nbsp;; il doit commencer par `/` et différer de `health_path` |
| `CYBERTRAIN_REUSE_PORT` | `reuse_port` | `false`&nbsp;; `1` ou `true` lie le port avec `SO_REUSEPORT`, de sorte que plusieurs processus peuvent écouter sur un même port et que, sous Linux, le noyau répartit les connexions entre eux (ignoré en développement&nbsp;; voir [Running several processes](../deploy.en.md#running-several-processes)). Mettez `CYBERTRAIN_WORKER=0` dans tous les processus sauf un |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`&nbsp;; le chemin du contrôle de santé intégré (voir [Exploitation](background-and-operations.md#operations-backups-vacuum-health-check))&nbsp;; une valeur vide le désactive&nbsp;; une valeur sans `/` initial arrête le serveur au démarrage. `health_worker_stale` (300&nbsp;s) se règle dans `config/app.rb` |
| `CYBERTRAIN_HEALTH_FEEDS` | `health_feeds` | `true`&nbsp;: le contrôle de santé répond aussi `503 feed stale` pour un flux WebSocket qui a cessé de signaler son état ou s’est tu (voir [Santé des flux](realtime.md#feed-health))&nbsp;; `0` ou `false` désactive cette partie |
| `CYBERTRAIN_HEALTH_FEED_STALE` | `health_feed_stale` | `180`&nbsp;: secondes de silence d’un flux, ou de son processus qui n’écrit plus son état, avant `503 feed stale`&nbsp;; au moins 1, et plus que `feed_status_interval` tant que `health_feeds` est actif (le démarrage le refuse sinon) |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`&nbsp;; `1` ou `true` permet à `Cybertrain::HttpClient` de se connecter au loopback, aux adresses privées et aux autres adresses non publiques (voir [HTTP sortant](external-services.md#outbound-http)) |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`&nbsp;; le serveur SMTP par lequel envoie `Cybertrain::Mailer` (voir [Envoyer des e-mails](external-services.md#sending-e-mail)) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`&nbsp;: le port du mode, 587 pour `starttls`, 465 pour `tls`, 25 pour `none`&nbsp;; toute valeur hors de 1 à 65535 vaut 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`&nbsp;: pas d’AUTH&nbsp;; s’il est défini, le mailer s’authentifie avec AUTH PLAIN |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`&nbsp;; un secret, jamais journalisé, jamais dans la bannière de démarrage ni dans un message d’erreur |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`&nbsp;: l’expéditeur qu’utilise `Mailer.deliver` quand `from:` n’est pas fourni |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`&nbsp;; aussi `tls` (TLS implicite) ou `none` (texte en clair, identifiants vers le loopback uniquement)&nbsp;; les deux modes TLS demandent `require "cybertrain/net/tls"` dans `bin/<app>.rb`&nbsp;: `require "cybertrain"` le charge, `cybertrain/core` et `cybertrain/mailer` non ([Sous-systèmes](how-it-works.md#subsystems)) |
| `CYBERTRAIN_MAIL_DELIVERY_METHOD` | `mail_delivery_method` | `:test` dans l’environnement de test, `:smtp` dans tous les autres&nbsp;: `:test` garde chaque courriel dans `Cybertrain::Mailer.deliveries` au lieu de l’envoyer ([Tester les courriels](testing.md#testing-mail))&nbsp;; hors de l’environnement de test il démarre avec un avertissement et n’envoie rien&nbsp;; toute autre valeur arrête le démarrage&nbsp;; `cybertrain test` utilise `:test` sauf si `config/app.rb` le règle, quoi que dise la variable. |
| `CYBERTRAIN_TEST_DATABASE` | — | `""`&nbsp;: le fichier que `cybertrain test` supprime, migre et sur lequel il exécute les tests, à la place de `storage/test.sqlite3`&nbsp;; un chemin de fichier (pas `:memory:` ni une URI `file:`). Un fichier existant n’est supprimé que si `cybertrain test` l’a créé (il marque ses bases), s’il est le `storage/test.sqlite3` de cette application ou s’il est vide&nbsp;; tout autre, et la base de développement ou de production, est refusé avec le code de sortie 2 sans rien supprimer ([Exécuter les tests](testing.md#running-the-tests)) |
| `CYBERTRAIN_I18N_DEFAULT_LOCALE` | `i18n_default_locale` | `:en`&nbsp;: la locale dans laquelle commence chaque requête, un nom comme `ja` ou `pt-BR` (voir [Locales](#locales))&nbsp;; toute autre valeur arrête le démarrage |
| `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS` | `auth_lockout_attempts` | `10`&nbsp;: mauvais mots de passe avant qu’un compte soit verrouillé&nbsp;; `0` désactive le verrouillage (voir [Réglages de l’authentification](#authentication-settings)) |
| `CYBERTRAIN_AUTH_LOCKOUT_PERIOD` | `auth_lockout_period` | `3600`&nbsp;: durée d’un verrouillage en secondes&nbsp;; au moins 1 |
| `CYBERTRAIN_AUTH_REMEMBER_FOR` | `auth_remember_for` | `2592000` (30 jours)&nbsp;: durée en secondes d’une connexion «&nbsp;rester connecté&nbsp;»&nbsp;; au moins 1 |
| `CYBERTRAIN_AUTH_IDLE_TIMEOUT` | `auth_idle_timeout` | `604800` (7 jours)&nbsp;: secondes sans requête après lesquelles une connexion prend fin&nbsp;; `0` le désactive |

`cybertrain test` donne à ses tests des valeurs qui lui sont propres pour
certains de ces réglages, sauf si `config/app.rb` les affecte. Outre les quatre
lignes qui le disent, `force_ssl` est désactivé et `CYBERTRAIN_HOSTS` est vidé
quoi que disent les variables, `csrf` est désactivé, `upload_root` vaut
`tmp/test_uploads`, et `smtp_from` vaut `"from@example.com"` sauf si
`CYBERTRAIN_SMTP_FROM` est défini
([Lancer les tests](testing.md#running-the-tests)).

N’utilisez `None` (avec `CYBERTRAIN_SESSION_PARTITIONED=1`) que pour une
application affichée dans un cadre d’un autre site&nbsp;; le navigateur doit
atteindre l’application en HTTPS.

Les autres attributs n’ont pas de variable&nbsp;; `config/app.rb` les définit&nbsp;:

| Attribut | Valeur par défaut | Signification |
| --- | --- | --- |
| `views_root` | `"app/views"` | D’où les templates sont lus en développement et en test&nbsp;; un binaire construit utilise ceux qu’il embarque |
| `public_root` | `"public"` | Le répertoire des fichiers statiques, et là où se trouvent les pages d’erreur `public/<status>.html` |
| `layout` | `"layouts/application"` | Le layout dans lequel chaque page est rendue&nbsp;; ignoré quand le fichier n’existe pas |
| `secret_key_path` | `"tmp/secret_key"` | Où le développement et les tests conservent leur secret généré |
| `log_tags` | `[:request_id]` | Les étiquettes de la requête sur chaque ligne de journal&nbsp;: `:remote_ip` ajoute l’adresse du client, `[]` n’en montre aucune, toute autre valeur arrête le démarrage ([Identifiants de requête](logs-and-errors.md#request-ids)) |
| `session_cookie_name` | `"_cybertrain_session"` | Le nom du cookie de session |
| `session_max_age` | `1209600` (2 semaines) | Le `Max-Age` du cookie de session, en secondes&nbsp;; il repart à chaque changement de la session |
| `session_absolute_max_age` | `1209600` (2 semaines) | La durée de vie maximale d’une session en secondes, aussi souvent qu’elle serve&nbsp;: un cookie plus ancien est chargé comme une session vide. `0` supprime la limite |
| `session_secure` | `true` en production, `false` ailleurs | Marque le cookie de session `Secure`&nbsp;; `SameSite=None` et `Partitioned` ajoutent `Secure` de toute façon |
| `pool_size` | `4` | Connexions SQLite dans le pool |
| `static_files` | `true` | Si `public/` est servi&nbsp;; désactivez-le quand un reverse proxy le sert |
| `csrf` | `true` | Si une requête autre que GET doit porter le jeton CSRF (403 sans lui) |
| `csrf_exempt_prefixes` | `[]` | Des préfixes de chemin dont les requêtes autres que GET sautent la vérification CSRF (voir plus bas) |
| `max_body_bytes` | `10485760` (10&nbsp;Mio) | Un corps de requête plus long, tel qu’envoyé, reçoit une 413 avant d’être lu&nbsp;; augmentez-le pour les gros envois de fichiers. La taille décompressée d’un corps gzip est bornée séparément, par `request.decoded_body(limit)` |
| `body_timeout` | `120` | Secondes que peut prendre tout le corps de la requête, à partir de la fin de l’en-tête&nbsp;; au-delà, la requête reçoit une 408 et la connexion est fermée, si régulièrement que le client envoie (slowloris). Augmentez-le pour de gros envois sur des liaisons lentes |
| `max_connections` | `1024` | Connexions ouvertes à la fois, connexions de flux comprises&nbsp;; la suivante reçoit une 503 et est fermée. Chaque connexion tient un descripteur de fichier&nbsp;: gardez-le nettement sous la limite du processus (`ulimit -n`), en laissant de la place pour le socket d’écoute, les journaux, la base de données et les autres fichiers ouverts&nbsp;; une fois la limite atteinte, le serveur ne peut même plus accepter une connexion pour répondre 503 |
| `max_render_depth` | `12` | Rendus ouverts à la fois, la page et ses partiels&nbsp;: la page est à la profondeur 1, les partiels s’imbriquent donc sur 11 niveaux (le layout est rendu après la page et ne s’imbrique pas). Au-delà, c’est une erreur de template&nbsp;; au moins 1, sinon le démarrage échoue |
| `max_upload_bytes` | `5242880` (5&nbsp;Mio) | La taille maximale d’un fichier envoyé&nbsp;; ne doit pas dépasser `max_body_bytes` |
| `max_multipart_parts` | `128` | Le nombre maximal de parties d’un corps multipart, champs texte compris&nbsp;; au plus 4096 |
| `upload_root` | `"storage/uploads"` | Où écrit `Cybertrain::BlobStore`&nbsp;; créé au premier envoi, pas au démarrage |

**Préfixes exemptés de CSRF&nbsp;:** `csrf_exempt_prefixes` sert à un point
d’accès que des programmes appellent avec un identifiant qui leur est propre,
comme `"/api/"`. Chaque préfixe doit commencer et finir par `/` et ne pas être
`/` seul, sinon le démarrage échoue. Il est comparé au chemin tel qu’envoyé,
donc une graphie encodée en pourcent reste vérifiée. Aucune autre route ne doit
correspondre à un chemin sous ce préfixe, et le contrôleur exempté ne doit pas
compter sur la session pour l’authentification, puisque la session y est tout
de même chargée.

**Jobs et flux&nbsp;:** en plus des variables ci-dessus, `config/app.rb` règle
`scheduler_interval` (1&nbsp;s, le tick du scheduler), `job_poll_interval`
(1&nbsp;s, l’attente d’un thread de jobs inoccupé), `job_max_attempts` (5), `job_heartbeat_interval`
(30&nbsp;s), `job_heartbeat_stale` (300&nbsp;s, plus que l’intervalle),
`job_drain_timeout` (10&nbsp;s, le temps que `SIGTERM` attend les jobs en
cours) et `scheduler_lease_ttl` (30&nbsp;s, au moins deux fois
`scheduler_interval`), ainsi que les réglages des flux `stream_poll_ms`,
`stream_retention`, `stream_ping_interval`, `stream_max_connections`,
`stream_max_message` et `stream_max_backlog` ([Limites et
réglages](realtime.md#limits-and-settings)). Une valeur hors limites arrête
le démarrage avec un message qui la nomme.

**En-têtes de sécurité&nbsp;:** chaque réponse qu’écrit le serveur (actions,
middleware des fichiers statiques, pages d’erreur et page de diagnostic de
développement, les 400/411/413/500 propres au serveur, et HEAD) porte
`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` et
`Permissions-Policy: camera=(), microphone=(), geolocation=()`, sauf si la
réponse définit déjà un en-tête de ce nom (quelle que soit la casse)&nbsp;:
`Response#to_http` les ajoute après les en-têtes propres à la réponse et
seulement s’ils manquent, donc
`response.set_header("X-Frame-Options", "DENY")` dans une action envoie
exactement votre valeur, une seule fois. `c.permissions_policy` remplace la
valeur du troisième (`"camera=(), microphone=(), geolocation=(self)"`), `""`
n’en envoie aucun, et un CR ou un LF dedans arrête le démarrage. Il n’y a
délibérément pas de réglage `Config` pour désactiver les deux premiers dans
toute l’application&nbsp;; un widget
intégrable remplace l’en-tête sur ses propres réponses (un en-tête
`Content-Security-Policy: frame-ancestors ...` l’emporte sur `X-Frame-Options`
dans les navigateurs actuels). À cause de `nosniff`, les navigateurs prennent
`Content-Type` au pied de la lettre&nbsp;: le middleware des fichiers statiques
connaît les extensions habituelles de `public/` (html, css, js/mjs, images dont
webp et avif, polices, wasm, pdf, audio et vidéo, json, csv, xml), et tout le
reste est servi en `application/octet-stream`, c’est-à-dire en
téléchargement&nbsp;; ajoutez l’extension à `Cybertrain::Static::EXTENSIONS` si
une application en a besoin d’une autre affichée directement. Un reverse proxy
qui sert lui-même `public/` contourne ces en-têtes (voir
[docs/deploy.en.md](../deploy.en.md)). `Cybertrain::Test::Client` appelle
l’application dans le même processus et ne sérialise jamais la réponse&nbsp;: il
ne montre donc pas ces valeurs par défaut&nbsp;; vérifiez-les sur
`response.to_http`.

**Content Security Policy&nbsp;:** désactivée par défaut, comme dans Rails&nbsp;;
`cybertrain new` écrit le bloc ci-dessous en commentaire dans `config/app.rb`.
`c.content_security_policy do |p| ... end` déclare la politique (une méthode
par directive, `p.script_src :self, "https://cdn.jsdelivr.net"`&nbsp;; un second
appel complète la même politique), `c.content_security_policy_nonce_directives`
(`[]`) nomme les directives qui reçoivent le nonce de la requête (un nom qui
n’est pas une directive arrête le démarrage), et
`c.content_security_policy_report_only` (`false`) envoie l’en-tête sous la forme
`Content-Security-Policy-Report-Only`. Un contrôleur déclare sa propre copie
avec `content_security_policy do |p|`&nbsp;; voir
[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts).

**Paramètres filtrés&nbsp;:** la ligne `Started GET "/login?..."` du journal des
requêtes et la page d’erreur de développement (sa ligne de requête, et son
affichage des params et d’un corps JSON) montrent la valeur de chaque paramètre
nommé dans `config.filter_parameters` sous la forme `[FILTERED]`, comme le fait
le `filter_parameters` de Rails, de sorte qu’un `?token=` dans une URL ou un mot
de passe posté à un formulaire qui échoue n’apparaît ni dans le journal des
requêtes du framework ni sur la page d’erreur de développement. Seules les
valeurs sont remplacées&nbsp;: le reste de la chaîne de requête est journalisé
tel qu’envoyé (caractères de contrôle échappés). La liste compare par
sous-chaîne, sans tenir compte de la casse&nbsp;; étendez-la dans
`config/app.rb` (`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`)
ou remplacez-la avec `CYBERTRAIN_FILTER_PARAMETERS`. Les valeurs qu’une action
journalise elle-même ne sont pas filtrées&nbsp;; interrogez-y
`Cybertrain::ParameterFilter.filter?(name)` ou
`ParameterFilter.filter_query(text)`.

**Chemins filtrés&nbsp;:** un secret dans le chemin lui-même (le jeton d’un lien
de partage dans `/results/<token>`) n’a pas de nom de paramètre par lequel le
filtrer&nbsp;; listez donc le préfixe qu’il suit&nbsp;: avec
`c.filter_path_prefixes = ["/results/"]`, tout le segment après `/results/`
est écrit `[FILTERED]` partout où le framework écrit le chemin d’une
requête&nbsp;: la ligne `Started` du journal des requêtes, une ligne
`Blocked host`, la requête d’un rapport d’erreur et la page d’erreur de
développement. Un préfixe est comparé au chemin tel qu’envoyé, depuis son
premier octet, et doit commencer et finir par `/` sans être `/` seul, sinon le
démarrage échoue. La liste est vide par défaut&nbsp;; les jetons signés du
framework (celui d’un lien de réinitialisation de mot de passe) sont masqués
d’après leur forme sans elle. Un proxy inverse placé devant tient son propre
journal&nbsp;: masquez-y le chemin aussi.

**Déploiement&nbsp;:** `cybertrain build` produit `dist/`&nbsp;: le binaire
`dist/NAME` avec les vues intégrées, `dist/public/` (ressources statiques, ou
laissez un reverse proxy le servir), ainsi que `dist/storage/` (le fichier
SQLite par défaut) et `dist/tmp/`. Lancez-le depuis `dist/` avec
`CYBERTRAIN_SECRET_KEY_BASE` défini&nbsp;; il est en production sauf si
`CYBERTRAIN_ENV` indique autre chose, et `./NAME
migrate` applique les migrations compilées dans le binaire. Le binaire ne parle
que du HTTP/1.1 simple&nbsp;; placez nginx/Caddy devant pour le TLS et HTTP/2
(le cookie de session est `Secure` en production, servez donc l’application en
HTTPS). En production, une exception renvoie une 500, et une réponse d’erreur
brute (la 404 en texte brut du routeur, `head :not_found`, `render plain:`) est
remplacée par `public/<status>.html` quand ce fichier existe&nbsp;; les erreurs
qu’une action rend en HTML ou en JSON passent telles quelles. `SIGTERM` cesse
d’accepter des connexions, laisse se terminer les requêtes déjà en cours
(auxquelles il est répondu avec `Connection: close`&nbsp;; les connexions
keep-alive inactives sont fermées immédiatement) et quitte quand elles sont
terminées, ou après le `drain_timeout` du serveur (10&nbsp;s). La boucle de
surveillance et de recompilation ne tourne jamais en production.
[docs/deploy.en.md](../deploy.en.md) (en japonais&nbsp;:
[docs/deploy.md](../deploy.md)) en décrit tout le parcours&nbsp;:
`cybertrain new`, un serveur Ubuntu, systemd, Caddy avec HTTPS, les
redéploiements, les retours arrière et les sauvegardes.

**Kamal&nbsp;:** `cybertrain new` écrit aussi ce dont
[Kamal 2](https://kamal-deploy.org) a besoin&nbsp;: un `Dockerfile` qui exécute
`cybertrain setup` et `cybertrain build` dans une étape de build Ubuntu et
copie `dist/` dans une étape allégée de la même version (migration au
démarrage, puis service sur `0.0.0.0:3000`, avec `SPINEL_GC_FULL_INTERVAL=8`
défini, une variable du ramasse-miettes de Spinel que
[docs/deploy.en.md](../deploy.en.md) explique et définit aussi pour systemd),
un `.dockerignore`,
`config/deploy.yml` (kamal-proxy avec Let’s Encrypt en façade, le contrôle de
santé sur `public/up.html`, le fichier SQLite sur un volume en
`/app/storage`) et `.kamal/secrets` (`KAMAL_REGISTRY_PASSWORD` et
`CYBERTRAIN_SECRET_KEY_BASE` tirés de l’environnement). Renseignez les valeurs
marquées `CHANGE ME`, committez, puis lancez `kamal setup`&nbsp;;
[docs/deploy-kamal.md](../deploy-kamal.md) donne les détails (partie 8 du
tutoriel de déploiement).
[examples/blog](../../examples/blog#deploying-with-kamal) embarque la même
configuration, construite avec le framework de cette copie du dépôt.

### Réglages de l’application

Les réglages propres à une application (une URL de base publique, un
interrupteur de fonctionnalité, un intervalle, un hôte SMTP) sont déclarés sur
le même `Config`, avec un type, une variable d’environnement et une valeur par
défaut&nbsp;:

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
  c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
  c.setting_bool :worker, env: "MYAPP_WORKER", default: true
  c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
end

Cybertrain.config.string_setting(:base_url)
Cybertrain.config.bool_setting(:worker)
Cybertrain.config.int_setting(:prune_interval)
```

Chaque valeur est lue une seule fois, quand `config/app.rb` s’exécute au
démarrage. Une variable vide ou non définie signifie la valeur par défaut. Un
booléen accepte `1`/`true` ou `0`/`false`&nbsp;; un entier accepte des chiffres
décimaux (avec un `-` initial facultatif) compris dans `min..max` (tous deux
facultatifs). Toute autre valeur se rabat sur la valeur par défaut et
journalise une ligne `WARN` qui le signale (une ligne de texte quel que soit
`log_format`&nbsp;: `config/app.rb` est encore en cours). Lire un nom non déclaré, ou
déclaré avec un autre type, lève `ArgumentError`, tout comme déclarer deux fois
un même nom. Les tests changent une valeur avec `set_string_setting`,
`set_int_setting` et `set_bool_setting`. `./NAME help` liste chaque réglage
déclaré avec sa variable et sa valeur par défaut, et la bannière de démarrage
affiche les valeurs courantes (`=> Settings: base_url="" worker=true ...`)&nbsp;;
un réglage `secret: true` n’apparaît dans les deux que par son nom, sous la
forme `[FILTERED]`. Il n’y a pas d’accesseur `Cybertrain.config.base_url`&nbsp;:
un réglage se déclare par un appel sur l’objet de configuration, et Spinel
compile `define_method` dans un corps de classe mais refuse celui qu’appelle
une méthode d’instance&nbsp;; les lecteurs sont donc des méthodes typées qui
prennent le nom.

### Locales

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.i18n_default_locale = :en               # ou CYBERTRAIN_I18N_DEFAULT_LOCALE
  c.i18n_available_locales = [:en, :ja]
  c.i18n_raise_on_missing = true if c.test?
end
```

`i18n_available_locales` (`[]`, la seule locale par défaut) liste les locales qu’acceptent `I18n.locale=` et `I18n.locale_available?`&nbsp;; le démarrage refuse une entrée qui n’est pas un nom de locale, et une locale par défaut absente d’une liste non vide. `i18n_raise_on_missing` (`false`) fait lever `I18n::MissingTranslationData` à une traduction manquante au lieu de répondre un marqueur (développement et test) ou la clé rendue lisible (production). Les dictionnaires et la locale par requête sont dans [Internationalisation](i18n.md).

### Réglages de l’authentification

Le code qu’écrit `cybertrain generate authentication` lit quatre réglages (les variables sont dans le tableau ci-dessus)&nbsp;: `auth_lockout_attempts` (10) et `auth_lockout_period` (3600&nbsp;s) pour le [verrouillage](authentication.md#lockout), `auth_remember_for` (30 jours) pour une connexion «&nbsp;rester connecté&nbsp;», et `auth_idle_timeout` (7 jours) pour une connexion inutilisée ([Rester connecté](authentication.md#remember-me-and-session-limits))&nbsp;; une connexion non mémorisée dure `session_absolute_max_age` (deux semaines). Une valeur hors limites arrête le démarrage. Le générateur déclare aussi le réglage d’application `base_url`, issu de `<APP>_BASE_URL`, par lequel commencent les liens des courriels&nbsp;; définissez-le, en https, partout où l’application est servie ([Liens dans les courriels](authentication.md#links-in-mails)).

## MySQL

Une application est compilée pour une seule base de données&nbsp;: SQLite, par défaut, ou MySQL 8.0 (`docs/design.md`, D96&nbsp;; la CI teste la 8.0.46, et encore aucune version plus récente). L’entrée `cybertrain` que requièrent `bin/<app>.rb` et `bin/db.rb` la choisit à la compilation de l’application (gen lit celle de `bin/<app>.rb`&nbsp;; gardez les deux identiques)&nbsp;; rien ne la change à l’exécution&nbsp;:

```ruby bin/<app>.rb (excerpt)
require "cybertrain/mysql"   # tous les sous-systèmes ; "cybertrain/core/mysql" est le cœur seul
```

`cybertrain new NAME --database=mysql` écrit cette ligne, explique `DATABASE_URL` dans `config/app.rb` et `.env.example` (qui en contient deux lignes en commentaire, la base de développement et la base `_test` dont `cybertrain test` a besoin, chacune avec `?ssl_mode=disabled` pour un serveur local), la passe comme secret dans `config/deploy.yml` et `.kamal/secrets`, et écrit un workflow de CI qui lance les tests contre un service MySQL. Les étapes suivantes que la commande affiche exportent la `DATABASE_URL` de développement et lancent `cybertrain db create` avant `cybertrain db migrate`. Elle refuse `--database` donné deux fois et toute option qu’elle n’a pas (`-d mysql`, `--databse=mysql`) avant d’écrire quoi que ce soit. Les modèles, les migrations et les tests sont les mêmes sur les deux&nbsp;; [Modèles et base de données](models.md#mysql) liste ce que MySQL répond autrement.

Une application créée pour SQLite passe à MySQL en changeant cette ligne dans les deux fichiers (ses données restent dans le fichier SQLite), puis&nbsp;:

- avec l’authentification, en relançant `cybertrain generate authentication` avec les options de sa génération (`--invite-only`, `--confirmable`) et `--force`. Il réécrit les fichiers dont la forme MySQL diffère&nbsp;: `app/commands/user_command.rb` et `test/integration/first_run_test.rb` (ils se connectent à `database_url`, pas à `database_path`), `app/models/user.rb` (l’UPDATE du verrouillage, dans l’ordre d’affectation de MySQL, et avec `--confirmable` le doublon de la confirmation, rattrapé par sa classe, `Cybertrain::DB::UniqueViolation`), `test/controllers/accounts_controller_test.rb` (le DDL de sa table et la classe d’erreur de la suppression refusée), avec `--invite-only` `app/controllers/setup_controller.rb` (la vérification du premier utilisateur, une lecture verrouillante&nbsp;: [Modèles et base de données](models.md#mysql)), et avec `--confirmable` `test/controllers/confirmations_controller_test.rb` (son déclencheur de course). Lisez le diff de ceux que vous avez modifiés depuis&nbsp;;
- en faisant dans le `Dockerfile`, `config/deploy.yml`, `.kamal/secrets` et `.github/workflows/ci.yml` les modifications que fait `new --database=mysql`&nbsp;: `DATABASE_URL` passée comme secret, un service MySQL dans la CI, et le rôle worker laissé en commentaire (plus bas).

La base de données est celle que nomme `DATABASE_URL` (`database_url`, lue avant l’exécution de `config/app.rb`)&nbsp;:

```shell
export DATABASE_URL='mysql://app:PASSWORD@db.internal:3306/shop_production'
```

- `USER`, `PASSWORD` et le nom de la base sont décodés (`%40` est `@`). Les paramètres après `?` sont `ssl_mode`, `connect_timeout` (5 secondes par défaut), `read_timeout` et `write_timeout` (30 secondes chacun, pour une attente du serveur, pas pour une requête entière)&nbsp;; tout autre nom arrête le démarrage. Aucun message, aucune ligne de journal ni aucun `inspect` ne montre le mot de passe&nbsp;: les lignes de journal du pool et `inspect` nomment la base par l’URL sans lui.
- Une instruction qui n’envoie rien avant d’avoir fini (un `ALTER TABLE` ou un `CREATE INDEX` sur une grande table, un gros tri) attend une seule fois pour toute son exécution&nbsp;: `read_timeout` est alors la limite de l’instruction entière. Une fois passé, la connexion est fermée avec `Cybertrain::DB::ConnectionLost`, mais le serveur n’est pas prié de s’arrêter et termine l’instruction. `db migrate`, `rollback`, `status` et le dump du schéma attendent donc jusqu’à un jour (`read_timeout=86400`, la plus grande valeur) sauf si `DATABASE_URL` nomme un `read_timeout`&nbsp;: le DDL de MySQL n’est pas annulé, si bien qu’une migration coupée ainsi garderait son changement sans que sa version soit enregistrée, et le `db migrate` suivant échouerait (`Duplicate key name`).
- Ouvrir une connexion (au démarrage, et quand le pool en rouvre une après une connexion perdue) commence par chercher le nom d’hôte avec le résolveur du système, qui bloque son worker du système jusqu’à sa réponse&nbsp;: ce temps compte dans `connect_timeout`, mais un résolveur lent n’est pas interrompu, et avec `SPINEL_WORKERS=1` tout le serveur l’attend. Un hôte donné par son adresse IP n’est pas cherché.
- Une connexion que le serveur a terminée pendant qu’elle attendait dans le pool (un redémarrage, `wait_timeout`, une bascule) est découverte par la première instruction après sa sortie du pool et rouverte, et cette instruction, hors transaction, est renvoyée quand la connexion s’est terminée avant le premier octet de sa réponse. Un serveur qui l’a exécutée puis a perdu la session se présente de la même façon, tout comme une connexion que quelqu’un sur le chemin réseau coupe exprès, avec `ssl_mode=verify` aussi (TLS cache les octets, pas la fin de la connexion)&nbsp;: cette première instruction peut donc s’exécuter deux fois. Mettez une instruction qui ne doit pas s’exécuter deux fois (un `INSERT` sans clé unique, `UPDATE ... SET n = n + 1`) dans `DB.transaction`, qui n’est jamais renvoyé. Après une expiration, d’une instruction ou du ping qui suit une erreur dans une transaction, la connexion est fermée et plus jamais utilisée (sa réponse tardive serait lue comme celle de l’instruction suivante), et une transaction perdue avec sa connexion compte comme annulée.
- Gardez le mot de passe dans l’environnement ou les secrets du déploiement (`.kamal/secrets`), jamais dans `config/app.rb` ni dans le dépôt&nbsp;: le binaire ne contient aucun mot de passe.
- `ssl_mode=verify`, par défaut, se connecte en TLS et vérifie le certificat du serveur et son nom d’hôte. `ssl_mode=disabled` se connecte sans TLS, et seulement à `localhost`, une adresse de boucle locale, une adresse privée (10/8, 172.16/12, 192.168/16) ou une adresse IPv6 locale unique écrite dans l’URL&nbsp;; tout autre hôte est refusé. Aucun mode ne chiffre sans vérifier le certificat.
- Sans TLS, le `caching_sha2_password` par défaut de MySQL 8.0 ne peut pas vérifier un mot de passe que le serveur n’a pas encore en cache, et la connexion est refusée avec un message qui le dit (`caching_sha2_password full authentication needs TLS (ssl_mode=verify)`, suivi de la cause habituelle&nbsp;: la première connexion du compte depuis le démarrage du serveur, ou depuis le changement de son mot de passe ou le vidage des privilèges). Utilisez TLS, connectez-vous une fois en TLS (ou avec le client `mysql`) après chaque redémarrage du serveur, ou donnez `mysql_native_password` à un utilisateur de développement (sur MySQL 8.0&nbsp;: la 8.4 désactive ce plugin par défaut et la 9.0 le supprime).
- Les certificats sont vérifiés avec le magasin de CA du système, ou avec `SSL_CERT_FILE` (un paquet) ou `SSL_CERT_DIR` s’ils sont définis, comme toute connexion TLS du framework. Le CA d’un serveur géré va là. Le `Dockerfile` qu’écrit `new --database=mysql` installe pour cela `ca-certificates` dans son étape d’exécution (et pas `libsqlite3-0`, qu’un binaire MySQL ne lie pas)&nbsp;; un serveur dont un CA privé a signé le certificat demande le fichier de ce CA dans l’image, nommé par `SSL_CERT_FILE`. Pour Amazon RDS ou Aurora MySQL, téléchargez le paquet global et nommez-le (`SSL_CERT_FILE` remplace le fichier de paquet du système pour toutes les connexions TLS du processus, client HTTP et courrier compris&nbsp;: réunissez les deux si l’application appelle aussi d’autres services)&nbsp;:

```shell
curl -fsSLo /etc/ssl/certs/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
cat /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/rds-global-bundle.pem > /etc/ssl/certs/app-ca.pem
export SSL_CERT_FILE=/etc/ssl/certs/app-ca.pem
export DATABASE_URL='mysql://app:PASSWORD@shop.abc123.ap-northeast-1.rds.amazonaws.com:3306/shop_production'
```

Les commandes `db` prennent la même base&nbsp;: `db create` et `db drop` la créent et la suppriment (`utf8mb4`, collation `utf8mb4_0900_bin`)&nbsp;; `migrate`, `rollback`, `status`, `schema` et `schema:dump` fonctionnent comme sur SQLite&nbsp;; `dbconsole` ouvre le client `mysql` dessus, en TCP, avec le même mode TLS et le même CA, le mot de passe dans l’environnement du client, et les réglages de session de l’application (`utf8mb4`, `time_zone '+00:00'`, le `sql_mode` strict, passés par `--init-command`), si bien que `NOW()` tapé là est en UTC, comme l’application le lit&nbsp;; ce n’est vérifié qu’avec le client `mysql` d’Oracle. `db backup`, `vacuum` et `normalize` sont propres à SQLite et sortent avec le statut 2&nbsp;: utilisez `mysqldump` ou les instantanés du fournisseur.

`cybertrain test` vide et migre à nouveau la base que nomme `DATABASE_URL` avant les tests&nbsp;; il refuse donc une base dont le nom ne finit pas par `_test`, un environnement autre que `test`, et une base qui a des tables mais pas la table repère `cybertrain_test_marker`, qu’il crée dans une base vide. Il ne crée ni ne supprime jamais de base&nbsp;: créez `NAME_test` une fois (`db create` avec cette URL, ou la console du fournisseur) et exportez son URL pour les tests. Entre les tests, les tables sont vidées et les fixtures insérées à nouveau&nbsp;; sur MySQL, le vidage est validé avant l’insertion des fixtures (remettre les id à zéro est du DDL), si bien qu’une fixture qui ne se charge pas laisse les tables vides. Avec `generate authentication --confirmable`, l’utilisateur de la base de test a besoin du privilège `TRIGGER`&nbsp;: le test de confirmation crée un déclencheur.

Les tables du framework (jobs, flux, cache, baux, calendrier du planificateur, état des flux WebSocket) ne sont pas dans `db/schema.rb`, et `db migrate` ne les crée pas&nbsp;: chacune est créée à la première utilisation de sa fonctionnalité, comme sur SQLite. Sur MySQL, un CREATE TABLE dans une transaction validerait la transaction à mi-chemin&nbsp;; une première utilisation dans `DB.transaction` (un `Job.enqueue` ou un `broadcast_*` dans une transaction, sur une base qui n’a jamais eu la table) lève donc `Cybertrain::DB::Error` à la place et ne valide rien. Le processus qui exécute les jobs crée `cybertrain_jobs` à son démarrage&nbsp;; pour les autres (ou pour des jobs mis en file avant le premier démarrage de ce processus), créez les tables une fois hors transaction après le premier `migrate`, par exemple avec une commande d’exploitation&nbsp;:

```ruby bin/<app>.rb (excerpt)
Cybertrain::Main.command("install_tables", "create the framework's tables") do |argv|
  Cybertrain::Job.install!
  Cybertrain::Stream.install!
  Cybertrain::Cache.install!
  0
end
```

Une clé de `Cache` (et donc de `rate_limit`) et la clé de concurrence d’un job peuvent être aussi longues que sur SQLite. Une table qu’une version antérieure de l’adaptateur MySQL a créée les limite toujours à 255 caractères (erreur 1406 au-delà) et fonctionne sinon comme avant&nbsp;; `docs/compatibility.md` donne les instructions qui lèvent la limite.

> [!NOTE]
> Un seul processus, pour l’instant. Sur MySQL, les jobs, les flux, les baux et les tâches planifiées sont garantis dans un processus (ils répondent comme sur SQLite), pas encore entre plusieurs processus ou hôtes qui partagent la base&nbsp;: c’est l’étape 2 de la feuille de route MySQL (la prise d’un job, l’ordre d’un flux, l’horloge d’un bail), pas encore faite. Faites tourner un seul conteneur, le rôle web seul, jusqu’à ce qu’une version dise autre chose&nbsp;; sur MySQL, `generate job` et `generate authentication` laissent en commentaire le rôle worker de `config/deploy.yml`.

## Fuseaux horaires

Spinel n’embarque pas de base de données tz, et définir `ENV["TZ"]` pour
convertir une heure la change pour tous les threads du processus.
`Cybertrain::TimeZone` lit plutôt les fichiers de fuseaux du système&nbsp;:
`/usr/share/zoneinfo/<name>`, ou `$TZDIR/<name>` quand `TZDIR` est défini
(installez le paquet `tzdata` dans une image de conteneur allégée). Il analyse
les versions 1 à 4 de TZif (RFC 9636, qui a remplacé la RFC 8536), y compris la règle TZ POSIX dont dépend
un fichier «&nbsp;slim&nbsp;» après sa dernière transition, et met chaque
fuseau en cache pour toute la durée de vie du processus (copie à l’écriture,
donc les recherches depuis plusieurs workers ne prennent aucun verrou).

Tout est exprimé en secondes epoch Integer. Une *epoch locale* est une lecture
d’horloge murale comptée comme si c’était de l’UTC, de sorte que
l’arithmétique sur l’heure murale est une simple addition, et que
`TimeZone.civil_to_epoch` / `TimeZone.epoch_to_civil` passent de cette valeur à
`[year, month, day, hour, minute, second]` et inversement&nbsp;:

```ruby
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
tokyo.found?                         # false pour un nom inconnu : le fuseau se comporte alors comme UTC
tokyo.utc_offset_at(Time.now.to_i)   # => 32400
tokyo.abbreviation_at(Time.now.to_i) # => "JST"

# Le prochain 09:00 à Tokyo :
now = Time.now.to_i
today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
```

Lors d’un changement d’heure, `local_to_utc` est déterministe&nbsp;: une heure
murale qu’un saut en avant fait sauter (02:30 le jour du passage à l’heure d’été
aux États-Unis) est lue avec le décalage d’avant le saut, et tombe donc après
lui (03:30 EDT)&nbsp;; une heure murale qu’un recul répète donne l’instant le
plus tôt. `find` n’accepte qu’un nom relatif composé de `A-Za-z0-9_+-./` sans
segment vide, `.` ou `..`, de sorte qu’un nom de fuseau tiré du profil d’un
utilisateur ne peut pas atteindre un fichier hors du répertoire des
fuseaux&nbsp;; un fuseau inconnu ou mal formé n’est pas mis en cache, et `"UTC"`
n’a besoin d’aucun fichier.

### Le fuseau de l’application

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.time_zone = "Asia/Tokyo"   # ou CYBERTRAIN_TIME_ZONE ; "UTC" par défaut
end
```

`c.time_zone` prend un nom IANA (les noms propres à Rails, comme « Tokyo »,
ne sont pas lus), et le démarrage s’arrête sur un fuseau que le système
n’a pas. Les valeurs restent des instants UTC&nbsp;: une colonne,
`Time.current` et les méthodes de calendrier renvoient un `Time` UTC, et
`time.hour` est l’heure UTC. Le fuseau décide du calendrier
(`beginning_of_day` et consorts, `Date.current`&nbsp;;
[Les heures et le fuseau horaire](models.md#times-and-the-time-zone)) et de
l’affichage&nbsp;: `l(time)` et `time_tag(time)` montrent un Time dans ce
fuseau, `%z` et `%Z` compris, et le `datetime` de `time_tag` est en ISO 8601
avec le décalage du fuseau (`2026-11-12T05:00:00+09:00`).
`l(time, zone: "America/New_York")` et `time_tag(time, zone: "...")`
montrent une valeur dans un autre fuseau. Un Time au décalage 0, c’est-à-dire
tout Time que le framework fournit, est montré dans le fuseau&nbsp;; un Time qui
porte un autre décalage qui lui est propre (`time.getlocal("+05:30")`) le
garde sauf si `zone:` est donné&nbsp;; une Date est montrée telle quelle. Les
tâches cron sans `tz:` suivent aussi le fuseau, sauf si `scheduler_tz` est
réglé. Une commande enregistrée (`Main.command`), `./<app> jobs` et
`./<app> console` installent aussi le fuseau avant de s’exécuter, et
refusent un fuseau inconnu comme le démarrage, avec
`error: time_zone "Mars/Base" is not a known time zone` et le code de
sortie 1, avant d’ouvrir la base. Dans `cybertrain test`, chaque test
commence dans le fuseau configuré. ([Dates et heures](i18n.md#dates-and-times) donne les formats de
`l`.)

## Mise à jour

La liste des réglages et des valeurs par défaut qu’une version change
figure par version dans [Mise à jour](upgrading.md#notes-by-version).
