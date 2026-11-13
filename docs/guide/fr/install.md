---
source_sha256: dcff54852c4d6fae14dd97b90f66e3dc7c39d37abc0be11123dc75a3aba5030f
---
# Installer cybertrain

Ce dont CyberTrain a besoin sur votre machine, comment installer la commande `cybertrain`, toutes les commandes qu’elle propose, et comment elle installe Spinel et le framework à votre place.

> [!NOTE]
> Pour essayer CyberTrain sans rien installer, ouvrez [le bac à sable](site:playground.html)&nbsp;:
> GitHub Codespaces ouvre le blog du tutoriel, la commande `cybertrain` et
> la version épinglée de Spinel dans VS Code, dans votre navigateur. La même image tourne aussi en local avec Docker.

## Prérequis

- Spinel, à la version de `Cybertrain::SPINEL_TAG`
  ([cybertrain/version.rb](../../cybertrain/version.rb)&nbsp;; `cybertrain doctor` l’affiche, et le
  `SPINEL_TAG` de la CI dans [.github/workflows/ci.yml](../../.github/workflows/ci.yml) est le même),
  une version de [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), le fork de matz/spinel qui intègre les
  corrections dont CyberTrain a besoin avant une version amont&nbsp;; non testé
  avec d’autres versions. Vous ne l’installez pas à la main&nbsp;: la commande
  `cybertrain` compile cette version dans `~/.cybertrain` la première fois
  qu’elle en a besoin (`cybertrain setup` le fait à la demande), sauf si un
  `spinel` de cette version est déjà dans le `PATH` — voir [Comment Spinel est installé](#how-spinel-is-installed).
- Pour le compiler&nbsp;: une chaîne de compilation C (`cc`, ou le compilateur
  désigné par `CC`) et `make` — Spinel compile chaque programme en C —, plus
  `git` et `curl`.
- En-têtes et bibliothèque SQLite 3 (`libsqlite3-dev` sous Debian/Ubuntu&nbsp;;
  fournis avec les Command Line Tools de Xcode sous macOS) — les modèles
  utilisent directement la FFI de Spinel, pas une gem.
- En-têtes et bibliothèque zlib (`zlib1g-dev` sous Debian/Ubuntu&nbsp;; dans le
  SDK de macOS) — les corps de requête gzip (`request.decoded_body`) sont
  décompressés par la zlib du système, liée de la même façon.
- En-têtes et bibliothèque OpenSSL (`libssl-dev` sous Debian/Ubuntu) — chaque
  application les lie&nbsp;: le cookie de session et `cookies.encrypted` sont en
  AES-256-GCM par le paquet `openssl` de Spinel, que Spinel ne compile que si
  les en-têtes sont présents. Sous macOS, installez celui de Homebrew
  (`brew install openssl@3`), qui est keg-only, et placez-le dans les chemins
  du compilateur&nbsp;: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- Ruby 3.2+ et RubyGems, pour la commande `cybertrain` et pour l’aperçu
  CRuby du serveur de développement, qui demande aussi la bibliothèque
  `fiddle` de Ruby (elle a besoin de libffi)&nbsp;; sans `fiddle`,
  `cybertrain server` ne lance que la boucle compilée. Une application
  déployée ne tourne jamais sur CRuby. Avec Ruby 3.2, la compilation de
  Spinel demande aussi la gem `prism` (ci-dessous).

`cybertrain doctor` vérifie ces outils et en-têtes, si le `ruby` du `PATH`
charge `fiddle`, ainsi que l’installation de Spinel&nbsp;; quand un élément
requis manque, il affiche aussi la commande d’installation pour votre
plateforme (un `fiddle` manquant ne compte pas&nbsp;: le serveur tourne
quand même, compilé).

<details><summary>Autres paquets — prism avec Ruby 3.2&nbsp;; jemalloc, facultatif</summary>

- La compilation de Spinel demande la gem `prism` de Ruby, que Ruby 3.3 et plus
  récent incluent&nbsp;; avec Ruby 3.2, `gem install prism` (avec les en-têtes
  de développement de Ruby, `ruby-dev` sous Debian/Ubuntu). `cybertrain doctor`
  le vérifie.
- Un Spinel compilé avant l’installation des en-têtes OpenSSL n’a pas de paquet
  `openssl`, et la compilation d’une application échoue alors&nbsp;; lancez
  `cybertrain setup --force` une fois qu’ils sont là pour le recompiler. Le même
  paquet sert à TLS (`require "cybertrain/net/tls"`) et aux colonnes chiffrées
  (`encrypts`).
- Le paquet de développement de jemalloc (`libjemalloc-dev`&nbsp;;
  `brew install jemalloc`) est facultatif&nbsp;: une application n’en a besoin
  qu’une fois que son `spin.toml` indique `allocator = "jemalloc"`, ligne que
  `cybertrain new` écrit en commentaire. Cela vaut la peine de l’activer en
  production&nbsp;: de 1,1 à 1,4 fois plus de requêtes par seconde sur
  examples/blog ([docs/benchmark.md](../benchmark.md)).

</details>

## Installer la CLI

```shell terminal — n’importe quel répertoire
gem install cybertrain
cybertrain doctor
```

La première ligne installe la commande depuis RubyGems et la seconde vérifie les
[prérequis](#requirements)&nbsp;; [le tutoriel](tutorial.md#install) continue à
partir de là, de `cybertrain new` à `cybertrain build`.

## La commande `cybertrain`

`cybertrain help` affiche ces commandes&nbsp;:

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` crée une application dans NAME, puis y lance `spin lock` et
  `SPIN_DEBUG=1 spin run gen`, en installant d’abord Spinel si nécessaire (la
  CLI compile gen et `bin/db.rb` dans le mode debug de spin).
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`)
  ajoute une ressource à l’application du répertoire courant.
- `cybertrain generate authentication` y ajoute la connexion par adresse e-mail
  et mot de passe&nbsp;: les tables users et sessions, les modèles `User` et
  `Session`, les contrôleurs et vues de connexion et d’inscription, les routes,
  un `before_action` dans `ApplicationController` et un test (voir
  [Ajouter la connexion](tutorial.md#authentication)). Avec `--invite-only`, il
  n’y a pas de page d’inscription&nbsp;: les utilisateurs sont créés avec
  `./NAME user EMAIL`, et le premier aussi sur une page `/setup` qui ne répond
  qu’à la machine du serveur elle-même, avec le jeton à usage unique
  qu’affiche son avertissement de démarrage, tant qu’aucun utilisateur
  n’existe.
- `cybertrain generate attachment MODEL FIELD [--any]` ajoute l’envoi d’un
  fichier à un modèle généré par scaffold&nbsp;: cinq colonnes de métadonnées,
  des méthodes et callbacks de modèle, une action de téléchargement, la route,
  le champ de formulaire et un test (voir
  [Ajouter une image de couverture](tutorial.md#attachments)). Un champ de scaffold
  `cover:attachment` fait la même chose.
- `cybertrain db migrate` génère, applique les migrations en attente, puis
  génère à nouveau (`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db --
  migrate; SPIN_DEBUG=1 spin run gen`)&nbsp;;
  `cybertrain migration` est conservé comme alias.
- `cybertrain db COMMAND...` lance toute autre commande de base de données
  après `SPIN_DEBUG=1 spin
  run gen`&nbsp;: `status`, `rollback [N]` (qui génère à nouveau ensuite),
  `schema:dump`, `create`.
- `cybertrain server [PORT] [--spinel]` démarre le serveur de développement
  (port 3000 par défaut). Juste après un changement, l’application tourne
  sous CRuby pendant que Spinel la compile en arrière-plan, et le binaire
  compilé reprend le port quand sa compilation réussit&nbsp;; les réponses
  de l’application portent `X-Cybertrain-Runtime: cruby` ou `spinel`
  ([La boucle de développement](how-it-works.md#the-development-loop)).
  `--spinel` ne lance que la boucle compilée, chaque changement attendant
  sa compilation (`SPIN_DEBUG=1 spin run gen`&nbsp;; `spin build NAME --
  --incremental` si un fichier Ruby est plus récent que
  `build/bin/NAME`&nbsp;; `spin run NAME`, ou `spin run NAME -- PORT`).
- `cybertrain build` compile NAME avec `app/views/` intégré et assemble
  `dist/` (le binaire, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` lance `spin` avec le Spinel épinglé, depuis
  n’importe quel répertoire (`cybertrain spin test`,
  `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` installe la version épinglée de Spinel dans
  `~/.cybertrain`, sauf si un `spinel` de cette version est déjà dans le
  `PATH`&nbsp;; `--force` recompile la copie sous `~/.cybertrain`.
- `cybertrain doctor` vérifie la chaîne de compilation C, les en-têtes SQLite,
  si Ruby charge `fiddle` (l’aperçu CRuby en a besoin) et l’installation de
  Spinel.
- `cybertrain version` affiche la version.

`db`, `server` et `build` s’exécutent dans une application&nbsp;; NAME est le
`[package] name` de son `spin.toml`.

## Comment Spinel est installé

Chaque commande qui lance `spin` (`new`, `db`, `server`, `build`, `spin`)
s’assure d’abord qu’un Spinel de la version de `Cybertrain::SPINEL_TAG` est
disponible. Un `spinel` du `PATH` (accompagné d’un `spin`) dont
`spinel --version` indique cette version est utilisé tel quel&nbsp;; sinon, la
copie que `cybertrain` conserve sous `~/.cybertrain/spinel/<SPINEL_TAG>/`
est utilisée&nbsp;; sinon, `cybertrain` compile cette copie à partir du tag de
version de `Cybertrain::SPINEL_REPOSITORY` (`git clone`, `make deps`,
`make -j`, `make install PREFIX=...`), une seule fois, en quelques minutes. Le
journal de compilation est `~/.cybertrain/log/spinel-<SPINEL_TAG>-build.log`
(ses dernières lignes sont affichées si une étape échoue).

S’il manque un
outil nécessaire à la compilation, `cybertrain` indique lequel et affiche la
commande d’installation pour votre plateforme avant de commencer. Un `spinel`
d’une autre version présent dans le `PATH` n’est jamais utilisé ni
modifié&nbsp;: `cybertrain` conserve sa propre copie (et le signale quand il
l’installe).

`cybertrain setup` fait la même chose à la demande et, chaque fois que c’est sa
propre copie qui est utilisée, affiche la ligne qui la place dans le `PATH`,
pour lancer `spin` vous-même&nbsp;:

```shell terminal — n’importe quel répertoire
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` contient des liens `spinel` et `spin` vers la version
utilisée, la ligne reste donc valable après un changement de version&nbsp;;
`cybertrain spin ...` n’a besoin d’aucun `PATH`.

<details><summary>Variables d’environnement — `CYBERTRAIN_HOME` déplace `~/.cybertrain`, `CYBERTRAIN_SPINEL_HOME` utilise une installation existante</summary>

Deux variables d’environnement remplacent tout cela&nbsp;:

- `CYBERTRAIN_HOME` remplace `~/.cybertrain` (un chemin sans espaces,
  guillemets, `$` ni `:`, que le Makefile de Spinel et le `PATH` ne
  supportent pas).
- `CYBERTRAIN_SPINEL_HOME=PREFIX` impose une installation existante&nbsp;:
  `cybertrain` utilise alors le `spinel` et le `spin` de `PREFIX/bin` (ou de
  `PREFIX` lui-même, si `spinel` s’y trouve directement) et s’arrête sur une
  erreur s’ils ne sont pas de cette version.

</details>

## La gem et le framework

`gem install cybertrain` installe une commande, pas le framework. La gem est la
commande `cybertrain`, du Ruby pur qui s’exécute sur votre machine sous CRuby
(3.2 ou plus récent) et appelle pour vous l’outil `spin` de Spinel&nbsp;; ni le
framework ni Spinel ne sont dans la gem. Le framework est un paquet Spinel dont
votre application dépend dans son `spin.toml`&nbsp;: Spinel le compile à
l’avance avec votre code, et c’est la partie qui est livrée. Le binaire de
`dist/` tourne sans Ruby, sans la gem et sans Spinel. Le code de
l’application, framework compris, ne tourne aussi sous CRuby qu’en
développement&nbsp;: `cybertrain server` sert un aperçu CRuby de
l’application jusqu’à ce que le binaire compilé prenne le relais.

### Ce que `cybertrain new` écrit

`cybertrain new` écrit l’application avec un `spin.toml` qui pointe vers la
version correspondant à la CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }`, où
X.Y.Z est ce qu’affiche `cybertrain version`), s’assure
que Spinel est installé, puis lance `spin lock` (spin récupère le framework dans
son cache, `~/.cache/spin/packages/`, et épingle le commit dans `spin.lock`) et
`SPIN_DEBUG=1 spin run gen`, un peu comme `rails new` lance `bundle install`, et affiche les
étapes suivantes. Rien du framework n’est copié dans l’application&nbsp;;
commitez `spin.toml` et `spin.lock`.

Si Spinel ou l’une des deux étapes `spin` échoue, les fichiers restent en
place, `new` sort avec le code 1 et affiche ce qu’il faut lancer une fois la
cause corrigée (pour Spinel&nbsp;: `cybertrain setup`, puis
`cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen` dans le nouveau répertoire).

Quatre options changent ce qu’elle écrit et lance&nbsp;:

- `--skip-spin` se contente d’écrire les fichiers&nbsp;: pas d’installation de
  Spinel, pas de `spin lock`, pas de `spin run gen`.
- `--path DIR` fait plutôt dépendre l’application d’une copie locale du dépôt
  (`--path ~/src/cybertrain`, là où se trouve la copie, pour travailler sur
  CyberTrain lui-même).
- `--git URL [--ref R]` fait dépendre l’application du framework situé à URL
  (à la branche ou au tag R).
- `--version V` fait dépendre l’application d’une version de l’index, une fois
  que le framework sera sur un `spin-index`.

N’indiquez qu’une seule des options `--path`, `--version` et `--git`&nbsp;;
`--ref` exige `--git`.

### Passer une application à une nouvelle version

La gem et le framework sont publiés à partir du même tag, leurs versions
correspondent donc&nbsp;: la gem X.Y.Z crée des applications qui dépendent du
framework `vX.Y.Z`. Pour passer une application à une nouvelle version, mettez
à jour la gem, faites pointer `spin.toml` vers le nouveau tag, puis lancez, dans
l’application&nbsp;:

```shell terminal — le répertoire de l’application
cybertrain spin lock
cybertrain spin run gen
```

Une application écrite pour 0.4 a quelques changements à faire (chaque session
prend fin une fois, OpenSSL est lié, un segment de route contenant un point a
besoin de `format: false`, etc.)&nbsp;: voir [Mettre à jour une application écrite pour 0.4](requests.md#upgrading-an-application-from-04).
