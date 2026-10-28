---
source_sha256: 5fd1dcbbdc9f9499d55d66c8be021ada6717fce4bdd06c2b3f16f4702d16f6fa
---
# Tâches de fond et exploitation

## Tâches de fond

Une application qui doit faire quelque chose en dehors d’une requête (envoyer
une notification une fois la réponse partie, purger les anciennes lignes toutes
les heures, réessayer un appel qui a échoué) l’enregistre auprès du framework,
qui l’exécute sur un thread d’arrière-plan du processus qui sert&nbsp;:

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

- **Quand il s’exécute.** Le thread démarre quand le binaire sert (`./<app>`,
  `./<app> server`), après que le démarrage a connecté la base de données, lié
  le port et défini `SPINEL_WORKERS`&nbsp;; les commandes `migrate`, `db ...` et
  `Main.command` ne le démarrent jamais, pas plus que
  `Cybertrain::Test::Client`. Une tâche s’exécute une première fois `seconds`
  après le démarrage, puis `seconds` après le début de chaque exécution. Chaque
  exécution est enveloppée dans un rescue qui journalise `[ERROR] Scheduled task
  "name" failed: ...`, et la boucle continue. Le bloc ne prend pas d’argument
  (Spinel n’a pas d’`instance_eval`). `Cybertrain::Scheduler.last_tick` est la
  seconde epoch du dernier tick, pour un contrôle de santé de votre cru.
- **Jobs.** `Job.enqueue` ajoute une ligne à la table `cybertrain_jobs`, que le
  framework crée lui-même (`CREATE TABLE IF NOT EXISTS`, à la première
  utilisation) et laisse hors de `db/schema.rb`. La charge utile est une
  String&nbsp;: encodez en JSON les données structurées. Dans un
  `DB.transaction`, la ligne est validée ou annulée avec le reste. Le worker,
  une tâche du scheduler qui interroge la table toutes les `job_poll_interval`
  secondes (5), réserve le plus ancien job échu dans une courte transaction
  `BEGIN IMMEDIATE`, exécute son handler en dehors de celle-ci, et le marque
  `done`. Un handler qui lève une exception est réessayé 1, 5, 15 puis
  60 minutes plus tard, avec `Class: message` (jusqu’à 1000 caractères) dans
  `last_error`, jusqu’à ce que `job_max_attempts` (5) tentatives aient
  échoué&nbsp;: la ligne est alors `failed` et reste là pour que vous
  l’examiniez. Un job dont le type n’a pas de handler est immédiatement
  `failed`&nbsp;; `Job.enqueue` refuse un type non enregistré. Les lignes qu’un
  processus planté a laissées `running` sont remises en file au démarrage du
  worker. `Job.state_count("failed")` et `Job.prune_done(before_epoch)` aident
  pour une page de santé et le ménage.
- **Un worker par base de données.** Chaque processus qui sert exécute le
  thread, sauf avec `CYBERTRAIN_WORKER=0` (`config.worker = false`)&nbsp;: quand
  plusieurs processus partagent un même fichier SQLite, désactivez-le dans tous
  sauf un, sinon chaque tâche planifiée s’exécute une fois par processus.
- **Gardez les tâches courtes.** Les tâches et les handlers s’exécutent un par
  un sur ce seul thread, et un appel SQLite occupe son worker OS jusqu’à ce
  qu’il rende la main&nbsp;: avec `SPINEL_WORKERS=1` (la valeur par défaut), une
  longue requête bloque chaque requête HTTP pendant tout ce temps. Découpez les
  gros travaux en lots (supprimer mille lignes par exécution, mettre un job en
  file par élément) plutôt que de tout faire d’un coup.
- **Tests.** `Cybertrain::Scheduler.run_due(now)` exécute un tick et
  `Cybertrain::Job.work_one(now)` un job, avec une heure epoch que vous
  choisissez, de sorte qu’un test n’attend jamais.

Il n’y a pas de syntaxe cron, ni priorité ni unicité pour les jobs, ni
mailer&nbsp;: cela couvre «&nbsp;envoyer plus tard&nbsp;» et «&nbsp;exécuter
toutes les N secondes&nbsp;» (`docs/design.md` D28).

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
ce temps (Spinel n’a pas de `Process.wait`, et un `Process.spawn` sans lui
laisse un zombie&nbsp;: utilisez donc `system` avec une liste d’arguments, jamais
une chaîne contenant des données de la requête). Une copie qui dure plus
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
