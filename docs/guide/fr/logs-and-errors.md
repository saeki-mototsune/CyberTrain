---
source_sha256: 95aa532ab50c281cb5b22692324ab27171bb65213f7c46a6ea6c7903d5bb5d88
---
# Journaux et signalement des erreurs

Ce qu’une application en service écrit dans son journal (la ligne, le niveau,
les lignes JSON, l’identifiant de requête et les étiquettes), et comment les
exceptions de ses requêtes, de ses jobs, de ses tâches planifiées et de ses
flux parviennent aux abonnés de l’application et à Sentry. Les jobs, les rôles
des processus et le contrôle de santé sont dans
[Tâches de fond et exploitation](background-and-operations.md).

## Journaux

Le framework et l’application journalisent par `Cybertrain.logger`, une ligne
par message sur la sortie standard, vidée après chaque ligne, comme le fait une
application douze facteurs (le journal de systemd, Kamal et Docker la
recueillent)&nbsp;:

```text sortie — ./blog server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 127.0.0.1
2026-11-14T09:30:00.132Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-14T09:30:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: RuntimeError: smtp down; retrying in 60 s
2026-11-14T09:30:02.410Z WARN [feed:prices] WebSocket "prices" silent for 60s; reconnecting
```

Une ligne est l’heure UTC à la milliseconde (dans un test, elle suit
`travel_to`), le niveau en majuscules, les étiquettes entre crochets et le
message. `Cybertrain.logger` a `debug`, `info`, `warn`, `error` et `fatal`,
qui prennent chacun une String. Les lignes de plusieurs threads ne se mêlent
jamais&nbsp;: chaque ligne est construite entière, puis écrite en un seul
write sous un verrou tenu pour cette écriture seulement. Une écriture qui
échoue (un tube fermé) abandonne la ligne&nbsp;; journaliser ne lève jamais
d’exception chez l’appelant. Un lecteur qui cesse de lire la sortie standard
(un tube plein) bloque tous les threads qui journalisent jusqu’à ce qu’il
lise de nouveau&nbsp;: gardez le collecteur en marche.

**Un événement, une ligne.** Un saut de ligne dans un message ou dans une
étiquette s’écrit comme les deux caractères `\n`, un retour chariot comme
`\r`, si bien qu’un message de plusieurs lignes, ou un faux, ne peut pas
commencer une ligne à lui&nbsp;:
`Cybertrain.logger.info("ok\n2026-11-11T12:00:00.000Z ERROR fake")` écrit
une ligne&nbsp;:

```text sortie — un événement, une ligne
2026-11-14T09:30:00.120Z INFO ok\n2026-11-11T12:00:00.000Z ERROR fake
```

Le seul saut de ligne tout à la fin d’un message est la fin de la ligne
elle-même et n’est pas échappé (`info("done\n")` écrit `done`)&nbsp;; un
second l’est. Rien d’autre n’est échappé&nbsp;: une barre oblique inverse
reste telle quelle, et les tabulations, les autres octets de contrôle et
l’UTF-8 invalide sont écrits tels quels. Les lignes JSON échappent comme
avant.

**Le niveau.** `c.log_level` dans `config/app.rb`, ou `CYBERTRAIN_LOG_LEVEL`
(`debug`, `info`, `warn`, `error`, `fatal` ou `none`, en majuscules ou
minuscules), est le niveau le moins important écrit&nbsp;; `:info` par
défaut. `:none` coupe aussi le journal des requêtes, et écrit toujours les
lignes d’erreur. Une affectation dans `config/app.rb` l’emporte sur la
variable. Toute autre valeur arrête le démarrage&nbsp;:
`error: log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)`.

**Lignes JSON.** `c.log_format = :json` (ou `CYBERTRAIN_LOG_FORMAT=json`)
écrit plutôt un objet JSON par ligne, pour un collecteur de journaux&nbsp;:

