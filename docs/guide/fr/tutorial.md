---
source_sha256: 6089daf50cee57c1a9721c18dbb9a850c8b9b6fdc50d6498999b523a0bb023a4
path: tutorial.html
title: "Premiers pas&nbsp;: le blog"
description: "Construisez le blog du guide Getting Started de Rails, des articles avec commentaires, avec CyberTrain&nbsp;: installez, générez un scaffold, validez, migrez, imbriquez les commentaires sous les articles et testez l’application avec cybertrain test."
og_title: "Premiers pas avec CyberTrain&nbsp;: le blog"
og_description: "Calqué sur le Getting Started de Rails&nbsp;: un blog avec des articles et des commentaires, construit avec CyberTrain sur Spinel."
og_image: tutorial.png
crumb: Tutoriel
nav: tutorial
toc_title: "Étapes 00–12"
meta:
  - term: "Prérequis"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, en-têtes SQLite 3, zlib et OpenSSL (Spinel est installé pour vous) <a class="meta-link" href="#requirements">Étape 00</a>'
  - term: "Point de départ"
    text: "`gem install cybertrain`"
  - term: "Résultat"
    text: "Un blog avec des articles, des commentaires et des tests"
---

# Premiers pas&nbsp;: le&nbsp;blog

Calqué sur le guide
[Getting Started](https://guides.rubyonrails.org/getting_started.html) de
Rails&nbsp;: un blog avec des articles et des commentaires. Vous allez installer
la CLI, générer le scaffold des articles, ajouter des validations, imbriquer
les commentaires sous les articles et lancer les tests, pour finir avec un
blog qui fonctionne sur votre machine. Le
[tutoriel avancé](advanced-tutorial.md) pousse ensuite le même blog plus
loin&nbsp;: commentaires en direct avec Turbo, job d’arrière-plan, JSON,
connexion, image envoyée et build déployable.


<!-- step 00 #requirements stage: Installation · Ruby, `cc`, SQLite -->
## Prérequis

> [!WHY]
> CyberTrain compile via Spinel vers du C&nbsp;: il lui faut donc une chaîne
> de compilation C et les en-têtes SQLite&nbsp;; la commande `cybertrain` est
> une gem, il lui faut donc Ruby.

<!-- list: checklist -->
- Ruby 3.2+ et RubyGems, pour la commande `cybertrain` et pour l’aperçu
  CRuby du serveur de développement (qui demande `fiddle`, la bibliothèque
  de Ruby)&nbsp;; une application déployée ne tourne jamais sur CRuby. Avec
  Ruby 3.2, ajoutez aussi `gem install prism`.
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

La première ligne l’installe depuis RubyGems. Le reste est tout le parcours
en un coup d’œil&nbsp;: les étapes ci-dessous le reprennent une commande à la
fois jusqu’à `cybertrain server`, et le
[tutoriel avancé](advanced-tutorial.md#ship) se termine par
`cybertrain build`.

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
qui raccourcit chaque build. Les étapes du tutoriel avancé qui en utilisent un
ajoutent sa ligne ([Sous-systèmes](how-it-works.md#subsystems)).

Le layout lie `app/assets/stylesheets/application.css` avec
`stylesheet_link_tag` et charge `app/javascript/application.js` via l’import
map de `config/importmap.rb` avec `javascript_importmap_tags`&nbsp;; `spin run
gen` écrit les deux avec une empreinte dans `public/assets/`, ignoré par git
(voir [Assets](assets.md)). `.env.example` liste les variables que lit
l’application, `.github/workflows/ci.yml` lance les tests sur GitHub
([Intégration continue](testing.md#continuous-integration)), et la dernière
ligne de l’arborescence est la configuration Kamal de
l’[étape 19](advanced-tutorial.md#ship).

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

Elle écrit une migration, un modèle, un contrôleur, cinq vues (`index`,
`show`, `new`, `edit`, `_form`), un fichier de fixtures et des tests
([étape 12](#test)), et insère `resources :articles` dans
`config/routes.rb`. Les types de champ sont `string`, `text`, `integer`,
`float`, `boolean`, `date`, `datetime`, `references` et `attachment` (un
fichier envoyé, [étape 18](advanced-tutorial.md#attachments))&nbsp;; le type par défaut est
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
  # jobs_page "/admin/jobs", before_action: :require_admin
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

  def new_action   # the `new` action: the generated routes call new_action
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

> [!RULE] new_action
> ### `new_action`, pas `new`
>
> L’action `new` s’écrit `new_action`&nbsp;: les routes générées l’appellent
> sous ce nom. Le renommage date du moment où il était consigné que Spinel ne
> compilait pas une méthode d’instance nommée `new` à côté de
> `ArticlesController.new(ctx)`&nbsp;; des programmes réduits de cette forme
> compilent avec la version épinglée, et le nom reste l’API. La route `GET /articles/new` y mène toujours&nbsp;; vous renommez
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
cybertrain server        # http://127.0.0.1:3000; une modification Ruby s’affiche tout de suite (CRuby), puis compilée; les vues n’ont besoin ni de l’un ni de l’autre
```

`spin run gen` lit `db/schema.rb` et `config/routes.rb`, analyse `app/` et
écrit `gen/`&nbsp;; `spin run db -- migrate` applique `db/migrate/*.rb` et
réécrit `db/schema.rb`. L’ordre compte&nbsp;: le premier `spin run gen` place
la nouvelle migration dans `gen/migrations.rb`, que requiert `bin/db.rb`, et
le second construit les modèles à partir du `db/schema.rb` réécrit.

`cybertrain server` sert l’application depuis CRuby en moins d’une seconde
et la compile avec Spinel en arrière-plan. La première compilation compile
toute l’application, ce qui prend quelques minutes&nbsp;; d’ici là, c’est
l’aperçu CRuby qui répond, et chaque page le dit dans son coin inférieur
droit&nbsp;:

```text sortie — cybertrain server
=> Booting cybertrain X.Y.Z
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> preview: CRuby (0.5s)
```

Une fois la compilation terminée, le serveur affiche `=> spinel: ready in …s; serving
the compiled binary`, et le binaire compilé répond à partir de là. Après une
modification Ruby, il affiche `Changed` et le fichier, répond de nouveau tout
de suite depuis CRuby et recompile ([La boucle de développement](how-it-works.md#the-development-loop)).
Ctrl-C l’arrête.

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
> modifications Ruby demandent une recompilation&nbsp;: en développement,
> `cybertrain server` y répond tout de suite par un aperçu CRuby et passe le
> port au binaire compilé quand sa compilation se termine. En développement,
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
> Un `cybertrain server` laissé en marche prend en compte les fichiers du
> scaffold dès qu’ils sont écrits, avant que la table n’existe. Le nouveau
> modèle `Comment` tient ses colonnes de `gen/models/comment.rb`, que gen
> n’écrit qu’une fois la table présente dans `db/schema.rb`&nbsp;: l’aperçu
> CRuby ne peut donc pas le charger (une `NoMethodError`), le serveur répond
> par sa propre page 503 qui nomme l’erreur, et la compilation Spinel échoue
> aussi. Une fois que `cybertrain db migrate` a réécrit `db/schema.rb`, le
> serveur répond de nouveau.

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

  # A nested block takes the mapper as its argument: `articles.resources`,
  # not Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] Mapper explicite
> ### Les blocs imbriqués reçoivent le mapper explicitement
>
> Écrivez `resources :articles do |articles|` et `articles.resources :comments`,
> pas un simple `resources :comments`. Cette forme a été introduite quand il
> était consigné que Spinel ne compilait pas un appel sans receveur dans un
> bloc imbriqué dans `instance_eval`&nbsp;; un programme réduit de cette forme
> compile avec la version épinglée, et le mapper explicite reste la forme
> documentée, celle qu’écrivent les générateurs et les tests.

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

Le scaffold a écrit le modèle de commentaire avec `belongs_to :article` et un
contrôle de présence sur `commenter`, son premier champ de type chaîne&nbsp;;
ajoutez-en un pour le corps&nbsp;:

```ruby app/models/comment.rb
class Comment
  belongs_to :article
  validates :commenter, presence: true
  validates :body, presence: true
end
```

Le `belongs_to` que le scaffold a déclaré rend aussi invalide un commentaire sans article
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
commentaire comme variable locale, pour que l’[étape 14](advanced-tutorial.md#turbo) puisse le
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

<!-- step 12 #test stage: Compilation · `cybertrain test` -->
## Tester

> [!WHY]
> minitest et RSpec trouvent les tests par réflexion, ce qu’un compilateur
> anticipé ne peut pas faire. Les tests sont tout de même les classes de
> Rails&nbsp;: `spin run gen` les réécrit en un seul programme, que
> `cybertrain test` compile et exécute.

### Ce que les générateurs ont écrit

Les scaffolds des étapes 03 et 08 ont écrit les tests de scaffold de
Rails&nbsp;: `test/fixtures/articles.yml` et `comments.yml` (les lignes `one` et
`two` par lesquelles commence chaque test), `test/models/article_test.rb`
et `comment_test.rb` (« the fixture is valid »), et
`test/controllers/articles_controller_test.rb` et
`comments_controller_test.rb` (une requête par action), et `cybertrain new` a
écrit `test/test_helper.rb`, que chaque fichier charge, et
`test/integration/health_test.rb`, une requête vers `/up`. Trois d’entre eux
doivent suivre le blog tel qu’il a grandi depuis&nbsp;: la fixture des articles
et les deux tests de contrôleur.

### Des fixtures qui passent les validations

Les valeurs d’exemple du scaffold (`MyString`, `MyText`) échouent aux
vérifications de l’[étape 05](#validations)&nbsp;: deux articles avec un même
titre, et des corps de moins de dix caractères. Donnez aux articles de
vraies valeurs&nbsp;:

```yaml test/fixtures/articles.yml
one:
  title: Hello Rails
  body: I am on Rails! This is my first article.

two:
  title: Second article
  body: Another article, with no comments.
```

Le test de création envoie le titre de la fixture elle-même, désormais
pris&nbsp;; donnez-lui-en un nouveau&nbsp;:

```ruby test/controllers/articles_controller_test.rb (extrait)
  test "should create article" do
    assert_difference(-> { Article.count }, 1) do
      post articles_url, params: { article: { body: @article.body, title: "A new title" } }
    end

    assert_redirected_to article_url(Article.last)
  end
```

Les lignes de `comments.yml` appartiennent à `article: one`. Comme dans
Rails, une fixture qui pointe vers un article empêche de supprimer cet
article&nbsp;: « should destroy article » échoue donc sur la clé étrangère sauf
si `Article` déclare `has_many :comments, dependent: :destroy` (l’encadré
à la fin de l’[étape 08](#scaffold-comment)). Ajoutez-le à
`app/models/article.rb` si ce n’est pas fait, comme examples/blog&nbsp;:

```ruby app/models/article.rb (extrait)
  has_many :comments, dependent: :destroy
```

### Les commentaires sous leur article

Le test des commentaires du scaffold demande les routes que
l’[étape 09](#nested-routes) a imbriquées sous les articles, dont les
helpers sont désormais `article_comments_path` et `article_comment_path`.
Remplacez-le&nbsp;:

```ruby test/controllers/comments_controller_test.rb
require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  test "a comment is added to its article" do
    article = articles(:one)
    assert_difference(-> { Comment.count }, 1) do
      post article_comments_path(article), params: { comment: { commenter: "Dave", body: "First!" } }
    end
    assert_redirected_to article_path(article)
  end

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

La protection contre la falsification de requêtes est désactivée dans les
tests, comme dans Rails, si bien qu’un `post` n’a pas besoin de jeton. Les
autres assertions sont dans [Tester une application](testing.md#assertions).

### Lancer les tests

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

La première exécution compile tous les tests en un seul programme, ce qui
prend des minutes (les tests d’examples/blog, 149 lors de la mesure du 2026-11-13, en ont pris
environ neuf sur une machine cloud à 4 vCPU)&nbsp;; une exécution sans changement ne recompile pas le programme de
test&nbsp;: elle peut reconstruire gen une fois (`build gen`, quelques
secondes), puis démarre en bien moins d’une seconde. Un fichier ou `-n` choisit quels tests s’exécutent, pas ce qui est
compilé&nbsp;: modifier n’importe quel test recompile le programme. Chaque
fichier affiche un titre, chaque test une ligne (`ok`, ou `FAIL` et `ERR`
avec la ligne du test et le message), puis les totaux, avec entre eux ce que le code testé affiche lui-même (la
ligne de sortie d’une commande, par exemple)&nbsp;; le code de sortie vaut 1
quand un test a échoué. À cette étape, le blog compte douze tests.

> [!NOTE]
> Avant chaque test, toutes les tables sont vidées et les fixtures
> insérées de nouveau, si bien que les tests ne dépendent pas les uns des
> autres. `gen/tests.rb` et `gen/test/` sont générés&nbsp;: validez-les avec le
> reste de `gen/`.

<!-- step → #where-next -->
## Pour aller plus loin

Vous avez un blog avec des articles et des commentaires, validé et testé,
servi par `cybertrain server`. Le tutoriel avancé reprend à partir d’ici, avec
la même application.

<!-- list: next-list -->
- [**Tutoriel avancé**](advanced-tutorial.md) — Étapes 13–19&nbsp;: un composant et un helper, des commentaires en direct avec Turbo, un job d’arrière-plan, JSON, la connexion, une image de couverture et un build pour le déploiement.
- [**Bon à savoir**](advanced-tutorial.md#things-to-know) — Les limites et les particularités à connaître avant qu’elles ne vous surprennent.
- [**`examples/blog`**](../../examples/blog) — L’application à laquelle mènent les deux tutoriels, avec ses tests.
- [**Guides**](index.md) — Une page par sujet&nbsp;: modèles, requêtes, templates, temps réel, tâches de fond, tests.
- [**Modèles et base de données**](models.md) — Migrations, requêtes, associations et tous les validateurs.
- [**Tests**](testing.md) — Les fixtures, les assertions et `cybertrain test` en détail.
- [**Référence de l’API**](site:api/index.html) — Chaque classe et méthode qu’utilise une application, avec des exemples.
- [**CyberTrain sur GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Le code source, le README et les versions publiées.
- [**Accueil CyberTrain**](site:index.html) — Présentation, fonctionnalités et fonctionnement.
