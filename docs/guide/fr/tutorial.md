---
source_sha256: 62cfdaff2b084f3fed0f46dc16b6967071128d69c23036f7cfd531bae3cbab7c
path: tutorial.html
title: "Premiers pas&nbsp;: le blog"
description: "Construisez le blog du guide Getting Started de Rails, des articles avec commentaires, avec CyberTrain&nbsp;: générez un scaffold, migrez, imbriquez les routes, diffusez les commentaires en direct avec Turbo, mettez un job en file, testez avec Cybertrain::Test et compilez pour le déploiement avec cybertrain build."
og_title: "Premiers pas avec CyberTrain&nbsp;: le blog"
og_description: "Calqué sur le Getting Started de Rails&nbsp;: un blog avec des articles et des commentaires, construit avec CyberTrain sur Spinel."
og_image: tutorial.png
crumb: Tutoriel
nav: tutorial
toc_title: "Étapes 00–19"
meta:
  - term: "Prérequis"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, en-têtes SQLite 3, zlib et OpenSSL (Spinel est installé pour vous) <a class="meta-link" href="#requirements">Étape 00</a>'
  - term: "Point de départ"
    text: "`gem install cybertrain`"
  - term: "Résultat"
    text: "`dist/blog`"
---

# Premiers pas&nbsp;: le&nbsp;blog

Calqué sur le guide
[Getting Started](https://guides.rubyonrails.org/getting_started.html) de
Rails&nbsp;: un blog avec des articles et des commentaires. Vous allez générer
le scaffold des articles, ajouter des validations, imbriquer les commentaires
sous les articles, pousser les nouveaux commentaires vers toutes les pages
ouvertes avec Turbo, mettre en file un job d’arrière-plan, répondre en JSON,
écrire des tests qui pilotent l’application dans le même processus, ajouter la
connexion, joindre une image envoyée, et compiler l’application dans un
dossier `dist/` déployable. L’application à laquelle mène ce tutoriel est
[`examples/blog`](../../examples/blog), testée par la CI sous Linux et macOS.


<!-- step 00 #requirements stage: Installation · Ruby, `cc`, SQLite -->
## Prérequis

> [!WHY]
> CyberTrain compile via Spinel vers du C&nbsp;: il lui faut donc une chaîne
> de compilation C et les en-têtes SQLite&nbsp;; la commande `cybertrain` est
> une gem, il lui faut donc Ruby.

<!-- list: checklist -->
- Ruby 3.2+ et RubyGems, uniquement pour la commande `cybertrain`&nbsp;; les
  applications ne tournent jamais sur CRuby. Avec Ruby 3.2, ajoutez aussi
  `gem install prism`.
- Spinel, à la version qu’épingle CyberTrain (`cybertrain doctor` l’affiche), du fork
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel), qui
  intègre les corrections dont CyberTrain a besoin avant une version
  amont&nbsp;; non testé avec d’autres versions. Vous ne l’installez pas à la
  main&nbsp;: la première commande qui en a besoin compile cette version dans
  `~/.cybertrain` (quelques minutes, une seule fois), sauf si un `spinel` de
  cette version est déjà dans le `PATH`.
- Une chaîne de compilation C (`cc`, ou le compilateur désigné par `CC`) et
  `make`, plus `git` et `curl`, pour compiler Spinel, qui compile chaque
  programme en C.