```json
{"time":"2026-11-14T09:30:00.132Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

`request_id` n’y est que lorsque la ligne en a un (dans une requête, ou dans
un job qu’une requête a mis en file) et que `log_tags` le montre&nbsp;; `tags`
contient les autres étiquettes dans l’ordre. Quand un message (ou une
étiquette) n’est pas de l’UTF-8 valide, chacun de ses octets à partir de
0x80, ceux des caractères valides compris, est écrit comme l’échappement
`\ufffd` en JSON, si bien qu’un seul mauvais octet change tout le texte non
ASCII du message en caractères de remplacement&nbsp;; un message valide est
écrit tel quel, et une ligne de texte garde les octets tels qu’ils ont été
journalisés. Un format autre que `:text` ou
`:json` arrête le démarrage&nbsp;:
`error: log_format must be :text or :json (got :xml)`. La première ligne du
démarrage lui-même (l’avertissement sur `mail_delivery_method :test` hors
des tests) suit le format&nbsp;; les avertissements sur un réglage
d’application dont la valeur est invalide (`setting_int`, `setting_bool` qui
reviennent à la valeur par défaut) sont journalisés
pendant que `config/app.rb` s’exécute, avant que le format soit connu, et sont
toujours des lignes de texte.

Le niveau et le format s’appliquent à `./<app> server`, `worker` et `feeds`,
ainsi qu’aux commandes enregistrées, à `jobs` et à `console`, qui refusent une
valeur inconnue avec le même message et le statut de sortie 1 avant d’ouvrir
la base. `migrate`, `db` et `dbconsole` ne les appliquent pas&nbsp;: leurs
lignes sont du texte au niveau `info`.

### Identifiants de requête

Chaque requête reçoit un identifiant, un UUID de version 4, que l’action lit
dans `request.request_id` et que la réponse renvoie dans `X-Request-Id`, y
compris sur le 403 du contrôle des hôtes, la redirection https de
`force_ssl`, les pages d’erreur, la page de diagnostic du développement et le
500 du serveur lui-même. Les 400 et 413 du serveur pour une requête qu’il ne
peut pas lire, qu’il renvoie avant que l’application ne la voie, n’en portent
pas. Chaque ligne journalisée pendant la requête porte l’identifiant comme
étiquette (la première, avec les `log_tags` par défaut), y compris les propres lignes `Cybertrain.logger.info` de
l’application, de même qu’un corps diffusé (`stream do ... end`, Server-Sent
Events) ou une connexion WebSocket ouverte par la requête, tant qu’elle reste
ouverte.

```ruby
Cybertrain.logger.info("export #{report.id} for #{request.request_id}")
```

L’identifiant d’un proxy n’est pris que d’un proxy de confiance&nbsp;: quand
la connexion vient d’un proxy de confiance (`CYBERTRAIN_TRUSTED_PROXY` ou
`CYBERTRAIN_TRUSTED_PROXIES`, le contrôle que fait `request.client_ip`&nbsp;;
[L’adresse du client derrière un proxy](requests.md#the-client-address-behind-a-proxy))
et que son `X-Request-Id` fait de 1 à 255 lettres ASCII, chiffres et traits
d’union, la requête prend cet identifiant, si bien que le journal du proxy et
celui de l’application le partagent. Tout autre `X-Request-Id`, un en-tête
envoyé deux fois compris, est écarté et un nouvel identifiant créé&nbsp;; il
n’est jamais modifié.

`c.log_tags` choisit les étiquettes de la requête, dans l’ordre&nbsp;:
`[:request_id]` par défaut, `[:request_id, :remote_ip]` pour ajouter
`request.client_ip` (désactivé par défaut&nbsp;: une adresse est une donnée
personnelle), `[]` pour aucune (l’en-tête est toujours envoyé). Toute autre
valeur arrête le démarrage&nbsp;:
`error: log_tags may hold :request_id and :remote_ip (got :user_agent)`.

### Étiquettes

`Cybertrain.logger.tagged` ajoute des étiquettes à chaque ligne journalisée
sur ce thread pendant le bloc, après celles de la requête, et les retire quand
le bloc se termine, y compris quand il lève&nbsp;; il renvoie la valeur du
bloc. Les blocs s’imbriquent. Il n’existe pas de forme sans bloc.

```ruby
Cybertrain.logger.tagged("billing", "order #{order.id}") do
  Cybertrain.logger.info("charged 300")
  # 2026-11-14T09:30:00.140Z INFO [3f2a9c1e-...] [billing] [order 7] charged 300
