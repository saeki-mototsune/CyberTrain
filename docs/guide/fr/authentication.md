---
source_sha256: ad73a71c35a10fd8d024458d144dd784063934ffc0d91ba95a6adcdd752bfd74
---
# Authentification

`cybertrain generate authentication` écrit la connexion par adresse e-mail et mot de passe comme le fait le générateur de Rails&nbsp;8, en code que possède l’application, avec ce qu’ajoute Devise&nbsp;: la réinitialisation du mot de passe par courriel, la confirmation facultative de l’adresse, le verrouillage, «&nbsp;rester connecté&nbsp;», une page de compte et des administrateurs.

## Le générer

```shell terminal — blog/
cybertrain generate authentication                  # une page d’inscription publique
cybertrain generate authentication --invite-only    # sans inscription : les utilisateurs viennent de la ligne de commande ou de /setup
cybertrain generate authentication --confirmable    # (dans les deux modes) les nouvelles adresses se confirment par courriel
cybertrain db migrate
```

Il écrit, dans l’application&nbsp;:

| Fichiers | Ce qu’ils sont |
| --- | --- |
| `db/migrate/*_create_users.rb`, `*_create_sessions.rb` | `users` (`email_address`, `password_digest`, `admin`, `failed_attempts`, `locked_until`&nbsp;; avec `--confirmable`, `confirmed_at` et `unconfirmed_email`) et `sessions` (une ligne par navigateur connecté, avec `remember` et `last_active_at`) |
| `app/models/user.rb`, `session.rb` | `password=`, `authenticate`, `User.authenticate_by`, les jetons, le verrouillage |
| `app/controllers/concerns/authentication.rb` | le concern `Authentication`, inclus dans `ApplicationController` |
| `sessions_controller.rb`, `registrations_controller.rb` (ou `setup_controller.rb`), `passwords_controller.rb`, `accounts_controller.rb`, `confirmations_controller.rb` | connexion, inscription (ou la page du premier utilisateur), réinitialisation du mot de passe, page de compte, confirmation |
| `app/mailers/passwords_mailer.rb`, `confirmations_mailer.rb` | les courriels |
| `app/commands/user_command.rb` | `./<app> user ...`, requis depuis `bin/<app>.rb` |
| `app/views/...` | les écrans, chaque texte passant par `t()`, et le partial `sessions/_nav` |
| `test/fixtures/users.yml`, `test/support/session_test_helper.rb`, `test/models/`, `test/controllers/`, `test/integration/` | les utilisateurs de fixture, `sign_in_as`, et des tests pour chaque partie ([Tests](#testing)) |

et des modifications, une fois chacune&nbsp;: `include Authentication` dans `ApplicationController`, les routes, la ligne de la page des jobs ([Administrateurs](#admin-users-and-the-jobs-page)), le partial de navigation dans le layout, la commande utilisateur dans `bin/<app>.rb` et le réglage `base_url` dans `config/app.rb` ([Liens dans les courriels](#links-in-mails)). Le relancer avec les mêmes options ne change rien&nbsp;: une modification déjà faite est retrouvée et sautée, et un fichier déjà tel qu’il l’écrirait est laissé. Un fichier qu’il écrirait autrement (que vous avez modifié, ou qu’un générateur plus ancien ou d’autres options ont écrit) n’est jamais écrasé sans `--force`&nbsp;: son diff est affiché à la place ([Mettre à jour depuis 0.4](#upgrading-from-04), [Activer la confirmation plus tard](#turning-on-confirmation-later)).

Les textes des écrans générés sont dans les dictionnaires anglais et japonais du framework, sous leurs clés de recherche paresseuse (`sessions.new.title`, `passwords.create.sent`)&nbsp;; une application les surcharge, ou ajoute une langue, dans `config/locales/` ([Internationalisation](i18n.md#the-bundled-dictionaries)).

## Se connecter et se déconnecter

```ruby app/controllers/concerns/authentication.rb (extrait)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session
    before_action :require_authentication
    helper_method :authenticated?
  end
```

Dès lors chaque action exige un utilisateur connecté, et un visiteur est envoyé vers `/session/new` (un 303&nbsp;; un GET est mémorisé et rejoint après la connexion s’il s’agit d’un chemin local). Un contrôleur ouvre des actions aux visiteurs comme dans Rails&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
```

`allow_unauthenticated_access(only:, except:)` est une méthode de `Cybertrain::Controller`, un `skip_before_action :require_authentication`. `resume_session` s’exécute encore sur les pages ouvertes, si bien qu’un template lit `@current_user` (et `@current_session`), ou appelle `authenticated?`. Il n’y a pas d’objet `Current`.

<!-- list: points -->
- `SessionsController` (`resource :session`)&nbsp;: `GET /session/new`, `POST /session`, `DELETE /session`. Les tentatives de connexion sont limitées à dix par adresse cliente toutes les trois minutes, comptées dans le cache, de sorte que tous les processus comptent ensemble&nbsp;; derrière un proxy, configurez les [proxys de confiance](requests.md#rate-limiting-and-the-client-address).
- Un mauvais mot de passe, une adresse inconnue et un compte verrouillé reçoivent le même message après la même vérification de mot de passe (contre un condensat factice quand il n’y a pas de compte).
- `resume_session` met fin à une connexion (et supprime sa ligne Session) si le mot de passe a changé depuis, après sa durée de vie, ou après `auth_idle_timeout` sans requête ([Rester connecté](#remember-me-and-session-limits)).
- Se déconnecter supprime la ligne Session et vide la session du cookie.

## Inscription, ou sur invitation

Par défaut le générateur écrit `RegistrationsController` (`/sign_up`), qui crée un utilisateur et le connecte. Le générateur de Rails n’a pas de page d’inscription et laisse le premier utilisateur à la console&nbsp;; CyberTrain n’a pas de console Ruby, il en écrit donc une. Les inscriptions sont limitées à dix par adresse cliente toutes les trois minutes, comme les connexions&nbsp;: chacune calcule un hachage de mot de passe, peut envoyer un lien, et son "has already been taken" dit si une adresse est inscrite.

Chaque adresse que le code généré enregistre, depuis la page d’inscription, `/setup`, la page de compte ou la commande utilisateur, doit être une seule adresse&nbsp;: `User.email_address_format?` exige exactement un `@` avec du texte de part et d’autre, et aucune virgule, aucun blanc, aucun chevron ni caractère de contrôle. Le mailer lit `ann@example.com,eve@evil.example` comme deux destinataires&nbsp;; sans ce contrôle, un compte pourrait avoir deux boîtes aux lettres, recevoir son lien de réinitialisation dans les deux et, avec `--confirmable`, être confirmé par l’une ou l’autre. L’adresse doit aussi passer le contrôle du mailer lui-même (`Cybertrain::Mailer.address_problem`)&nbsp;: de l’ASCII seulement (donc aucun blanc ni caractère de contrôle Unicode non plus), aucun de `( ) [ ] ; : \ "`, une partie locale d’au plus 64&nbsp;octets et au plus 254&nbsp;octets en tout. Une adresse que le mailer refuserait pourrait être enregistrée mais ne recevrait jamais de courrier&nbsp;; elle est donc refusée dès la saisie. Certaines adresses que les normes du courrier admettent sont refusées aussi (une partie locale entre guillemets contenant un espace ou une virgule, une adresse non ASCII)&nbsp;; la méthode est à l’application de la changer. Une adresse enregistrée avant ce contrôle n’est pas contrôlée de nouveau, si bien que son compte peut toujours être réinitialisé et utilisé pour se connecter.

`--invite-only` n’écrit pas de page d’inscription, le bon choix par défaut pour un outil interne, où sinon le premier à atteindre le serveur obtiendrait un compte. Le premier utilisateur vient de la commande utilisateur, ou de `SetupController` (`GET` et `POST /setup`), qui crée l’utilisateur et le connecte&nbsp;:

<!-- list: points -->
- Elle ne répond que tant qu’aucun utilisateur n’existe, qu’avec le jeton à usage unique, et qu’à une connexion dont le pair de la socket est l’adresse de bouclage et qui ne porte pas d’en-tête `X-Forwarded-For` (un proxy sur le même hôte fait de chaque requête une requête de bouclage, et ajoute cet en-tête). Tous les autres reçoivent un 404.
- Le jeton fait 32 caractères hexadécimaux aléatoires, créés au démarrage du programme (`SetupController.setup_token`), comparés en temps constant. Il garde la page fermée là où le contrôle d’adresse ne le peut pas, derrière un proxy qui n’ajoute pas `X-Forwarded-For`. Le journal des requêtes l’affiche comme `[FILTERED]`.
- Tant qu’aucun utilisateur n’existe, le serveur journalise `[WARN] no user exists yet: run ./<app> user EMAIL, or open /setup?token=<token> from this machine` avant de démarrer&nbsp;; c’est le seul endroit où le jeton est affiché.
- `<APP>_SETUP_OPEN=1` (le réglage `setup_open` dans `config/app.rb`) lève le contrôle d’adresse, jamais celui du jeton, pour un premier lancement derrière un proxy sur un autre hôte. Retirez-le une fois l’utilisateur créé.

## La commande utilisateur

`./<app> user` est écrite dans les deux modes&nbsp;:

```shell terminal — hôte de production
./blog user ann@example.com                       # créer, ou changer le mot de passe ; il est lu sur stdin
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user admin ann@example.com                 # en faire un administrateur
./blog user unadmin ann@example.com
```

Sans argument de mot de passe, elle lit une ligne de l’entrée standard (avec une invite sur un terminal&nbsp;; la saisie s’affiche), ce qui garde le mot de passe hors de `ps` et de l’historique du shell. Définir un mot de passe déconnecte les navigateurs de cet utilisateur et lève un verrouillage. Avec `--confirmable`, les utilisateurs qu’elle crée sont confirmés. Elle affiche `created`, `updated`, `admin` ou `unadmin` et l’adresse et sort avec 0, ou affiche l’usage ou une erreur et sort avec 1.

## Rester connecté et durée des sessions

Le formulaire de connexion a une case «&nbsp;Keep me signed in&nbsp;» (`check_box_tag :remember_me`). Une connexion dure&nbsp;:

| | Cochée | Non cochée |
| --- | --- | --- |
| La ligne Session et le cookie finissent après | `auth_remember_for` (30 jours) | `session_absolute_max_age` (deux semaines) |
| Le cookie | `Max-Age` du temps restant | ni `Max-Age` ni `Expires`&nbsp;: il finit avec le navigateur |
| Inutilisée pendant `auth_idle_timeout` (7 jours&nbsp;; `0` le désactive) | finit | finit |

`last_active_at` est écrit au plus une fois par minute. Le `start_new_session_for(user, remember:)` généré appelle `session.restart_lifetime!`, puis `session.stamp_lifetime!(seconds, persistent)`, dans cet ordre&nbsp;: un redémarrage efface le marquage. La limite qu’il marque n’est jamais 0&nbsp;: avec `session_absolute_max_age = 0`, une connexion non mémorisée dure `session_max_age`, ou deux semaines. Les réglages sont dans [Configuration](configuration.md#authentication-settings).

## Verrouillage

`auth_lockout_attempts` (10) mauvais mots de passe verrouillent le compte pendant `auth_lockout_period` (une heure). Un compte verrouillé répond par le message du mauvais mot de passe, quel que soit le mot de passe. Une connexion réussie, une réinitialisation du mot de passe et `./<app> user EMAIL` remettent le compteur à zéro&nbsp;; `auth_lockout_attempts = 0` désactive le verrouillage et cesse d’appliquer un verrou posé auparavant. Le compte est un seul `UPDATE` qui lit la ligne telle qu’elle est (`Relation#update_all_sql`), si bien que des connexions simultanées comptent toutes. La limite de débit par adresse cliente reste.

## Réinitialisation du mot de passe

La page de connexion renvoie vers `/passwords/new`. Le formulaire d’adresse répond toujours "If that address is registered, a link to reset the password was sent to it.", après le même travail pour une adresse inconnue, l’envoi excepté. Le courriel (`PasswordsMailer.reset(user, url).deliver_later`, dans la langue de la requête) porte `/passwords/<token>/edit`&nbsp;; le jeton vaut 15 minutes et seulement tant que le mot de passe et l’adresse restent les mêmes, il ne sert donc qu’une fois. Définir le nouveau mot de passe lève un verrouillage et met fin à toutes les sessions de l’utilisateur&nbsp;; avec `--confirmable`, elle retire aussi une nouvelle adresse en attente ([Confirmer les adresses](#confirming-addresses)).

<!-- list: points -->
- Le courriel est envoyé par un thread de jobs avec les réglages `CYBERTRAIN_SMTP_*` ([Envoyer des courriels](external-services.md#sending-e-mail))&nbsp;: il faut un processus qui exécute les jobs, et la base de données.
- La page du lien répond avec `Referrer-Policy: no-referrer`, et le journal des requêtes du framework écrit le jeton comme `[FILTERED]`.
- Dix requêtes par adresse cliente toutes les trois minutes.

### Liens dans les courriels

Un lien commence par le réglage `base_url` que le générateur déclare dans `config/app.rb`, issu de `<APP>_BASE_URL` (`BLOG_BASE_URL=https://blog.example.com`). Définissez-le, en https, partout où l’application est servie. Sans lui, le lien ne prend l’adresse à laquelle est arrivée la requête que si l’en-tête `Host` est contrôlé (en développement, ou avec `CYBERTRAIN_HOSTS` défini) ou dans les tests&nbsp;; partout ailleurs aucun courriel n’est envoyé, le journal dit `[ERROR] password reset mail not sent: set <APP>_BASE_URL (or CYBERTRAIN_HOSTS)`, et la page répond comme d’habitude. Un `Host` forgé n’atteint jamais un lien.

## Confirmer les adresses

Avec `--confirmable`, une inscription envoie un lien à l’adresse et ne connecte personne. Le bon mot de passe pour une adresse pas encore confirmée est refusé avec son propre message (un mauvais reçoit le message habituel), et la page de connexion renvoie vers un formulaire qui renvoie le lien. Ouvrir le lien (`/confirmations/<token>`, valable trois jours, une fois) confirme l’adresse&nbsp;; l’utilisateur se connecte ensuite. Le `start_new_session_for` du concern refuse lui aussi un utilisateur non confirmé, quel que soit le contrôleur qui le demande, et journalise `[WARN] no session started: user <id> has not confirmed its address`. Ce contrôle est dans le concern que le générateur écrit avec `--confirmable`&nbsp;: dans une nouvelle application, et dans une mise à jour depuis 0.4, où le concern est un nouveau fichier. Une application qui a déjà le concern reçoit le contrôle sous forme de diff ([Activer la confirmation plus tard](#turning-on-confirmation-later)).

Une nouvelle adresse sur la page de compte attend dans `unconfirmed_email`, et prend la place de l’ancienne quand son propre lien est ouvert&nbsp;; la page peut la retirer (`DELETE /account/pending_email`), ce qui met fin à ce lien. Les utilisateurs créés par la commande utilisateur et par `/setup` sont confirmés. Une réinitialisation du mot de passe confirme un compte jamais confirmé (le lien a prouvé la boîte aux lettres), jamais une nouvelle adresse en attente&nbsp;: elle retire cette adresse, ce qui met fin à son lien, car celui qui l’a demandée peut être celui à qui le propriétaire reprend le compte. Le propriétaire la redemande ensuite. Un nouveau mot de passe sur la page de compte garde l’adresse en attente (l’utilisateur est là et la voit).

## La page de compte

`/account/edit` («&nbsp;Account&nbsp;» dans la navigation) change l’adresse ou le mot de passe, chacun seulement avec le mot de passe actuel, et supprime le compte (avec ses sessions, dans une transaction) seulement avec le mot de passe. Un nouveau mot de passe met fin à toutes les sessions de l’utilisateur et reconnecte ce navigateur, mémorisé comme il l’était. Les modifications et suppressions du compte (donc aussi les mauvais mots de passe actuels) sont limitées à dix toutes les trois minutes par adresse cliente et par utilisateur, et un mauvais mot de passe actuel ne compte pas pour le verrouillage.

## Les administrateurs et la page des jobs

`users.admin` (false) se règle avec `./<app> user admin EMAIL`. Le `require_admin` du concern répond 404 sauf si l’utilisateur connecté est un administrateur&nbsp;:

```ruby app/controllers/concerns/admin_gate.rb (extrait, examples/blog)
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
  end
end
```

Le générateur dessine la page des jobs derrière lui, à la place du commentaire qu’écrit `cybertrain new`&nbsp;:

```ruby config/routes.rb (extrait)
jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
```

<!-- list: points -->
- Sur la page des jobs, `require_admin` s’exécute seul, si bien qu’un visiteur reçoit le 404, comme s’il n’y avait pas de page. Dans un contrôleur qui déclare lui-même `before_action :require_admin`, `require_authentication` s’exécute d’abord (l’ordre de Rails), donc un visiteur est envoyé se connecter (303) et un non-administrateur connecté reçoit le 404.
- gen refuse un `skip_before_action:` sans `before_action:`, et un qui nomme le `before_action:` lui-même&nbsp;: l’un comme l’autre ouvrirait la page à tous.
- Une ligne `jobs_page` que l’application a écrite elle-même est laissée telle quelle. Une ligne qui a déjà `skip_before_action: :require_authentication` compte comme tracée&nbsp;; pour toute autre, le générateur dit de l’ajouter. Écrivez la ligne `jobs_page "...", before_action: :require_admin, skip_before_action: :require_authentication` pour le 404 (gen refuse le saut sans le `before_action:`).
- Quand `ApplicationController` définit `require_admin` lui-même, cette méthode prend la place de celle du concern dans tous les contrôleurs. Le générateur le dit en insérant `include Authentication` (`warn  app/controllers/application_controller.rb defines require_admin itself: ...`), et trace la page des jobs sans le saut (`jobs_page "/admin/jobs", before_action: :require_admin`), si bien que `require_authentication` s’exécute avant elle là aussi. Supprimez la méthode pour utiliser celle du concern.
- Un job de courriel en échec ou abandonné garde le courriel dans sa ligne, et la page des jobs montre les arguments de la ligne&nbsp;: un administrateur peut y lire un lien de réinitialisation ou de confirmation tant qu’il est valable. La page est réservée aux administrateurs, qui peuvent déjà agir sur n’importe quel compte.
- `/setup` et la commande utilisateur créent des utilisateurs ordinaires&nbsp;; faites du premier un administrateur avec `./<app> user admin EMAIL`.

## Ce qui reste à l’application

Voici les choix que fait le code généré, chacun avec sa raison&nbsp;:

<!-- list: points -->
- Un mauvais mot de passe pour un compte existant non verrouillé écrit sa ligne une fois (le compte)&nbsp;; une adresse inconnue et un compte verrouillé, non. Cette écriture unique est une différence de durée, acceptée comme dans le lockable de Devise&nbsp;: des écritures équivalentes pour les adresses inconnues ajouteraient de la charge pour un signal que la limite de débit borne déjà. Le formulaire de réinitialisation a la même sorte de différence&nbsp;: une adresse connue met son courriel en file, une ligne de plus.
- Les courriels d’inscription, de réinitialisation et de confirmation sont limités par adresse cliente seulement, pas par adresse destinataire&nbsp;: quelqu’un peut faire écrire à une adresse à ce rythme. Les connexions sont limitées à dix toutes les trois minutes par adresse cliente, le seuil de verrouillage, si bien qu’un seul client peut garder verrouillé un compte connu. Une limite par adresse (`rate_limit ... by:`) et une fenêtre plus longue sont à ajouter par l’application.
- L’ancienne adresse n’est pas prévenue d’un changement d’adresse, une nouvelle adresse en attente n’expire jamais (son lien, si, et une réinitialisation du mot de passe la retire), et un compte jamais confirmé n’est jamais supprimé.
- Le "has already been taken" de la page de compte dit à un utilisateur connecté, qui a donné le mot de passe actuel, qu’une adresse est inscrite (comme Devise), dans la limite de débit de la page.

## Les briques que fournit le framework

Le code généré est construit à partir d’API du framework, utilisables seules&nbsp;:

| API | Ce qu’elle fait |
| --- | --- |
| `Cybertrain::Password` | condensats PBKDF2-HMAC-SHA256&nbsp;: `hash`, `verify?`, `verify_serialized`, `dummy_digest`, `needs_rehash?`, `session_key`, `session_key_matches?` ([docs/design.md](../design.md) D25) |
| `Cybertrain::Token` | `issue(purpose, id, expires_in, bound_to)` donne `"<id>--<expires>--<hmac>"`&nbsp;; `id_from(token)`&nbsp;; `valid?(token, purpose, bound_to)` |
| `Cybertrain::MailMessage` | ce que renvoie une méthode de mailer&nbsp;: `deliver_later` (un job) ou `deliver_now` |
| `Session#restart_lifetime!`, `stamp_lifetime!(seconds, persistent)` | la durée de vie propre d’une connexion et un cookie de session de navigateur |
| `Relation#update_all_sql(sql, binds)` | `UPDATE ... SET <sql>` sur les lignes correspondantes |
| `Controller.allow_unauthenticated_access`, `skip_before_action` | ouvrir des actions aux visiteurs |
| `Controller#safe_redirect_path(text, fallback)` | un chemin local venant de la requête, ou la valeur de repli |
| `ParameterFilter.filter_path(path)` | un chemin dont les segments en forme de jeton deviennent `[FILTERED]` |
| `check_box_tag(name, value = "1", checked = false)` | une case à cocher sans champ caché |

Une connexion écrite à la main utilise `Password` comme le fait le `User` généré&nbsp;: `Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)` vérifie un mot de passe à la fois par processus (une vérification prend environ 0,2&nbsp;s de CPU) et prend autant de temps pour une adresse inconnue&nbsp;; `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)` à la connexion, vérifié par `session_key_matches?` à chaque requête, déconnecte un navigateur une fois le mot de passe changé.

`Token.valid?` vérifie un jeton contre le `bound_to` donné&nbsp;: cherchez donc d’abord l’enregistrement par `Token.id_from` et vérifiez contre la valeur propre de cet enregistrement, comme le fait `User.find_by_password_reset_token`.

## Tests

Le générateur écrit des classes de test à la Rails, que `cybertrain test`
exécute ([Tester une application](testing.md))&nbsp;:

| Fichier | Ce qu’il teste |
| --- | --- |
| `test/fixtures/users.yml` | `one` (un administrateur) et `two`, dont le mot de passe est `"password"` (avec `--confirmable`, tous deux confirmés) |
| `test/support/session_test_helper.rb` | `sign_in_as(user, remember: false)`, `sign_out` et `open_session` (un second navigateur), inclus dans chaque test d’intégration par `test/test_helper.rb` |
| `test/models/user_test.rb` | le format de l’adresse |
| `test/controllers/sessions_controller_test.rb` | la connexion et la déconnexion |
| `test/controllers/registrations_controller_test.rb` | l’inscription (pas avec `--invite-only`) |
| `test/integration/first_run_test.rb` | `/setup` et la commande user (avec `--invite-only`) |
| `test/controllers/passwords_controller_test.rb` | la réinitialisation, son courriel et son lien |
| `test/controllers/accounts_controller_test.rb` | la page du compte |
| `test/controllers/confirmations_controller_test.rb` | la confirmation (avec `--confirmable`) |
| `test/integration/remember_me_test.rb` | le jour 15 et le jour 30, la limite d’inactivité |
| `test/integration/lockout_test.rb` | le verrouillage et son heure |
| `test/integration/admin_test.rb` | `require_admin`, `user admin` |

Le temps avance avec `travel_to` et `travel` (aucune ligne n’est reculée
dans le temps), et les courriels se lisent dans
`Cybertrain::Mailer.deliveries` avec `assert_emails` et
`perform_enqueued_jobs`. Un scaffold généré après l’authentification
connecte `users(:one)` en tête de son test de contrôleur&nbsp;; un scaffold
généré avant ne le fait pas&nbsp;: ajoutez `sign_in_as users(:one)` à son
`setup`. Relancé sur une application dont un générateur précédent a écrit
les tests (`test/authentication.rb`, `admin.rb`, `remember_me.rb`,
`lockout.rb`, `passwords.rb`, `accounts.rb`, `confirmations.rb`,
`test/support/app_test.rb`, `test/support/authentication_helpers.rb`), le
générateur nomme chacun avec le fichier qui le remplace&nbsp;; `--force` les
supprime.

`script/auth-e2e signup invite confirmable upgrade04` dans ce dépôt construit des applications avec le générateur et les pilote de bout en bout.

## Mettre à jour depuis 0.4

Relancez le générateur dans une application que 0.4 a générée. Il écrit les fichiers manquants, une migration avec les colonnes qui manquent aux migrations existantes, et les modifications&nbsp;; pour chaque fichier qu’il écrirait en entier et qui existe avec un autre contenu, il ne change rien et affiche un diff&nbsp;:

```text sortie — cybertrain generate authentication (extrait)
exist db/migrate/20260925120000_create_users.rb
create db/migrate/20260925120002_add_authentication_columns.rb
manual  app/models/user.rb (diff below)
create app/controllers/concerns/authentication.rb
manual  app/controllers/sessions_controller.rb (diff below)
create app/controllers/passwords_controller.rb
...
manual  app/controllers/application_controller.rb (diff below)
...
manual  app/controllers/application_controller.rb: apply this diff by hand, or re-run with --force to overwrite the file
--- a/app/controllers/application_controller.rb
+++ b/app/controllers/application_controller.rb
@@ -1,95 +1,5 @@
 class ApplicationController < Cybertrain::Controller
-  # ---- Authentication (cybertrain generate authentication) -------------
-  # Every action needs a signed-in user unless its controller opens it:
...
-  # ---- end of authentication ------------------------------------------
+  include Authentication
```

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) est la sortie complète pour une application avec inscription que 0.4 a générée.

<!-- list: points -->
- Enregistrez la sortie et appliquez-la avec `patch -p1` depuis le répertoire de l’application (patch saute les lignes qui ne font pas partie d’un diff), ou appliquez chaque diff à la main là où vous avez modifié le fichier. L’application peut ne pas se construire tant qu’ils ne sont pas appliqués&nbsp;: les nouveaux fichiers appellent ce qu’ajoutent les diffs.
- `--force` écrit à la place les nouveaux fichiers par-dessus les anciens, pour les fichiers que vous n’avez jamais modifiés&nbsp;; le bloc de 0.4 dans `ApplicationController` n’est remplacé que s’il est exactement tel que 0.4 l’a écrit.
- La nouvelle migration n’ajoute que les colonnes manquantes&nbsp;; lancez `cybertrain db migrate`. Avec `--confirmable`, elle compte aussi les utilisateurs déjà là comme confirmés (depuis leur création), sans quoi aucun ne pourrait se connecter.
- Avec `--confirmable`, les diffs des contrôleurs sessions et registrations portent une ligne `IMPORTANT:`&nbsp;: tant qu’ils ne sont pas appliqués, un compte non confirmé n’apprend pas pourquoi il ne peut pas se connecter, et une inscription ne reçoit aucun lien. Dans une application 0.4, le concern est un nouveau fichier, écrit avec son contrôle de confirmation, si bien qu’il ne démarre toujours aucune session pour un compte non confirmé (et journalise `[WARN] no session started: user <id> has not confirmed its address`) même si ces diffs ne sont jamais appliqués.
- Chaque session prend fin une fois à la mise à jour (le cookie est désormais chiffré), et le reste de [Mettre à jour une application depuis 0.4](requests.md#upgrading-an-application-from-04) s’applique aussi.

### Activer la confirmation plus tard

Lancez `cybertrain generate authentication --confirmable` (avec `--invite-only` si l’application l’a) dans une application générée sans. Il écrit les fichiers de confirmation et une migration d’ajout de colonnes, qui compte comme confirmés les utilisateurs déjà là, et affiche un diff pour chaque fichier qu’il a écrit auparavant. Ici le concern existe, donc son contrôle de confirmation arrive comme l’un de ces diffs, et la sortie le marque `IMPORTANT:`&nbsp;: tant que le diff du concern n’est pas appliqué, les comptes non confirmés se connectent, quoi que disent les autres diffs. Appliquez-le, ainsi que celui du contrôleur sessions, avant de déployer. Avec `--invite-only`, le diff du contrôleur setup est marqué aussi&nbsp;: tant qu’il n’est pas appliqué, le premier utilisateur que `/setup` crée n’est pas confirmé et ne peut pas se connecter (une réinitialisation du mot de passe le confirme).