- En-têtes et bibliothèques SQLite 3, zlib et OpenSSL&nbsp;: `libsqlite3-dev`,
  `zlib1g-dev` et `libssl-dev` sous Debian/Ubuntu. Sous macOS, SQLite et zlib
  sont fournis avec les Command Line Tools de Xcode, et OpenSSL par Homebrew
  (`brew install openssl@3`, puis les deux chemins qu’indique
  [Prérequis](install.md#requirements)).

`cybertrain doctor` vérifie tout cela et affiche la commande d’installation de
ce qui manque. La liste complète et ce qui est
facultatif&nbsp;: [Prérequis](install.md#requirements)&nbsp;; où Spinel est placé
et comment utiliser une autre installation&nbsp;:
[comment Spinel est installé](install.md#how-spinel-is-installed).

> [!NOTE]
> Pas de machine sur laquelle installer&nbsp;? Le
> [bac à sable](site:playground.html) ouvre ce blog dans un GitHub Codespace
> avec les étapes 02, 03, 04 et 07 déjà faites.

<!-- step 01 #install stage: Installation · la CLI `cybertrain` -->
## Installer la CLI

> [!WHY]
> `cybertrain` est la commande qui crée les applications, génère les scaffolds
> de ressources, migre, sert et compile.

La première ligne l’installe depuis RubyGems. Le reste est le tutoriel entier
en un coup d’œil&nbsp;; les étapes ci-dessous le reprennent une commande à la
fois.

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">terminal &mdash; n’importe quel répertoire, puis&nbsp;blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Code&nbsp;: terminal &mdash; n’importe quel répertoire, puis blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># installe Spinel la première fois (quelques minutes)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># production: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

[Toutes les commandes](install.md#the-cybertrain-command), avec leurs options, sont listées
dans le guide d’installation.

<!-- step 02 #new-app stage: Vous écrivez · `blog/` -->
## Créer l’application

> [!WHY]
> Vous obtenez les conventions de répertoires de Rails, plus trois programmes
> dans `bin/`&nbsp;: `bin/blog.rb` (l’application), `bin/gen.rb` (le
> générateur) et `bin/db.rb` (les migrations en développement).

```shell terminal — n’importe quel répertoire
cybertrain new blog
cd blog
```

`cybertrain new` écrit l’application avec un `spin.toml` qui pointe vers la
version correspondant à la CLI (X.Y.Z est ce qu’affiche `cybertrain version`)&nbsp;:

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }
```

Ensuite, il s’assure que Spinel est installé (la première fois, cela signifie
compiler la version épinglée de Spinel dans `~/.cybertrain`&nbsp;: quelques
minutes, une seule fois&nbsp;; voir l’[étape 00](#requirements)) et lance
`spin lock` (spin récupère le framework dans son cache,
`~/.cache/spin/packages/`, et épingle le commit dans `spin.lock`) et
`SPIN_DEBUG=1 spin run gen` (gen compilé dans le mode debug de spin), un peu
comme `rails new` lance `bundle install`, pour que
`cybertrain server` fonctionne tout de suite. Il termine en affichant les
étapes suivantes. Rien du framework n’est copié dans l’application&nbsp;;
commitez `spin.toml` et `spin.lock`.

> [!NOTE]
> Si Spinel ou l’une des deux étapes `spin` échoue, les fichiers restent en
> place, `new` sort avec le code 1 et affiche ce qu’il faut lancer une fois la
> cause corrigée (pour Spinel&nbsp;: `cybertrain setup`, puis
> `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen` dans le
> nouveau répertoire). `--skip-spin` se contente d’écrire les fichiers&nbsp;;
> `--path DIR` fait plutôt dépendre l’application d’une copie locale du dépôt,
> `--git URL [--ref R]` du framework situé à URL (à la branche ou au tag R),
> et `--version V` d’une version de l’index, une fois que `cybertrain` sera
> sur un `spin-index`.

Les noms d’application utilisent des lettres minuscules, des chiffres et `_`,
et commencent par une lettre. L’arborescence générée&nbsp;:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb  config/locales/en.yml  .env.example
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/  app/jobs/
  app/assets/stylesheets/application.css  app/assets/images/
  app/javascript/application.js  config/importmap.rb
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/  .github/workflows/ci.yml
  Dockerfile  config/deploy.yml  .kamal/secrets
```

`bin/blog.rb` est l’unique point d’entrée de l’application, le programme que
compile `spin build blog`&nbsp;: `./blog` sert l’application, `./blog migrate`
et `./blog db status` gèrent la base de données. `bin/gen.rb` lance le
générateur (`spin run gen`), et `bin/db.rb` lance le migrateur pendant le
développement (`cybertrain db migrate` l’utilise, car `bin/blog.rb` ne peut
pas compiler tant que la première migration n’a pas généré `gen/models/`).
`gen/` contient déjà ce qu’a écrit `spin run gen`, dont `views.rb`&nbsp;: la
table des vues intégrées, versionnée et vide.

`bin/blog.rb` et `bin/db.rb` commencent tous deux par
`require "cybertrain/core"`&nbsp;: le framework sans ses sous-systèmes
optionnels (les jobs, Turbo Streams, le mailer, le cache et les autres), ce
qui raccourcit chaque build. Les étapes suivantes qui en utilisent un ajoutent
sa ligne ([Sous-systèmes](how-it-works.md#subsystems)).

Le layout lie `app/assets/stylesheets/application.css` avec
`stylesheet_link_tag` et charge `app/javascript/application.js` via l’import
map de `config/importmap.rb` avec `javascript_importmap_tags`&nbsp;; `spin run
gen` écrit les deux avec une empreinte dans `public/assets/`, ignoré par git
(voir [Assets](assets.md)). `.env.example` liste les variables que lit
l’application, `.github/workflows/ci.yml` lance les tests sur GitHub
([Intégration continue](testing.md#continuous-integration)), et la dernière
ligne de l’arborescence est la configuration Kamal de
l’[étape 19](#ship).

`ApplicationController` commence ainsi, pour qu’un enregistrement introuvable
donne une 404 via `rescue_from`&nbsp;:

```ruby app/controllers/application_controller.rb
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

<!-- step 03 #scaffold-article stage: Vous écrivez · `app/`, `db/migrate/` -->
## Scaffold d’un article

> [!WHY]
> Une seule commande écrit toute la tranche CRUD, à la Rails.

```shell terminal — blog/
cybertrain generate scaffold article title:string body:text
```

Elle écrit une migration, un modèle, un contrôleur et cinq vues (`index`,
`show`, `new`, `edit`, `_form`), et insère `resources :articles` dans
`config/routes.rb`. Les types de champ sont `string`, `text`, `integer`,
`float`, `boolean`, `date`, `datetime`, `references` et `attachment` (un
fichier envoyé, [étape 18](#attachments))&nbsp;; le type par défaut est
`string`. Le `cybertrain g scaffold` du démarrage rapide est la même commande.

> [!NOTE]
> Les fichiers existants ne sont jamais écrasés&nbsp;: chaque fichier est
> signalé comme `create`, `identical` ou `exist`.

<!-- step 04 #root-route stage: Vous écrivez · `config/routes.rb` -->
## Définir la route racine

> [!WHY]
> `/` doit afficher la liste des articles.

```ruby config/routes.rb
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

> [!NOTE]
> Les routes sont lues à la compilation&nbsp;: `spin run gen` les transforme
> en `gen/routes.rb`. `cybertrain server`, `cybertrain db migrate` et
> `cybertrain build` le lancent pour vous.

<!-- step 05 #validations stage: Vous écrivez · `app/models/` -->
## Ajouter des validations au modèle

> [!WHY]
> Comme dans le guide Rails, ajoutez à la main une validation de longueur.

```ruby app/models/article.rb
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` n’a pas de superclasse écrite&nbsp;: la superclasse
`Cybertrain::Model`, les colonnes et les finders viennent de
`gen/models/article.rb`. Un enregistrement qui échoue signale des messages
tels que «&nbsp;Title can't be blank&nbsp;», «&nbsp;Title has already been
taken&nbsp;» et «&nbsp;Body is too short (minimum is 10 characters)&nbsp;».
Les autres validateurs (`format`, `inclusion`, `numericality`, ...) sont dans
[Validations](models.md#validations).

<!-- step 06 #articles-controller stage: Vous écrivez · `app/controllers/` -->
## Le contrôleur ArticlesController

> [!WHY]
> Un CRUD complet, à la Rails jusqu’aux strong params et au flash suivi d’une
> redirection, à deux choses près que Spinel impose partout.

```ruby app/controllers/articles_controller.rb
# app/controllers/articles_controller.rb (index/show/edit are as plain as
# Rails' own scaffold; update mirrors create)
class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  def new_action   # a `new` method would shadow ArticlesController.new
    @article = Article.new
  end

  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = "Article was successfully created."
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
```

> [!RULE] Règle Spinel&nbsp;: new_action
> ### `new_action`, pas `new`
>
> Une méthode nommée littéralement `new` masquerait
> `ArticlesController.new(ctx)`, que le framework utilise pour construire le
> contrôleur. La route `GET /articles/new` y mène toujours&nbsp;; vous renommez
> seulement la méthode. La vue reste `new.html.erb` et `render :new` ne change
> pas.

> [!RULE] Règle Spinel&nbsp;: callbacks
> ### Les callbacks reçoivent le contrôleur explicitement
>
> Il n’y a pas d’`instance_exec` sur un bloc stocké, donc un callback sous forme
> de bloc reçoit le contrôleur (ou l’enregistrement) en argument&nbsp;:
> `before_action { |c| c.do_thing }`, et non `before_action { do_thing }`. Les
> actions et les callbacks sont appelés par leur nom littéral, jamais via
> `send`.

Le scaffold écrit le contrôleur complet, avec aussi `index`, `show`, `edit`,
`update` et `destroy`&nbsp;; l’extrait ci-dessus les omet. Dans `index`,
`@articles = Article.all.to_a`&nbsp;: le `.to_a` est obligatoire.

> [!NOTE]
> Les variables d’instance sont trouvées par un balayage lexical des
> `@ivar =`&nbsp;: relancez donc `cybertrain spin run gen` après en avoir
> ajouté une&nbsp;; le serveur de développement le fait pour vous.

<!-- step 07 #run stage: Compilation, puis exécution · `gen/` &rarr; `build/bin/blog` -->
## Générer, migrer, lancer

> [!WHY]
> Transformer le schéma et les routes en `gen/`, créer la base SQLite,
> démarrer le serveur.

```shell terminal — blog/
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen (gen et db en mode debug)
cybertrain server        # http://127.0.0.1:3000; recompile après une modification Ruby, les vues se rechargent sans recompilation
```

`spin run gen` lit `db/schema.rb` et `config/routes.rb`, analyse `app/` et
écrit `gen/`&nbsp;; `spin run db -- migrate` applique `db/migrate/*.rb` et
réécrit `db/schema.rb`. L’ordre compte&nbsp;: le premier `spin run gen` place
la nouvelle migration dans `gen/migrations.rb`, que requiert `bin/db.rb`, et
le second construit les modèles à partir du `db/schema.rb` réécrit.

`cybertrain server` affiche chaque commande `spin` qu’il lance, puis la
bannière de démarrage de l’application. Le premier démarrage compile
l’application, il prend donc un moment&nbsp;:

```text sortie — cybertrain server
=> Booting cybertrain X.Y.Z
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- Relancez `cybertrain spin run gen` et commitez `gen/` après avoir modifié le
  schéma, les routes, les callbacks et ivars d’un contrôleur ou d’un modèle,
  un helper, un composant ou un job, ou un asset. Le serveur de développement
  le fait pour vous, et `cybertrain spin run gen -- --check` liste ce qui est
  périmé sans rien écrire.
- Changez le port avec `cybertrain server 4000` (ou `PORT=4000`).
- `cybertrain db` ajoute le `--` dont `spin run db` a besoin avant ses
  arguments&nbsp;; `cybertrain db status` et les autres commandes de base de
  données fonctionnent de la même façon.

> [!RULE] Règle Spinel&nbsp;: la console n’est pas du Ruby
> ### La console n’est pas du Ruby
>
> `rails console` n’a pas d’équivalent exact&nbsp;: Spinel n’a pas d’`eval`.
> `cybertrain spin run blog -- console` (`./blog console` une fois compilé)
> évalue des expressions de template sur les modèles, comme
> `Article.where(title: "x").count`, et `dbconsole` ouvre `sqlite3`
> ([La console](background-and-operations.md#the-console)). Les
> modifications Ruby demandent une recompilation, que `cybertrain server` fait
> pour vous en développement (recompilation, arrêt, `execv`). En développement,
> les vues sont analysées depuis le disque à chaque requête, donc en modifier
> une ne demande pas de recompilation&nbsp;; `cybertrain build` les intègre pour
> la production.

<!-- step 08 #scaffold-comment stage: Vous écrivez · `db/migrate/`, `app/` -->
## Scaffold des commentaires

> [!WHY]
> Le type `references` vous donne la clé étrangère dont l’association est
> déduite.

```shell terminal — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # le scaffold a écrit une migration pour la table comments
```

`article:references` ajoute une colonne `article_id`, un index et une clé
étrangère — de quoi donner à `Article`/`Comment` leur association&nbsp;:
`spin run gen` lit `Article#comments` et `Comment#article` dans la clé
étrangère. Le schéma obtenu&nbsp;:

```ruby db/schema.rb (extrait)
  s.create_table "comments" do |t|
    t.string "commenter"
    t.text "body"
    t.integer "article_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"

  s.add_foreign_key "comments", "articles", column: "article_id"
```

Le scaffold insère une ligne `resources :comments` indépendante, que l’étape
suivante remplace.

> [!NOTE]
> Un `cybertrain server` laissé en marche recompile dès que le scaffold écrit
> ses fichiers, avant que la table n’existe, et journalise `Build failed; still
> serving the previous build (see tmp/rebuild.log)`. Il recompile de nouveau
> une fois que `cybertrain db migrate` a réécrit `db/schema.rb`.

> [!EXAMPLE] Supprimer un article qui a des commentaires
> ### Supprimer un article qui a des commentaires
>
> La clé étrangère refuse de supprimer un article qui a encore des
> commentaires. Déclarez l’association, comme dans Rails, et `destroy` les
> supprime d’abord, dans sa transaction&nbsp;:
>
> ```ruby app/models/article.rb (extrait)
>   # each comment's own destroy runs, callbacks included
>   has_many :comments, dependent: :destroy
> ```

<!-- step 09 #nested-routes stage: Vous écrivez · `config/routes.rb` -->
## Imbriquer les routes

> [!WHY]
> Le guide Rails imbrique les commentaires sous les articles.

```ruby config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper explicitly (Spinel's instance_eval
  # trampoline only rewires `self` for the outermost block): `articles.resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
end
```

> [!RULE] Règle Spinel&nbsp;: mapper explicite
> ### Les blocs imbriqués reçoivent le mapper explicitement
>
> Écrivez `resources :articles do |articles|` et `articles.resources :comments`,
> pas un simple `resources :comments`. Le trampoline `instance_eval` de Spinel
> ne redirige `self` que pour le bloc le plus externe.

<!-- step 10 #comments-controller stage: Vous écrivez · `app/controllers/` -->
## Le contrôleur CommentsController

> [!WHY]
> Seules deux actions sont accessibles, et l’article parent vient de l’URL
> (`params[:article_id]`), pas de `:id`.

```ruby app/controllers/comments_controller.rb
class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    if @comment.save
      flash[:notice] = "Comment was successfully created."
    else
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
    end
    redirect_to article_path(@article), status: :see_other
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    @comment.destroy
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:commenter, :body)
  end
end
```

Ajoutez ensuite des validations au modèle de commentaire&nbsp;:

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true

  belongs_to :article
end
```

La déclaration `belongs_to` rend aussi invalide un commentaire sans article
(«&nbsp;Article can't be blank&nbsp;»), avant que la base ne le refuse.

> [!NOTE]
> `Article#comments` est la relation des commentaires&nbsp;: le
> `@article.comments.find(params[:id])` de Rails fonctionne donc tel quel dans
> `destroy`, et un commentaire placé sous le mauvais article renvoie une 404.

<!-- step 11 #views stage: Exécution · `app/views/`, lues depuis le disque en développement, intégrées par `cybertrain build` -->
## Vues et partiels

> [!WHY]
> La page d’un article liste ses commentaires et se termine par un formulaire
> lié à `[@article, @comment]`.

Supprimez d’abord les vues de commentaire `index`, `show`, `new` et `edit`,
désormais inaccessibles, et donnez à `ArticlesController#show` un `@comment`
vide&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
  def show
    @comment = Comment.new
  end
```

Affichez ensuite les commentaires et le formulaire à la fin de la page de
l’article, et remplacez le formulaire de commentaire du scaffold&nbsp;:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<h2>Comments</h2>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>

<h2>Add a comment:</h2>
<%= render "comments/form", comment: @comment %>

<%# app/views/comments/_form.html.erb %>
<%# locals: (comment:) %>
<%= form_with(model: [@article, comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

Le partiel de commentaire&nbsp;:

```erb app/views/comments/_comment.html.erb
<%# locals: (comment:) %>
<div class="comment">
  <p>
    <strong>Commenter:</strong>
    <%= comment.commenter %>
  </p>

  <p>
    <strong>Comment:</strong>
    <%= comment.body %>
  </p>

  <%= button_to "Destroy comment", [@article, comment], method: :delete %>
</div>
```

### Où pointent le formulaire et le bouton

`button_to ... [@article, comment]` et
`form_with(model: [@article, comment])` se résolvent tous deux selon la même
règle `[parent, child]`&nbsp;: un nouvel enfant est routé vers la collection
imbriquée (`article_comments_path`), un enfant persisté vers le membre
imbriqué (`article_comment_path`), tous deux générés dans `gen/routes.rb` à
partir du bloc `resources` imbriqué ci-dessus. Le formulaire reçoit son
commentaire comme variable locale, pour que l’[étape 13](#turbo) puisse le
rendre de nouveau avec un commentaire neuf.

> [!RULE] Les vues forment une grammaire fermée
> ### Les vues forment une grammaire fermée, pas du Ruby
>
> Spinel n’a pas d’`eval`, les templates sont donc interprétés selon une
> grammaire fixe. `link_to` n’a pas d’option `method:`&nbsp;; utilisez
> `button_to`. `each` accepte un ou deux paramètres de bloc. Un commentaire de
> locals stricts comme `<%# locals: (comment:) %>` n’accepte pas de valeurs par
> défaut. Un partiel reçoit une copie de l’environnement de l’appelant, donc
> `@article` est visible dans `comments/_form`.

> [!EXAMPLE] L’index avec le nombre de commentaires et un filtre par date
> ### L’index avec le nombre de commentaires et un filtre par date
>
> examples/blog liste les articles les plus récents d’abord avec leur nombre
> de commentaires, en deux requêtes quel que soit le nombre d’articles, et les
> filtre par date&nbsp;:
>
> ```ruby app/models/article.rb (extrait) · app/controllers/articles_controller.rb (extrait)
>   scope :recent, -> { order(created_at: :desc) }
>
>   def index
>     articles = Article.recent.includes(:comments)
>     from = Cybertrain::Cast.date_or_nil(params[:from])   # nil sauf pour une date YYYY-MM-DD
>     unless from.nil?
>       articles = articles.where_between(:created_at, Time.utc(from.year, from.month, from.day), nil)
>     end
>     @articles = articles.to_a
>   end
> ```
>
> Dans la vue, `article.comments.size` répond à partir des commentaires
> préchargés. Le `where(created_at: from..)` de Rails s’écrit ici
> `where_between`, car Spinel ne construit pas de Range de Time ([Conditions
> et recherches](models.md#conditions-and-finders)).

<!-- step 12 #component stage: Vous écrivez · `app/components/`, `app/helpers/` -->
## Un composant et un helper

> [!WHY]
> À partir de l’étape suivante, un commentaire est rendu à deux
> endroits&nbsp;: sur la page, et dans une diffusion derrière laquelle il n’y
> a aucune requête. Un composant, une classe avec son template à côté, se rend
> de la même façon dans les deux cas&nbsp;; un helper est une méthode que tout
> template peut appeler.

```shell terminal — blog/
cybertrain generate component comment comment   # le nom, puis ses attributs : un seul, appelé lui aussi comment
cybertrain generate helper comments
```

La première écrit `app/components/comment_component.rb`, avec un mot-clé par
attribut, et son template&nbsp;; la seconde écrit un `CommentsHelper` vide.
Chacune écrit aussi un test, sur lequel revient l’[étape 16](#test). La classe
est déjà ce qu’il faut au blog&nbsp;:

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

Remplacez le template généré par le balisage du commentaire, et donnez au
helper son unique méthode&nbsp;:

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # Le nom de l’auteur du commentaire dans un <strong>, échappé : <%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

Rendez ensuite le composant là où la page rendait le partiel, et supprimez
`app/views/comments/_comment.html.erb`&nbsp;:

```erb app/views/articles/show.html.erb (extrait)
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- Le template voit les variables d’instance du composant comme des variables
  locales (`comment`) et ses méthodes publiques sans paramètre par leur nom.
  Il ne reçoit que le commentaire, pas le `@article` de la page&nbsp;: le
  chemin du bouton est donc construit à partir de `comment.article_id`.
- `dom_id(comment)` vaut `comment_7` pour le commentaire d’id 7&nbsp;: c’est
  l’id d’élément que visent les diffusions de l’étape suivante.
- Un composant est désigné comme l’est un partiel, par son nom en snake_case
  sans `_component`&nbsp;: les templates ne peuvent pas nommer de constantes.
- `Cybertrain::Html.tag` échappe son contenu et renvoie une `SafeString`,
  qu’un template affiche telle quelle&nbsp;; une simple `String` renvoyée par
  un helper est échappée.

> [!RULE] Règle Spinel&nbsp;: les helpers et les composants sont du dispatch généré
> ### Les helpers et les composants sont du dispatch généré
>
> Les templates ne peuvent pas appeler `send`&nbsp;: `spin run gen` lit donc
> `app/helpers/` et `app/components/` comme du texte et écrit le dispatch dans
> `gen/helpers.rb` et `gen/components.rb`. Les paramètres d’un helper sont
> nommés (pas de `*rest`, pas de `**opts`), et ses arguments arrivent sous la
> forme des valeurs du template, ce qui explique que `comment_author`
> restreigne son argument avec `case ... when Comment`. Le reste se trouve dans
> [Helpers de l’application](template-language.md#application-helpers) et
> [Composants](template-language.md#components).

<!-- step 13 #turbo stage: Exécution · Turbo Streams sur Server-Sent Events -->
## Des commentaires en direct avec Turbo

> [!WHY]
> Un commentaire posté dans un navigateur doit apparaître sur toutes les pages
> ouvertes de cet article, sans rechargement. Comme dans une application
> Rails&nbsp;8, c’est le rôle de Turbo Streams, et il n’y a rien à installer ni
> à démarrer à côté du serveur.

### Charger Turbo

`cybertrain new` a laissé les deux lignes en commentaire&nbsp;;
décommentez-les&nbsp;:

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

Le `javascript_importmap_tags` du layout écrit l’import map et
`import "application"`&nbsp;: chaque page exécute donc désormais Turbo
([L’import map](assets.md#the-import-map)).

Le côté serveur de Turbo Streams est un sous-système&nbsp;: ajoutez sa ligne
sous celle du cœur dans `bin/blog.rb`, et la même ligne dans `bin/db.rb`.
Sans elle, `spin run gen` s’arrête au `turbo_stream_from` ci-dessous et nomme
la ligne.

```ruby bin/blog.rb (extrait)
require "cybertrain/core"
require "cybertrain/streams"
```

### Abonner la page

Donnez un id à la liste et un autre au formulaire, et abonnez la page au flux
de l’article&nbsp;:

```erb app/views/articles/show.html.erb (extrait)
<h2>Comments</h2>

<%= turbo_stream_from @article %>

<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render component: "comment", comment: comment %>
  <% end %>
</div>

<h2>Add a comment:</h2>

<div id="comment_form">
  <%= render "comments/form", comment: @comment %>
</div>
```

### Diffuser et répondre

`create` diffuse le commentaire enregistré, puis répond au navigateur qui l’a
posté&nbsp;; `destroy` dit aux autres pages de retirer l’élément&nbsp;:

```ruby app/controllers/comments_controller.rb (extrait)
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Chaque page abonnée avec turbo_stream_from @article ajoute le commentaire à la fin de sa liste.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    @new_comment = Comment.new   # le formulaire vide que create.turbo_stream.erb remet en place
    respond_to do |format|
      format.turbo_stream   # app/views/comments/create.turbo_stream.erb
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    target = Cybertrain::Html.dom_id(@comment)   # lu avant que destroy n’efface l’id
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end
```

```erb app/views/comments/create.turbo_stream.erb
<%= turbo_stream.append "comments", html: render(component: "comment", comment: @comment) %>
<%= turbo_stream.update "comment_form", partial: "comments/form", locals: { comment: @new_comment } %>
```

Ouvrez un article dans deux fenêtres et postez un commentaire dans
l’une&nbsp;: il apparaît dans les deux, et le formulaire qui l’a envoyé
revient vide.

### Ce qui se passe

<!-- list: points -->
- `turbo_stream_from @article` écrit un élément `<turbo-stream-source>` pour
  le flux `articles:<id>`, avec un jeton signé. Turbo l’ouvre comme un
  `EventSource` sur `/cybertrain/stream`, que le serveur sert déjà.
- Une diffusion est une ligne dans `cybertrain_messages`, une table que le
  framework crée lui-même. Chaque processus serveur l’interroge et remet la
  ligne aux pages qu’il tient ouvertes, en un dixième de seconde environ.
- Turbo soumet le formulaire en demandant un Turbo Stream&nbsp;:
  `format.turbo_stream` rend donc `create.turbo_stream.erb`, sans layout. Un
  envoi de formulaire ordinaire, JavaScript désactivé, passe par
  `format.html` et est redirigé comme avant.
- La fenêtre qui a posté reçoit le commentaire deux fois, dans la réponse et
  dans la diffusion, et ne l’affiche qu’une fois&nbsp;: Turbo remplace un
  élément qui a le même id.

Pour en savoir plus, notamment sur WebSocket et sur les flux pour votre propre
JavaScript&nbsp;: [Temps réel](realtime.md#turbo-streams).

> [!NOTE]
> Turbo est ici récupéré depuis jsDelivr. Pour le servir vous-même, copiez
> `turbo.es2017-esm.js` dans `vendor/javascript/` et épinglez-le avec
> `to: "turbo.es2017-esm.js"`. Si vous activez la Content Security Policy que
> `config/app.rb` contient en commentaire, son `script_src` doit autoriser
> l’origine qui sert Turbo, quelle qu’elle soit
> ([Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)).

<!-- step 14 #job stage: Vous écrivez · `app/jobs/` -->
## Un job d’arrière-plan

> [!WHY]
> Un travail qui ne doit pas retarder la réponse, une notification par
> exemple, s’exécute après elle. Comme avec Active Job sur Solid Queue, un job
> est une classe dans `app/jobs/` et une ligne dans la base de données de
> l’application elle-même&nbsp;: aucun autre service.

```shell terminal — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

Elle écrit `app/jobs/notify_comment_job.rb`, avec la ligne `retry_on` que
demandait l’option et un `perform` vide, ainsi qu’un test, et ajoute
`require "cybertrain/jobs"` à `bin/blog.rb` et `bin/db.rb`. Complétez
`perform`&nbsp;; celui-ci se contente de journaliser, là où une vraie
application enverrait un e-mail&nbsp;:

```ruby app/jobs/notify_comment_job.rb
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
```

Mettez-le en file depuis `create`, une fois le commentaire enregistré&nbsp;:

```ruby app/controllers/comments_controller.rb (extrait)
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Chaque page abonnée avec turbo_stream_from @article ajoute le commentaire à la fin de sa liste.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

Postez un commentaire&nbsp;: le journal du serveur montre le job qui s’exécute
après la réponse&nbsp;:

```text sortie — cybertrain server
[INFO] Started POST "/articles/1/comments" for 127.0.0.1
[INFO] Completed 200 in 2ms
[INFO] new comment 1 on article 1
[INFO] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` est le Hash donné à `perform_later`, stocké en JSON et relu avec des
  clés String&nbsp;: passez des ids, pas des enregistrements, et restreignez
  les valeurs avec `Cybertrain::Cast`. `perform_in(seconds, args)` et
  `perform_at(time, args)` le mettent en file pour plus tard.
- Les jobs sont des lignes de `cybertrain_jobs`, exécutées par trois threads
  de jobs du processus qui sert, ou d’un processus distinct lancé avec
  `./blog worker`
  ([Rôles des processus](background-and-operations.md#process-roles)).
- `retry_on StandardError, wait: 30, attempts: 3` remet en file une exécution
  qui a échoué 30 secondes plus tard, trois tentatives en tout&nbsp;; la ligne
  est ensuite `failed` et conservée
  ([Nouvelles tentatives et abandons](background-and-operations.md#retries-and-discards)).
- Un job peut s’exécuter plus d’une fois (quand un processus meurt au milieu
  d’un job, celui-ci est exécuté de nouveau)&nbsp;: écrivez donc `perform` de
  sorte qu’il puisse être répété sans risque.
- Les jobs en échec se listent, se réessaient et s’abandonnent avec
  `./blog jobs`, ou sur la page que monte la ligne `jobs_page`, en
  commentaire dans `config/routes.rb`
  ([La page des jobs](background-and-operations.md#the-jobs-page-and-the-jobs-command)).

> [!RULE] Règle Spinel&nbsp;: les politiques des jobs sont lues comme du texte
> ### Les politiques des jobs sont lues comme du texte
>
> `spin run gen` lit chaque classe de `app/jobs/` et écrit son autre moitié
> dans `gen/jobs.rb`&nbsp;: `perform_later`, et chaque `retry_on` sous la forme
> d’une branche `rescue`. `retry_on`, `discard_on` et `limits_concurrency`
> tiennent donc chacun sur une ligne, avec des valeurs littérales&nbsp;:
> `wait: 30`, pas `wait: 30.seconds` ni une lambda.

> [!EXAMPLE] Supprimer chaque nuit les jobs terminés
> ### Supprimer chaque nuit les jobs terminés
>
> Chaque commentaire laisse derrière lui une ligne `done`. `config/app.rb` se
> termine par une tâche planifiée, en commentaire, qui supprime celles qui ont
> une semaine&nbsp;; décommentez-la&nbsp;:
>
> ```ruby config/app.rb (extrait)
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> L’expression cron est lue dans le fuseau `CYBERTRAIN_SCHEDULER_TZ` (UTC par
> défaut), et un seul processus à la fois exécute la planification
> ([Les tâches planifiées](background-and-operations.md#scheduled-tasks)).

<!-- step 15 #json stage: Vous écrivez · `app/controllers/` -->
## Répondre en JSON

> [!WHY]
> Une même action peut servir la page et une API&nbsp;: `respond_to`, comme
> dans Rails.

```ruby app/controllers/articles_controller.rb (extrait)
  def index
    @articles = Article.all.to_a
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:as_json) }
    end
  end

  def show
    @comment = Comment.new
    respond_to do |format|
      format.html
      format.json { render json: @article.as_json }
    end
  end
```

```console terminal — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- Le format vient de l’extension (`/articles.json`) ou, sans extension, de
  l’en-tête `Accept`. Un format que l’action ne liste pas, comme
  `/articles.xml`, reçoit la réponse `406 Not Acceptable`.
- `format.html` sans bloc rend le template de l’action, comme avant.
- `as_json` donne les colonnes de l’enregistrement, les dates et heures en
  ISO 8601, en UTC. JSON n’a pas de templates&nbsp;: une action y répond avec
  `render json:`.
- Limitez le bloc à ses lignes `format.`&nbsp;: quand une requête se replie
  sur html, le bloc s’exécute une seconde fois.

`/articles/1.json` renvoie un seul article, grâce au même bloc dans `show`.
Tout sur les formats&nbsp;:
[Formats et `respond_to`](requests.md#formats-and-respond_to).

<!-- step 16 #test stage: Compilation · `cybertrain spin test` -->
## Tester

> [!WHY]
> minitest et RSpec trouvent les tests par réflexion, ce qu’un compilateur AOT
> ne peut pas faire&nbsp;; CyberTrain fournit donc `Cybertrain::Test`.

### Un test de modèle

```ruby test/articles.rb (fragment)
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Assertions&nbsp;: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. Le client ajoute
`assert_response` et `assert_redirected_to`.

### Un parcours HTTP complet

```ruby test/articles.rb (fragment)
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "POST /articles creates an article and redirects to it" do
  client = Cybertrain::Test::Client.new(BLOG)
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, BlogTest.article_path(Article.last)
  assert_response res, :see_other
end
```

`Cybertrain::Test::Client` pilote une application dans le même processus (sans
socket) avec une cookie jar, de sorte que les sessions et le CSRF se
comportent comme derrière un navigateur. Les requêtes sans le jeton reçoivent
une 403.

### Le job, le Turbo Stream et le composant

Le client de test ne démarre aucun thread de jobs&nbsp;: un job mis en file le
reste donc jusqu’à ce que le test l’exécute. Un troisième argument de `post`
définit des en-têtes de requête, ici l’`Accept` que Turbo envoie avec un
formulaire&nbsp;:

```ruby test/comments.rb (fragment)
require_relative "support/blog_test"   # charge aussi cybertrain/test/jobs

def post_comment(client, article, headers = {})
  client.get(BlogTest.article_path(article))
  client.post("#{BlogTest.article_path(article)}/comments",
              { "authenticity_token" => BlogTest.form_token(client),
                "comment[commenter]" => "Dave", "comment[body]" => "First!" }, headers)
end

test "a comment queues its notification" do
  BlogTest.reset
  post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article)
  assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
  assert_equal 1, perform_enqueued_jobs
  assert_no_enqueued_jobs
end

test "a form Turbo submits is answered with a Turbo Stream" do
  BlogTest.reset
  res = post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article,
                     { "accept" => "text/vnd.turbo-stream.html, text/html" })
  assert_response res, :ok
  assert_includes res.body, "<turbo-stream action=\"append\" target=\"comments\">"
end
```

L’[étape 12](#component) a écrit `test/comment_component.rb`, qui rend le
composant avec une String là où le template attend désormais un commentaire.
Remplacez son contenu&nbsp;:

```ruby test/comment_component.rb
require_relative "support/blog_test"
require "cybertrain/test/views"   # Cybertrain::Test.render_component

test "the comment component names its author" do
  BlogTest.reset
  comment = BlogTest.comment(BlogTest.article, "Alice", "Great post!")
  html = Cybertrain::Test.render_component(CommentComponent.new(comment: comment))
  assert_includes html, "<strong class=\"comment-author\">Alice</strong> wrote:"
end

Cybertrain::Test.run!
```

`render_component` rend comme le fait une diffusion, sans requête. Les autres
helpers, et la façon de lire un flux dans un test&nbsp;:
[Tester les jobs](testing.md#testing-jobs) et
[Tester les flux et les composants](testing.md#testing-streams-and-components).

> [!COMPILE] Ce que les fragments omettent
> ### Ce que les fragments omettent
>
> - `support/blog_test` correspond à
>   [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb)&nbsp;:
>   copiez-le dans le `test/support/` de votre application, où les fichiers sont
>   requis, pas exécutés. Il migre une base `storage/test.sqlite3` neuve,
>   démarre l’application sous le nom `BLOG`, charge `Cybertrain::Test`, son
>   client et les helpers de jobs, et vous fournit `BlogTest.form_token` (le
>   jeton CSRF du dernier formulaire rendu), `BlogTest.article_path`,
>   `BlogTest.article` et `BlogTest.comment` (un enregistrement sauvegardé
>   chacun) et `BlogTest.reset` (tables, cache et file de jobs vidés).
> - Terminez le fichier par `Cybertrain::Test.run!`, qui lance les tests et
>   affiche les lignes que compare le snapshot.
> - Définissez `c.log_level = :none if c.test?` dans `config/app.rb` pour garder
>   les logs de requêtes hors de la sortie comparée.

### Lancer les tests

```shell terminal — blog/
cybertrain spin test
```

`cybertrain spin test` lance `spin test` avec le Spinel épinglé&nbsp;; avec la
chaîne d’outils dans le `PATH` ([étape 00](#requirements)), `spin test` fait
la même chose. Il compile chaque `test/*.rb` en un programme distinct et
compare (diff) sa sortie (stdout et stderr ensemble) à un snapshot
`test/<name>.rb.expected` versionné. Les fichiers de `test/support/` sont
requis, pas exécutés. Les tests que les générateurs ont écrits aux étapes 12
et 14 (`test/comments_helper.rb`, `test/notify_comment_job.rb`) s’exécutent
avec les autres. Pour écrire un snapshot&nbsp;:

```shell terminal — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` écrit le snapshot à partir de la sortie de CRuby. Les tests qui
> accèdent à SQLite via FFI ne peuvent pas tourner sous CRuby&nbsp;: leur
> snapshot vient donc du binaire compilé (la deuxième ligne ci-dessus).
> `cybertrain spin test` sort avec un code non nul tant qu’un snapshot est
> périmé, il est donc suivi de `;` et non de `&&`&nbsp;; la vérification
> `[ -x ]` saute la capture si la compilation a échoué, ce qui conserve
> l’ancien snapshot. Les tests qui ne peuvent pas tourner sous CRuby ont
> besoin de ce snapshot avant que `cybertrain spin test` puisse réussir&nbsp;;
> les autres tests sans snapshot sont comparés à la sortie de CRuby.

<!-- step 17 #authentication stage: Vous écrivez · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Ajouter la connexion

> [!WHY]
> Jusqu’ici, n’importe qui peut modifier ou supprimer un article. Comme
> `bin/rails generate authentication` dans Rails 8, une seule commande ajoute
> la connexion par adresse e-mail et mot de passe, écrite comme du code qui
> appartient à l’application plutôt qu’installée comme un moteur.

```shell terminal — blog/
cybertrain generate authentication
cybertrain db migrate    # crée les tables users et sessions
```

Il écrit les migrations et les modèles `users` et `sessions`, le concern `Authentication`, qu’il inclut dans `ApplicationController`, les contrôleurs et les vues de la connexion, de l’inscription, de la réinitialisation du mot de passe et de la page de compte, un mailer, la commande `./blog user`, et des tests. Il ajoute aussi les routes, un partial `sessions/_nav` en haut du layout, et un réglage `base_url` dans `config/app.rb`, par lequel commencent les liens des courriels. Il ajoute enfin à `bin/blog.rb` et `bin/db.rb` les lignes des sous-systèmes que son code utilise : `cybertrain/jobs` (la page des jobs et le thread qui envoie les courriels), `cybertrain/mailer`, `cybertrain/mailer/later` (les courriels partent avec `deliver_later`) et `cybertrain/rate_limit` (les tentatives de connexion sont limitées, plus bas). Chaque fichier est listé dans [Authentification](authentication.md#generating-it).

```ruby app/controllers/concerns/authentication.rb (extrait)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
```

Désormais, chaque action exige un utilisateur connecté, et un visiteur est
redirigé vers `/session/new`. Rouvrez les pages que tout le monde peut lire,
comme le fait le guide de Rails&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

`resume_session` s’exécute toujours sur ces pages, donc les templates peuvent
lire `@current_user`. Masquez ce qu’un visiteur ne peut pas utiliser&nbsp;:

```erb app/views/articles/show.html.erb (extrait)
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>

  <div id="comment_form">
    <%= render "comments/form", comment: @comment %>
  </div>
<% end %>
```

Le composant de commentaire garde son bouton «&nbsp;Destroy comment&nbsp;»
pour tout le monde&nbsp;: une diffusion le rend une seule fois pour tous ceux
qui regardent la page, sans requête et donc sans utilisateur courant. Un
visiteur qui clique dessus est envoyé vers la page de connexion, puisque
`CommentsController` n’ouvre aucune action&nbsp;; les nouveaux commentaires
atteignent tout de même la page d’un visiteur, car le flux n’est pas une
action d’un contrôleur.

Démarrez le serveur et ouvrez `http://127.0.0.1:3000/sign_up` pour créer le premier utilisateur. Le générateur de Rails n’a pas de page d’inscription et laisse cela à la console&nbsp;; CyberTrain écrit `RegistrationsController`, si bien que le premier utilisateur s’inscrit dans le navigateur. Pour une application sur invitation, lancez plutôt le générateur avec `--invite-only`&nbsp;: il n’y a pas de page d’inscription, et le premier utilisateur vient de `./blog user EMAIL` ou d’une page `/setup` que seule la machine du serveur peut ouvrir ([Inscription, ou sur invitation](authentication.md#sign-up-or-invite-only)).

La page de connexion renvoie aussi vers une réinitialisation du mot de passe par courriel, et la navigation vers une page de compte&nbsp;; le guide [Authentification](authentication.md) les décrit, avec le verrouillage, «&nbsp;rester connecté&nbsp;», `--confirmable` et les administrateurs. Un courriel de réinitialisation a besoin des réglages SMTP et, en production, de `BLOG_BASE_URL` ([Liens dans les courriels](authentication.md#links-in-mails)).

> [!RULE] Règle Spinel&nbsp;: has_secure_password
> ### `has_secure_password` est écrit en toutes lettres
>
> Spinel ne peut pas définir de méthodes à l’exécution, donc le modèle `User`
> écrit lui-même ce que `has_secure_password` définirait&nbsp;: `password=`,
> `authenticate` et `User.authenticate_by(email_address:, password:)`. Les mots
> de passe sont hachés par `Cybertrain::Password`, du PBKDF2-HMAC-SHA256 en
> Ruby, 100&nbsp;000 itérations par défaut (environ 0,2&nbsp;s une fois
> compilé)&nbsp;: bcrypt demanderait que le binaire lie une bibliothèque C.
> Augmentez le coût avec `Cybertrain::Password.iterations = 600_000` dans
> `config/app.rb`&nbsp;; `User#authenticate` refait le hachage de chaque
> utilisateur à sa connexion.

### Mettre à jour les tests

Tout test de l’[étape 16](#test) qui attend un formulaire, en soumet un ou
atteint une action autre que `index` et `show` tombe désormais sur la page de
connexion. Connectez d’abord le client avec les helpers que le générateur a
écrits dans `test/support/app_test.rb`&nbsp;:

```ruby test/signed_in.rb
require_relative "support/app_test"   # written by generate authentication: APP, AppTest

test "a signed-in user creates an article" do
  client = Cybertrain::Test::Client.new(APP)
  AppTest.user("ann@example.com", "s3cr3t-s3cr3t")
  AppTest.sign_in(client, "ann@example.com", "s3cr3t-s3cr3t")
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => AppTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, "/articles/#{Article.last.id}"
end
```

> [!NOTE]
> Lancez `cybertrain spin test` comme à l’[étape 16](#test)&nbsp;; `test/authentication.rb`, les autres tests qu’écrit le générateur et celui-ci utilisent SQLite, leurs instantanés viennent donc des binaires compilés. Les tentatives de connexion sont limitées comme dans le générateur de Rails&nbsp;: dix par adresse cliente toutes les trois minutes, comptées dans la base de données de l’application, si bien que tous les processus comptent ensemble&nbsp;; derrière un reverse proxy, configurez les [proxys de confiance](requests.md#rate-limiting-and-the-client-address). `examples/blog` fait cette étape avec `--invite-only` et réserve ses pages `/admin` aux administrateurs.

<!-- step 18 #attachments stage: Vous écrivez · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Ajouter une image de couverture

> [!WHY]
> Un article peut porter une image. Même partage des rôles que pour la
> connexion&nbsp;: le framework analyse `multipart/form-data` et stocke les
> octets, et une seule commande écrit le reste comme du code qui appartient à
> l’application, à la place du `has_one_attached` d’Active Storage.

L’image sera affichée sur la page de l’article, que les visiteurs peuvent lire
depuis l’étape 17&nbsp;: son téléchargement doit donc leur être ouvert aussi.
Avant de lancer le générateur, ajoutez `:cover` à la liste écrite à
l’étape 17&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell terminal — blog/
cybertrain generate attachment article cover   # pour un nouveau modèle : generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # ajoute les colonnes cover_* à articles
```

Elle écrit une migration qui ajoute cinq colonnes à `articles` (`cover_key`,
`cover_filename`, `cover_content_type`, `cover_byte_size`,
`cover_checksum`&nbsp;; le fichier lui-même n’est pas dans SQLite) et un bloc
dans `Article` avec `cover_file=`, `cover_attached?`, `cover_url`, une
validation et des callbacks de sauvegarde et de suppression. Dans
`ArticlesController`, elle ajoute une action `cover` derrière
`before_action :set_article` et une ligne dans `create` et dans
`update`&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 17 wrote [:index, :show]; you added :cover
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show (and authentication applies).
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end
  # ...
  def create
    @article = Article.new(article_params)
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
  # ...
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.update(article_params)
```

Le téléchargement trouve son article par `set_article`, comme `show`&nbsp;:
tout ce que `set_article` fait pour limiter les articles qu’un utilisateur
peut voir limite donc aussi le téléchargement. Parmi les lignes qu’il affiche,
le générateur émet un avertissement, parce que ce `show` a du code qui lui est
propre&nbsp;:

```text sortie — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

Ici, ce code construit un commentaire et choisit un format&nbsp;; il ne refuse
personne, il n’y a donc rien à recopier dans `cover`.

Le générateur ajoute aussi `get "/articles/:id/cover"` à `config/routes.rb`,
`multipart: true` et un champ de fichier au formulaire, au-dessus du bouton
d’envoi, et l’image à la page d’affichage, juste après le `<h1>`&nbsp;:

```erb app/views/articles/_form.html.erb (extrait)
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb (extrait)
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!NOTE]
> Le générateur copie les règles d’accès de `show` sur le téléchargement, mais
> seulement celles qu’il peut lire&nbsp;: les callbacks. Un `before_action`
> autre que `set_article` qui liste `:show` sans la nouvelle action l’arrête
> avec `cannot preserve show's authorization for :cover`, et rien n’est écrit.
> Le code placé dans `def show`, il ne peut pas lire ce qu’il vérifie, d’où
> l’avertissement. Avec un `show` vide, il ajoute de lui-même `:cover` à
> `allow_unauthenticated_access` là où `:show` figure&nbsp;; avec du code dans
> `show`, il ne touche pas à cette ligne, et sans `:cover` à cet endroit
> l’image exige une connexion.

> [!RULE] Règle Spinel&nbsp;: has_one_attached
> ### `has_one_attached` est écrit en toutes lettres
>
> Spinel ne peut pas définir de méthodes à l’exécution (pas de `define_method`),
> donc il n’y a ni `has_one_attached` ni table d’attachements partagée. Le
> générateur écrit en toutes lettres ce qu’il définirait, sous forme de méthodes
> nommées d’après le champ, dans `Article`, et place les métadonnées dans cinq
> colonnes de `articles`. Elles sont `NOT NULL`, avec `""` et `0` pour dire
> «&nbsp;rien d’attaché&nbsp;»&nbsp;: des colonnes nullables coûteraient à
> Spinel son inférence de types. SQLite ne contient que les métadonnées (une
> valeur texte s’arrête à un octet NUL)&nbsp;; les octets sont des fichiers.

### Comment les fichiers sont servis

<!-- list: points -->
- **Types.** Par défaut, seuls PNG, JPEG, GIF et WebP jusqu’à 2&nbsp;Mo sont
  acceptés (`COVER_TYPES` et `COVER_MAX_BYTES` dans le modèle&nbsp;; `--any`
  accepte tous les types). Le type est détecté d’après les premiers octets du
  fichier, jamais repris du navigateur.
- **Stockage.** Les octets vont dans `storage/uploads/<2 hex>/<32 hex key>`
  (`Cybertrain::BlobStore`, mode 0600). Remplacer un fichier supprime
  l’ancien, et supprimer l’article supprime son fichier. Sauvegardez
  `storage/uploads/` avec le fichier SQLite.
- **Service.** Les fichiers sortent par `send_blob` dans le contrôleur, jamais
  depuis `public/`. Les quatre types d’image sont servis en ligne&nbsp;; tout
  le reste est un téléchargement (`application/octet-stream`). Chaque réponse
  porte `X-Content-Type-Options: nosniff` et
  `Content-Security-Policy: default-src 'none'; sandbox`.
- **Paramètres.** `params.nested(:article).upload(:cover)` est un
  `Cybertrain::UploadedFile`, ou nil si aucun fichier n’a été choisi. `permit`
  ne renvoie jamais de fichiers, donc un fichier ne peut arriver que par cette
  ligne explicite. Le jeton CSRF est lu dans les corps multipart comme dans
  ceux de n’importe quel formulaire. Un corps cassé ou trop gros donne une
  400&nbsp;; `max_upload_bytes` et `max_multipart_parts` dans `config/app.rb`
  fixent les limites, et `upload_root` le répertoire.

Lancez le serveur, modifiez un article et choisissez une image. Le générateur
a aussi écrit `test/attachment_article_cover.rb`, qui teste tout le parcours
et se connecte d’abord, puisque l’application a maintenant un `User`. Comme
`:cover` est public ici, il vérifie qu’un visiteur peut télécharger l’image,
et il remplit le corps avec `"A article."`, allongé jusqu’au minimum de
10&nbsp;caractères de l’[étape 05](#validations).

> [!NOTE]
> Lancez `cybertrain spin test` comme à l’[étape 16](#test)&nbsp;; le test
> utilise SQLite, donc son instantané vient du binaire compilé.
> `examples/blog` comporte aussi cette étape, et son JSON n’inclut pas les
> colonnes `cover_*` (`Article#public_json`). Pas encore pris en charge&nbsp;:
> plusieurs fichiers par champ, S3 ou un autre stockage distant, les variantes
> d’image, et l’envoi de gros corps en flux vers le disque (le corps entier
> est lu en mémoire, jusqu’à `max_body_bytes`).

<!-- step 19 #ship stage: Exécution · `dist/blog` -->
## Compiler pour le déploiement

> [!WHY]
> Une seule commande compile l’application dans un dossier `dist/` déployable,
> avec toutes les vues intégrées.

```shell terminal — blog/
cybertrain build
```

Elle écrit `dist/`&nbsp;: le binaire de l’application avec toutes les vues
intégrées, plus les fichiers qu’il utilise, à côté de lui. Elle lance
`SPIN_DEBUG=1 spin run gen -- --embed-views`, `spin build blog` et
`SPIN_DEBUG=1 spin run gen` (qui
remet en place le `gen/views.rb` versionné et vide, même après un échec ou un
Ctrl-C), puis assemble&nbsp;:

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>le framework compilé, les contrôleurs, les modèles et l’interpréteur de templates, avec toutes les vues intégrées</span></li>
  <li><code>dist/public/</code><span>ressources statiques et pages d’erreur, ou laissez un reverse proxy le servir</span></li>
  <li><code>dist/storage/</code><span>créé vide&nbsp;; contient le fichier SQLite par défaut (une recompilation ne le vide jamais)</span></li>
  <li><code>dist/tmp/</code><span>créé vide (une recompilation ne le vide jamais)</span></li>
</ul>

Copiez `dist/` sur une machine avec le même OS et le même CPU (le binaire est
lié à la SQLite du système) et lancez-le là-bas. Un binaire compilé est en
mode production par défaut (`CYBERTRAIN_ENV` permet de le changer). Définissez
`CYBERTRAIN_SECRET_KEY_BASE` (`cybertrain secret` en affiche un aussi)&nbsp;;
à titre d’illustration&nbsp;:

```shell terminal — hôte de production
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` applique les migrations compilées dans le binaire, et
`./blog db status` affiche leur état&nbsp;; `PORT` définit le port. Gardez le
même secret d’un redémarrage à l’autre&nbsp;: le changer met fin à toutes les
sessions. `./blog help` liste les autres commandes du binaire, parmi
lesquelles `worker`, `jobs`, `console` et `db backup`.

`Cybertrain::Config` lit d’abord l’environnement&nbsp;; `config/app.rb` a le
dernier mot. Les variables que rencontre un premier déploiement (la liste
complète&nbsp;:
[Configuration](configuration.md#configuration-and-environment-variables))&nbsp;:

<div class="table-scroll" role="region" aria-label="Variables d’environnement" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">Variable</th><th scope="col">Attribut</th><th scope="col">Par défaut</th></tr></thead>
  <tbody>
    <tr><td data-label="Variable"><code>CYBERTRAIN_ENV</code></td><td data-label="Attribut"><code>env</code></td><td data-label="Par défaut"><code>"development"</code>&nbsp;; <code>"production"</code> dans un binaire issu de <code>cybertrain build</code> (aussi <code>"test"</code>)</td></tr>
    <tr><td data-label="Variable"><code>PORT</code></td><td data-label="Attribut"><code>port</code></td><td data-label="Par défaut"><code>3000</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_DATABASE</code></td><td data-label="Attribut"><code>database_path</code></td><td data-label="Par défaut"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="Attribut"><code>secret_key_base</code></td><td data-label="Par défaut">requis en production&nbsp;; en dev/test, un secret est généré automatiquement dans <code>tmp/secret_key</code></td></tr>
    <tr><td data-label="Variable"><code>SPINEL_WORKERS</code></td><td data-label="Attribut"><code>workers</code></td><td data-label="Par défaut"><code>1</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_HOST</code></td><td data-label="Attribut"><code>host</code></td><td data-label="Par défaut"><code>"127.0.0.1"</code>&nbsp;; <code>0.0.0.0</code> écoute sur toutes les interfaces (conteneurs)</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="Attribut"><code>session_same_site</code></td><td data-label="Par défaut"><code>"Lax"</code>&nbsp;; aussi <code>Strict</code> ou <code>None</code> (<code>None</code> ajoute toujours <code>Secure</code>)&nbsp;; toute autre valeur arrête le serveur au démarrage</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="Attribut"><code>session_partitioned</code></td><td data-label="Par défaut"><code>false</code>&nbsp;; <code>1</code> ou <code>true</code> ajoute <code>Partitioned</code> (et <code>Secure</code>)</td></tr>
  </tbody>
</table>
</div>

```ruby config/app.rb
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

<!-- list: points -->
- Le serveur parle du HTTP/1.1 simple&nbsp;: placez nginx ou Caddy devant pour
  le TLS et HTTP/2. Le cookie de session est `Secure` en production, servez
  donc l’application en HTTPS (ne définissez `c.session_secure = false` dans
  `config/app.rb` que si la production est vraiment en http simple). Derrière
  un tel proxy, `CYBERTRAIN_FORCE_SSL=1` redirige http vers https et
  `CYBERTRAIN_HOSTS` nomme les hôtes auxquels l’application répond
  ([hôtes et `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)).
- Le processus qui sert exécute aussi les jobs, les tâches planifiées et le
  poller des flux des étapes 13 et 14&nbsp;: un seul processus constitue un
  déploiement complet. `./blog worker` déplace les jobs dans un processus à
  part ([Rôles des processus](background-and-operations.md#process-roles)).
- En production, l’application refuse de démarrer sans
  `CYBERTRAIN_SECRET_KEY_BASE`.
- En production, une exception renvoie une 500, et une réponse d’erreur brute
  (la 404 en texte brut du routeur, `head :not_found`, `render plain:`) est
  remplacée par `public/<status>.html` quand ce fichier existe&nbsp;;
  `cybertrain new` écrit `404.html` et `500.html`.
- `SIGTERM` cesse d’accepter des connexions, laisse se terminer les requêtes
  en cours et quitte quand elles sont terminées, ou après le `drain_timeout`
  du serveur (10&nbsp;s).
- La surveillance des fichiers et la boucle de recompilation ne tournent
  jamais en production. Un `cybertrain server` en cours d’exécution saute ses
  recompilations tant que `cybertrain build` détient
  `tmp/cybertrain-build.lock`.

`cybertrain new` écrit aussi une configuration
[Kamal 2](https://kamal-deploy.org). Le `Dockerfile` exécute
`cybertrain setup` et `cybertrain build` dans une étape de build Ubuntu et
copie `dist/` dans une étape allégée de la même version, qui applique les
migrations au démarrage puis écoute sur `0.0.0.0:3000`. À côté se trouvent
`.dockerignore`, `config/deploy.yml` (kamal-proxy avec Let&rsquo;s Encrypt en
façade, le contrôle de santé sur `public/up.html`, le fichier SQLite sur un
volume monté en `/app/storage`) et `.kamal/secrets`, qui lit
`KAMAL_REGISTRY_PASSWORD` et `CYBERTRAIN_SECRET_KEY_BASE` dans
l’environnement. Renseignez les valeurs marquées `CHANGE ME` dans
`config/deploy.yml`, committez, puis&nbsp;:

```shell terminal — blog/
kamal setup    # la première fois : installe Docker et kamal-proxy sur le serveur, construit, pousse et démarre
kamal deploy   # chaque déploiement suivant
```

Le binaire est compilé dans l’image, son OS correspond donc toujours à celui
de l’image&nbsp;; réglez `builder.arch` dans `config/deploy.yml` sur le CPU du
serveur. Déployez sur un seul serveur&nbsp;: la base de données est un fichier
SQLite sur le volume de ce serveur. La partie 8 de
[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) (en
japonais&nbsp;; version anglaise&nbsp;:
[`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)) détaille la procédure,
sauvegardes comprises.

L’application terminée,
[`examples/blog`](../../examples/blog#deploying-with-kamal), embarque cette
configuration avec une différence&nbsp;: elle se construit avec le framework
du dépôt (`path = "../.."` dans son `spin.toml`), donc son `Dockerfile`
exécute `cybertrain setup` et `cybertrain build` depuis le dépôt au lieu
d’installer la gem, et le contexte de build est la racine du dépôt
(`builder.context: ../..`, `Dockerfile.dockerignore` n’envoyant que le
framework et l’application). La CI
([`blog-image.yml`](../../.github/workflows/blog-image.yml)) construit cette
image à chaque version publiée, vérifie le contrôle de santé, la création d’un
article via le formulaire, l’arrêt propre et la base conservée sur son volume,
et charge `config/deploy.yml` avec Kamal.

> [!NOTE]
> Comment ces pièces s’assemblent, et Kamal comparé à un serveur derrière
> Caddy, sont expliqués sur la [page Déployer](site:deploy.html).

<!-- step + #things-to-know -->
## Bon à savoir

> [!WHY]
> Des limites et particularités à connaître avant qu’elles ne vous
> surprennent.

<!-- list: points know -->
- Les sessions ne contiennent que des String, dans un cookie chiffré.
- SQLite uniquement, via la FFI de Spinel.
- Pas de backtraces&nbsp;: les erreurs affichent la classe, le message, la
  ligne de requête et le nom/la ligne du template.
- Un attribut mal orthographié dans une vue lève une erreur
  (`undefined method 'titel' for Article`)&nbsp;; une colonne qui contient
  `nil` s’affiche vide.
- Les associations viennent des clés étrangères ou de déclarations d’une
  ligne&nbsp;; pas de `has_many :through`, d’`includes` imbriqué, d’enums, de
  STI ni d’associations polymorphes.
- Pas de `constraints` ni de `mount`&nbsp;; on répond en JSON avec
  `render json:` (il n’y a pas de templates JSON).
- Dans un modèle généré par scaffold, seul le premier champ string reçoit une
  validation de présence par défaut.
- Le générateur utilise un balayage lexical (des regex), pas un parseur, sur
  `app/controllers`, `app/models`, `app/helpers`, `app/components` et
  `app/jobs`.
- Les jobs s’exécutent au moins une fois, et une diffusion n’atteint que les
  pages ouvertes au moment de son envoi, ou qui se reconnectent dans la
  minute.
- Les vues sont intégrées à la compilation&nbsp;: une modification qui ne
  touche que les vues nécessite `cybertrain build` et un redémarrage avant
  d’atteindre la production.
- Compilez `dist/` sur le même OS et le même CPU que la machine qui
  l’exécute&nbsp;: le binaire est lié à la SQLite du système.
- `SPINEL_WORKERS` vaut `1` par défaut.
- Seule la version épinglée de Spinel (`Cybertrain::SPINEL_TAG`) est testée.
- D’autres différences avec Rails, dans un seul tableau&nbsp;: [Différences avec Rails](how-it-works.md#differences-from-rails).

<!-- step → #where-next -->
## Pour aller plus loin

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — L’application à laquelle mène ce tutoriel, avec ses tests.
- [**Authentification**](authentication.md) — Réinitialisation du mot de passe, confirmation, verrouillage, rester connecté, page de compte et administrateurs.
- [**Internationalisation**](i18n.md) — Dictionnaires, `t` et `l`, et une locale par requête.
- [**Guides**](index.md) — Une page par sujet&nbsp;: modèles, requêtes, templates, temps réel, tâches de fond, tests.
- [**CyberTrain sur GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Le code source, le README et les versions publiées.
- [**Référence de l’API**](site:api/index.html) — Chaque classe et méthode qu’utilise une application, avec des exemples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Les spikes et les contraintes du compilateur qu’ils ont révélées.
- [**Spinel**](https://github.com/matz/spinel) — Le compilateur Ruby AOT de matz.
- [**Accueil CyberTrain**](site:index.html) — Présentation, fonctionnalités et fonctionnement.