end
```

Les étiquettes appartiennent au thread&nbsp;: un thread que vous lancez
commence sans, quelles que soient celles du thread qui l’a lancé. Le framework
étiquette son propre travail de la même façon&nbsp;:

- **Jobs.** Les lignes de chaque tentative portent `[<JobClass> <id>]` (pour
  un job de bloc de `Job.handle`, son type), puis l’identifiant de la
  requête qui l’a mis en file&nbsp;: `INFO [WelcomeJob 7] [3f2a9c1e-...]
  welcome 1`. L’identifiant est enregistré dans la ligne du job
  (`cybertrain_jobs.request_id`) quoi que dise `log_tags`, et montré quand
  `log_tags` contient `:request_id`. Un job mis en file par un job enregistre
  l’identifiant de son parent&nbsp;; un job mis en file par une tâche
  planifiée, un flux ou une commande n’en enregistre aucun.
- **Tâches planifiées.** `[schedule:<name>]` pendant qu’une tâche
  s’exécute, sa ligne d’échec comprise.
- **Flux.** `[feed:<name>]` sur chaque ligne que journalise le thread d’un
  flux, celles de ses callbacks comprises. Les lignes de redémarrage et
  d’abandon du superviseur, journalisées sur son propre thread, n’ont pas
  d’étiquette.

## Signalement des erreurs

`Cybertrain.error` recueille les exceptions qui mettent fin à une requête, à
une tentative de job, à une tâche planifiée ou à un flux, ainsi que celles que
l’application signale elle-même, et remet chacune aux abonnés que
l’application ajoute et à Sentry (ou GlitchTip) quand un DSN est défini. Il est
dans le cœur&nbsp;; l’envoi à Sentry est une ligne à part, que charge
`require "cybertrain"` et qu’une application sur `cybertrain/core` ajoute à
`bin/<app>.rb` (pas à `bin/db.rb`&nbsp;;
[Sous-systèmes](how-it-works.md#subsystems)). `cybertrain new` écrit les
lignes de cette section en commentaire&nbsp;: les variables dans
`.env.example`, un abonné dans `config/app.rb`, le DSN dans
`config/deploy.yml` et `.kamal/secrets`, et cette ligne dans le commentaire
de `bin/<app>.rb`&nbsp;:

```ruby
require "cybertrain/error_reporter/sentry"   # bin/<app>.rb, après require "cybertrain/core"
```

```ruby
# Une exception que l'application a rattrapée, avec ce qu'elle sait :
begin
  charge(order)
rescue PaymentError => e
  Cybertrain.error.report(e, context: { "order_id" => order.id })
end

