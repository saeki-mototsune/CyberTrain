---
source_sha256: afad0b5f4ec95c128b33a9ffa1a21e091c996842a1fa1e1d893a6e92b6a3e025
---
# Tester une application

Les tests d’une application sont des classes à la Rails sous `test/`, et
`cybertrain test` les exécute tous comme un seul programme compilé. Minitest
et RSpec trouvent les méthodes de test par réflexion, ce qu’un compilateur
anticipé ne peut pas faire&nbsp;: `spin run gen` réécrit donc chaque classe de
test en méthodes ordinaires et écrit une table de répartition sur tous les
tests.

## Écrire un test

`cybertrain new` écrit `test/test_helper.rb`&nbsp;; chaque fichier de test
commence par le charger, comme dans Rails&nbsp;:

```ruby test/test_helper.rb
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # Les méthodes d’aide utilisées par tous les tests vont ici.
end
```

```ruby test/models/article_test.rb
require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "title must be present" do
    article = Article.new(body: "a body long enough to pass length")
    assert_not article.save
    assert_includes article.errors.full_messages, "Title can't be blank"
  end
end
```

```ruby test/controllers/articles_controller_test.rb
require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", text: @article.title
  end

  test "creates an article" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough" } }
    end
    assert_redirected_to article_path(Article.last)
  end
end
```

