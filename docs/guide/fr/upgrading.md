---
source_sha256: 45a936279cc9a0eb9a65fd3141efb6218521a5d3bb4a7b17ee0efb2db4fe9659
---
# Mise à jour

Comment passer une application à une version plus récente de CyberTrain. La procédure est la même pour chaque version&nbsp;: chaque section ci-dessous est une étape, dans l’ordre, avec sa commande et ce à quoi ressemble un résultat correct. Ce qu’une version demande en plus de la procédure se trouve dans les [Notes par version](#notes-by-version).

## Avant de commencer

Partez d’un état auquel vous pouvez revenir, sur la version que l’application utilise aujourd’hui&nbsp;:

```shell terminal — le répertoire de l’application
git status --short
cybertrain version
cybertrain test
```

<!-- list: points -->
- `git status --short` n’affiche rien&nbsp;: tout est commité, si bien que chaque étape suivante apparaît comme un diff à part.
- `cybertrain version` affiche la version de la commande. Celle de l’application est la `version` sous `[lock.cybertrain]` dans `spin.lock`. Les deux sont identiques, sinon `cybertrain test` s’arrête.
- `cybertrain test` passe. Un test qui échoue maintenant se corrige d’abord, sur l’ancienne version&nbsp;: ensuite, vous ne pourriez plus le distinguer d’un échec dû à la mise à jour.
- La production a une sauvegarde du jour ([Exploitation&nbsp;: sauvegardes, VACUUM, contrôle de santé](background-and-operations.md#operations-backups-vacuum-health-check)). Une version peut changer ce qui est stocké dans la base de données.

Lisez les notes de la version visée avant de changer quoi que ce soit. Une application qui saute des versions lit les notes de chaque version intermédiaire, de la plus ancienne à la plus récente.

## Installer la nouvelle commande

Le gem et le framework sont publiés à partir du même tag, et chaque version est écrite pour une version de Spinel et compile l’application avec elle ([Comment Spinel est installé](install.md#how-spinel-is-installed)). Une mise à jour commence donc par la nouvelle commande et le Spinel qu’elle épingle&nbsp;:

```shell terminal — n’importe quel répertoire
gem install cybertrain -v X.Y.Z
cybertrain version
cybertrain doctor
cybertrain setup
```

`cybertrain version` affiche `cybertrain X.Y.Z`. La sortie de `cybertrain doctor` commence par la version et le Spinel qu’elle épingle, `cybertrain X.Y.Z, pinned to Spinel SPINEL_TAG`, et contient une ligne `spinel    ok` quand ce Spinel est sur la machine. S’il y est, `cybertrain setup` dit `nothing to install`, comme lorsque le Spinel épinglé n’a pas changé avec cette version. Sinon, `cybertrain setup` compile le nouveau Spinel dans `~/.cybertrain/spinel/<release>/`, ce qui prend quelques minutes, laisse l’ancien en place et fait pointer les liens de `~/.cybertrain/bin` vers le nouveau.

Les commandes qui lancent spin font la même installation la première fois qu’elles en ont besoin, `cybertrain spin lock` à l’étape suivante comprise. Lancer `cybertrain setup` ici ne fait que choisir le moment de l’attente.

## Changer la version

La commande `cybertrain` refuse une application dont le framework est d’une autre version qu’elle ([Passer une application à une nouvelle version](install.md#moving-an-app-to-a-new-release)). L’application suit donc la commande, dans deux fichiers&nbsp;:

1. `spin.toml`&nbsp;: la ligne `cybertrain` sous `[dependencies]` nomme le nouveau tag, `ref = "vX.Y.Z"`.
2. `spin.lock`, qui est réécrit à partir de rien&nbsp;:

```shell terminal — le répertoire de l’application
rm spin.lock
cybertrain spin lock
```

La commande affiche `locked 1 package(s)`, et `git diff spin.lock` montre la nouvelle `version` et un nouveau `ref` (le commit du tag) sous `[lock.cybertrain]`. Sans le `rm`, `spin lock` garde le commit qu’il avait verrouillé et le diff est vide. Une application qui a d’autres dépendances, ou qui dépend d’une version de l’index spin, se reverrouille comme le décrit [Passer une application à une nouvelle version](install.md#moving-an-app-to-a-new-release).

Deux fichiers écrits par `cybertrain new` nomment aussi la version. Changez-les si l’application les a&nbsp;:

<!-- list: points -->
- `Dockerfile`&nbsp;: `gem install cybertrain -v X.Y.Z`. L’image est construite avec cette commande, et son `cybertrain build` s’arrête quand la version n’est pas celle qui est verrouillée.
- `.github/workflows/ci.yml`&nbsp;: le tag après `setup-cybertrain@` ([Intégration continue](testing.md#continuous-integration)).

Tant que la commande et `spin.lock` ne concordent pas, `server`, `build`, `db`, `test` et `generate` s’arrêtent avec le code de sortie 1 et «&nbsp;`error: this application's framework is cybertrain A.B.C (spin.lock), but this cybertrain command is X.Y.Z.`&nbsp;», avant de lancer spin ou d’écrire un fichier. `cybertrain spin ...` n’est jamais vérifié.

## Régénérer et lire le diff

Le code généré dans `gen/` est commité, et le générateur du nouveau framework peut l’écrire autrement ([Génération de code à la compilation](how-it-works.md#build-time-code-generation))&nbsp;:

```shell terminal — le répertoire de l’application
SPIN_DEBUG=1 cybertrain spin run gen
git status --short gen/
git diff gen/
```

Le générateur affiche `wrote` pour chaque fichier qu’il a modifié et `identical` pour les autres. Lisez le diff&nbsp;: c’est ce que la version a changé dans le code que votre application compile, et une note de version qui dit «&nbsp;après `spin run gen`&nbsp;» est réglée par cette étape. Un diff vide signifie que la version n’a rien changé à cet endroit.

Quand le générateur refuse quelque chose dans le code de l’application, il s’arrête avec un message qui dit quoi. Les notes de la version disent ce qu’il faut changer&nbsp;; relancez ensuite la commande.

## Relancer les générateurs

Le code qu’un générateur a écrit dans `app/`, `config/` et `test/` appartient à l’application, et `spin run gen` n’y touche pas. Un générateur capable de mettre ce code à jour se relance dans l’application. Aujourd’hui, c’est `generate authentication`, dans une application qui l’utilise&nbsp;:

```shell terminal — le répertoire de l’application
cybertrain generate authentication > authentication.upgrade 2>&1
patch -p1 < authentication.upgrade
```

Passez les options avec lesquelles l’application a été générée (`--invite-only`, `--confirmable`). Le générateur écrit les fichiers manquants et une migration pour les colonnes manquantes, et affiche une ligne `manual` et un diff pour chaque fichier existant qu’il écrirait autrement, sans le modifier. `patch -p1` applique ces diffs&nbsp;; appliquez à la main ceux des fichiers que vous avez modifiés, et supprimez les fichiers qu’une ligne `manual` dit remplacés ([Relancer le générateur](authentication.md#running-the-generator-again)).

L’étape est terminée quand une seconde exécution n’affiche plus aucune ligne `manual`. Supprimez alors `authentication.upgrade`. Les autres générateurs (`scaffold`, `attachment`, `job`, `helper`, `component`) n’écrivent que du code nouveau&nbsp;; ce qu’une version change dans le code qu’ils ont écrit auparavant figure dans ses notes.

## Migrer la base de données

```shell terminal — le répertoire de l’application
cybertrain db migrate
cybertrain db status
```

`db migrate` affiche `== <version> <Name>: migrating` pour chaque migration ajoutée par les générateurs, l’applique, puis réécrit `db/schema.rb` et les modèles de `gen/`&nbsp;; `db status` montre alors `up` sur chaque ligne. Une table qui appartient au framework (`cybertrain_jobs`) n’a pas besoin de migration&nbsp;: le premier processus qui y touche ajoute une colonne manquante.

Une version qui change la façon dont les données existantes sont stockées nomme une commande `db` dans ses notes. Lancez-la ici, sur la base de développement, puis de nouveau sur celle de production pendant le déploiement ([Déployer](#deploy)). Une telle commande peut être lancée deux fois sans risque.

## Appliquer les notes de la version

Parcourez la section de la version dans les [Notes par version](#notes-by-version), sujet par sujet. Chaque entrée dit ce qui a changé et ce qu’il faut faire. Une entrée dont le sujet n’est pas utilisé par l’application ne demande rien.

La plupart des entrées sont trouvées par l’étape suivante, sous la forme d’une erreur de compilation ou d’un test qui échoue. Celles qui ne le sont pas concernent les données stockées, les cookies, les journaux et tout ce qui se trouve hors du code de l’application&nbsp;: les scripts qui lisent le journal, le proxy, la supervision. Vérifiez celles-là en les lisant.

## Lancer les tests

```shell terminal — le répertoire de l’application
cybertrain test
cybertrain build
```

`cybertrain test` compile les tests avec le nouveau framework et passe. `cybertrain build` compile le binaire que la production exécute, `dist/<app>`, avec les vues embarquées. Un réglage exigé par la nouvelle version arrête ce binaire au démarrage avec un message qui nomme le réglage&nbsp;; démarrez-le donc une fois comme le fait la production avant de déployer ([une répétition de la production](../deploy.en.md#2-6-a-production-rehearsal)).

Commitez ensuite tout ce que les étapes ont changé&nbsp;: `spin.toml`, `spin.lock`, `gen/`, `db/`, les fichiers des générateurs et vos propres modifications.

## Déployer

Dans cet ordre&nbsp;:

1. Installez la nouvelle commande sur chaque machine qui construit l’application (le serveur, dans [le tutoriel de déploiement](../deploy.en.md#upgrading-the-framework)&nbsp;; le `Dockerfile` avec Kamal), et lancez-y `cybertrain setup`. La construction du déploiement s’arrête quand la commande et `spin.lock` diffèrent.
2. Ajoutez à l’environnement les réglages et les secrets que nomment les notes ([Configuration et variables d’environnement](configuration.md#configuration-and-environment-variables)).
3. Faites une sauvegarde.
4. Arrêtez tous les anciens processus (`server`, `worker`, `feeds`) avant que le premier nouveau ne démarre, quand les notes le demandent ([Rôles des processus](background-and-operations.md#process-roles)).
5. Déployez comme d’habitude&nbsp;: la construction, `./<app> migrate`, puis les commandes `db` que nomment les notes, puis les nouveaux processus.

Pour revenir en arrière, basculez sur la construction précédente et redémarrez ([Revenir en arrière](../deploy.en.md#rolling-back)). Cela n’annule pas les migrations, et une commande `db` qui a réécrit des données stockées n’est pas défaite. À moins que les notes de la version ne disent que l’ancienne version lit les données réécrites, revenir en arrière après une telle commande signifie restaurer la sauvegarde de l’étape 3.

## Les étapes dont une version a besoin

Chaque étape s’exécute pour chaque version&nbsp;; la plupart se terminent aussitôt quand la version n’en a pas besoin. Chacune le dit elle-même&nbsp;:

| Étape | Rien à faire quand |
| --- | --- |
| Installer la nouvelle commande | jamais pour la commande&nbsp;; pour son Spinel, quand `cybertrain setup` dit `nothing to install` |
| Changer la version | jamais&nbsp;: chaque version la change |
| Régénérer | `git status --short gen/` n’affiche rien |
| Relancer les générateurs | l’exécution n’affiche ni ligne `manual` ni ligne `create` |
| Migrer | `cybertrain db status` ne montre aucune ligne `down` |
| Appliquer les notes | la version n’a pas de section ci-dessous |
| Tests, déploiement | jamais |

Une version corrective (de `X.Y.Z` à `X.Y.Z+1`) ne contient aucun changement de compatibilité et n’a pas de notes. Une version mineure (de `X.Y` à `X.Y+1`) peut en contenir, et elle a alors une section ci-dessous ([le contrat de compatibilité](../compatibility.md#changing-a-contract)).

## Notes par version

Les sections qui suivent contiennent ce que chaque version demande en plus de la procédure, de la plus récente à la plus ancienne. Une section porte le nom des deux versions entre lesquelles elle se situe et se divise par sujet. Les notes d’une version s’écrivent ici et nulle part ailleurs&nbsp;: le guide d’un sujet décrit le framework tel qu’il est, et la procédure ci-dessus ne nomme aucune version.

## De 0.4 à 0.5

### Depuis 0.4&nbsp;: requêtes

Ce qui change pour une application écrite pour 0.4&nbsp;:

- Chaque session prend fin une fois&nbsp;: le cookie chiffré ne lit pas l’ancien cookie signé, donc les utilisateurs se reconnectent. Le code qui appelle `Session.load` ou `Session.dump` passe la clé dérivée, `Crypto.derive_key(secret, SessionStore::SESSION_KEY_LABEL)`&nbsp;; le secret brut lève `Encryptor::Error`.
- Chaque application est liée à OpenSSL ([Installation](install.md#requirements))&nbsp;; un Dockerfile écrit auparavant par `cybertrain new` a besoin de `libssl-dev` dans son étape de build et de `libssl3t64` dans son étape d’exécution.
- Un segment dynamique ne capture plus de `.` dans une route qui prend un format&nbsp;: un identifiant contenant des points a besoin de `format: false` sur sa route.
- Une lambda `url_resolver` écrite à la main prend trois arguments, `->(name, args, options)`&nbsp;; une application qui passe `Gen::Routes.url_resolver` n’a besoin que de `spin run gen`.
- `params.permit` renvoie `Hash{String => Object}`&nbsp;: appelez `Cast.str` ou `.to_s` sur une valeur avant de l’utiliser comme String.
- `rate_limit` compte dans le cache&nbsp;: `store: :memory` garde l’ancien compteur par processus, deux limites dans un même contrôleur ont besoin de leur propre `name:`, une méthode `by:` qui répond nil ou `""` lève une erreur, et une méthode `with:` qui ne rend rien est suivie de la 429.
- Les helpers numériques lèvent une erreur pour une valeur qui n’est pas un nombre (nil donne `""` dans un template, comme avant), et pour une précision hors de 0 à 100.
- `include A, B` dans un contrôleur ou un modèle inclut B d’abord, comme Ruby&nbsp;; l’`include` d’un module qui n’est pas un concern est laissé à Ruby.
- Tous les ETag changent une fois (ils portent désormais le format de la requête et une empreinte du build), une réponse négociée par `Accept` envoie `Vary: Accept`, et le repli html couvre tout `Accept` qui liste `text/html` ou `*/*`. Une requête qui peut se replier sur html (`application/json, text/html`) a son propre ETag, distinct de celui d’une requête pour ce seul format&nbsp;; `text/html;q=0` dans `Accept` ne reçoit pas le repli html (406 quand l’action n’a que du html), même à côté de `*/*`&nbsp;; et `If-None-Match: *` reçoit une 304 d’une réponse validée par `last_modified:` seul.
- `permit` et `expect` lèvent `ArgumentError` pour un filtre qui n’est pas un Array&nbsp;; un `layout` qui nomme un layout absent lève `MissingTemplate` (le layout `application` par défaut reste facultatif)&nbsp;; un cookie du jar de plus de 4096 octets lève `Session::CookieOverflow`.
- `public/style.css` continue de fonctionner&nbsp;; le déplacer dans `app/assets/stylesheets/` est facultatif ([Assets](assets.md#moving-publicstylecss)).
- Les messages de validation viennent du dictionnaire fourni ([Internationalisation](i18n.md#models-and-validation-messages)), avec le même texte anglais sauf en trois points&nbsp;: un message sur `:base` n’est plus préfixé par "Base", un attribut qui se termine par `_id` est nommé sans "id" ("Article can't be blank", et non "Article id can't be blank"), et une limite de longueur de 1 donne "1 character". Les tests qui comparent ces messages changent.
- `time_tag` sans `format:`, ou avec un nom de format, formate par `I18n.l` (le même texte anglais qu’avant dans une page en anglais).
- gen écrit `gen/locales.rb` (vide sans `config/locales/`) et charge `app/mailers/**/*.rb`&nbsp;; `cybertrain new` écrit `config/locales/en.yml`, qu’une application plus ancienne peut ajouter.
- `allow_unauthenticated_access` est désormais une méthode du framework&nbsp;; celle que le générateur de 0.4 a écrite dans `ApplicationController` fonctionne toujours et l’emporte. Relancer `cybertrain generate authentication` ajoute la réinitialisation du mot de passe, le verrouillage, «&nbsp;rester connecté&nbsp;», la page de compte et les administrateurs, et affiche des diffs pour les fichiers que 0.4 a écrits ([Depuis 0.4&nbsp;: authentification](#from-04-authentication)).

### Depuis 0.4&nbsp;: modèles et base de données

Chaque changement ci-dessous est une modification à faire en un passage dans
une application écrite pour CyberTrain 0.4&nbsp;:

1. Un lecteur `has_many` renvoie une relation, pas un Array&nbsp;: ajoutez
   `.to_a` avant une méthode propre aux Array (`map`, `select`, `[]`, `+`).
   Les templates ne changent pas.
2. Les dates-heures sont stockées au format de Rails&nbsp;: lancez
   `db normalize` une fois après la mise à jour ([Dates-heures et `db
   normalize`](models.md#datetimes-and-db-normalize))&nbsp;; d’ici là, une colonne
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
   générée sous `<column>_column` ([Noms de colonnes](models.md#column-names)).
10. Un lecteur `belongs_to` garde le parent qu’il a lu jusqu’à ce que la clé
    étrangère change (il le relisait à chaque appel)&nbsp;: appelez `reload`
    pour voir un changement fait par un autre processus.

### Depuis 0.4&nbsp;: authentification

Relancez `cybertrain generate authentication` dans l’application que 0.4 a générée ([Relancer les générateurs](#run-the-generators-again)).

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) est la sortie complète pour une application avec inscription que 0.4 a générée.

<!-- list: points -->
- Le bloc de 0.4 dans `ApplicationController` devient `include Authentication`. `--force` ne le remplace que s’il est exactement tel que 0.4 l’a écrit.
- Avec `--confirmable`, les diffs des contrôleurs sessions et registrations portent une ligne `IMPORTANT:`&nbsp;: tant qu’ils ne sont pas appliqués, un compte non confirmé n’apprend pas pourquoi il ne peut pas se connecter, et une inscription ne reçoit aucun lien. Dans une application 0.4, le concern est un nouveau fichier, écrit avec son contrôle de confirmation, si bien qu’il ne démarre toujours aucune session pour un compte non confirmé (et journalise `WARN [<request id>] no session started: user <id> has not confirmed its address`) même si ces diffs ne sont jamais appliqués.
- Chaque session prend fin une fois à la mise à jour (le cookie est désormais chiffré).

### Depuis 0.4&nbsp;: configuration

Deux valeurs par défaut ont changé après 0.4
([Configuration et variables d’environnement](configuration.md#configuration-and-environment-variables))&nbsp;:

- L’imbrication des rendus était illimitée&nbsp;; elle est désormais plafonnée
  par `max_render_depth`, 12 par défaut. Une application dont l’arbre de
  partiels est plus profond (commentaires en fil, menu de catégories) obtient
  une erreur de template tant qu’elle n’augmente pas ce réglage.
- `job_poll_interval` valait 5 secondes et vaut maintenant 1&nbsp;: les jobs
  s’exécutent sur leurs propres threads, et un thread inoccupé cherche du
  travail chaque seconde.

### Depuis 0.4&nbsp;: jobs

- `cybertrain_jobs` gagne la colonne `concurrency_key` et l’état
  `discarded`&nbsp;; le premier processus qui touche la table ajoute la
  colonne. Le code qui liste les états (un tableau de bord sur
  `Job.state_count`) ajoute `discarded`. `Job.prune_done` ne purge toujours
  que les lignes `done`.
- Les tâches `every` reprennent à partir du calendrier après un redémarrage
  au lieu de repartir de zéro&nbsp;: un intervalle écoulé pendant que le
  processus était arrêté s’exécute une fois au démarrage.
- Une application qui exécute des jobs arrête tous les anciens processus
  avant que le premier nouveau démarre ([Déployer](#deploy), étape 4). 0.4
  n’écrit aucun battement de cœur pour un job qu’il exécute&nbsp;: un nouveau
  processus prend donc ce job pour abandonné, le remet en file et l’exécute
  une seconde fois à côté de l’ancien.
- Donner une clé à un kind existant (`limits_concurrency ... key:`) repose
  sur cet arrêt. Le
  premier nouveau processus attribue leur clé aux lignes `queued` mises en
  file auparavant (il journalise les ids des lignes dont la charge utile n’a
  pas ce champ), et une ligne `running` laissée par un ancien processus
  reçoit sa clé quand elle est reprise.
- `jobs` est désormais une commande intégrée&nbsp;: une commande de
  l’application nommée `jobs` doit être renommée.

### Depuis 0.4&nbsp;: journaux et rapports d’erreur

- Chaque ligne de journal change de forme&nbsp;: le niveau entre crochets au
  début (`[INFO]`) cède la place à l’heure, au niveau et aux étiquettes,
  `2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`. Ce
  qui lit le journal (un grep de `[ERROR]` dans un script, une alerte)
  change avec elle&nbsp;; un test qui cherchait une ligne entière cherche
  le niveau et le message séparément (`" ERROR "` et le message&nbsp;;
  [Depuis 0.4&nbsp;: tests](#from-04-tests)).
- Chaque réponse de l’application porte `X-Request-Id` (pas les 400 et 413
  du serveur pour une requête qu’il ne peut pas lire). Un proxy qui en
  posait un voit le sien utilisé seulement s’il est de confiance.
- `cybertrain_jobs` gagne la colonne `request_id`&nbsp;; le premier processus
  qui touche la table l’ajoute.
- Une ligne de journal en texte ne continue plus sur les lignes
  suivantes&nbsp;: un saut de ligne ou un retour chariot dans un message ou
  une étiquette s’écrit `\n` ou `\r`. Ce qui lisait un message sur
  plusieurs lignes lit les échappements.
- Une colonne de modèle nommée `handle` se lit maintenant `handle_column`&nbsp;:
  une application qui a une colonne `users.handle` change ses appels
  `user.handle` en `user.handle_column` (les requêtes gardent le nom SQL).
  Les colonnes `request_id` ou `release` qui ne sont pas du texte sont
  refusées par gen ([Noms de colonnes](models.md#column-names)).
- `cybertrain test` ignore un `CYBERTRAIN_LOG_FORMAT` et un
  `CYBERTRAIN_SENTRY_DSN` exportés (les tests lisent des lignes de texte et
  n’envoient rien) sauf si `config/app.rb` les fixe. Les tests de mot de passe
  qu’écrit `generate authentication` coupent les lignes JSON dans leur
  `with_config`&nbsp;; une application générée plus tôt dont les tests
  tournent avec `log_format :json` relance le générateur ou recopie ce
  changement.
- `require "cybertrain"` lie maintenant `HttpClient` et la couche TLS, à
  travers l’envoyeur Sentry.

### Depuis 0.4&nbsp;: tests

- Ajoutez `test/test_helper.rb`
  ([Écrire un test](testing.md#writing-a-test)), et sortez-en ce qu’un
  fichier de support faisait au chargement (`AppTest.boot`,
  `BlogTest.boot`, migrer une base)&nbsp;: le programme de test démarre sur une
  base neuve avant le premier test, et un second démarrage ne fait que
  coûter du temps.
- Remplacez l’étape de CI `spin test` par `cybertrain test`.
- Deux fichiers qui définissent la même aide ou constante de premier
  niveau (un `new_client` dans chacun, comme les générateurs de 0.4 les
  écrivaient) sont refusés ensemble&nbsp;: déplacez l’aide dans
  `test/support/` ou renommez-en une.
- Toutes les tables sont vidées avant chaque test, donc un test ultérieur
  ne peut plus compter sur les lignes qu’un précédent a créées&nbsp;: déplacez
  ces données dans les fixtures ou dans `setup`.
- Les points d’injection d’horloge ont disparu&nbsp;: `Cybertrain::Cache.clock=`,
  `Cache.system_clock`, `RateLimit.current_time=`, `SessionStore#fixed_now=`,
  `Application.status_now=` et `Background.supervisor_clock=`. Utilisez
  `travel_to`, `travel` ou `freeze_time`, dont le bloc rétablit l’heure sans
  `ensure` de votre part.
- Les courriels des tests sont gardés dans `Cybertrain::Mailer.deliveries`&nbsp;;
  un test qui lit un courriel sur un `Test::SmtpReceiver` règle d’abord
  `Cybertrain.config.mail_delivery_method = :smtp`.
- Un test de helper écrit par le `generate helper` de 0.4 définit un
  `render_inline(source)` de premier niveau, en conflit avec celui du
  framework&nbsp;: renommez-le `render_helper_template` dans ce fichier, appels
  compris.
- `1.month.ago` s’écrit `Time.current.months_ago(1)`.
- `assert_equal` échoue avec le texte sur deux lignes de Minitest&nbsp;; un
  instantané de test qui passe ne change pas.
- `cybertrain generate authentication`, relancé, écrit les tests en forme
  de classe et nomme chaque ancien fichier qu’ils remplacent
  (`test/authentication.rb`, `test/support/app_test.rb`, ...)&nbsp;; `--force`
  les supprime.
- Un test qui cherchait une ligne de journal entière, son niveau entre
  crochets en tête, cherche le niveau et le message séparément (`" ERROR "`
  et `"password reset mail not sent: "`)&nbsp;: une ligne commence
  maintenant par l’heure et peut porter l’identifiant de la requête
  ([Journaux](logs-and-errors.md#logs)).
- Un `CYBERTRAIN_LOG_FORMAT` ou un `CYBERTRAIN_SENTRY_DSN` exporté n’atteint
  plus les tests&nbsp;; pour tester avec, fixez-les dans `config/app.rb`, ou
  affectez le DSN dans le test.