# Exécuter un bloc, signaler ce qu'il lève, continuer avec nil :
price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)
end
```

`report(e, handled: true, context: {})` renvoie nil aussitôt&nbsp;: le
rapport est livré sur le thread propre du rapporteur. Les clés et les valeurs
du contexte deviennent des Strings, par-dessus le contexte qu’ajoute le
framework (l’identifiant et la tentative d’un job). `handle(context: {}) { }`
renvoie la valeur du bloc, ou nil après avoir signalé une `StandardError` (ou
`JSON::ParserError`, `JSON::NestingError`) levée par le bloc&nbsp;; `break v`
dans son bloc fait renvoyer `v` à `handle`, et `return` sort de la méthode qui
l’entoure. Une exception hors de ces classes levée dans le bloc de `handle`
va jusqu’à l’appelant. Le signalement lui-même ne lève jamais d’exception
chez l’appelant&nbsp;: si le signalement échoue, le journal dit
`error report failed: <Class>: <message>` au niveau error.

**Abonnés.** Un abonné est une classe de l’application, une sous-classe de
`Cybertrain::ErrorSubscriber` qui définit `report(event)`&nbsp;:

```ruby
# config/app.rb, au-dessus de la ligne qui l'abonne (bin/<app>.rb charge
# config/app avant app/, donc une classe sous app/ n'est pas encore chargée ici)
class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message} at #{event.error_where}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)
```

Chaque abonné reçoit chaque rapport, sur le thread du rapporteur, pas dans la
requête ou le job qui a échoué. Un abonné qui lève est journalisé au niveau
error, `error subscriber AuditSubscriber failed: <Class>: <message>`, et n’est
jamais signalé lui-même&nbsp;; les autres reçoivent quand même l’événement.
L’événement est une valeur faite de Strings&nbsp;:

| Lecteur | Contenu |
| --- | --- |
| `error_class` | le nom de classe de l’exception, avec son espace de noms (`"Cybertrain::DB::Error"`) |
| `error_message` | son message |
| `error_where` | `"ArticlesController#create"`, `"request"` (aucune action n’a tourné), la classe ou le type d’un job, `"cybertrain mail"`, `"job thread"`, `"schedule:<name>"`, `"feed:<name>"`, ou `""` |
| `error_request_id`, `error_request_method`, `error_request_path` | ceux de la requête, le chemin sans sa chaîne de requête et filtré comme le filtre le journal des requêtes&nbsp;; dans un job, l’identifiant de la requête qui l’a mis en file&nbsp;; `""` hors d’une requête |
| `error_environment`, `error_release` | `Cybertrain.config.env` et `c.release` |
| `error_handled` | vrai pour `report` et `handle`, faux pour ce que le framework a signalé |
| `error_context` | un `Hash{String => String}`&nbsp;: le contexte de l’application, et `job.id`, `job.attempt`, `job.max_attempts` dans un job |
| `error_backtrace` | un `Array<String>`, vide dans un binaire de `cybertrain build` (ci-dessous) |
| `error_occurred_at` | un `Time`, tiré de l’horloge |

**Ce qui est signalé sans une ligne de votre part&nbsp;:**

- Une requête qui se termine en 500, une fois&nbsp;: une exception que
  `Cybertrain::ClientError.status_for` associe à 500 ou plus. Jamais un 4xx
  (un paramètre invalide, un échec CSRF, un 404), jamais ce que `rescue_from`
  a traité. Si servir la page d’erreur lève ensuite une nouvelle exception
  (un `public/500.html` illisible), celle-ci est signalée aussi&nbsp;: deux
  rapports, chacun un vrai échec.
- Les tentatives échouées d’un job (`where` sa classe ou son type&nbsp;;
  `job.attempt` et `job.max_attempts` dans le contexte), sous la politique
  par défaut, `retry_on` ou `discard_on`. Dans un job, la clé de
  dédoublonnage contient aussi l’identifiant du job
  ([Livraison](#error-reporting), ci-dessous)&nbsp;: deux jobs d’un même
  type qui échouent pareil font deux rapports, et une tentative d’un job qui
  échoue avec la classe et le message de sa propre tentative signalée moins
  d’une minute avant est journalisée mais pas signalée de nouveau (sous la
  politique par défaut la première reprise attend une minute, donc chaque
  tentative est signalée&nbsp;; avec `retry_on ..., wait: 30` la tentative
  qui suit de 30 secondes une tentative signalée ne l’est pas). Un abandon
  est signalé une fois. `job.max_attempts` vaut
  `job_max_attempts` sous la politique par défaut, le `attempts:` de la
  politique sous `retry_on`, et la tentative à laquelle il s’est arrêté sous
  `discard_on`. Un courriel `deliver_later` qui échoue relève du job
  `cybertrain mail`. Une exception qui s’échappe de la boucle d’un thread de
  jobs, ou une erreur de base de données à cet endroit, a pour `where`
  `job thread`.
- Une tâche planifiée dont le bloc lève, ou une tâche `cron` sans exécution
  suivante dans les cinq ans (`schedule:<name>`).
- Un `on_open`, `on_message` ou `on_tick` de flux qui lève, un thread de flux
  qui meurt, et le superviseur qui abandonne un flux
  (`Cybertrain::Background::FeedFailed`, un nom sans classe derrière, avec le
  message `feed <name> restarted <n> times in <w> s; exiting`), tous
  `feed:<name>`.

Une exception levée pendant l’écriture d’un corps diffusé (`stream do ...
end`, Server-Sent Events) ou d’une connexion WebSocket mise à niveau est
signalée une fois, après la ligne `stream error: <Class>: <message>` du
serveur, avec l’identifiant, la méthode et le chemin de la requête et le
`where` `ArticlesController#index (stream)` (`request (stream)` quand
aucune action n’a tourné). Un client parti (`EOFError`, `IOError`,
`Errno::ECONNRESET`, `Errno::EPIPE` sortis de l’écrivain) est journalisé
par cette ligne et non signalé. Non signalés&nbsp;: un job dont le type n’a
pas de handler, et, en développement, une exception que la page de
diagnostic lève elle-même en montrant une exception déjà signalée. Chaque
ligne de journal que le framework écrivait auparavant reste telle
quelle&nbsp;; le rapport vient en plus.

