---
source_sha256: 2e896de3ac3ca018498820245a9fc252a601dde546621f740f224404a46d459f
---
# Tâches de fond et exploitation

## Tâches de fond

Une application qui doit faire quelque chose en dehors d’une requête (envoyer
une notification une fois la réponse partie, purger les anciennes lignes
chaque nuit, réessayer un appel qui a échoué) le confie au framework, qui
l’exécute sur des threads d’arrière-plan du processus qui sert, ou d’un
processus worker séparé. Un job est une classe dans `app/jobs/`, comme dans
Rails. Les jobs et les tâches planifiées demandent `require "cybertrain/jobs"`
dans `bin/<app>.rb` et `bin/db.rb`, que `cybertrain generate job` ajoute
([Sous-systèmes](how-it-works.md#subsystems))&nbsp;:

```ruby
# app/jobs/welcome_job.rb
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError

  def perform(args)
    user = User.find(Cybertrain::Cast.int(args["user_id"]))
    Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  end
end
```

```ruby
# dans une action, après l’enregistrement de l’utilisateur
WelcomeJob.perform_later("user_id" => @user.id)
WelcomeJob.perform_in(600, "user_id" => @user.id)   # ou perform_at(time, args)
```

```ruby
# config/app.rb (ou un fichier que bin/<app>.rb requiert avant Cybertrain::Main.run)
Cybertrain::Scheduler.cron("0 4 * * *", "nightly digest", job: "DigestJob")
Cybertrain::Scheduler.every(300, "refresh rates") { Rates.refresh }
```

- **Où cela s’exécute.** Les jobs s’exécutent sur `job_threads` threads de
  jobs (3, `CYBERTRAIN_JOB_THREADS`)&nbsp;; les tâches planifiées sur un
  thread de scheduler bien à elles, si bien qu’un long job ne retarde jamais
  une tâche. Les deux démarrent quand le binaire sert (`./<app>`,
  `./<app> server`) ou tourne comme worker (`./<app> worker`, voir
  [Rôles des processus](#process-roles)), après que le démarrage a connecté
  la base de données et défini `SPINEL_WORKERS`&nbsp;; les commandes
  `migrate`, `db ...`, `jobs ...`, `console` et `Main.command` ne les
  démarrent jamais, pas plus que `Cybertrain::Test::Client`. Avec les jobs
  requis, les threads de jobs démarrent dans chacun de ces processus, même
  dans une application sans classe de job&nbsp;: le framework enregistre son propre job de mail
  (`Mailer.deliver_later`,
  [Envoyer des e-mails](external-services.md#sending-e-mail)).
- **La table.** Les jobs sont des lignes de `cybertrain_jobs`, que le
  framework crée lui-même (`CREATE TABLE IF NOT EXISTS`, à la première
  utilisation) et laisse hors de `db/schema.rb`. Dans une `DB.transaction`,
  la ligne est validée ou annulée avec le reste. Chaque thread de jobs
  réserve la ligne échue la plus ancienne dans une courte transaction
  `BEGIN IMMEDIATE`, l’exécute hors de celle-ci et cherche la suivante&nbsp;;
  quand rien n’est échu, il attend `job_poll_interval` secondes (1), si bien
  qu’un job mis en file par une requête démarre en une seconde environ. Une
  ligne est `queued`, `running`, `done`, `failed` (ses nouvelles tentatives
  sont épuisées&nbsp;; elle reste là pour que vous l’examiniez) ou
  `discarded` (un `discard_on` l’a arrêtée).

### Les classes de job

`spin run gen` lit chaque fichier sous `app/jobs/` (y compris les
sous-répertoires&nbsp;: `Admin::ReportJob` dans
`app/jobs/admin/report_job.rb`) et écrit dans `gen/jobs.rb` l’autre moitié de
chaque classe qui a `Cybertrain::Job::Base` pour ancêtre&nbsp;:
`perform_later`, `perform_at`, `perform_in`, `perform_now`, `job_kind` et le
code qui l’exécute, puis enregistre la classe. `cybertrain generate job
send_digest --retry Cybertrain::Mailer::TimeoutError:60:5` écrit un fichier
de classe et un test pour elle.

- **`args`** est le Hash donné à `perform_later`, stocké en JSON et relu
  comme un `Hash<String, Object>`&nbsp;: affinez ses valeurs avec
  `Cybertrain::Cast.int(args["user_id"])`, `Cast.str`, `Cast.hash`,
  `Cast.array`. Un job prend ce seul Hash&nbsp;; passez des ids, pas des
  enregistrements (c’est aussi le conseil de Rails). `perform_later` lève
  `ArgumentError` pour tout ce qui n’est pas un Hash, et sans argument
  envoie `{}`.
- **Mise en file.** `perform_later(args)`, `perform_at(time, args)` et
  `perform_in(seconds, args)` renvoient l’id de la ligne&nbsp;; le kind de la
  ligne est le nom de la classe (`"WelcomeJob"`, `"Admin::ReportJob"`).
  `perform_now(args)` exécute `perform` sur le thread appelant, sans file,
  sans politique de nouvelle tentative et sans rescue, et renvoie
  `nil`&nbsp;: la forme qu’attend un test.
- **Le corps de la classe.** Chaque classe de job définit `perform(args)`
  (le générateur refuse une classe qui ne le définit ni n’en hérite).
  `retry_on`, `discard_on` et `limits_concurrency` sont lus comme du texte,
  un par ligne avec des valeurs littérales (un Integer ou
  `:polynomially_longer` pour `wait:`, un Integer pour `attempts:` et `to:`,
  une String entre guillemets pour `key:`)&nbsp;; un bloc, une lambda,
  `5.minutes`, une flèche `=>` ou un commentaire en fin de ligne arrête
  `spin run gen` avec le fichier, la ligne et ce qu’il faut écrire à la
  place.
- **Quelles classes d’exception.** Un `retry_on` ou un `discard_on` nomme une
  classe que le programme définit avant le job&nbsp;: une classe du cœur
  (`ArgumentError`, `KeyError`, ...), l’une des classes `...Error` du
  framework (le générateur ajoute le require nécessaire), ou une classe de
  l’application définie dans `app/models/`, dans
  `app/jobs/application_job.rb` ou au-dessus de la ligne dans le fichier du
  job lui-même. Tout le reste arrête `spin run gen`&nbsp;: sous Spinel, un
  `rescue` qui nomme une classe que le programme ne définit pas peut avaler
  toutes les exceptions (spikes/NOTES.md, règle 89).
- **`ApplicationJob`.** Une classe `ApplicationJob < Cybertrain::Job::Base`
  dans `app/jobs/application_job.rb` n’est pas un job à part entière&nbsp;:
  ses lignes `retry_on` et `discard_on` s’appliquent à chaque job qui en
  hérite, après celles du job, et son `limits_concurrency` à un job qui n’en
  déclare aucun. Toute autre classe de job peut être un parent&nbsp;; c’est
  alors un job à part entière.
- **`Job.handle`, la forme courte.** Un bloc enregistré sous un kind String
  ne demande ni classe ni générateur&nbsp;; il reçoit la charge utile String
  et la politique par défaut ci-dessous&nbsp;:

  ```ruby
  # config/app.rb
  Cybertrain::Job.handle("notify", concurrency: 1) { |payload| Notifier.post(payload) }

  # n’importe où, plus tard
  Cybertrain::Job.enqueue("notify", JSON.generate({ "text" => "Deployed" }), run_at: Time.now + 60)
  ```

  Les classes de job et les kinds de `Job.handle` partagent un seul espace de
  noms, si bien que `Job.enqueue("WelcomeJob", json)` ajoute la même ligne
  que `perform_later`. `Job.enqueue` refuse un kind non enregistré.

### Nouvelles tentatives et abandons

- **La politique par défaut.** Une exception qu’aucune ligne de la classe ne
  reconnaît (et toute exception d’un bloc `Job.handle`) est réessayée 1, 5,
  15 puis 60 minutes plus tard, avec `Class: message` (jusqu’à 1000
  caractères) dans `last_error`, jusqu’à ce que `job_max_attempts` (5)
  tentatives aient échoué&nbsp;; la ligne passe alors à `failed`. Un
  `NotImplementedError` (un helper pas encore écrit), un `SystemStackError`
  ou un autre `ScriptError` levé par le code du job suit cette politique
  aussi, bien qu’aucun ne soit un `StandardError`&nbsp;; toute autre
  exception hors de `StandardError` est journalisée (`ERROR Job thread N:
  ...`) et [signalée](#error-reporting), le thread de jobs continue, et la ligne reste `running` jusqu’à ce
  que la reprise (ci-dessous) la prenne.
- **`retry_on Klass, wait: 60, attempts: 5`.** `wait:` est un nombre de
  secondes (3 s’il est omis, la valeur par défaut de Rails) ou
  `:polynomially_longer` (`attempts ** 4 + 2` secondes&nbsp;: 3, 18, 83, 258,
  ...)&nbsp;; `attempts:` (5 s’il est omis) compte chaque tentative, la
  première comprise. Plusieurs lignes sont permises&nbsp;: la première dont
  la classe reconnaît l’exception (une sous-classe est reconnue) l’emporte,
  donc écrivez la classe la plus étroite d’abord. `retry_on StandardError`
  avant `discard_on ArgumentError` réessaie l’`ArgumentError`.
- **`discard_on Klass`** arrête tout de suite&nbsp;: la ligne passe à
  `discarded`, avec l’erreur dans `last_error`, et n’est jamais réessayée.
- **`def retries_exhausted(error)`** s’exécute quand les tentatives d’une
  ligne `retry_on` sont épuisées, une fois la ligne réellement `failed`
  (jamais pour une tentative qu’un autre worker a reprise et dont
  l’exécution peut encore réussir). C’est le bloc `retry_on ... do |job,
  error|` de Rails&nbsp;; une exception qu’il lève est journalisée.
- **La reprise** (ci-dessous) suit elle aussi la classe&nbsp;: une ligne d’une
  classe avec `attempts: 20` dont le processus est mort à la tentative 5 est
  remise en file, pas marquée en échec.

### Concurrence par kind et par clé

`limits_concurrency to: 1, key: "account_id"` laisse au plus `to:` jobs de la
classe s’exécuter en même temps dans tous les processus qui partagent la
base, comptés par valeur de `args["account_id"]` (`to:` seul compte pour
toute la classe&nbsp;; `Job.handle(kind, concurrency: n)` fait de même pour un
bloc). Les autres kinds, et les autres clés, continuent de s’exécuter
pendant ce temps. Mettre en file un job à clé dont les `args` n’ont pas la
clé lève `ArgumentError`. La limite compte les lignes `running`, elle tient
donc tant que les battements de cœur tiennent&nbsp;: un job qui tourne encore
après que son battement de cœur est devenu périmé est chevauché par la
prochaine exécution de la ligne reprise (ci-dessous)&nbsp;; un travail qui ne
doit jamais se chevaucher a besoin de sa propre garde.

### Les tâches planifiées

`Scheduler.every(seconds, name) { ... }` exécute un bloc toutes les
`seconds`&nbsp;; `Scheduler.cron(expr, name, ...)` s’exécute aux minutes que
désigne une expression cron à cinq champs&nbsp;:

```ruby
Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
                           job: "MorningReportJob", args: { "scope" => "all" })
Cybertrain::Scheduler.cron("*/5 * * * *", "poll feeds", catch_up: true) { Feeds.poll }
```

- **L’expression.** Minute, heure, jour du mois, mois, jour de la semaine,
  avec `*`, `*/n`, `a-b`, `a,b`, `a-b/n` et les noms `jan`-`dec` et
  `sun`-`sat` (les jours `0` et `7` sont le dimanche)&nbsp;; `@hourly` et ses
  semblables ne sont pas acceptés. Une expression illisible, ou qui ne
  correspond jamais, lève `ArgumentError` en nommant la tâche au chargement
  de `config/app.rb`, ce qui arrête le démarrage.
- **Fuseaux horaires.** `tz:` nomme un fuseau IANA
  ([Fuseaux horaires](configuration.md#time-zones))&nbsp;; sans lui, la tâche
  lit `scheduler_tz` (`CYBERTRAIN_SCHEDULER_TZ`, qui suit le `time_zone` de l’application quand il n’est pas réglé). Une heure murale que
  le passage à l’heure d’été saute ne s’exécute pas ce jour-là. Dans l’heure
  répétée du changement d’automne, une expression dont le champ des heures
  commence par `*` s’exécute aux deux occurrences et une expression à heure
  fixe une seule fois, comme le fait Vixie cron.
- **`job:`** nomme un kind de job (un nom de classe en String, ou un kind de
  `Job.handle`) et `args:` ses arguments&nbsp;: la tâche ne fait alors que le
  mettre en file, ce que devrait faire une tâche qui a du vrai travail. Un
  kind inconnu arrête le démarrage avec la liste des kinds enregistrés.
- **Le calendrier** est conservé dans la base (`cybertrain_schedules`, hors
  de `db/schema.rb`)&nbsp;: quand chaque tâche s’est exécutée pour la dernière
  fois et quand elle s’exécutera ensuite. Un redémarrage, ou un autre
  processus qui prend la tête, reprend à partir de lui. Une tâche `every`
  dont l’heure est passée pendant que rien ne tournait s’exécute une fois au
  démarrage&nbsp;; un créneau `cron` manqué pendant que rien ne tournait est
  sauté (la règle de cron), sauf si la tâche indique `catch_up: true`, qui
  l’exécute une fois au démarrage. Un créneau échu pendant que des processus
  tournaient sans qu’aucun leader l’exécute (un bail qui change de mains)
  s’exécute une fois lors de la reprise. Une tâche que vous renommez ou
  supprimez garde sa ligne jusqu’au démarrage suivant. Une tâche qui n’a
  pas encore tourné suit son horaire actuel quand celui-ci tombe plus tôt
  que la prochaine exécution qu’une version précédente a enregistrée (une
  tâche hebdomadaire rendue horaire avant sa première exécution tourne dans
  l’heure).
- **Comment une tâche s’exécute.** Un bloc s’exécute sur le thread du
  scheduler, une tâche à la fois&nbsp;; chaque exécution est enveloppée dans
  un rescue qui journalise `ERROR [schedule:name] Scheduled task "name"
  failed: ...` et le signale, et la boucle continue. Le bloc ne prend pas d’argument (Spinel n’a pas
  d’`instance_eval`). Un appel SQLite garde son worker système jusqu’à son
  retour&nbsp;: avec `SPINEL_WORKERS=1` (la valeur par défaut), une longue
  requête bloque toutes les requêtes HTTP, et tous les autres threads,
  aussi longtemps. Confiez à un job une tâche qui a du vrai travail (`job:`,
  ou `Job.enqueue` depuis le bloc), et découpez les gros travaux (mille
  lignes par exécution, un job par élément).
  `Cybertrain::Scheduler.last_tick` est la seconde epoch du dernier tick,
  pour un contrôle de santé de votre cru.

### La page des jobs et la commande `jobs`

```ruby
# config/routes.rb
Cybertrain::Routes.draw do
  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
end
```

`jobs_page` monte une page qui liste le nombre de lignes par état, le nombre
de lignes en file et la prochaine échéance, les lignes `failed` et
`discarded` (kind, arguments, erreur, tentatives, dates) et les lignes
`running` (qui les a réservées, l’âge de leur battement de cœur), à raison de
`jobs_page_per_page` (50, `CYBERTRAIN_JOBS_PAGE_PER_PAGE`) lignes par liste.
Une ligne en échec peut être réessayée (remise en file tout de suite,
tentatives remises à zéro), abandonnée ou supprimée, une ligne abandonnée
réessayée ou supprimée, et toutes les lignes en échec réessayées ou
abandonnées d’un coup&nbsp;; chaque action ne touche que les lignes `failed`
et `discarded`, si bien qu’une ligne qu’un worker vient de réserver est
laissée tranquille.

- Le contrôleur généré hérite d’`ApplicationController`, si bien que le
  layout, les helpers et la protection CSRF de l’application s’appliquent,
  et `before_action:` nomme l’une de ses méthodes&nbsp;: elle doit rendre une
  réponse ou rediriger pour refuser. `cybertrain generate authentication`
  dessine la ligne ci-dessus, avec le `require_admin` de son concern (404
  sauf si un administrateur est connecté&nbsp;;
  [Administrateurs](authentication.md#admin-users-and-the-jobs-page)). Sans
  `before_action:`, la page est ouverte à tous les visiteurs, et `spin run
  gen` affiche un avertissement qui le dit.
- `skip_before_action:` nomme un before callback hérité que la page
  n’exécute pas. Avec `:require_authentication`, `require_admin` répond
  seul à un visiteur, par un 404 plutôt qu’une redirection vers la
  connexion. gen le refuse sans `before_action:`, et quand il nomme le
  `before_action:` lui-même.
- Ses boutons sont des formulaires avec le jeton CSRF. Gardez le chemin de
  la page hors de `csrf_exempt_prefixes`&nbsp;: sous un préfixe exempté, ces
  formulaires seraient acceptés depuis n’importe quel site.

Depuis un shell, `./<app> jobs` fait de même sur la base configurée (il ne
démarre aucun thread)&nbsp;:

```sh
./blog jobs list               # lignes en échec, les plus récentes d’abord (les 1000 plus récentes) ; ou : list queued|running|done|discarded
./blog jobs retry 42           # ou : retry --all (toutes les lignes en échec)
./blog jobs discard 42
./blog jobs delete 42
./blog jobs prune --before 30  # supprime les lignes failed et discarded de plus de 30 jours (7 par défaut)
```

Les lignes `done` restent jusqu’à ce que quelque chose les supprime&nbsp;:
`Job.prune_done(before_epoch)` depuis une tâche
(`Cybertrain::Scheduler.cron("0 3 * * *", "prune done jobs") {
Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400) }`).
`Job.state_count("failed")` sert une page de santé de votre cru.

### Plusieurs workers, au moins une fois, arrêt

- **Plusieurs workers par base.** Chaque processus qui exécute des jobs écrit
  un battement de cœur pour les jobs qu’il exécute toutes les
  `job_heartbeat_interval` (30 s). Une ligne `running` dont le battement de
  cœur est plus ancien que `job_heartbeat_stale` (un processus qui a planté
  ou a été arrêté en plein job) est remise en file par le premier processus
  qui regarde, à son démarrage puis une fois par minute, sauf si cette
  tentative était sa dernière (la plus grande de `job_max_attempts` et de la
  plus grande valeur `attempts:` de la classe)&nbsp;: la ligne reste alors
  `failed`, avec `process stopped (heartbeat stale)` dans `last_error`, si
  bien qu’un job qui tue son processus n’est pas réessayé indéfiniment. Les
  tâches planifiées s’exécutent dans un seul processus à la fois&nbsp;: les
  processus partagent un bail dans la base (`cybertrain_leases`, renouvelé à
  chaque tick, `scheduler_lease_ttl` 30 s), et seul son détenteur exécute
  les tâches échues&nbsp;; un autre prend le relais quand il cesse de le
  renouveler. Le bail est renouvelé avant chaque tâche, pas pendant qu’elle
  s’exécute, si bien qu’une tâche plus longue que le ttl peut chevaucher
  celle du détenteur suivant&nbsp;: gardez les tâches courtes et sûres à
  répéter. Ainsi deux processus `worker`, ou un serveur et un worker,
  peuvent partager un même fichier SQLite&nbsp;; `CYBERTRAIN_WORKER=0`
  désactive les jobs, les tâches et les flux dans un processus `server` qui
  ne doit servir que le HTTP.
- **Au moins une fois.** Un job peut s’exécuter deux fois&nbsp;: un processus
  tué, ou bloqué plus longtemps que `job_heartbeat_stale` (300 s), peut être
  encore en train d’exécuter un job quand un autre processus reprend la
  ligne. Seul compte le résultat de la réservation qui détient la ligne (le
  résultat d’un réservataire précédent, qui finit en retard, est écarté),
  mais les effets de bord du job ont eu lieu deux fois&nbsp;; écrivez donc des
  jobs qui peuvent sans danger s’exécuter à nouveau (vérifier si le mail est
  déjà parti, faire un upsert plutôt qu’un insert), comme avec toute file de
  jobs. Une tâche planifiée peut s’exécuter deux fois autour d’un changement
  de leader pour la même raison.
- **Arrêt.** Sur `SIGTERM`, les threads de jobs cessent de réserver de
  nouveaux jobs, et le processus attend jusqu’à `job_drain_timeout` (10 s)
  les jobs en cours. Un job encore en cours garde alors sa ligne
  `running`&nbsp;; son battement de cœur s’est arrêté, si bien qu’un autre
  processus l’exécute à nouveau une fois périmé.
- **Tests.** `WelcomeJob.perform_now(args)` exécute un job,
  `Cybertrain::Scheduler.run_due(now)` un tick et
  `Cybertrain::Job.work_one(now)` un job en file, avec un temps epoch de
  votre choix, si bien qu’un test ne dort jamais&nbsp;;
  [Tester les jobs](testing.md#testing-jobs) donne les assertions.

### Mise à jour depuis 0.4

- `cybertrain_jobs` gagne la colonne `concurrency_key` et l’état
  `discarded`&nbsp;; le premier processus qui touche la table ajoute la
  colonne. Le code qui liste les états (un tableau de bord sur
  `Job.state_count`) ajoute `discarded`. `Job.prune_done` ne purge toujours
  que les lignes `done`.
- Les tâches `every` reprennent à partir du calendrier après un redémarrage
  au lieu de repartir de zéro&nbsp;: un intervalle écoulé pendant que le
  processus était arrêté s’exécute une fois au démarrage.
- Donner une clé à un kind existant (`limits_concurrency ... key:`)&nbsp;:
  arrêtez tous les anciens processus avant que le premier nouveau démarre,
  comme pour toute mise à jour ([Rôles des processus](#process-roles)). Le
  premier nouveau processus attribue leur clé aux lignes `queued` mises en
  file auparavant (il journalise les ids des lignes dont la charge utile n’a
  pas ce champ), et une ligne `running` laissée par un ancien processus
  reçoit sa clé quand elle est reprise.
- `jobs` est désormais une commande intégrée&nbsp;: une commande de
  l’application nommée `jobs` doit être renommée.

Non construit&nbsp;: la priorité des jobs, les noms de file et l’unicité, un
mode de job en ligne pour les tests (`perform_now` et
`perform_enqueued_jobs` couvrent les tests). La conception&nbsp;:
`docs/design.md` D28 et D51 à D53.

## Rôles des processus

Un seul binaire tourne dans trois rôles. Par défaut, `./<app> server` fait
tout, comme `rails server` avec Solid Queue dans Puma&nbsp;; les deux autres
permettent à un déploiement de répartir le travail entre des processus ou
des conteneurs, tous à partir de la même image et de la même base&nbsp;:

| Commande | Exécute | Écoute |
| --- | --- | --- |
| `./<app> server [PORT]` | le HTTP, le [point d’entrée des flux](realtime.md#which-process-does-what), et sauf avec `CYBERTRAIN_WORKER=0` les tâches planifiées, les threads de jobs et les flux WebSocket | oui |
| `./<app> worker` | les tâches planifiées (un processus à la fois, grâce au bail), les threads de jobs, les battements de cœur et la reprise | non |
| `./<app> feeds [NAME...]` | les [flux WebSocket](external-services.md#consuming-websocket-feeds), tous ou ceux nommés | non |

- `worker` et `feeds` affichent une bannière (`=> worker: 3 job threads, 2
  scheduled tasks`), tournent jusqu’à `SIGTERM` ou `SIGINT` (Ctrl-C) puis s’arrêtent comme le fait
  un serveur. Ils exécutent toujours leur travail&nbsp;: `CYBERTRAIN_WORKER=0`,
  réglé pour le rôle web, ne les désactive pas.
- `feeds` avec des noms n’exécute que ces abonnements (un conteneur par
  flux), et un nom inconnu arrête le démarrage avec la liste des noms
  enregistrés. Avec les flux dans leur propre processus, réglez
  `CYBERTRAIN_WORKER=0` sur les serveurs, sinon chaque processus recevrait
  chaque flux.
- Un processus `feeds` redémarre un flux dont le thread est mort, et se
  termine avec le statut 1 quand un même flux continue de mourir
  (`feed_restart_limit` redémarrages dans `feed_restart_window`)&nbsp;;
  lancez-le donc sous une politique de redémarrage (`restart:
  unless-stopped` de Docker, `Restart=always` de systemd)&nbsp;;
  [Consommer des flux WebSocket](external-services.md#consuming-websocket-feeds)
  donne les détails. `./<app> feeds status` affiche le dernier état signalé
  par chaque flux.
- Un découpage typique&nbsp;: `server` avec `CYBERTRAIN_WORKER=0` derrière le
  proxy, un ou plusieurs `worker`, et `feeds` s’il y a des abonnements.
  `cybertrain new` écrit un rôle `web` et un rôle `worker` dans
  `config/deploy.yml` (et un `feeds` en commentaire)&nbsp;;
  [docs/deploy.en.md](../deploy.en.md), partie 7, «&nbsp;Splitting the
  roles&nbsp;», donne les unités systemd.
- **Mise à jour depuis une version sans battements de cœur**&nbsp;: arrêtez
  tous les anciens processus avant de démarrer le premier nouveau. Un nouveau
  worker prendrait pour abandonnés les jobs qu’un ancien exécute encore,
  puisqu’un ancien processus n’écrit aucun battement de cœur.
- `Cybertrain::Main.worker?(ARGV)` et `Main.feeds?(ARGV)`, comme
  `Main.server?(ARGV)`, indiquent à `bin/<app>.rb` quel rôle il démarre.
- `worker` demande `require "cybertrain/jobs"` dans `bin/<app>.rb`, et `feeds`
  `require "cybertrain/feeds"` (que `cybertrain/websocket` charge)&nbsp;; sans
  elle, le binaire dit quelle ligne manque et sort avec 1.

## Le cache

`Cybertrain::Cache` garde des réponses un certain temps dans la base de
l’application elle-même, pour que la requête suivante ne réinterroge pas
l’API lente. `require "cybertrain"` le charge&nbsp;; une application sur
`cybertrain/core` ajoute `require "cybertrain/cache"` à `bin/<app>.rb` et
`bin/db.rb`, ou là où il sert&nbsp;:

```ruby
require "cybertrain/cache"

text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  client.get("https://api.llama.fi/tvl").body
end
data = Cybertrain::Cache.fetch_hash("prices/#{sym}", expires_in: 60) { { "usd" => price } }
count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)   # true quand écrit
```

- **Les valeurs sont des Strings.** `fetch(key, expires_in:,
  race_condition_ttl:) { String }` renvoie la valeur vivante, ou exécute le
  bloc et stocke ce qu’il renvoie&nbsp;; `fetch_hash`, `fetch_array` et
  `fetch_int` stockent du texte JSON ou Integer et le relisent en sortie, si
  bien qu’une cellule corrompue se lit `{}`, `[]` ou `0` jusqu’à ce qu’elle
  expire et que le bloc s’exécute à nouveau (Spinel n’a pas de `Marshal`, et
  une méthode renvoie un seul type). `read(key)` (une String, ou nil),
  `write(key, value, expires_in:, unless_exist:)`, `delete`, `exist?`,
  `increment(key, by: 1, expires_in:)` (une seule instruction&nbsp;; un
  compteur expiré repart de `by`, et `expires_in:` ne fixe l’expiration
  qu’au départ du compteur, si bien qu’un compteur d’une minute compte cette
  minute) et `clear` complètent l’ensemble.
- **Expiration.** `expires_in:` est en secondes&nbsp;; `0`, la valeur par
  défaut, n’expire jamais (une valeur négative non plus).
  `race_condition_ttl: n`&nbsp;: quand une ligne a expiré, le premier
  appelant la prolonge de `n` secondes et calcule la nouvelle valeur pendant
  que les autres continuent de lire l’ancienne, comme dans Rails&nbsp;; sans
  lui, chaque appelant d’une clé expirée calcule. Un bloc qui lève une
  exception n’écrit rien.
- **Stockage.** Les lignes vivent dans `cybertrain_cache`, que le framework
  crée à la première utilisation et laisse hors de `db/schema.rb`. Rien
  n’est gardé en mémoire&nbsp;: chaque lecture est un SELECT, auquel SQLite
  répond depuis son cache de pages. Chaque écriture prend le verrou
  d’écriture de la base, qu’attendent les requêtes qui écrivent leurs
  propres lignes&nbsp;: mettez en cache ce que produisent les jobs, ou des
  valeurs lues bien plus souvent qu’elles ne changent, plutôt que d’écrire
  dans un chemin de requête chargé.
- **Purge.** Avec les jobs chargés, requérir le fichier enregistre la tâche
  planifiée `"cybertrain cache prune"`, qui supprime les lignes expirées
  toutes les `cache_prune_interval` secondes (300,
  `CYBERTRAIN_CACHE_PRUNE_INTERVAL`), mille par instruction. Sans les jobs, le
  cache se purge lui-même&nbsp;: la première écriture d’un processus, puis la
  première après chaque `cache_prune_interval`, supprime jusqu’à mille lignes
  expirées. L’intervalle est lu quand le fichier est
  requis&nbsp;: réglez la variable, ou `c.cache_prune_interval` dans un bloc
  `Cybertrain.configure` exécuté avant le require. `Cache.prune(now)` est le
  point d’entrée des tests.

Non construit&nbsp;: un fichier de base séparé pour le cache, une taille
maximale, un stockage en mémoire. La conception&nbsp;: `docs/design.md` D54.

## La console

`./<app> console` est une invite sur les modèles de l’application. Spinel
n’a pas d’`eval`, donc elle n’exécute pas de Ruby&nbsp;: elle évalue les
expressions qu’évalue le `<%= %>` d’un template ([le langage de
templates](template-language.md#expressions), sans blocs), plus les noms de
modèles. En développement, lancez-la avec
`cybertrain spin run <app> -- console`.

```console
$ ./blog console
Cybertrain console (production). Type help for commands, exit to quit.
>> Article.where(title: "Hello").count
1
>> a = Article.find(1)
#<Article id: 1, title: "Hello", body: "First post", created_at: 2026-11-05 10:00:00 UTC, updated_at: 2026-11-05 10:00:00 UTC>
>> a.update(title: "Hello again")
true
```

- Un nom de modèle est sa relation (`Article`), avec `where`, `where_like`,
  `order`, `limit`, `offset`, `page`, `first`, `last`, `find`, `find_by`,
  `to_a`, `count`, `exists?`, `pluck_str` / `pluck_int` / `pluck_float`,
  `sum_int`, `count_by`, `delete_all`, `to_sql` et `create`. Un
  enregistrement a ses attributs et ses méthodes, `update`, `save`,
  `destroy`, `reload`, `valid?`, `errors` et `attributes`. `help` les liste
  tous.
- `x = expr` garde une valeur pour les lignes suivantes, et `_` est la
  dernière valeur. `sql "..."` exécute du SQL et affiche les lignes en
  tableau, les caractères de contrôle d’une cellule échappés (`\e`, `\n`)&nbsp;:
  les données ne peuvent ni envoyer une séquence d’échappement au terminal ni
  casser le tableau (une valeur TEXT contenant un octet NUL est coupée au NUL
  à la lecture, comme dans toute lecture en SQL brut&nbsp;; un BLOB garde tous
  ses octets)&nbsp;; `tables` liste les tables&nbsp;; `exit`, `quit` ou Ctrl-D
  quitte.
- Une ligne qui ne s’analyse pas affiche son erreur, une ligne qui lève une
  exception affiche `Class: message`, et l’invite revient. Une valeur binaire
  s’affiche comme `<N bytes>`.
- Les écritures sont réelles. En production, la console le signale d’abord
  dans une bannière.

`./<app> dbconsole` ouvre le shell `sqlite3` sur la base configurée
(`CYBERTRAIN_DATABASE`), comme le `dbconsole` de Rails&nbsp;; il faut que la
commande `sqlite3` soit installée, et son code de sortie est transmis. Aucune
de ces deux commandes ne démarre le scheduler, les jobs ou les flux.

## Exploitation&nbsp;: sauvegardes, VACUUM, contrôle de santé

Les données d’une application déployée tiennent dans un seul fichier SQLite,
donc le binaire embarque les trois outils d’exploitation dont une telle
application a besoin. Une application avec des envois de fichiers garde aussi
leurs octets sous sa racine d’envoi (`upload_root`, `storage/uploads/` par
défaut)&nbsp;: sauvegardez ce répertoire et restaurez-le en même temps que la
base de données, sinon les enregistrements restaurés pointent vers des fichiers
absents ([Ajouter un envoi de fichier](tutorial.md#attachments)).

**Sauvegardes.** `./<app> db backup PATH` écrit une copie cohérente de la base
de données configurée (`CYBERTRAIN_DATABASE`) pendant que le serveur continue de
tourner&nbsp;: le `VACUUM INTO` de SQLite (3.27 ou plus récent&nbsp;; le binaire
le vérifie) lit un seul instantané, et sous WAL les écritures du serveur se
poursuivent pendant ce temps. La copie est écrite dans un fichier temporaire à
côté de `PATH`, créé de façon exclusive avec le mode 0600 (le fichier contient
des condensats de mots de passe et des jetons de session), synchronisé sur
disque (fsync), et seulement ensuite renommé en `PATH`, de sorte qu’une copie
échouée ou interrompue ne laisse jamais de fichier partiel sous le vrai nom (le
fichier temporaire est supprimé). Un `PATH` existant est refusé sauf si vous
passez `--force`&nbsp;; la base de données elle-même n’est jamais une cible, et
une base `:memory:` n’est jamais une source.

```sh
./blog db backup /srv/blog/backups/before-upgrade.sqlite3
./blog db backup /srv/blog/backups/ --keep 14    # blog-20261025T031500Z.sqlite3, les 14 plus récents sont conservés
```

Une cible qui se termine par `/` (ou un répertoire existant) reçoit un nom
daté, `<app>-<YYYYmmddTHHMMSSZ>.sqlite3` en UTC, dans un répertoire créé avec le
mode 0700 s’il n’existe pas&nbsp;; `--keep N` supprime alors les fichiers les
plus anciens ayant exactement cette forme au-delà de N et ne touche à rien
d’autre à cet endroit. Restaurer consiste à copier une sauvegarde par-dessus le
fichier de la base de données, serveur arrêté (et à supprimer les fichiers
`-wal` et `-shm` qui l’accompagnent).

**VACUUM.** Supprimer des lignes laisse des pages libres dans le fichier.
`./<app> db vacuum` lance `VACUUM` puis `PRAGMA wal_checkpoint(TRUNCATE)`, de
sorte que les pages reconstruites atteignent le fichier de la base de données,
que le fichier est ramené à sa nouvelle taille et que le WAL est vidé&nbsp;; il
affiche la taille sur disque (base de données plus WAL) avant et après.
`VACUUM` réécrit tout le fichier et détient le verrou d’écriture pendant ce
temps&nbsp;: lancez-le donc quand l’application est calme. Si un lecteur
empêche le checkpoint de se terminer, la commande le signale, et le WAL
diminue lors d’un checkpoint ultérieur.

**Lancez les sauvegardes hors du serveur.** Un appel SQLite occupe son worker
OS jusqu’à ce qu’il rende la main, donc un gros `VACUUM INTO` dans une tâche
`Scheduler` bloquerait les requêtes (avec `SPINEL_WORKERS=1`, toutes) pendant
toute la durée de la copie. Lancez plutôt la commande depuis cron ou un timer
systemd, dans un processus séparé&nbsp;:

```sh
# crontab de l’utilisateur de l’application : chaque nuit à 03:15, conserver deux semaines
15 3 * * * cd /srv/blog/current && ./blog db backup /srv/blog/backups/ --keep 14
```

Une application qui veut faire ses sauvegardes elle-même peut lancer son propre
binaire comme processus enfant depuis une tâche planifiée, plutôt que
d’exécuter le SQL sur son propre thread&nbsp;: `system` n’attend l’enfant que
sur le thread du scheduler, et les requêtes continuent d’être servies pendant
ce temps (utilisez `system` avec une liste d’arguments, jamais une chaîne
contenant des données de la requête). Une copie qui dure plus
longtemps que `health_worker_stale` fait répondre `worker stale` au contrôle de
santé jusqu’à ce qu’elle soit terminée.

```ruby
# config/app.rb, dans un binaire servi lancé depuis son propre répertoire (dist/)
Cybertrain::Scheduler.every(86_400, "nightly backup") do
  system("./blog", "db", "backup", "storage/backups/", "--keep", "14")
end
```

**Contrôle de santé.** Tant que le contrôle de santé est activé (il l’est par
défaut&nbsp;; un `config.health_path` vide le désactive), l’application servie
répond à `GET /up` (et `HEAD`) avant les fichiers statiques, la session, le
CSRF et le routeur&nbsp;: aucun contrôleur n’intervient, aucun `before_action`
de connexion ne peut le rediriger, et il ne définit aucun cookie. Il exécute
`SELECT count(*) FROM sqlite_master`, qui doit lire la page du schéma dans le
fichier (un simple `SELECT 1` n’y touche jamais), et répond en `text/plain` avec
`Cache-Control: no-store`&nbsp;:

| Statut | Corps | Quand |
| --- | --- | --- |
| 200 | `ok` | la requête a réussi |
| 503 | `database unavailable` | elle a levé `Cybertrain::DB::Error` (le fichier est absent ou illisible, le pool est fermé) |
| 503 | `worker stale` | le `Scheduler` d’arrière-plan tourne et son dernier tick est plus ancien que `health_worker_stale` secondes (300)&nbsp;: une tâche est bloquée, ou dure bien trop longtemps |
| 503 | `feed stale` | un [flux WebSocket](external-services.md#consuming-websocket-feeds), dans ce processus ou un autre, n’a pas signalé son état, ou n’a rien reçu (pas même un pong), depuis `health_feed_stale` secondes (180)&nbsp;; voir [Santé des flux](realtime.md#feed-health) |

Une interrogation est journalisée comme toute requête (deux lignes). Le chemin
est `config.health_path` (`CYBERTRAIN_HEALTH_PATH`, `/up` par défaut&nbsp;; une
valeur vide désactive le contrôle, et le chemin passe alors à `public/` et au
routeur comme avant). Un répartiteur de charge, kamal-proxy ou un script de
déploiement peut l’interroger&nbsp;; `public/up.html`, qu’écrit
`cybertrain new` et que sa configuration Kamal interroge toujours, montre
seulement que le processus répond en HTTP.

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
contient les autres étiquettes dans l’ordre. Les octets qui ne sont pas de
l’UTF-8 valide sont écrits `�` en JSON&nbsp;; une ligne de texte garde
les octets tels qu’ils ont été journalisés. Un format autre que `:text` ou
`:json` arrête le démarrage&nbsp;:
`error: log_format must be :text or :json (got :xml)`. La première ligne du
démarrage lui-même (l’avertissement sur `mail_delivery_method :test` hors
des tests) suit le format&nbsp;; les avertissements sur un réglage
d’application illisible (`setting_int`, `setting_bool`) sont journalisés
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
peut pas lire, répondus avant que l’application ne la voie, n’en portent pas.
Chaque ligne journalisée pendant la requête porte l’identifiant comme
première étiquette, y compris les propres lignes `Cybertrain.logger.info` de
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
[Sous-systèmes](how-it-works.md#subsystems))&nbsp;:

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
l’entoure. Aucun des deux ne lève jamais d’exception chez l’appelant&nbsp;: si
le signalement lui-même échoue, le journal dit
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
  a traité.
- Chaque tentative échouée d’un job (`where` sa classe ou son type&nbsp;;
  `job.attempt` et `job.max_attempts` dans le contexte), une tentative de
  `retry_on` et un abandon de `discard_on`. `job.max_attempts` vaut
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

Non signalés&nbsp;: une exception pendant l’écriture d’un corps diffusé (le
serveur journalise `stream error:`&nbsp;; la réponse a commencé), et un job
dont le type n’a pas de handler. Chaque ligne de journal que le framework
écrivait auparavant reste telle quelle&nbsp;; le rapport vient en plus.

**Ce qui n’est jamais envoyé.** Les paramètres, les en-têtes, les cookies, la
session, l’adresse du client et la chaîne de requête ne sont pas dans un
événement&nbsp;; le chemin d’une requête est filtré comme le filtre le
journal des requêtes. Seul ce que l’application met dans `context:` est
ajouté. Les messages d’exception ne sont pas filtrés&nbsp;: un message qui
contient des données personnelles (le refus d’un serveur SMTP qui nomme le
destinataire) est envoyé tel quel.

**Livraison.** Les rapports vont dans une file de 100 et un thread les livre.
Une même classe, un même message et un même `where` sont mis en file au plus
une fois par minute, si bien qu’une page qui échoue pour chaque visiteur fait
un rapport par minute&nbsp;; quand la file est pleine, un rapport est
abandonné et compté, et `error reports dropped: <n>` est journalisé au niveau
warn au plus une fois par minute. Tant qu’il n’y a ni abonné ni DSN, rien
n’est mis en file et aucun thread ne démarre. Une livraison qui échoue est
journalisée, `error delivery failed: <Class>: <message>`, et le rapport
suivant démarre un nouveau thread si l’ancien s’est terminé. Quand le
serveur, un worker ou un processus feeds s’arrête, il attend jusqu’à 2
secondes les rapports en file après l’arrêt de ses services&nbsp;; ce qui
reste est perdu. Une reconstruction en développement attend aussi.

**Envoyer à Sentry ou GlitchTip.** Avec la ligne dans `bin/<app>.rb`, définir
`CYBERTRAIN_SENTRY_DSN` (ou `c.sentry_dsn`) au DSN du projet envoie chaque
rapport comme un événement Sentry&nbsp;:

```sh
CYBERTRAIN_SENTRY_DSN=https://<public key>@o1.ingest.sentry.io/42
CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # facultatif : envoyé comme release de l'événement
CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # facultatif : en envoyer un quart
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
  démarrage&nbsp;:
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
- Chaque envoi attend au plus 5 secondes et n’est jamais retenté. Un refus est
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
La conception&nbsp;: [docs/design.md](../design.md) D86 et D87.

### Mettre à jour les journaux et les rapports d’erreur depuis 0.4

- Chaque ligne de journal change de forme&nbsp;: le niveau entre crochets au
  début (`[INFO]`) cède la place à l’heure, au niveau et aux étiquettes,
  `2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`. Ce
  qui lit le journal (un grep de `[ERROR]` dans un script, une alerte)
  change avec elle&nbsp;; un test qui comparait une ligne capturée en entier
  compare le niveau et le message séparément.
- Chaque réponse porte `X-Request-Id`. Un proxy qui en posait un voit le
  sien utilisé seulement s’il est de confiance.
- `cybertrain_jobs` gagne la colonne `request_id`&nbsp;; le premier processus
  qui touche la table l’ajoute.
- Le framework définit maintenant des méthodes nommées `request_id` et
  `release` (chacune renvoie une String) et `handle` (la valeur du bloc).
  Une colonne de modèle de l’un de ces noms dont le lecteur renvoie un autre
  type (un `request_id` entier, une clé étrangère) peut arrêter la
  compilation, car un nom de méthode n’a qu’un type de retour dans tout le
  programme (règle 34 de spikes/NOTES.md), et gen ne la renomme pas&nbsp;:
  renommez la colonne.
- `cybertrain test` ignore un `CYBERTRAIN_LOG_FORMAT` et un
  `CYBERTRAIN_SENTRY_DSN` exportés (les tests lisent des lignes de texte et
  n’envoient rien) sauf si `config/app.rb` les fixe. Les tests de mot de passe
  qu’écrit `generate authentication` coupent les lignes JSON dans leur
  `with_config`&nbsp;; une application générée plus tôt dont les tests
  tournent avec `log_format :json` relance le générateur ou recopie ce
  changement.
- `require "cybertrain"` lie maintenant `HttpClient` et la couche TLS, à
  travers l’envoyeur Sentry.
