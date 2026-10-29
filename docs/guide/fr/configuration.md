---
source_sha256: 73e63b06a3c0e42694f5489b74b58f65464e506bfc88c1ba18759c91bd5771dd
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
| `CYBERTRAIN_ENV` | `env` | `"development"`&nbsp;; `"production"` dans un binaire issu de `cybertrain build` (aussi `"test"`) |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | requis en production&nbsp;; en dev/test, un secret est généré automatiquement dans `tmp/secret_key` |
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`&nbsp;; `0.0.0.0` écoute sur toutes les interfaces (conteneurs) |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | Le développement accepte `localhost`, `127.0.0.1`, `[::1]`&nbsp;; des noms d’hôte exacts séparés par des virgules étendent cette liste (sans schéma, port ni joker). Les autres hôtes reçoivent une 403 avant les fichiers statiques, les sessions, le routage ou les diagnostics. C’est distinct de l’adresse d’écoute&nbsp;; la production et le test n’appliquent pas cette protection propre au développement |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`&nbsp;; aussi `Strict` ou `None` (`None` ajoute toujours `Secure`)&nbsp;; toute autre valeur arrête le serveur au démarrage |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`&nbsp;; `1` ou `true` ajoute `Partitioned` (et `Secure`) |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`&nbsp;; `1` ou `true` fait de `request.client_ip` (ce que compte `rate_limit`) la dernière adresse de `X-Forwarded-For` d’une connexion venant du loopback, pour un reverse proxy sur le même hôte (voir [Limitation du débit](requests.md#rate-limiting-and-the-client-address))&nbsp;; raccourci de `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`&nbsp;; des adresses IPv4/IPv6 ou des CIDR séparés par des virgules (`172.16.0.0/12,10.0.0.0/8`) dont les connexions ont leur `request.client_ip` tiré de la dernière adresse de `X-Forwarded-For`, pour un proxy atteint par un réseau, comme kamal-proxy dans son conteneur&nbsp;; une entrée invalide arrête le serveur au démarrage |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`&nbsp;: la plus grande page que donne `params.page_number` et qu’accepte `Relation#page` (voir [Pagination](models.md#pagination))&nbsp;; une valeur qui n’est pas un nombre d’au plus 18 chiffres, ou inférieure à 1, donne la valeur par défaut |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`&nbsp;; des noms séparés par des virgules remplacent la liste. Un paramètre dont le nom contient l’un d’eux (sans tenir compte de la casse ASCII&nbsp;: `password` correspond aussi à `user[password]`) voit sa valeur écrite `[FILTERED]` dans le journal des requêtes et sur la page d’erreur de développement&nbsp;; `[]` dans `config/app.rb` désactive ce filtrage |
| `CYBERTRAIN_WORKER` | `worker` | `true`&nbsp;; `0` ou `false` empêche ce processus d’exécuter les tâches planifiées et les jobs (voir [Tâches de fond](background-and-operations.md#background-work))&nbsp;; `scheduler_interval` (1&nbsp;s), `job_poll_interval` (5&nbsp;s) et `job_max_attempts` (5) se règlent dans `config/app.rb` |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`&nbsp;; le chemin du contrôle de santé intégré (voir [Exploitation](background-and-operations.md#operations-backups-vacuum-health-check))&nbsp;; une valeur vide le désactive&nbsp;; une valeur sans `/` initial arrête le serveur au démarrage. `health_worker_stale` (300&nbsp;s) se règle dans `config/app.rb` |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`&nbsp;; `1` ou `true` permet à `Cybertrain::HttpClient` de se connecter au loopback, aux adresses privées et aux autres adresses non publiques (voir [HTTP sortant](external-services.md#outbound-http)) |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`&nbsp;; le serveur SMTP par lequel envoie `Cybertrain::Mailer` (voir [Envoyer des e-mails](external-services.md#sending-e-mail)) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`&nbsp;: le port du mode, 587 pour `starttls`, 465 pour `tls`, 25 pour `none`&nbsp;; toute valeur hors de 1 à 65535 vaut 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`&nbsp;: pas d’AUTH&nbsp;; s’il est défini, le mailer s’authentifie avec AUTH PLAIN |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`&nbsp;; un secret, jamais journalisé, jamais dans la bannière de démarrage ni dans un message d’erreur |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`&nbsp;: l’expéditeur qu’utilise `Mailer.deliver` quand `from:` n’est pas fourni |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`&nbsp;; aussi `tls` (TLS implicite) ou `none` (texte en clair, identifiants vers le loopback uniquement)&nbsp;; les deux modes TLS demandent `require "cybertrain/net/tls"` |

N’utilisez `None` (avec `CYBERTRAIN_SESSION_PARTITIONED=1`) que pour une
application affichée dans un cadre d’un autre site&nbsp;; le navigateur doit
atteindre l’application en HTTPS.

Autres attributs aux valeurs par défaut fixes et modifiables&nbsp;: `views_root`
(`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 semaines), `session_secure` (`true` en production, ce qui
marque le cookie de session `Secure`&nbsp;; `false` ailleurs, mais
`SameSite=None` et `Partitioned` ajoutent `Secure` de toute façon),
`pool_size` (4), `static_files`/`csrf` (`true`), `csrf_exempt_prefixes`
(`[]`&nbsp;: des préfixes de chemin comme `"/api/"` dont les requêtes autres que
GET sautent la vérification CSRF, pour un point d’accès que des programmes
appellent avec un identifiant qui leur est propre&nbsp;; chacun doit commencer
et finir par `/` et ne pas être `/` seul, sinon le démarrage échoue&nbsp;; le
préfixe est comparé au chemin tel qu’envoyé, donc une graphie encodée en
pourcent reste vérifiée&nbsp;; aucune autre route ne doit correspondre à un
chemin sous ce préfixe, et le contrôleur exempté ne doit pas compter sur la
session pour l’authentification, puisque la session y est tout de même
chargée), `max_body_bytes` (10&nbsp;Mio&nbsp;: un corps de requête plus long,
tel qu’envoyé, reçoit une 413 avant d’être lu&nbsp;; augmentez-le pour les gros
envois de fichiers&nbsp;; la taille décompressée d’un corps gzip est bornée
séparément par `request.decoded_body(limit)`), `max_render_depth` (12 rendus
ouverts à la fois&nbsp;: la page et ses partiels&nbsp;; augmentez-le pour des
partiels qui s’appellent récursivement plus profondément à juste titre&nbsp;; il
doit valoir au moins 1, sinon le démarrage échoue). Note de mise à
niveau&nbsp;: l’imbrication des rendus, illimitée auparavant, est désormais
plafonnée à 12 par défaut (la page est à la profondeur 1, les partiels peuvent
donc s’imbriquer sur 11 niveaux&nbsp;; le layout est rendu après la page et ne
s’imbrique pas), et une application avec un arbre plus profond (commentaires en
fil, menu de catégories) obtient une erreur de template tant qu’elle ne définit
pas `max_render_depth`. Envois de fichiers&nbsp;: `max_upload_bytes`
(5&nbsp;Mio par fichier envoyé&nbsp;; ne doit pas dépasser `max_body_bytes`),
`max_multipart_parts` (128 parties, champs texte compris, au plus 4096),
`upload_root` (`"storage/uploads"`, où écrit `Cybertrain::BlobStore`&nbsp;; créé
au premier envoi, pas au démarrage).

**En-têtes de sécurité&nbsp;:** chaque réponse qu’écrit le serveur (actions,
middleware des fichiers statiques, pages d’erreur et page de diagnostic de
développement, les 400/411/413/500 propres au serveur, et HEAD) porte
`X-Content-Type-Options: nosniff` et `X-Frame-Options: SAMEORIGIN`, sauf si la
réponse définit déjà un en-tête de ce nom (quelle que soit la casse)&nbsp;:
`Response#to_http` les ajoute après les en-têtes propres à la réponse et
seulement s’ils manquent, donc
`response.set_header("X-Frame-Options", "DENY")` dans une action envoie
exactement votre valeur, une seule fois. Il n’y a délibérément pas de réglage
`Config` pour les désactiver dans toute l’application&nbsp;; un widget
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
ne montre donc pas ces deux valeurs par défaut&nbsp;; vérifiez-les sur
`response.to_http`.

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
démarrage, puis service sur `0.0.0.0:3000`), un `.dockerignore`,
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
journalise une ligne `[WARN]` qui le signale. Lire un nom non déclaré, ou
déclaré avec un autre type, lève `ArgumentError`, tout comme déclarer deux fois
un même nom. Les tests changent une valeur avec `set_string_setting`,
`set_int_setting` et `set_bool_setting`. `./NAME help` liste chaque réglage
déclaré avec sa variable et sa valeur par défaut, et la bannière de démarrage
affiche les valeurs courantes (`=> Settings: base_url="" worker=true ...`)&nbsp;;
un réglage `secret: true` n’apparaît dans les deux que par son nom, sous la
forme `[FILTERED]`. Il n’y a pas d’accesseur `Cybertrain.config.base_url`&nbsp;:
Spinel n’a pas de `define_method`, les lecteurs sont donc des méthodes typées
qui prennent le nom.

## Fuseaux horaires

Spinel n’embarque pas de base de données tz, et définir `ENV["TZ"]` pour
convertir une heure la change pour tous les threads du processus.
`Cybertrain::TimeZone` lit plutôt les fichiers de fuseaux du système&nbsp;:
`/usr/share/zoneinfo/<name>`, ou `$TZDIR/<name>` quand `TZDIR` est défini
(installez le paquet `tzdata` dans une image de conteneur allégée). Il analyse
les versions 1 à 4 de TZif (RFC 8536), y compris la règle TZ POSIX dont dépend
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
n’a besoin d’aucun fichier. Les helpers de formatage pour les templates
(`l(time, zone:)`) n’existent pas encore.