**Ce qui n’est jamais envoyé.** Les paramètres, les en-têtes, les cookies,
la session, l’adresse du client et la chaîne de requête ne sont pas dans un
événement&nbsp;; le chemin d’une requête est filtré comme le filtre le
journal des requêtes. Seul ce que l’application met dans `context:` est
ajouté. Les messages d’exception sont envoyés tels quels, sauf si un filtre
les change&nbsp;: un message qui contient des données personnelles (le refus
d’un serveur SMTP qui nomme le destinataire) en demande un.

**Filtres.** Un filtre est une sous-classe de
`Cybertrain::ErrorReporter::Filter` qui définit `filter_event(event)`, et
renvoie vrai pour garder l’événement, faux pour l’abandonner. Il peut
changer le message (`event.error_message =`) et le contexte
(`event.set_error_context(key, value)`, `event.delete_error_context(key)`).
Celui-ci masque les adresses électroniques ASCII simples, sans guillemets, et l’autre abandonne une classe
que l’application ne veut pas signaler&nbsp;:

```ruby
# config/app.rb
class MaskAddresses < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_message = event.error_message.gsub(/[\w.+-]+@[\w-]+(\.[\w-]+)+/, "[email]")
    event.delete_error_context("email")
    true
  end
end

class DropDeclinedCards < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_class != "PaymentGateway::Declined"
  end
end

Cybertrain.error.add_filter(MaskAddresses.new)
Cybertrain.error.add_filter(DropDeclinedCards.new)
```

Le motif de `MaskAddresses` laisse passer deux sortes d’adresses. Celles qui
ont des caractères hors ASCII, comme `alice@例え.テスト`&nbsp;: le `\w` de
Ruby ne correspond qu’aux lettres, chiffres ASCII et à `_` sans propriété
Unicode demandée. Et celles dont la partie locale est entre guillemets, comme
`"alice smith"@example.com`&nbsp;: le motif veut une lettre, un chiffre, `.`, `+`, `-`
ou `_` juste avant le `@`, n’en trouve pas après le guillemet fermant et ne
correspond à rien dedans, si bien que l’adresse entière reste dans le
message. Écrivez un motif pour les adresses
que vous attendez, ou abandonnez plutôt l’événement.

Les filtres tournent sur le thread du rapporteur, dans l’ordre d’ajout, avant
les abonnés et l’envoyeur&nbsp;; le filtre suivant, les abonnés et Sentry
voient ce qu’un filtre a changé. Dès qu’un filtre abandonne l’événement, les
suivants ne tournent pas et personne ne le reçoit (il n’est pas compté parmi
les abandons de la file). Un filtre qui lève abandonne l’événement, car un
filtre existe pour empêcher quelque chose de sortir, et journalise
`error filter failed: <Filter class>: <Class>: <message>` au niveau
error&nbsp;; il n’est jamais signalé. Le dédoublonnage est décidé avant les
filtres, sur la classe, le message et le `where` non filtrés&nbsp;: une
réécriture par un filtre ne change pas les rapports regroupés, et un
événement qu’un filtre abandonne garde sa place pour la minute. La ligne de
journal `ERROR` du framework est écrite avant que l’événement existe et
n’est pas filtrée. Un filtre seul ne met pas les rapports en file (il faut un
abonné ou un DSN). Les filtres ajoutés dans `config/app.rb` restent pour
chaque test&nbsp;; un filtre ajouté dans un test est retiré avant le suivant.

**Livraison.** Les rapports vont dans une file de 100 et un thread les livre.
Une même classe, un même message et un même `where` (et, dans un job,
l’identifiant du job) sont mis en file au plus
une fois par minute, si bien qu’une page qui échoue pour chaque visiteur avec le
même message fait un rapport par minute (un message qui porte un
identifiant, `Couldn't find Article with id=5`, en fait un par message
distinct)&nbsp;; quand la file est pleine, un rapport est
abandonné et compté, et `error reports dropped: <n>` est journalisé au niveau
warn au plus une fois par minute. Tant qu’il n’y a ni abonné ni DSN, rien
n’est mis en file et aucun thread ne démarre. Une livraison qui échoue est
journalisée, `error delivery failed: <Class>: <message>`, et le rapport
suivant démarre un nouveau thread si l’ancien s’est terminé. Quand le
serveur, un worker ou un processus feeds s’arrête, il attend jusqu’à 2
secondes les rapports en file après l’arrêt de ses services&nbsp;; ce qui
reste est perdu. Une reconstruction en développement attend aussi, de même
qu’une commande enregistrée, `./<app> jobs` et `./<app> console` avant de
fermer la base et de se terminer.