Il y a trois classes de base, celles de Rails&nbsp;: `ActiveSupport::TestCase`
(modèles, jobs, mailers, tout ce qui se passe sans requête),
`ActionDispatch::IntegrationTest` (les requêtes,
[Tests d’intégration](#integration-tests)) et `ViewComponent::TestCase`
(`render_inline`, [Tester les flux et les composants](#testing-streams-and-components)).
Une application peut placer sa propre classe de base dans
`test/test_helper.rb` ou `test/support/` et en hériter. Les méthodes
d’aide, les constantes et `private` vont dans le corps de la classe comme
dans Rails&nbsp;; chaque test s’exécute sur une nouvelle instance, si bien que
les variables d’instance posées dans `setup` appartiennent à ce test.
`fixtures :all` et `require "test_helper"` sont acceptés et ne font rien
par eux-mêmes&nbsp;: toutes les fixtures sont chargées pour chaque test.

Chaque test s’exécute dans cet ordre&nbsp;:

1. toutes les tables sont vidées, y compris celles du framework (jobs,
   cache, messages Turbo, planifications, flux, baux), et les ids
   repartent de 1&nbsp;;
2. les fixtures sont insérées ([Fixtures](#fixtures))&nbsp;;
3. `Mailer.deliveries`, les compteurs de limitation de débit et
   `I18n.locale` sont remis à zéro, et le fuseau horaire est celui que
   `config/app.rb` a configuré&nbsp;;
4. `setup` (celui de la superclasse d’abord&nbsp;; plusieurs blocs
   `setup do` dans l’ordre)&nbsp;;
5. le corps du test, si rien n’a échoué avant&nbsp;;
6. `teardown`, toujours&nbsp;: après une assertion en échec, une exception
   ou un setup en échec (plusieurs blocs `teardown do` dans l’ordre
   inverse, puis celui de la superclasse)&nbsp;;
7. l’horloge redevient réelle, et chaque récepteur démarré par le test est
   arrêté.

Rails annule plutôt chaque test dans une transaction. Cela ne convient pas
ici&nbsp;: SQLite n’a pas de points de sauvegarde dans ce framework, donc la
propre `transaction` d’un test terminerait celle qui l’englobe, et les
threads de jobs utilisent d’autres connexions qui ne verraient pas les
lignes du test.

## Exécuter les tests

```sh
cybertrain test                                         # tous les tests
cybertrain test test/controllers                        # les fichiers d’un répertoire
cybertrain test test/models/article_test.rb             # un fichier
cybertrain test -n "creates an article"                 # un test par son nom
cybertrain test -n test_creates_an_article              # ou par le nom de sa méthode
cybertrain test -n /article/                            # les tests dont le nom contient « article »
```

`cybertrain test` lance `SPIN_DEBUG=1 spin run gen` (gen construit dans le
mode de débogage de spin, comme toutes les commandes du CLI le
construisent), qui écrit `gen/tests.rb` (le programme) et une copie
réécrite de chaque classe de test sous `gen/test/`, tous deux validés avec
le reste de `gen/`&nbsp;; il compile ensuite `gen/tests.rb` en
`build/test/tests` (une compilation de production) dès qu’une entrée est
plus récente que ce binaire, et l’exécute. Chaque `test/**/*_test.rb` et
chaque autre `test/*.rb` sauf `test/test_helper.rb` en font partie&nbsp;;
`test/support/` (chargé par le helper) et `test/fixtures/` ne contiennent
pas de tests. Le programme supprime `storage/test.sqlite3`, en migre une
nouvelle et y démarre l’application avant le premier test (sans threads de
jobs, de planificateur ni de flux&nbsp;: un test exécute lui-même les jobs).
`CYBERTRAIN_TEST_DATABASE` désigne un autre fichier à la place. Comme le programme supprime le fichier sur lequel il teste, il marque
chaque base qu’il crée (`PRAGMA application_id`, une valeur à lui) et ne
supprime ou ne vide un fichier existant que s’il porte cette marque, s’il
est le `storage/test.sqlite3` de cette application (quelle que soit l’écriture du chemin) ou s’il est vide. Tout autre fichier est
refusé avec le code de sortie 2, sans rien supprimer&nbsp;: `cybertrain test refuses to delete <path>: not a database cybertrain test created; delete it yourself or name another file`. Un
fichier nommé `development.sqlite3` ou `production.sqlite3` (quelle que soit
la casse), ou le même fichier que `storage/development.sqlite3` ou
`storage/production.sqlite3`, est refusé par `cybertrain test refuses to delete <path>: it is the development database` (ou `production`). Le
nom doit être un chemin de fichier&nbsp;: `:memory:` et les URI `file:` sont
refusés (`cybertrain test refuses CYBERTRAIN_TEST_DATABASE ":memory:": name the test database by its file path (not :memory: or a file: URI)`). Après une mise à niveau, un fichier que vous aviez
désigné dans `CYBERTRAIN_TEST_DATABASE` ne porte pas de marque et est
refusé une fois&nbsp;: supprimez-le (avec ses `-wal` et `-shm`), et
`cybertrain test` en crée un marqué&nbsp;; le `storage/test.sqlite3` par défaut n’a besoin de rien. Un chemin qui
devient un lien symbolique pendant la création de la base est refusé avec
le code de sortie 2&nbsp;: `cybertrain test refuses <path>: it became a symlink while the test database was created (nothing was marked or migrated); remove it and run again`. Le vidage avant chaque test ne touche que les
tables de la base principale, jamais une table TEMP ou attachée du même
nom. Limites connues&nbsp;: la marque survit à un `cp` d’une base de test, si
bien qu’une copie nommée comme la base de test (ou à laquelle un test se
connecte) est vidée&nbsp;; une exécution tuée entre la création du fichier et
sa marque laisse un fichier non marqué à un chemin que vous avez désigné,
refusé la fois suivante (supprimez-le)&nbsp;; un répertoire à
`storage/test.sqlite3` lève une exception quand le programme le supprime.

Le programme prépare l’environnement de test comme celui de Rails, sauf si
`config/app.rb` règle lui-même la même chose&nbsp;: protection contre la
falsification désactivée, journal des requêtes muet (le niveau `:none`, qui
écrit toujours les lignes d’erreur), lignes de journal en texte (un
`CYBERTRAIN_LOG_FORMAT` exporté n’est pas lu), aucun rapport d’erreur envoyé à
Sentry (un `CYBERTRAIN_SENTRY_DSN` exporté est vidé), courriels gardés dans
`Mailer.deliveries` (`:test`) et `force_ssl` désactivé (les variables
`CYBERTRAIN_MAIL_DELIVERY_METHOD` et `CYBERTRAIN_FORCE_SSL` ne sont pas lues pour les tests, même invalides),
fichiers envoyés écrits dans `tmp/test_uploads/`, vidé à chaque exécution,
et pas de contrôle d’hôte (un `CYBERTRAIN_HOSTS` exporté ne l’active pas). `www.example.com`, l’hôte des helpers `*_url`, est
toujours un hôte autorisé.

```text sortie — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:14)
         Expected change of 1, got 0 (from 2 to 2)
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

Un titre par fichier, une ligne par test, puis les totaux, sans durées. La
ligne indiquée est celle du `test "..."` du test&nbsp;: un programme compilé
n’a pas de trace d’appels, donc la ligne de l’assertion en échec n’est pas
connue. Le code de sortie vaut 1 quand un test a échoué, 0 sinon, et 2 pour des arguments qu’il n’accepte pas. Ce que le code testé
affiche lui-même (la ligne de sortie d’une commande) apparaît entre les
lignes des tests. Un test, un setup, un teardown ou un hook qui lève
`NotImplementedError`, une autre `ScriptError` ou `SystemStackError` est
un `ERR` comme toute autre exception, et l’exécution continue&nbsp;; seuls
`Interrupt`, `SystemExit` et `NoMemoryError` l’arrêtent. Sous Spinel, un
vrai débordement de pile arrête encore le processus par une erreur de
segmentation&nbsp;: seule une `SystemStackError` levée par le code lui-même
atteint le runner.

Les arguments&nbsp;: `-n NAME` garde le test de ce nom ou de ce nom de
méthode, et `-n /TEXT/` les tests dont le nom ou le nom de méthode
contient TEXT comme texte simple (`.`, `?` et `()` valent pour
eux-mêmes). Un TEXT qui contient l’un de `^ $ \ * + [ ] { } |` est
refusé avec le code de sortie 2, puisque ce n’est pas une expression
régulière&nbsp;: `-n /^test_create/: the text between the slashes is a plain
substring of the test name, not a regexp (^ would be looked for as itself);
write the text to look for (-n /test_create/)`. Un fichier ou un
répertoire garde ses tests&nbsp;; `FILE:LINE` est refusé (`line filters are
not supported; give the file, and -n for the name`)&nbsp;; `--` termine les
options. Un filtre qui ne garde aucun test affiche `no test matched the
filter` avant les totaux et sort avec le code 0. Ajouter ou supprimer un
fichier sous `test/` recompile le programme.

**Ce que coûte une modification.** Un argument de fichier et `-n`
choisissent quels tests s’exécutent, pas ce qui est compilé&nbsp;: le programme
contient toujours tous les tests, donc changer de filtre réutilise le
binaire, et modifier n’importe quel test (ou toute autre chose dont le
programme est construit) recompile tout le programme, après avoir
reconstruit `bin/gen`. Mesuré les 2026-11-12 et 2026-11-13 sur une machine
cloud partagée à 4 vCPU (votre propre machine donnera d’autres
chiffres)&nbsp;: les 149 tests en 21 fichiers d’examples/blog ont compilé en
environ 527 s la première fois (toute la première exécution a pris 656 s,
le binaire fait 10,2 Mo), et une deuxième exécution sans changement un `cybertrain test test/controllers` ultérieur, sans changement, a
réutilisé le binaire et démarré en environ 1 s (l’exécution du blog
lui-même, 2026-11-13)&nbsp;; l’application du blog avec trois fichiers de
test de huit tests a compilé en 162 à 233 s avec un pic d’environ 2,2 Go,
en un binaire de 8,1 Mo (2026-11-12). Écrivez plusieurs tests avant de les exécuter, et
restreignez l’exécution, pas la compilation, pendant que vous travaillez
sur l’un d’eux.

`gen/tests.rb` est refusé, et `cybertrain test` se termine avec le code 1,
la raison et aucune compilation, quand deux fichiers de test ou de support
définissent la même méthode ou constante de premier niveau (elles n’en
feraient qu’une dans un seul programme&nbsp;: déplacez une aide partagée dans
`test/support/` ou dans la classe), ainsi que dans les autres cas de
[Ce que gen refuse dans une classe de test](#what-gen-refuses-in-a-test-class).

## Fixtures

```yaml test/fixtures/users.yml
alice:
  email_address: alice@example.com
  admin: true
```

```yaml test/fixtures/articles.yml
one:
  title: First post
  body: A body long enough to pass the length check.
  author: alice
  created_at: 2026-11-01 09:00:00

two:
  id: 42
  title: Second post
  body: Another body long enough.
  author: alice
```

`test/fixtures/<table>.yml` a la forme de Rails&nbsp;: des étiquettes, puis des
colonnes. gen lit les fichiers quand il s’exécute, avec le sous-ensemble
YAML [des dictionnaires](i18n.md#dictionaries), et refuse, avec
`fichier:ligne`, un fichier qui n’est pas une table de `db/schema.rb`, une
clé qui n’est ni une colonne ni un `belongs_to` du modèle, l’ERB (`<%`
n’importe où&nbsp;: il n’y a pas d’`eval`&nbsp;; fixez une heure relative à
maintenant dans `setup` ou avec `travel_to`), une valeur qui n’est pas du
type de la colonne (une date impossible, un entier hors de 64 bits, `yes`
pour un booléen), deux étiquettes avec un même id, et une étiquette de
`belongs_to` qui ne désigne aucune ligne du fichier du parent. `DEFAULTS`
n’est pas une ligne, comme dans Rails.

- Une ligne sans `id:` reçoit l’id de Rails pour son étiquette
  (`ActiveRecord::FixtureSet.identify`), donc une étiquette a le même id
  que dans une application Rails. `author: alice` met dans `author_id`
  l’id d’alice.
- Les dates-heures sont en UTC. Les `created_at` et `updated_at` qu’une
  ligne omet valent l’heure de l’horloge au moment où la ligne est
  insérée, avant chaque test.
- `articles(:one)` renvoie `Article.find` de cette ligne&nbsp;; une étiquette
  inconnue lève `Cybertrain::Test::FixtureNotFound`. Une étiquette par
  appel.
- Une fixture est vérifiée quand gen s’exécute, mais son erreur n’arrête
  que l’exécution des tests&nbsp;: `spin run gen` (et donc
  `cybertrain db migrate`, que la fixture d’un scaffold précède) continue,
  et `cybertrain test` affiche `test/fixtures/<table>.yml:<ligne>: ...` et
  se termine avec le code 1.
- Comme dans Rails, une fixture qui pointe vers un parent empêche de
  supprimer ce parent&nbsp;: dès que `comments.yml` contient `article: one`,
  le test « should destroy article » du scaffold échoue sur la clé
  étrangère. Déclarez `has_many :comments, dependent: :destroy`, faites
  pointer les fixtures enfants vers une autre ligne (`article: two`), ou
  supprimez une ligne que rien ne référence.
- Non proposés&nbsp;: `fixtures :articles` (chaque fichier est chargé),
  `articles(:one, :two)`, les étiquettes polymorphes
  (`commentable: one (Article)`&nbsp;; écrivez les colonnes `_id` et
  `_type`), les étiquettes de `has_and_belongs_to_many`, les ancres et
  les alias.

## Tests d’intégration

`ActionDispatch::IntegrationTest` envoie des requêtes à l’application
démarrée, dans le processus, sans socket et avec une nouvelle cookie jar
pour chaque test&nbsp;:

- `get`, `post`, `patch`, `put`, `delete`, `head` (chemin, `params: {}`,
  `headers: {}`), écrits comme dans Rails. Chacun renvoie la
  `Cybertrain::Response` (Rails renvoie le statut), qui est aussi
  `response` (`response.body`, `response.status`, `response.header(name)`).
- `params:` accepte des Hash imbriqués, envoyés comme un formulaire les
  envoie (`article[title]=New`)&nbsp;; une valeur peut être une String, un
  Symbol, un nombre, `true` / `false`, nil, une Date ou un Time (envoyés
  sous la forme du texte que la colonne relit), si bien qu’un test de
  scaffold peut envoyer les valeurs d’un enregistrement telles quelles. Un
  Array est refusé.
- `fixture_file_upload("cover.png", "image/png")` dans les `params:` de
  `post`, `patch` ou `put` envoie la requête en multipart&nbsp;; le fichier
  est lu dans `test/fixtures/files/`.
- `headers:` prend le nom de l’en-tête, ou la forme `HTTP_ACCEPT` de Rails.
- Les helpers de chemin de `config/routes.rb` fonctionnent comme dans un
  contrôleur. Un helper `*_url` écrit `http://www.example.com/...`&nbsp;; une
  URL sur cet hôte est demandée par son chemin, et `assert_redirected_to`
  compare l’une ou l’autre forme. Une URL sur un autre hôte est refusée.
- `cookies` est la cookie jar du test, un `Cybertrain::Test::ClientCookies`&nbsp;:
  `cookies[:user]` ou `cookies["user"]` (la valeur brute, encore encodée
  en pourcentage), `[]=`, `key?`, `delete`, `keys`, `size`, `empty?` et
  `to_h`. Un cookie dont le `Max-Age` ou l’`Expires` est passé sur
  l’horloge, donc aussi après un `travel_to` au-delà, a disparu (`Max-Age`
  l’emporte sur `Expires`)&nbsp;; un cookie qu’un test écrit avec `[]=`
  n’expire jamais. Un `Max-Age` illisible (`Max-Age=abc`) est ignoré et un
  négatif fait expirer le cookie. Contrairement à celle de Rails, elle n’a
  ni `each`, ni `length`, ni `include?`, ni `fetch`, ni `==`&nbsp;: un test porté
  lit `cookies.to_h` pour cela.
- `follow_redirect!` demande le `Location` de la dernière réponse (sans
  son `#fragment`)&nbsp;; après une réponse qui n’est pas une redirection,
  il fait échouer le test&nbsp;: `follow_redirect!: the last response was 200,
  not a redirect (3xx with a Location)`.
- `assert_response(:success)` (ou tout
  symbole de statut, ou un nombre&nbsp;; `:error` signifie exactement 500, là
  où Rails accepte n’importe quel 5xx), `assert_redirected_to(path)`,
  `assert_select`, `assert_turbo_stream`.
- Absents&nbsp;: `session`, `flash`, `assigns`, `request`, `host!` et `as:`.
  Vérifiez plutôt la page (`assert_select`, `response.body`).

**La protection contre la falsification de requêtes** est désactivée dans
les tests sauf si `config/app.rb` règle `csrf`, comme dans l’environnement
de test de Rails&nbsp;: un `post` n’a donc pas besoin de jeton. Un test de la
vérification l’active pour quelques requêtes&nbsp;:

```ruby
test "a form without the token is refused" do
  with_forgery_protection do
    post articles_path, params: { article: { title: "x" } }
    assert_response :forbidden
  end
end
```

Dans le bloc, un formulaire a besoin de l’`authenticity_token` d’une page
demandée par le test&nbsp;; tout est rétabli à la fin du bloc, même quand une
assertion y échoue, et ce que le test a lui-même réglé (la racine des
fichiers envoyés, le fuseau, la locale, le niveau de journal) est gardé.

**Se connecter.** `cybertrain generate authentication` écrit
`test/support/session_test_helper.rb`, inclus dans chaque test
d’intégration&nbsp;: `sign_in_as users(:one)` (le mot de passe des
utilisateurs de fixture est `"password"`&nbsp;; `remember: true` coche « Rester
connecté »), `sign_out`,
`authenticity_token_in(response.body)` (le jeton du premier formulaire
d’une page, pour les requêtes dans `with_forgery_protection`), et
`open_session`, un second navigateur avec ses
propres cookies (`phone = open_session`, puis `phone.sign_in_as users(:two)`
et `phone.get ...`). Chaque requête vient de `127.0.0.1`&nbsp;; un test qui a
besoin d’une autre adresse cliente crée son propre
`client = Cybertrain::Test::Client.new(Cybertrain::Test.app)` et règle
`client.peer_address = "203.0.113.7"` (les méthodes propres au client sont
`client.get(path, headers)` et `client.post(path, fields, headers)`).

## Assertions

`assert`, `assert_not` (`refute`), `assert_equal`, `assert_not_equal`,
`assert_nil`, `assert_not_nil`, `assert_includes`, `assert_not_includes`,
`assert_empty`, `assert_not_empty`, `assert_match` / `assert_no_match`
(une Regexp, ou une String comme sous-chaîne), `assert_in_delta(expected,
actual, delta = 0.001)`, `assert_nothing_raised { }` et `flunk`, comme dans
Minitest. `assert_equal` échoue avec le texte de Minitest (`Expected: 1`
et `  Actual: 0` sur deux lignes), de même que les assertions plus
récentes&nbsp;; `assert_includes`, `assert_nil` et `flunk` gardent des textes
plus courts qui leur sont propres. `assert` et `refute` prennent un
message en deuxième argument. Les formes à bloc prennent un lambda, passé
en position&nbsp;:

```ruby
assert_difference -> { Article.count }, 1 do
  post articles_path, params: { article: { title: "New", body: "A body long enough" } }
end
assert_no_difference(-> { Article.count }) { post articles_path, params: { article: { title: "" } } }
assert_changes(-> { article.reload.title }, from: "Old", to: "New") { article.update(title: "New") }

message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
assert_includes message, "999"
```

- `assert_raises` prend une classe (une sous-classe convient, comme dans
  Minitest), une partie d’un nom de classe sous forme de String
  (`assert_raises("RecordNotFound")`), ou rien (toute StandardError), et
  renvoie le **message** de l’exception, pas l’exception&nbsp;: là où Rails
  écrit `error = assert_raises(X) { }` puis `error.message`, utilisez la
  String qu’il renvoie. Sous Spinel une méthode renvoie un seul type, et
  c’est le message que les tests lisent.
- Les assertions à bloc renvoient nil, pas la valeur du bloc.
- Non proposés&nbsp;: `assert_predicate` (il faudrait un `send` calculé&nbsp;:
  écrivez `assert article.valid?`), les expressions en String dans
  `assert_difference` (il faudrait `eval`), un Array ou un Hash
  d’expressions, et un argument de message pour les autres assertions. Des
  noms `refute_*` de Minitest, seul `refute` existe&nbsp;: écrivez
  `assert_not_equal`, `assert_not_nil` et les autres formes `assert_not_*`&nbsp;;
  un appel à `refute_equal` arrête la compilation du programme de test, car
  rien ne le définit.

## Voyager dans le temps

```ruby
test "a remembered session survives day 15" do
  sign_in_as users(:one), remember: true
  travel_to 15.days.from_now do
    get root_path
    assert_response :success
  end
end

test "the cache entry expires" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 5.minutes)
  travel 6.minutes
  assert_nil Cybertrain::Cache.read("k")
end
```

`travel_to(time)`, `travel(seconds)`, `freeze_time` et `travel_back` sont
les helpers de Rails&nbsp;: chacun fige l’horloge et laisse tomber la partie
inférieure à la seconde&nbsp;; avec un bloc, l’heure précédente revient à la fin
du bloc (même s’il lève une exception), et sans bloc le voyage dure jusqu’à
`travel_back` ou la fin du test. Tout ce que le framework horodate suit&nbsp;:
`Time.current`, `Time.now` dans un programme de test, les horodatages des
enregistrements, l’expiration du cache, les limitations de débit, la durée
de vie de la session, le `run_at` des jobs, l’expiration des jetons, le
planificateur. Les attentes et les délais (lectures de flux, récepteurs)
restent en temps réel, si bien qu’une horloge figée n’en bloque jamais
aucun. En production `Time.now` est l’horloge du système&nbsp;: le code qui doit
suivre un voyage lit `Time.current`, comme Rails le conseille. `Time.now` renvoie l’heure locale, dans le `TZ`
du processus, comme le fait la méthode d’origine, tandis que
`Time.current` est en UTC. `travel_to` prend un Time, pas une Date, et il
n’y a pas de `Time.zone.local`&nbsp;: écrivez l’instant avec `Time.utc(...)`.
Le planificateur garde ce qu’il a retenu (la dernière reprise, les
prochaines exécutions) à travers un voyage&nbsp;; un test qui voyage pendant
que des threads de planificateur ou de worker tournent n’est pas pris en
charge.

Les durées sont des secondes entières&nbsp;: `5.minutes` vaut `300`, et
`2.weeks.ago` et `3.days.from_now` renvoient un Time sur l’horloge. Il n’y a
pas de `1.month` (un mois n’a pas de durée en secondes)&nbsp;: c’est une
`NoMethodError` quand il s’exécute. Utilisez les méthodes de calendrier de
Time&nbsp;: `Time.current.months_ago(1)`, `advance(months: 1)`,
`beginning_of_day`, `end_of_month`, `yesterday`
([Les heures et le fuseau horaire](models.md#times-and-the-time-zone)).
`advance` ajoute les heures, minutes et secondes comme du temps écoulé,
après la partie calendaire, et prend des entiers&nbsp;; l’horloge réelle garde
les microsecondes.

## Tester les flux et les composants

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "Alice"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
```

`render_inline(component, content: "")` et `render_inline(partial:,
locals: {})` rendent hors de toute requête, renvoient le HTML (Rails
renvoie un fragment Nokogiri et prend le contenu en bloc) et le gardent
pour `assert_select`. Un helper qui a besoin d’une requête lève
`Cybertrain::Views::OutsideRequest`.

`assert_select(selector, equality = nil, count:, minimum:, maximum:,
text:)` vérifie le dernier `render_inline` ou la dernière réponse de ce
test (sans l’un ni l’autre il échoue&nbsp;: « No response yet ») et renvoie
les éléments trouvés&nbsp;:

- Sélecteurs&nbsp;: une balise, `.class`, `#id`, `[attr]`, `[attr="v"]`, des
  composés (`a.btn[href="/x"]`), les combinateurs descendant et enfant
  (`>`), et une liste (`h1, h2`). Les pseudo-classes, `+` et `~`, les autres opérateurs d’attribut, une barre oblique inverse
  (`assert_select: CSS escapes (\) are not supported`) et la forme à bloc
  imbriqué échouent avec
  `assert_select: <feature> is not supported`.
- `text:` est une String comparée au texte de chaque élément, ou une
  Regexp appliquée à ce texte. Dans ce texte, chaque suite de blancs
  devient une espace et les extrémités sont retirées (Rails ne retire que
  les extrémités). Le deuxième argument peut être le texte positionnel de
  Rails (une String ou une Regexp), un nombre (un entier) ou `true` /
  `false`&nbsp;; un nombre peut
  aussi être un Range comme `2..3`&nbsp;; un nombre donné là et aussi dans
  `count:`, `minimum:` ou `maximum:` est refusé, de même qu’un Range
  négatif, inversé ou sans ses deux bornes (`assert_select: a Range count needs both ends (got 2..)`).
- Le HTML est lu tel qu’il est écrit, sans la réparation qu’un navigateur
  (et Nokogiri, derrière l’`assert_select` de Rails) ferait&nbsp;: `table > tr`
  correspond à une table écrite sans `<tbody>`, `p > div` correspond à
  `<p><div>`, et une balise de fin omise (`<li>a<li>b`, `<p>a<p>b`) ou un
  `<div/>` auto-fermant fait échouer l’assertion avec sa position. Les
  gabarits du framework se lisent tous.

Une diffusion est une ligne de `cybertrain_messages`, donc les assertions
de flux lisent la table, sans poller ni socket&nbsp;:

```ruby
test "a new comment is broadcast and answered with a Turbo Stream" do
  article = articles(:one)
  payloads = assert_broadcasts(article, 1) do
    post article_comments_path(article), params: { comment: { commenter: "Dave", body: "Hi" } },
                                         headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end
  assert_includes payloads[0], 'target="comments"'
  assert_turbo_stream action: "append", target: "comments"
end
```

`assert_broadcasts(stream, count) { }` compte ce qui a été diffusé sur un
flux (un nom, ou un enregistrement) pendant le bloc, ou sans bloc depuis le
début du test, et renvoie les contenus&nbsp;; `assert_no_broadcasts(stream)`
n’en veut aucun. `assert_turbo_stream(action:, target:, count: 1)` lit la
dernière réponse, qui doit être `text/vnd.turbo-stream.html`, ou le dernier
`render_inline`. Pour lire un flux en direct comme le fait un navigateur,
`client.get_stream(path, events: n)` d’un `Cybertrain::Test::Client`
exécute une réponse en streaming en mémoire ([Temps réel](realtime.md)).

## Tester les courriels

Dans `cybertrain test`, `Cybertrain.config.mail_delivery_method` vaut
`:test` sauf si `config/app.rb` le règle&nbsp;: `deliver_now`, `Mailer.deliver` et le job de `deliver_later`
vérifient le message et le gardent dans `Cybertrain::Mailer.deliveries` au
lieu de se connecter, et la liste est vidée avant chaque test. Le programme
de test donne aux courriels l’expéditeur `from@example.com` quand
l’application n’en fixe aucun.

```ruby
test "a reset mails a link" do
  assert_emails 1 do
    post passwords_path, params: { email_address: users(:one).email_address }
  end
  mail = Cybertrain::Mailer.deliveries.last
  assert_equal "Reset your password", mail.mail_subject
  assert_includes mail.mail_body, "/passwords/"
end
```

`assert_emails(count) { }` compte les courriels que le bloc a envoyés&nbsp;; un
courriel mis en file dans le bloc avec `deliver_later` est d’abord envoyé,
et un job de courriel qui échoue fait échouer l’assertion avec son erreur.
`assert_no_emails { }` n’en veut aucun. Les lecteurs d’un message sont
`mail_to`, `mail_from`, `mail_subject`, `mail_body` et `mail_html`. Un test
du chemin SMTP lui-même règle
`Cybertrain.config.mail_delivery_method = :smtp` et remet `:test` dans
`teardown` (le réglage n’est pas remis à zéro entre les tests), comme dans
[Tester les appels sortants](#testing-outbound-calls). Hors de
l’environnement de test, `:test` démarre avec un avertissement, et aucun
courriel n’est envoyé.

## Tester les jobs

```ruby test/jobs/notify_comment_job_test.rb
require "test_helper"

class NotifyCommentJobTest < ActiveSupport::TestCase
  test "a comment queues its notification, which runs" do
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    assert_enqueued_jobs 1, "NotifyCommentJob"
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id }
    assert_equal 1, perform_enqueued_jobs
    assert_no_enqueued_jobs
  end

  test "the jobs a block queues run at once" do
    performed = perform_enqueued_jobs { ReminderJob.perform_in(3600, { "id" => 1 }) }
    assert_equal 1, performed
  end
end
```

- `assert_enqueued_jobs(count, kind = "")` compte les jobs en file (d’un
  type quand il est donné)&nbsp;; `assert_no_enqueued_jobs(kind = "")` n’en
  veut aucun.
- `assert_enqueued_with(kind, args)` veut un job en file de ce type dont
  les arguments contiennent chaque clé donnée avec une valeur égale
  (`"comment_id" => 7` correspond à un `7` JSON&nbsp;; `comment_id: 7`
  fonctionne aussi).
- `perform_enqueued_jobs { }`, la forme en ligne de Rails, exécute le bloc,
  puis chaque job mis en file pendant celui-ci et les jobs que ceux-ci
  mettent en file, quel que soit leur `run_at`, et renvoie combien ont
  tourné. Un job qui lève une exception fait échouer le test avec sa classe
  et son erreur, et n’est pas réessayé&nbsp;; un job que l’application écarte
  (`discard_on`) compte comme exécuté.
- `perform_enqueued_jobs(now = Time.current)` sans bloc exécute chaque job
  dû à `now`, un par un, jusqu’à ce qu’il n’y en ait plus. Une nouvelle
  tentative prévue plus tard reste en file&nbsp;: faites `travel` au-delà, ou
  passez un `now` plus tardif. Les deux formes font échouer le test après
  10 000 jobs (un job qui se remet lui-même en file).
- `clear_enqueued_jobs` supprime les jobs en file&nbsp;;
  `WelcomeJob.perform_now(args)` en exécute un directement, une exception
  remontant jusqu’au test.
- Les tâches planifiées s’exécutent un tour à la fois avec
  `Cybertrain::Scheduler.run_due(Time.current.to_i)` (des secondes epoch).

## Tester les appels sortants

Quand le code testé envoie un webhook ([HTTP sortant](external-services.md#outbound-http))
ou un courriel par SMTP ([Envoyer des courriels](external-services.md#sending-e-mail)),
le test le reçoit dans le processus&nbsp;: `Cybertrain::Test::HttpReceiver` et
`Cybertrain::Test::SmtpReceiver` écoutent sur `127.0.0.1`, enregistrent ce
qui arrive et répondent par une réponse préparée. Un récepteur démarré
dans un test est arrêté après lui, même quand il échoue.

```ruby test/integration/signup_hook_test.rb
require "test_helper"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

class SignupHookTest < ActiveSupport::TestCase
  setup do
    Cybertrain.config.http_allow_private = true   # sinon HttpClient refuse le loopback
  end

  teardown do
    Cybertrain.config.http_allow_private = false
    Cybertrain.config.mail_delivery_method = :test
  end

  test "a sign-up posts a webhook" do
    hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    hook.start                                   # se lie à un port libre et le renvoie
    SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # le code de l’application
    req = hook.received_request                  # attend au plus 5 s ; nil si rien n’est venu
    assert_equal "POST", req.http_method
    assert_equal "/hooks/signup", req.http_target
    assert_equal "application/json", req.http_header("Content-Type")
    assert_includes req.http_body, "ann@example.com"
  end

  test "a refused recipient is reported" do
    Cybertrain.config.mail_delivery_method = :smtp
    smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
    port = smtp.start
    mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
    assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
    mail = smtp.received_message
    assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
                 mail.transcript.first(3)
    assert_not mail.delivered?
  end
end
```

`HttpReceiver.new` prend les `status:`, `headers:`, `body:` et `chunked:`
préparés (`respond_with` les change entre les requêtes)&nbsp;; la requête
revient sous forme de `ReceivedRequest` (`http_method`, `http_target`,
`http_path`, `http_headers` avec des noms en minuscules,
`http_header(name)`, `http_body` avec un corps chunked décodé).
`SmtpReceiver` joue 220, EHLO (avec 8BITMIME sauf `eight_bit_mime: false`,
AUTH PLAIN avec `auth: true`), MAIL, RCPT, DATA et QUIT&nbsp;; `reject:` fait
échouer n’importe lequel de `:greeting`, `:ehlo`, `:mail`, `:rcpt`, `:data`
ou `:message` avec la réponse donnée. Un `ReceivedMessage` a
`envelope_from`, `envelope_recipients`, `message_data` (le dot-stuffing
défait), `message_header(name)`, `message_body` et la `transcript` des
commandes&nbsp;; pour un message HTML, `message_parts` le décode en
`"subject"`, `"text"` et `"html"`. Les deux acceptent une connexion sauf si
`max:` en indique davantage (`received_requests` / `received_messages` les
renvoient toutes). Chaque attente est bornée&nbsp;: un récepteur abandonne après
`accept_window:` (10 s) sans connexion et un client muet après
`read_timeout:` (5 s), et `stop` (sans risque deux fois) termine son thread
et ferme son port, si bien qu’un récepteur ne prend jamais la connexion
d’un test ultérieur. Un récepteur démarré hors d’un test (en haut d’un
fichier) n’est pas arrêté pour vous.

Un flux WebSocket se teste de la même façon avec
`Cybertrain::Test::WebSocketReceiver`, un serveur WebSocket scénarisé sur
`127.0.0.1`&nbsp;: chaque connexion joue une liste de
`Cybertrain::Test::WsStep` (`"accept"`, `"send_text"`, `"expect"`,
`"silent"`, `"close"`, `"drop"`, `"echo_until_close"`, ...), et les trames
envoyées par le client reviennent démasquées de `ws_received`.

```ruby test/integration/trades_feed_test.rb
require "test_helper"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # une constante : les blocs ne voient pas les variables locales

# Les blocs sont écrits dans une méthode, où leurs paramètres sont utilisés.
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

class TradesFeedTest < ActiveSupport::TestCase
  test "a trade message is stored" do
    rx = Cybertrain::Test::WebSocketReceiver.new
    rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                  Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
    rx.start
    subscribe_trades(rx.url("/trades"))
    Cybertrain::WebSocket.start!               # le programme de test ne démarre jamais les flux
    # ... interroger TICKS pendant quelques secondes au plus ...
    Cybertrain::WebSocket.stop!
    assert_equal ["tick"], TICKS
    assert_equal "subscribe", rx.ws_received[0].rec_data
  end
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` rend exacts les délais de
reconnexion. `test/websocket_integration.rb` dans ce dépôt montre un test
complet.

## Tester les journaux et les rapports d’erreur

Le `X-Request-Id` d’une réponse est l’identifiant de la requête. Pour lire des
lignes de journal, un test donne à `Cybertrain.logger` un `StringIO` pour le
travail qu’il observe et remet le logger en place ensuite, dans une méthode à
part (sous Spinel, un `rescue` ou un `ensure` autour d’un `yield` va dans une
méthode simple)&nbsp;:

```ruby test/integration/logging_test.rb
require "test_helper"
require "stringio"

class LoggingTest < ActionDispatch::IntegrationTest
  test "a comment's job logs the request's id" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Ann", body: "Hi" } }
    rid = response.header("X-Request-Id").to_s
    log = StringIO.new
    perform_jobs_logging_to(log)
    assert_includes log.string, "] [#{rid}] new comment "
  end

  private

  def perform_jobs_logging_to(io)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end
end
```

L’heure en tête de ligne change d’une exécution à l’autre (figez-la avec
`freeze_time` pour la comparer)&nbsp;: comparez donc ce qui la suit, le
niveau, les étiquettes et le message. Le journal des requêtes d’une
application est muet dans les tests (`log_level :none`), mais la ligne `ERROR`
d’un job qui échoue est écrite quand même&nbsp;; un test qui exécute un job en
échec capture le logger comme ci-dessus, ou la ligne apparaît parmi les lignes
des tests.

Les rapports d’erreur vont à `Cybertrain::Test::SentryReceiver`, un Sentry sur
`127.0.0.1` que charge `cybertrain/test_help`. `cybertrain test` ignore un DSN
exporté&nbsp;: un test en affecte donc un et le remet ensuite. L’exemple
exécute le `NotifyCommentJob` d’examples/blog, qui lève son propre
`NotifyCommentJob::CommentGone` quand le commentaire qu’on lui donne a
disparu et s’abandonne ([Retries and discards](background-and-operations.md#retries-and-discards))&nbsp;; le job du tutoriel ne fait que
journaliser, donnez-lui d’abord ce `find_by`, la classe et
`discard_on CommentGone`&nbsp;:

```ruby test/integration/error_reporting_test.rb
require "test_helper"

class ErrorReportingTest < ActionDispatch::IntegrationTest
  setup do
    @sentry = Cybertrain::Test::SentryReceiver.new
    @sentry.start
    @saved_dsn = Cybertrain.config.sentry_dsn
    @saved_private = Cybertrain.config.http_allow_private
    Cybertrain.config.sentry_dsn = @sentry.dsn                # http://public@127.0.0.1:<port>/1
    Cybertrain.config.http_allow_private = true               # sinon HttpClient refuse le loopback
  end

  teardown do
    Cybertrain.config.sentry_dsn = @saved_dsn
    Cybertrain.config.http_allow_private = @saved_private
  end

  test "a job whose comment is gone is discarded and reported" do
    NotifyCommentJob.perform_later("comment_id" => 999_999, "article_id" => articles(:one).id)
    perform_enqueued_jobs                                       # un abandon ne fait pas échouer le test
    event = @sentry.received_events(1)[0]                      # attend 5 s au plus
    assert_equal "NotifyCommentJob", event.sentry_field("transaction")
    assert_equal "NotifyCommentJob::CommentGone", event.sentry_field("exception.values.0.type")
  end
end
```

`SentryReceiver.new(status: 200, max: 50, accept_window: 10.0)` répond à
chaque enveloppe comme Sentry (un autre `status:`, comme 429, joue un Sentry
qui refuse)&nbsp;; `dsn(project = "1", prefix = "")` est un DSN qui lui
envoie, et `received_events(count, wait = 5.0)` renvoie ce qui est arrivé.
Chacun est un `Cybertrain::Test::SentryEnvelope`&nbsp;: `sentry_path`,
`sentry_auth` (`X-Sentry-Auth`), `sentry_content_type`, `sentry_body` (les
trois lignes JSON), `sentry_field("a.b.0.c")` pour un champ de l’événement
(`""` quand il est absent) et `sentry_header_field(name)` pour l’en-tête de
l’enveloppe. Une clé de `extra` qui contient un point se lit entière, car
dans un objet la plus longue suite du chemin qui est une clé est prise
d’abord&nbsp;: `sentry_field("extra.job.attempt")`. Un récepteur démarré dans un test est arrêté après lui, comme
les autres.

Un abonné ajouté dans un test est retiré avant le test suivant (celui
qu’ajoute `config/app.rb` reste), et avant chaque test le rapporteur livre ce
qui est encore en file et oublie sa fenêtre de dédoublonnage, si bien que le
même échec dans deux tests est signalé dans les deux.
`Cybertrain.error.drain_reports` attend (2 s au plus) les rapports en file,
pour un test qui lit ce qu’un abonné a reçu&nbsp;:

```ruby
# En tête du fichier de test :
REPORTS_SEEN = Array.new(0) { "" }
class SeenReports < Cybertrain::ErrorSubscriber
  def report(event)
    REPORTS_SEEN << event.error_class
    nil
  end
end

# Dans un test :
Cybertrain.error.subscribe(SeenReports.new)
get "/articles/999999"
Cybertrain.error.drain_reports
assert_equal 0, REPORTS_SEEN.size             # un 404 n'est pas signalé
```

## Ce que gen refuse dans une classe de test

gen réécrit une classe de test en méthodes&nbsp;: `test "shows it" do` devient
`def test_shows_it` (un caractère ASCII hors de `[A-Za-z0-9_]` devenant `_`, tout autre
`_u<hex>_` (son point de code en minuscules, fermé par `_`), si bien que
`"ログ"` donne `test__u30ed__u30b0_` et `"café x"` `test_caf_ue9__x`&nbsp;; `-n` prend le
nom de méthode ou le nom écrit), et les blocs `setup do` et
`teardown do` deviennent des méthodes `setup` et `teardown` qui appellent
`super`. Ce que la réécriture ne peut pas reporter exactement fait refuser le
fichier, jamais une copie fausse en silence ni un test perdu&nbsp;:

- un nom de test qui n’est pas un simple littéral de chaîne
  (interpolation), ou qui contient un échappement que gen ne lit pas
  (`\u`, `\x`, `\c`, `\C`, `\M` ou un octal&nbsp;: écrivez le caractère
  lui-même&nbsp;; `\n`, `\t` et `\"` sont lus)&nbsp;;
- deux tests dont les noms de méthode coïncident dans une classe, un
  `def test_x` compris&nbsp;;
- à la fois `setup do` et `def setup` dans une classe (de même pour
  `teardown`), et un `def setup` ou `def teardown` sans `super` dans une
  classe dont le parent est une classe de base d’application (ses blocs
  `setup do` ne s’exécuteraient pas)&nbsp;;
- un `def test_x` qui prend des paramètres, ou placé après `private` ou
  `protected` (Minitest n’exécute que les méthodes de test publiques)&nbsp;;
- `setup { }` et `setup :name` (écrivez `setup do ... end`), et des
  paramètres de bloc sur `test`, `setup` ou `teardown`&nbsp;;
- `next`, `break` ou `redo` dans le corps d’un test, d’un setup ou d’un
  teardown, même dans un `if`, `unless`, `case` ou `begin` de ce corps
  (utilisez `return`), et `return <value>` (chacun renvoie nil)&nbsp;;
- une classe de test imbriquée dans une autre classe ou un module, une
  classe de test ouverte deux fois, et `setup do` dans un
  `ActiveSupport::TestCase` rouvert (écrivez une classe de base
  d’application avec `setup do` et héritez-en)&nbsp;;
- une ligne `test`, `setup` ou `teardown` que gen ne peut pas placer dans
  le corps de la classe (dans une condition, une boucle, une chaîne ou un
  heredoc), une forme sur une ligne qui ne se termine pas par `end`, un
  `end` suivi de code, et une indentation qui mélange tabulations et
  espaces&nbsp;;
- un `require_relative` dont l’argument n’est pas un littéral de chaîne.

Un fichier refusé n’arrête pas `spin run gen`, si bien que le serveur de
développement, `cybertrain db migrate` et `cybertrain build` continuent de
fonctionner&nbsp;: gen écrit un `gen/tests.rb` qui ne fait qu’afficher la
raison, et `cybertrain test` affiche alors `<path>:<line>: <reason>` et se
termine avec le code 1, sans compilation. Corrigez la ligne indiquée.
`test "name" do` peut aussi s’écrire `test"name"` ou avec une tabulation.
Un `test "x" do` écrit après `private` n’est pas refusé, mais il devient
une méthode privée de la copie et échoue quand il s’exécute, là où Rails
l’exécute&nbsp;: gardez les tests au-dessus de `private`. Autres limites
connues&nbsp;: un nom qui contient le texte `_u3042_` a le nom de méthode d’un
nom avec `"あ"` à sa place (gen refuse la paire dans une même classe)&nbsp;; un
`def setup` dans un module n’est pas vérifié pour `super`&nbsp;; une classe à
deux niveaux sous une classe de base d’application doit appeler `super`
même quand cette base ne définit pas de `setup`&nbsp;; et tant qu’un fichier
de test est refusé, `spin run gen -- --check` ne compare pas les copies
périmées de `gen/test/` (la CI échoue alors à `cybertrain test`).

`cybertrain test` refuse aussi, de la même façon, un
`test`, `setup` ou `teardown` de premier niveau dans `test/test_helper.rb`
ou `test/support/` (il ne s’exécuterait jamais), un `def render_inline` de
premier niveau (il remplacerait celui du framework), `assert_select ... do`
et `render_inline ... do`, et les aides de premier niveau en double de
[Exécuter les tests](#running-the-tests). Un fichier en forme de classe ne
s’exécute que par `cybertrain test`&nbsp;: sous `spin test`, le corps de sa
classe lève « class-form tests run with `cybertrain test FILE` ».

## La forme de premier niveau

La forme précédente, des blocs `test` au niveau supérieur d’un fichier,
fonctionne toujours, dans `cybertrain test` (comme ici, avec l’application
et les fixtures du programme) et sous `cybertrain spin test`&nbsp;:

```ruby test/legacy.rb
require "test_helper"

setup do
  Cybertrain.config.http_allow_private = true
end

teardown do
  Cybertrain.config.http_allow_private = false
end

test "shows an article" do
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  res = client.get("/articles/#{articles(:one).id}")
  assert_response res, :success
  assert_includes res.body, articles(:one).title
end

Cybertrain::Test.run!
```

Les blocs `setup do` et `teardown do` de premier niveau s’exécutent avant
et après chaque test de leur fichier. `cybertrain spin test` compile chaque
`test/*.rb` en son propre programme et compare sa sortie avec
`test/<name>.rb.expected`&nbsp;; il n’y a là ni vidage ni fixtures (il leur
faut la liste des tables de gen), et `Cybertrain::Test.run!` exécute les
tests du fichier. Dans `cybertrain test`, les tests du fichier s’exécutent
avec les autres, après le vidage et les fixtures, et `run!` ne fait rien.
Sous `spin test`, rien ne démarre l’application pour le fichier&nbsp;: un tel
fichier la démarre donc lui-même, comme le faisaient les fichiers de
support de 0.4 (`AppTest.boot`, `BlogTest.boot`), et n’utilise pas de
fixtures. `Cybertrain::Test::Client` pilote l’application avec une
cookie jar, CSRF compris (`client.get`, `client.post(path, fields, headers)`,
`client.follow_redirect!`, `client.response`, et les formes à deux
arguments `assert_response res, :ok` et `assert_redirected_to res, path`).
L’instantané d’un test qui touche SQLite vient du binaire compilé&nbsp;:
`script/regen-snapshot test/<name>.rb` dans le dépôt du framework, ou
`rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`.

## Mettre à niveau depuis 0.4

- Ajoutez `test/test_helper.rb` comme ci-dessus, et sortez-en ce qu’un
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
  ([Journaux](background-and-operations.md#logs)).
- Un `CYBERTRAIN_LOG_FORMAT` ou un `CYBERTRAIN_SENTRY_DSN` exporté n’atteint
  plus les tests&nbsp;; pour tester avec, fixez-les dans `config/app.rb`, ou
  affectez le DSN dans le test.

## Intégration continue

`cybertrain new` écrit `.github/workflows/ci.yml` pour l’application. Il
appelle l’action `setup-cybertrain` de ce dépôt
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
épinglée sur l’étiquette de version du CLI, qui installe les en-têtes de
SQLite, zlib et OpenSSL et Ruby, lit dans `spin.lock` le commit du
framework auquel l’application est verrouillée, récupère le framework à ce
commit et lance son `cybertrain doctor` et son `cybertrain setup` (avec
`~/.cybertrain/spinel` mis en cache par version de Spinel et image de
runner). Le workflow vérifie ensuite que `spin.lock` est à jour
(`spin lock && git diff --exit-code spin.lock`) et que `gen/` est frais
(`SPIN_DEBUG=1 spin run gen -- --check`), et lance `cybertrain test`. Quand
les étapes de la chaîne d’outils changent, c’est l’action qui change, pas
la copie de chaque application. Le commit est lu dans `spin.lock`, donc le
workflow suppose la dépendance git par défaut&nbsp;; une application créée avec
`--path` passe le dépôt du framework à l’action en tant que
`framework-path`.
