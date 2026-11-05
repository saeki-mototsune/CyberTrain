---
source_sha256: 77841c7742a645fc550aff1b97447e8c187efef9c00561905363ab8bed7e5a54
---
# Tâches de fond et exploitation

## Tâches de fond

Une application qui doit faire quelque chose en dehors d’une requête (envoyer
une notification une fois la réponse partie, purger les anciennes lignes toutes
les heures, réessayer un appel qui a échoué) l’enregistre auprès du framework,
qui l’exécute sur des threads d’arrière-plan du processus qui sert, ou d’un
processus worker séparé&nbsp;:

```ruby
# config/app.rb (ou un fichier que bin/<app>.rb requiert avant Cybertrain::Main.run)
Cybertrain::Scheduler.every(3600, "prune sessions") do
  Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
end

Cybertrain::Job.handle("welcome_mail") do |payload|
  data = Cybertrain::Cast.hash(JSON.parse(payload))
  WelcomeMail.deliver(data["email"].to_s)   # lever une exception pour qu’il soit réessayé
end
```

```ruby
# dans une action, après l’enregistrement de l’utilisateur
Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => @user.email }))
Cybertrain::Job.enqueue("reminder", @order.id.to_s, run_at: Time.now + 600)
```

- **Où cela s’exécute.** Les tâches planifiées s’exécutent sur un thread de
  scheduler&nbsp;; les jobs s’exécutent sur `job_threads` threads de jobs
  bien à eux (3, `CYBERTRAIN_JOB_THREADS`), si bien qu’un long job ne
  retarde jamais une tâche. Les deux démarrent quand le binaire sert
  (`./<app>`, `./<app> server`) ou tourne comme worker (`./<app> worker`,
  voir [Rôles des processus](#process-roles)), après que le démarrage a
  connecté la base de données et défini `SPINEL_WORKERS`&nbsp;; les
  commandes `migrate`, `db ...`, `console` et `Main.command` ne les
  démarrent jamais, pas plus que `Cybertrain::Test::Client`. Une tâche
  s’exécute une première fois `seconds` après le démarrage, puis `seconds`
  après le début de chaque exécution. Chaque exécution est enveloppée dans
  un rescue qui journalise `[ERROR] Scheduled task "name" failed: ...`, et
  la boucle continue. Le bloc ne prend pas d’argument (Spinel n’a pas
  d’`instance_eval`). `Cybertrain::Scheduler.last_tick` est la seconde epoch
  du dernier tick, pour un contrôle de santé de votre cru.
- **Jobs.** `Job.enqueue` ajoute une ligne à la table `cybertrain_jobs`, que
  le framework crée lui-même (`CREATE TABLE IF NOT EXISTS`, à la première
  utilisation) et laisse hors de `db/schema.rb`. La charge utile est une
  String&nbsp;: encodez en JSON les données structurées. Dans une
  `DB.transaction`, la ligne est validée ou annulée avec le reste. Chaque
  thread de jobs réserve le job échu le plus ancien dans une courte
  transaction `BEGIN IMMEDIATE`, exécute son handler hors de celle-ci, le
  marque `done` et cherche le suivant&nbsp;; quand rien n’est échu, il
  attend `job_poll_interval` secondes (1), si bien qu’un job mis en file par
  une requête démarre en une seconde environ. Un handler qui lève une
  exception est réessayé 1, 5, 15 puis 60 minutes plus tard, avec
  `Class: message` (jusqu’à 1000 caractères) dans `last_error`, jusqu’à ce
  que `job_max_attempts` (5) tentatives aient échoué&nbsp;: la ligne passe
  alors à `failed` et reste là pour que vous l’examiniez. Un job dont le
  type n’a pas de handler passe aussitôt à `failed`&nbsp;; `Job.enqueue`
  refuse un type non enregistré. `Job.state_count("failed")` et
  `Job.prune_done(before_epoch)` aident pour une page de santé et le
  ménage.
- **Au moins une fois.** Un job peut s’exécuter deux fois&nbsp;: un
  processus tué, ou bloqué plus longtemps que `job_heartbeat_stale`
  (300&nbsp;s), peut encore exécuter un job quand un autre processus
  reprend la ligne (ci-dessous). Seul le résultat de la réservation qui
  détient la ligne compte (le résultat tardif d’une réservation antérieure
  est ignoré), mais les effets de bord du handler ont eu lieu deux
  fois&nbsp;: écrivez des
  handlers qui peuvent sans risque s’exécuter de nouveau (vérifiez si le
  mail est déjà parti, faites un upsert plutôt qu’un insert), comme avec
  toute file de jobs.
- **Concurrence par type.** `Job.handle("sync_account", concurrency: 1) {
  ... }` laisse au plus ce nombre de jobs de ce type s’exécuter en même
  temps, sur tous les processus qui partagent la base (pour une API à débit
  limité, ou un travail qui ne doit pas se chevaucher)&nbsp;; la valeur par
  défaut, 0, signifie aucune limite. Les autres types continuent pendant ce
  temps. La limite compte les lignes `running`, elle tient donc tant que
  les battements de cœur tiennent&nbsp;: un handler qui tourne encore après
  que son battement de cœur a vieilli est chevauché par la prochaine
  exécution de la ligne reprise (ci-dessous)&nbsp;; un travail qui ne doit
  jamais se chevaucher a besoin de sa propre protection.
- **Plusieurs workers par base de données.** Chaque processus qui exécute
  des jobs écrit un battement de cœur pour les jobs en cours toutes les
  `job_heartbeat_interval` (30&nbsp;s). Une ligne `running` dont le
  battement de cœur est plus vieux que `job_heartbeat_stale` (un processus
  qui a planté ou a été arrêté en plein job) est remise en file par le
  premier processus qui regarde, à son démarrage puis une fois par minute.
  Les tâches planifiées s’exécutent dans un seul processus à la fois&nbsp;:
  les processus partagent un bail dans la base (`cybertrain_leases`,
  renouvelé à chaque tick, `scheduler_lease_ttl` 30&nbsp;s), et seul son
  détenteur exécute les tâches échues&nbsp;; un autre prend le relais quand
  il cesse de le renouveler. Le bail est renouvelé avant chaque tâche, pas
  pendant qu’elle tourne&nbsp;: une tâche plus longue que le ttl peut donc
  chevaucher celles du détenteur suivant. Gardez les tâches courtes
  (`Job.enqueue` pour le vrai travail) et sûres à répéter. Deux processus `worker`, ou un serveur et un
  worker, peuvent donc partager un même fichier SQLite&nbsp;;
  `CYBERTRAIN_WORKER=0` désactive les jobs, les tâches et les flux dans un
  processus `server` qui ne doit servir que du HTTP.
- **Arrêt.** Sur `SIGTERM`, les threads de jobs cessent de réserver de
  nouveaux jobs, et le processus attend jusqu’à `job_drain_timeout`
  (10&nbsp;s) les jobs en cours. Un job qui tourne encore garde alors sa
  ligne `running`&nbsp;; son battement de cœur s’est arrêté, donc un autre
  processus l’exécute de nouveau une fois qu’il est périmé.
- **Gardez les tâches courtes.** Les tâches s’exécutent une par une sur le
  thread du scheduler, et un appel SQLite occupe son worker OS jusqu’à ce
  qu’il revienne&nbsp;: avec `SPINEL_WORKERS=1` (la valeur par défaut), une
  longue requête bloque toutes les requêtes, et tous les autres threads,
  aussi longtemps. Confiez à un job une tâche qui a du vrai travail
  (`Job.enqueue` depuis la tâche), et découpez les gros travaux (supprimer
  mille lignes par exécution, mettre en file un job par élément) plutôt que
  de tout faire d’un coup.
- **Tests.** `Cybertrain::Scheduler.run_due(now)` exécute un tick et
  `Cybertrain::Job.work_one(now)` un job, avec un temps epoch de votre
  choix, si bien qu’un test ne dort jamais.

Il n’y a pas de syntaxe cron, ni de priorité ou d’unicité pour les jobs, ni
de `deliver_later`&nbsp;: un job qui envoie un mail appelle lui-même
`Cybertrain::Mailer` ([Envoyer des e-mails](external-services.md#sending-e-mail)).
Cela couvre «&nbsp;envoyer plus tard&nbsp;» et «&nbsp;exécuter toutes les N
secondes&nbsp;» (`docs/design.md` D28).

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
  scheduled tasks`), tournent jusqu’à `SIGTERM` puis s’arrêtent comme le fait
  un serveur. Ils exécutent toujours leur travail&nbsp;: `CYBERTRAIN_WORKER=0`,
  réglé pour le rôle web, ne les désactive pas.
- `feeds` avec des noms n’exécute que ces abonnements (un conteneur par
  flux), et un nom inconnu arrête le démarrage avec la liste des noms
  enregistrés. Avec les flux dans leur propre processus, réglez
  `CYBERTRAIN_WORKER=0` sur les serveurs, sinon chaque processus recevrait
  chaque flux.
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

Une interrogation est journalisée comme toute requête (deux lignes). Le chemin
est `config.health_path` (`CYBERTRAIN_HEALTH_PATH`, `/up` par défaut&nbsp;; une
valeur vide désactive le contrôle, et le chemin passe alors à `public/` et au
routeur comme avant). Un répartiteur de charge, kamal-proxy ou un script de
déploiement peut l’interroger&nbsp;; `public/up.html`, qu’écrit
`cybertrain new` et que sa configuration Kamal interroge toujours, montre
seulement que le processus répond en HTTP.
