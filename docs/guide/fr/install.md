---
source_sha256: d96e0c0b98809ba5aa1e5ed13ecfec209883ed53af829ab37190846bb5498f8d
---
# Installer cybertrain

## L’essayer dans le navigateur

[Ouvrez le bac à sable dans GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
pour essayer cybertrain sans rien installer&nbsp;: VS Code s’ouvre dans votre
navigateur avec Spinel 2026.10.27.7020, la CLI `cybertrain` et le blog du
tutoriel ci-dessous déjà créé (`cybertrain new blog`, le scaffold des articles,
la route racine et la première migration, compilé une fois pour que le serveur
démarre sans compiler), son serveur de développement lancé dans un terminal, et
l’application, qui affiche la liste des articles, dans un nouvel onglet du
navigateur. L’application est un dépôt git avec un seul commit, donc Source
Control montre ce que vous modifiez. `PLAYGROUND.md`, dans l’application, liste
ce qu’il y a à essayer, de la modification d’une vue à la suite du tutoriel avec
les commentaires. Une modification de vue apparaît au rechargement suivant&nbsp;;
une modification Ruby entraîne une recompilation complète, environ une minute,
après quoi le serveur redémarre de lui-même&nbsp;; l’onglet de l’application ne
se recharge pas de lui-même. `cybertrain new` y fonctionne sans réseau.

- Un compte GitHub est nécessaire, et le codespace tourne sur votre propre
  quota Codespaces&nbsp;: l’offre gratuite de GitHub inclut 120 heures-cœur et
  15 Go-mois de stockage par mois, soit environ 60 heures sur la machine à
  2 cœurs par défaut qu’utilise le bac à sable. Par défaut, GitHub arrête un
  codespace inactif au bout de 30 minutes&nbsp;; son stockage est décompté
  jusqu’à ce que vous le supprimiez.
- Si VS Code vous demande si vous faites confiance aux auteurs des fichiers de
  ce dossier, choisissez «&nbsp;Trust Folder & Continue&nbsp;»&nbsp;: le
  terminal du serveur ne démarre qu’à ce moment-là.
- Si l’onglet de l’application ne s’est pas ouvert (un bloqueur de fenêtres
  surgissantes, ou le codespace a été arrêté puis redémarré), cliquez sur
  «&nbsp;Open in Browser&nbsp;» dans la notification de VS Code pour le
  port 3000 ou dans la vue Ports, ou faites Ctrl-clic sur l’URL de
  l’application dans le terminal `server`. `PLAYGROUND.md` indique où se trouve
  chacun.
- La même image tourne en local (elle est publiée pour linux/amd64&nbsp;; sur
  arm64, construisez-la depuis une copie du dépôt)&nbsp;:

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Ouvrez ensuite http://localhost:3000. [playground/README.md](../../playground/README.md)
  décrit l’image, sa construction et la configuration de Codespaces.

## Prérequis

- Spinel `2026.10.27.7020` (`Cybertrain::SPINEL_TAG`, la même version que
  `SPINEL_TAG` dans [.github/workflows/ci.yml](../../.github/workflows/ci.yml)),
  une version de [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), le fork de matz/spinel qui intègre les
  corrections dont cybertrain a besoin avant une version amont&nbsp;; non testé
  avec d’autres versions. Vous ne l’installez pas à la main&nbsp;: la commande
  `cybertrain` compile cette version dans `~/.cybertrain` la première fois
  qu’elle en a besoin (`cybertrain setup` le fait à la demande), sauf si un
  `spinel` de cette version est déjà dans le `PATH` — voir [Installer la CLI](#installing-the-cli).
- Pour le compiler&nbsp;: une chaîne de compilation C (`cc`, ou le compilateur
  désigné par `CC`) et `make` — Spinel compile chaque programme en C —, plus
  `git` et `curl`.
- En-têtes et bibliothèque SQLite 3 (`libsqlite3-dev` sous Debian/Ubuntu&nbsp;;
  fournis avec les Command Line Tools de Xcode sous macOS) — les modèles
  utilisent directement la FFI de Spinel, pas une gem.
- En-têtes et bibliothèque zlib (`zlib1g-dev` sous Debian/Ubuntu&nbsp;; dans le
  SDK de macOS) — les corps de requête gzip (`request.decoded_body`) sont
  décompressés par la zlib du système, liée de la même façon.
- Ruby 3.2+ et RubyGems, uniquement pour la commande `cybertrain` (les
  applications ne tournent jamais sur CRuby). La compilation de Spinel demande
  aussi la gem `prism` de Ruby, que Ruby 3.3 et plus récent incluent&nbsp;; avec
  Ruby 3.2, `gem install prism` (avec les en-têtes de développement de Ruby,
  `ruby-dev` sous Debian/Ubuntu). `cybertrain doctor` le vérifie.
- Les en-têtes OpenSSL (`libssl-dev`) sont facultatifs&nbsp;: sans eux, Spinel
  est compilé sans son paquet `openssl`, que cybertrain n’utilise pas. Sous
  macOS, une application qui requiert `openssl` a besoin de l’OpenSSL de
  Homebrew (keg-only) dans les chemins du compilateur&nbsp;: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- Le paquet de développement de jemalloc (`libjemalloc-dev`&nbsp;;
  `brew install jemalloc`) est facultatif&nbsp;: une application n’en a besoin
  qu’une fois que son `spin.toml` indique `allocator = "jemalloc"`, ligne que
  `cybertrain new` écrit en commentaire. Cela vaut la peine de l’activer en
  production&nbsp;: de 1,1 à 1,4 fois plus de requêtes par seconde sur
  examples/blog ([docs/benchmark.md](../benchmark.md)).

`cybertrain doctor` vérifie ces outils et en-têtes ainsi que l’installation de
Spinel&nbsp;; quand un élément requis manque, il affiche aussi la commande
d’installation pour votre plateforme.

Le framework n’a pas de lanceur de tests séparé&nbsp;; il se teste lui-même.
`spin` est fourni avec Spinel, et `cybertrain spin` lance la copie qu’installe
`cybertrain` sans toucher au `PATH` (ou placez cette copie dans le `PATH` avec
la ligne `export
PATH=...` qu’affiche `cybertrain setup`, et appelez `spin` directement)&nbsp;:

```sh
cybertrain spin test
```

compile et lance chaque programme de `test/` et compare (diff) sa sortie à un
snapshot `test/<name>.rb.expected` versionné — minitest/RSpec ne peuvent pas
tourner sous Spinel, car ils trouvent les méthodes de test par réflexion, et un
compilateur AOT n’a rien sur quoi réfléchir à l’exécution. `cybertrain spin test
--regen test/<name>.rb` réécrit un snapshot à partir de la sortie de CRuby&nbsp;;
quelques tests qui accèdent à SQLite via FFI prennent plutôt le leur dans le
binaire compilé ([spikes/NOTES.md](../../spikes/NOTES.md), règle 23)&nbsp;;
`script/regen-snapshot
test/<name>.rb` fait pour vous cette étape compilation-puis-capture et affiche
le résumé du diff.

## Installer la CLI

```sh
gem install cybertrain
cybertrain new blog    # installe aussi Spinel, la première fois (quelques minutes)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # production : dist/
```

La commande `cybertrain` est en Ruby pur et la gem l’exécute sous CRuby (3.2 ou
plus récent)&nbsp;; ni le framework ni Spinel ne sont dans la gem. Ses commandes
(`cybertrain help` les affiche)&nbsp;:

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` crée une application dans NAME, puis y lance `spin lock` et
  `spin run gen`, en installant d’abord Spinel si nécessaire.
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
  [Ajouter un envoi de fichier](tutorial.md#attachments)). Un champ de scaffold
  `cover:attachment` fait la même chose.
- `cybertrain db migrate` génère, applique les migrations en attente, puis
  génère à nouveau (`spin run gen; spin run db -- migrate; spin run gen`)&nbsp;;
  `cybertrain migration` est conservé comme alias.
- `cybertrain db COMMAND...` lance toute autre commande de base de données
  après `spin
  run gen`&nbsp;: `status`, `rollback [N]` (qui génère à nouveau ensuite),
  `schema:dump`, `create`.
- `cybertrain server [PORT]` génère, puis démarre le serveur de développement
  (`spin run gen; spin run NAME`, ou `spin run NAME -- PORT`&nbsp;; port 3000
  par défaut).
- `cybertrain build` compile NAME avec `app/views/` intégré et assemble
  `dist/` (le binaire, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` lance `spin` avec le Spinel épinglé, depuis
  n’importe quel répertoire (`cybertrain spin test`,
  `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` installe Spinel `2026.10.27.7020` dans
  `~/.cybertrain`, sauf si un `spinel` de cette version est déjà dans le
  `PATH`&nbsp;; `--force` recompile la copie sous `~/.cybertrain`.
- `cybertrain doctor` vérifie la chaîne de compilation C, les en-têtes SQLite
  et l’installation de Spinel.
- `cybertrain version` affiche la version.

`db`, `server` et `build` s’exécutent dans une application&nbsp;; NAME est le
`[package] name` de son `spin.toml`.

Chaque commande qui lance `spin` (`new`, `db`, `server`, `build`, `spin`)
s’assure d’abord qu’un Spinel de la version de `Cybertrain::SPINEL_TAG` est
disponible. Un `spinel` du `PATH` (accompagné d’un `spin`) dont
`spinel --version` indique cette version est utilisé tel quel&nbsp;; sinon, la
copie que `cybertrain` conserve sous `~/.cybertrain/spinel/2026.10.27.7020/`
est utilisée&nbsp;; sinon, `cybertrain` compile cette copie à partir du tag de
version de `Cybertrain::SPINEL_REPOSITORY` (`git clone`, `make deps`,
`make -j`, `make install PREFIX=...`), une seule fois, en quelques minutes. Le
journal de compilation est `~/.cybertrain/log/spinel-2026.10.27.7020-build.log`
(ses dernières lignes sont affichées si une étape échoue)&nbsp;; s’il manque un
outil nécessaire à la compilation, `cybertrain` indique lequel et affiche la
commande d’installation pour votre plateforme avant de commencer. Un `spinel`
d’une autre version présent dans le `PATH` n’est jamais utilisé ni
modifié&nbsp;: `cybertrain` conserve sa propre copie (et le signale quand il
l’installe).

`cybertrain setup` fait la même chose à la demande et, chaque fois que c’est sa
propre copie qui est utilisée, affiche la ligne qui la place dans le `PATH`,
pour lancer `spin` vous-même (`~/.cybertrain/bin` contient des liens `spinel`
et `spin` vers la version utilisée, la ligne reste donc valable après un
changement de version&nbsp;; `cybertrain spin ...` n’a besoin d’aucun `PATH`)&nbsp;:

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

Deux variables d’environnement remplacent tout cela&nbsp;: `CYBERTRAIN_HOME`
remplace `~/.cybertrain` (un chemin sans espaces, guillemets, `$` ni `:`, que le
Makefile de Spinel et le `PATH` ne supportent pas), et
`CYBERTRAIN_SPINEL_HOME=PREFIX` impose une installation existante —
`cybertrain` utilise alors le `spinel` et le `spin` de `PREFIX/bin` (ou de
`PREFIX` lui-même, si `spinel` s’y trouve directement) et s’arrête sur une
erreur s’ils ne sont pas de cette version.

`cybertrain new` écrit l’application avec un `spin.toml` qui pointe vers la
version correspondant à la CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`), s’assure
que Spinel est installé, puis lance `spin lock` (spin récupère le framework dans
son cache, `~/.cache/spin/packages/`, et épingle le commit dans `spin.lock`) et
`spin run gen`, un peu comme `rails new` lance `bundle install`, et affiche les
étapes suivantes. Rien du framework n’est copié dans l’application&nbsp;;
commitez `spin.toml` et `spin.lock`. Si Spinel ou l’une des deux étapes `spin`
échoue, les fichiers restent en place, `new` sort avec le code 1 et affiche ce
qu’il faut lancer une fois la cause corrigée (pour Spinel&nbsp;:
`cybertrain setup`, puis `cybertrain spin
lock && cybertrain spin run gen` dans le nouveau répertoire).

`--skip-spin` se contente d’écrire les fichiers&nbsp;: pas d’installation de
Spinel, pas de `spin lock`, pas de `spin run gen`. `--path DIR` fait plutôt
dépendre l’application d’une copie locale du dépôt, `--git URL [--ref R]` du
framework situé à URL (à la branche ou au tag R), et `--version V` d’une version
de l’index, une fois que cybertrain sera sur un `spin-index`. N’indiquez qu’une
seule des options `--path`, `--version` et `--git`&nbsp;; `--ref` exige `--git`.

Pour travailler sur cybertrain lui-même, lancez la CLI depuis la copie du dépôt
(`spin install` compile `bin/cybertrain.rb` dans `~/.local/bin/cybertrain`&nbsp;;
`ruby -I.
bin/cybertrain.rb` fonctionne aussi) et créez des applications qui l’utilisent
avec `cybertrain
new NAME --path ~/src/cybertrain` (là où se trouve la copie du dépôt).