**Envoyer à Sentry ou GlitchTip.** Avec la ligne dans `bin/<app>.rb`, définir
`CYBERTRAIN_SENTRY_DSN` (ou `c.sentry_dsn`) au DSN du projet envoie chaque
rapport comme un événement Sentry&nbsp;:

```sh
export CYBERTRAIN_SENTRY_DSN=https://PUBLIC_KEY@o1.ingest.sentry.io/42
export CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # facultatif : envoyé comme release de l'événement
export CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # facultatif : en envoyer un quart
```

- Le DSN s’écrit `http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>`
  (le secret, l’ancienne seconde moitié de Sentry, est ignoré)&nbsp;; les
  événements vont à `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/`,
  que Sentry et GlitchTip acceptent tous deux. Il contient une clé&nbsp;:
  gardez-le dans les secrets du déploiement, pas dans un fichier versionné.
  Un DSN illisible arrête le démarrage, en nommant la partie et jamais la
  clé&nbsp;:
  `error: sentry_dsn must look like https://<public key>@<host>/<project id>: the project id must be digits`.
- Un DSN défini dans un programme qui ne lie pas l’envoyeur arrête le
  démarrage, et fait refuser une commande enregistrée, `jobs` et `console`
  avant qu’ils n’ouvrent la base (statut de sortie 1)&nbsp;:
  `error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`.
  Une classe d’envoyeur à vous (une sous-classe de
  `Cybertrain::ErrorReporter::Sender`) définit `sender_name` pour renvoyer un
  nom non vide, ou elle se heurte au même refus.
- `CYBERTRAIN_ERROR_SAMPLE_RATE` (`c.error_sample_rate`, 1.0) est la part des
  rapports envoyés, de 0.0 à 1.0&nbsp;; les abonnés voient toujours chaque
  rapport. La variable doit être des chiffres avec un `.chiffres` facultatif,
  sinon le démarrage s’arrête&nbsp;:
  `error: error_sample_rate must be a number from 0.0 to 1.0 (got "x")`.
- `CYBERTRAIN_RELEASE` (`c.release`, vide par défaut) nomme la version ou le
  commit&nbsp;; il n’est pas vérifié.
- Chaque envoi attend au plus 5 secondes une fois le nom de l’hôte résolu (la
  résolution bloque le thread de livraison et l’échéance ne peut pas
  l’interrompre, si bien qu’un résolveur bloqué peut retenir un envoi plus
  longtemps), et n’est jamais retenté. Un refus est
  journalisé au niveau warn, `error report not sent: Sentry answered 429`, de
  même qu’un échec de connexion, `error report not sent: <Class>: <message>`.
- L’événement porte la classe et le message, `where` comme transaction,
  l’environnement, la release, l’identifiant de requête comme étiquette, la
  méthode et le chemin de la requête, le contexte comme `extra`, et la pile
  d’appels comme frames quand il y en a une.
- L’appel passe par `Cybertrain::HttpClient` et sa garde contre les adresses
  privées ([HTTP sortant](external-services.md#outbound-http))&nbsp;: un
  GlitchTip sur un réseau privé ou sur la même machine demande
  `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`, qui lève la garde pour chaque appel
  sortant de l’application.

**Piles d’appels.** Un binaire de `cybertrain build` est une version release
de Spinel, dont les exceptions n’ont pas de pile d’appels&nbsp;: ses rapports
ont la classe, le message et `where`. Dans une version `--debug`, et sous
CRuby, les frames sont jointes.

`cybertrain test` n’envoie rien à Sentry&nbsp;: il vide un
`CYBERTRAIN_SENTRY_DSN` exporté sauf si `config/app.rb` en affecte un, et un
test pointe plutôt le DSN vers un `Test::SentryReceiver`
([Tester les journaux et les rapports d’erreur](testing.md#testing-logs-and-error-reports)).
La conception&nbsp;: [docs/design.md](../design.md) D86 et D88.

### Mise à jour des journaux et des rapports d’erreur

Ce qu’une version change dans les journaux et les rapports d’erreur
figure par version dans [Mise à jour](upgrading.md#notes-by-version).
