---
source_sha256: 7fc302298fd20959b22acd10653c103b8a8b01a96b97fbe159edbf336958e282
path: tutorial.html
title: "Premiers pas&nbsp;: le blog"
description: "Construisez le blog du guide Getting Started de Rails, des articles avec commentaires, avec CyberTrain&nbsp;: générez un scaffold, migrez, imbriquez les routes, testez avec Cybertrain::Test et compilez pour le déploiement avec cybertrain build."
og_title: "Premiers pas avec CyberTrain&nbsp;: le blog"
og_description: "Calqué sur le Getting Started de Rails&nbsp;: un blog avec des articles et des commentaires, construit avec CyberTrain sur Spinel."
og_image: tutorial.png
crumb: Tutoriel
nav: tutorial
toc_title: "Étapes 00–15"
meta:
  - term: "Prérequis"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, en-têtes SQLite 3 (Spinel `2026.10.27.7020` est installé pour vous) <a class="meta-link" href="#requirements">Étape 00</a>'
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
sous les articles, écrire un test qui pilote l’application dans le même
processus, ajouter la connexion, joindre une image envoyée, et compiler
l’application dans un dossier `dist/` déployable. L’application terminée est
[`examples/blog`](../../examples/blog), testée par la CI sous Linux et macOS.


<!-- step 00 #requirements stage: Installation · Ruby, `cc`, SQLite -->
## Prérequis

> [!WHY]
> CyberTrain compile via Spinel vers du C&nbsp;: il lui faut donc une chaîne
> de compilation C et les en-têtes SQLite&nbsp;; la commande `cybertrain` est
> une gem, il lui faut donc Ruby.

<!-- list: checklist -->
- Ruby 3.2+ et RubyGems, uniquement pour la commande `cybertrain`&nbsp;; les
  applications ne tournent jamais sur CRuby. La compilation de Spinel demande
  aussi la gem `prism` de Ruby&nbsp;: Ruby 3.3 et plus récent
  l’incluent&nbsp;; avec Ruby 3.2, lancez `gem install prism` (avec les
  en-têtes de développement de Ruby, `ruby-dev` sous Debian/Ubuntu).
  `cybertrain doctor` le vérifie.
- Spinel `2026.10.27.7020`, une version du fork
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel), qui
  intègre les corrections dont CyberTrain a besoin avant une version
  amont&nbsp;; non testé avec d’autres versions. Vous ne l’installez pas à la
  main&nbsp;: la première commande qui en a besoin compile cette version dans
  `~/.cybertrain` (quelques minutes, une seule fois), sauf si un `spinel` de
  cette version est déjà dans le `PATH`.
- Une chaîne de compilation C (`cc`, ou le compilateur désigné par `CC`) et
  `make`, plus `git` et `curl`, pour compiler Spinel, qui compile chaque
  programme en C.
- En-têtes et bibliothèques SQLite 3 et zlib&nbsp;: `libsqlite3-dev` et
  `zlib1g-dev` sous Debian/Ubuntu&nbsp;; fournis avec les Command Line Tools
  de Xcode sous macOS.
- Les en-têtes OpenSSL (`libssl-dev`) sont facultatifs&nbsp;: sans eux, Spinel
  est compilé sans son paquet `openssl`, que CyberTrain n’utilise pas.

`cybertrain doctor` vérifie ces outils et en-têtes ainsi que l’installation de
Spinel&nbsp;; quand un élément requis manque, il affiche aussi la commande
d’installation pour votre plateforme.

<details><summary>Comment CyberTrain installe Spinel — Ce qui se passe la première fois qu’une commande a besoin de `spin`</summary>

`cybertrain new`, `db`, `server`, `build` et `spin` cherchent d’abord Spinel
`2026.10.27.7020`&nbsp;: un `spinel` et un `spin` de cette version déjà dans
le `PATH`, sinon la copie sous `~/.cybertrain/spinel/2026.10.27.7020/`, sinon
ils compilent cette copie à partir du tag de version de Spinel (`git clone`,
`make deps`, `make -j`, `make install`), une seule fois, en quelques minutes.
Le journal est `~/.cybertrain/log/spinel-2026.10.27.7020-build.log`&nbsp;;
s’il manque un outil nécessaire à la compilation, `cybertrain` indique lequel
et affiche la commande d’installation pour votre plateforme avant de
commencer.

`cybertrain setup` fait la même chose à la demande (`--force` recompile la
copie sous `~/.cybertrain`) et, quand c’est sa propre copie qui est utilisée,
affiche la ligne qui la place dans votre `PATH`, pour lancer `spin`
vous-même&nbsp;:

```shell terminal — n’importe quel répertoire
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` contient des liens `spinel` et `spin` vers la version
utilisée. S’il n’est pas dans le `PATH`, `cybertrain spin ARGS...` lance
`spin` avec cette version depuis n’importe quel répertoire. `CYBERTRAIN_HOME`
remplace `~/.cybertrain`, et `CYBERTRAIN_SPINEL_HOME=PREFIX` utilise à la
place le Spinel installé dans `PREFIX` (ce doit être cette version). Un
`spinel` d’une autre version présent dans le `PATH` n’est jamais utilisé ni
modifié.

</details>

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
<span class="ln cmd">cybertrain new blog          <span class="c"># installe Spinel 2026.10.27.7020 la première fois (quelques minutes)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># production: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

La commande `cybertrain` est en Ruby pur et la gem l’exécute sous CRuby (3.2
ou plus récent)&nbsp;; ni le framework ni Spinel ne sont dans la gem. Ses
commandes (`cybertrain help` les affiche)&nbsp;:

<!-- list: points -->
- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]`
  crée une application dans NAME, puis y lance `spin lock` et `spin run gen`,
  en installant d’abord Spinel si nécessaire.
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`)
  ajoute une ressource à l’application du répertoire courant.
- `cybertrain generate authentication` ajoute la connexion par adresse e-mail
  et mot de passe à l’application du répertoire courant
  ([étape 13](#authentication)).
- `cybertrain generate attachment MODEL FIELD [--any]` ajoute l’envoi d’un
  fichier à un modèle généré par scaffold dans l’application du répertoire
  courant ([étape 14](#attachments)).
- `cybertrain db migrate` génère, applique les migrations en attente, puis
  génère à nouveau
  (`spin run gen; spin run db -- migrate; spin run gen`)&nbsp;;
  `cybertrain migration` est conservé comme alias.
- `cybertrain db COMMAND...` lance toute autre commande de base de données
  après `spin run gen`&nbsp;: `status`, `rollback [N]` (qui génère à nouveau
  ensuite), `schema:dump`, `create`.
- `cybertrain server [PORT]` génère, puis démarre le serveur de développement
  (`spin run gen; spin run NAME`, ou `spin run NAME -- PORT`&nbsp;; port 3000
  par défaut).
- `cybertrain build` compile NAME avec `app/views/` intégré et assemble
  `dist/` (le binaire, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` lance `spin` avec le Spinel épinglé, depuis
  n’importe quel répertoire&nbsp;: `cybertrain spin test`,
  `cybertrain spin run gen -- --check`.
- `cybertrain setup [--force]` installe Spinel `2026.10.27.7020` dans
  `~/.cybertrain`, sauf si un `spinel` de cette version est déjà dans le
  `PATH`&nbsp;; `--force` recompile la copie sous `~/.cybertrain`.
- `cybertrain doctor` vérifie la chaîne de compilation C, les en-têtes SQLite
  et l’installation de Spinel.
- `cybertrain version` affiche la version (`cybertrain 0.3.1`)&nbsp;;
  `cybertrain help` affiche l’aide.

> [!NOTE]
> `db`, `server` et `build` s’exécutent dans une application&nbsp;; NAME est
> le `[package] name` de son `spin.toml`.

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
version correspondant à la CLI&nbsp;:

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

Ensuite, il s’assure que Spinel est installé (la première fois, cela signifie
compiler Spinel `2026.10.27.7020` dans `~/.cybertrain`&nbsp;: quelques
minutes, une seule fois&nbsp;; voir l’[étape 00](#requirements)) et lance
`spin lock` (spin récupère le framework dans son cache,
`~/.cache/spin/packages/`, et épingle le commit dans `spin.lock`) et
`spin run gen`, un peu comme `rails new` lance `bundle install`, pour que
`cybertrain server` fonctionne tout de suite. Il termine en affichant les
étapes suivantes. Rien du framework n’est copié dans l’application&nbsp;;
commitez `spin.toml` et `spin.lock`.

> [!NOTE]
> Si Spinel ou l’une des deux étapes `spin` échoue, les fichiers restent en
> place, `new` sort avec le code 1 et affiche ce qu’il faut lancer une fois la
> cause corrigée (pour Spinel&nbsp;: `cybertrain setup`, puis
> `cybertrain spin lock && cybertrain spin run gen` dans le nouveau
> répertoire). `--skip-spin` se contente d’écrire les fichiers&nbsp;;
> `--path DIR` fait plutôt dépendre l’application d’une copie locale du dépôt,
> `--git URL [--ref R]` du framework situé à URL (à la branche ou au tag R),
> et `--version V` d’une version de l’index, une fois que `cybertrain` sera
> sur un `spin-index`.

Les noms d’application utilisent des lettres minuscules, des chiffres et `_`,
et commencent par une lettre. L’arborescence générée&nbsp;:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` est l’unique point d’entrée de l’application, le programme que
compile `spin build blog`&nbsp;: `./blog` sert l’application, `./blog migrate`
et `./blog db status` gèrent la base de données. `bin/gen.rb` lance le
générateur (`spin run gen`), et `bin/db.rb` lance le migrateur pendant le
développement (`cybertrain db migrate` l’utilise, car `bin/blog.rb` ne peut
pas compiler tant que la première migration n’a pas généré `gen/models/`).
`gen/` contient déjà `views.rb`, la table des vues intégrées, versionnée et
vide.

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
`float`, `boolean`, `date`, `datetime` et `references`&nbsp;; le type par
défaut est `string`. Le `cybertrain g scaffold` du démarrage rapide est la
même commande.

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
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` n’a pas de superclasse écrite&nbsp;: la superclasse
`Cybertrain::Model`, les colonnes et les finders viennent de
`gen/models/article.rb`. Un enregistrement qui échoue signale des messages
tels que «&nbsp;Title can't be blank&nbsp;» et «&nbsp;Body is too short
(minimum is 10 characters)&nbsp;».

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
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
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
=> Booting cybertrain 0.3.1
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- Relancez `cybertrain spin run gen` et commitez `gen/` après avoir modifié le
  schéma, les routes, ou les callbacks et ivars d’un contrôleur ou d’un
  modèle. Le serveur de développement le fait pour vous.
- Changez le port avec `cybertrain server 4000` (ou `PORT=4000`).
- `cybertrain db` ajoute le `--` dont `spin run db` a besoin avant ses
  arguments&nbsp;; `cybertrain db status` et les autres commandes de base de
  données fonctionnent de la même façon.

> [!RULE] Règle Spinel&nbsp;: pas de console
> ### Il n’y a pas de console
>
> `rails console` n’a pas d’équivalent&nbsp;: Spinel n’a pas d’`eval`. Les
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
étrangère — de quoi donner à `Article`/`Comment` leur association&nbsp;; il
n’y a pas de `has_many`/`belongs_to` à écrire, `spin run gen` la lit dans la
clé étrangère. Le schéma obtenu&nbsp;:

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

> [!EXAMPLE] Supprimer un article qui a des commentaires
> ### Supprimer un article qui a des commentaires
>
> Les associations viennent uniquement des clés étrangères, et `dependent:`
> n’est pas implémenté. L’exemple ajoute un callback `before_destroy` qui reçoit
> l’enregistrement explicitement&nbsp;:
>
> ```ruby app/models/article.rb (extrait)
>   # Rails' `has_many :comments, dependent: :destroy`: the foreign key
>   # would refuse to delete an article that still has comments.
>   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
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
    @comment = Comment.where(article_id: @article.id).find(params[:id])
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
end
```

> [!NOTE]
> `Article#comments` est ici un Array&nbsp;: le
> `@article.comments.find(params[:id])` de Rails devient donc
> `Comment.where(article_id: @article.id).find(params[:id])`. Un commentaire
> placé sous le mauvais article renvoie une 404.

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

Affichez ensuite les commentaires et le formulaire sur la page de
l’article&nbsp;:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>
<%= render "comments/form" %>

<%# app/views/comments/_form.html.erb %>
<%= form_with(model: [@article, @comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

Le partiel de commentaire, tel qu’il est livré dans l’exemple&nbsp;:

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

`button_to ... [@article, comment]` et
`form_with(model: [@article, @comment])` se résolvent tous deux selon la même
règle `[parent, child]`&nbsp;: un nouvel enfant est routé vers la collection
imbriquée (`article_comments_path`), un enfant persisté vers le membre
imbriqué (`article_comment_path`) — générés dans `gen/routes.rb` à partir du
bloc `resources` imbriqué ci-dessus.

> [!RULE] Les vues forment une grammaire fermée
> ### Les vues forment une grammaire fermée, pas du Ruby
>
> Spinel n’a pas d’`eval`, les templates sont donc interprétés selon une
> grammaire fixe. `link_to` n’a pas d’option `method:`&nbsp;; utilisez
> `button_to`. `each` accepte un ou deux paramètres de bloc. Un commentaire de
> locals stricts comme `<%# locals: (comment:) %>` n’accepte pas de valeurs par
> défaut. Un partiel reçoit une copie de l’environnement de l’appelant, donc
> `@article` est visible dans `comments/_form`.

<!-- step 12 #test stage: Compilation · `cybertrain spin test` -->
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
`assert_includes`, `assert_raises("Class") { }`, `flunk`. L’exemple utilise
aussi `assert_response` et `assert_redirected_to`.

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

> [!COMPILE] Ce que les fragments omettent
> ### Ce que les fragments omettent
>
> - `support/blog_test` correspond à
>   [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb)&nbsp;:
>   copiez-le dans le `test/support/` de votre application, où les fichiers sont
>   requis, pas exécutés. Il migre une base `storage/test.sqlite3` neuve,
>   démarre l’application sous le nom `BLOG`, charge `Cybertrain::Test` et son
>   client, et vous fournit `BlogTest.form_token` (le jeton CSRF du dernier
>   formulaire rendu) et `BlogTest.article_path`.
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
requis, pas exécutés. Pour écrire un snapshot&nbsp;:

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

<!-- step 13 #authentication stage: Vous écrivez · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
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

Elle écrit les migrations de `users` (`email_address`, `password_digest`, un
index unique) et de `sessions` (une ligne par navigateur connecté), les
modèles `User` et `Session`, `SessionsController` (`/session/new`,
`POST /session`, `DELETE /session`) et `RegistrationsController` (`/sign_up`)
avec leurs vues, un partiel `sessions/_nav` rendu en haut du layout, ainsi que
`test/authentication.rb` et `test/support/app_test.rb`. Elle insère aussi les
routes, et un bloc juste après la ligne de classe
d’`ApplicationController`&nbsp;:

```ruby app/controllers/application_controller.rb (extrait)
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
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
  <%= render "comments/form" %>
<% end %>
```

Lancez le serveur et ouvrez `http://127.0.0.1:3000/sign_up` pour créer le
premier utilisateur. Le générateur de Rails n’a pas de page d’inscription et
laisse cela à la console&nbsp;; CyberTrain n’a pas de console, il écrit donc
`RegistrationsController`. Supprimez-le, avec ses routes, pour une application
sur invitation.

<details><summary>Une application sur invitation&nbsp;: `--invite-only` — Pas de page d’inscription&nbsp;; le premier utilisateur vient de la ligne de commande ou d’une page que seule la machine du serveur peut ouvrir</summary>

La page d’inscription permet à quiconque atteint le serveur de s’inscrire, ce
qui est le mauvais comportement par défaut pour un outil interne&nbsp;: celui
qui arrive avant l’administrateur a un compte. `--invite-only` n’écrit ni
`RegistrationsController` ni lien d’inscription&nbsp;; le premier utilisateur
vient de la ligne de commande ou d’une page que seule la machine du serveur
elle-même peut ouvrir, avec un lien que le serveur affiche à son
démarrage&nbsp;:

```shell terminal — blog/
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # puis ouvrez, sur la même machine, le lien http://127.0.0.1:3000/setup?token=... qu’il affiche
```

En production, depuis le répertoire où tourne le binaire&nbsp;:

```shell terminal — hôte de production
./blog user ann@example.com                        # lit le mot de passe sur stdin (une ligne)
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user ann@example.com 's3cr3t-s3cr3t'        # ou en argument (visible dans ps)
```

<!-- list: points -->
- `app/commands/user_command.rb` enregistre la commande `user` avec
  `Cybertrain::Main.command` (donc `./blog help` la liste) et est requis
  depuis `bin/blog.rb`. `EMAIL [PASSWORD]` crée l’utilisateur, ou définit le
  mot de passe de celui qui a cette adresse (ce qui déconnecte les navigateurs
  de cet utilisateur, comme tout changement de mot de passe)&nbsp;; elle
  affiche `created ADDRESS` ou `updated ADDRESS` et sort avec 0. Sans
  `PASSWORD`, elle lit une ligne de l’entrée standard (avec une invite quand
  c’est un terminal&nbsp;; la saisie s’affiche) et retire le saut de ligne
  final, de sorte que le mot de passe reste hors de `ps` et de l’historique du
  shell. Un mot de passe vide, un enregistrement qui ne passe pas la
  validation (un mot de passe de moins de 8 caractères) ou de mauvais
  arguments affichent une erreur ou la ligne d’usage et sortent avec 1.
- `SetupController` (`GET`/`POST /setup`, `app/views/setup/new.html.erb`) crée
  le premier utilisateur et le connecte. Il ne répond que tant qu’aucun
  utilisateur n’existe, qu’avec le jeton à usage unique (ci-dessous), et qu’à
  une connexion dont le pair de la socket est l’adresse de bouclage
  (`request.loopback?`&nbsp;: `127.0.0.0/8` ou `::1`) et qui ne porte pas
  d’en-tête `X-Forwarded-For` (un proxy sur le même hôte fait de chaque
  requête une requête de bouclage, et il ajoute cet en-tête). Un en-tête peut
  fermer la page, jamais l’ouvrir. Tous les autres, ainsi qu’un jeton absent
  ou faux, reçoivent un 404.
- Le jeton&nbsp;: `SetupController::SETUP_TOKEN`, 32 caractères hexadécimaux
  aléatoires (`Cybertrain::Crypto.random_token(16)`) créés au démarrage du
  programme et gardés jusqu’à sa sortie, donc un redémarrage en crée un
  nouveau. `GET /setup` le reçoit en `?token=`, le formulaire le renvoie dans
  un champ caché, et les deux le comparent en temps constant
  (`Cybertrain::Crypto.secure_compare`). C’est lui qui garde la page fermée
  quand la vérification d’adresse n’y suffit pas&nbsp;: un proxy sur le même
  hôte qui n’ajoute pas `X-Forwarded-For` (nginx sans
  `proxy_set_header X-Forwarded-For ...`) fait passer chaque client pour du
  bouclage, et seul quelqu’un qui peut lire le journal du serveur a le jeton.
  Le journal des requêtes ne le répète pas&nbsp;: `token` fait partie des
  `filter_parameters` par défaut, donc la ligne s’écrit `Started GET
  "/setup?token=[FILTERED]"` (sauf si `config.filter_parameters` ou
  `CYBERTRAIN_FILTER_PARAMETERS` laisse `token` de côté). Le jeton n’ouvre
  plus rien une fois l’utilisateur créé.
- Pour un premier lancement derrière un proxy situé sur un autre hôte,
  `BLOG_SETUP_OPEN=1` (déclaré dans `config/app.rb` avec
  `c.setting_bool :setup_open`) lève la vérification d’adresse, toujours
  seulement tant qu’aucun utilisateur n’existe et toujours seulement avec le
  jeton. Retirez-le une fois l’utilisateur créé.
- Tant qu’aucun utilisateur n’existe, le serveur journalise
  `[WARN] no user exists yet: run ./blog user EMAIL, or open /setup?token=<token> from this machine`
  avant de démarrer (`UserCommand.warn_if_no_user`, appelé depuis
  `bin/blog.rb` quand `Cybertrain::Main.server?(ARGV)`&nbsp;; il se connecte
  pour cette seule question et ne dit rien tant que la table users n’est pas
  migrée). Cette ligne est le seul endroit où le jeton est affiché.

Le `test/authentication.rb` généré couvre les deux&nbsp;: `/setup` avec et
sans le jeton (`SetupController.setup_token`) ou avec un mauvais, depuis une
autre adresse (`client.peer_address = "203.0.113.7"`), à travers un proxy, une
fois qu’un utilisateur existe et avec l’interrupteur activé, ainsi que la
commande `user` lancée dans le même processus via `Cybertrain::Main.run`. Tout
cela est du code applicatif, à vous de le modifier (docs/design.md D29)&nbsp;;
le framework ne fournit que `request.loopback?`, `Main.command`,
`Main.server?`, `Crypto.random_token` / `Crypto.secure_compare` et le
`peer_address` du client de test.

</details>

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

<details><summary>Authentification&nbsp;: ce que fournit le framework — Les pièces dont le générateur est fait, utilisables sans lui</summary>

Le générateur ci-dessus écrit le parcours&nbsp;; les pièces dont il est fait
sont de l’API du framework, utilisables sans lui (pour un jeton d’API, un mot
de passe d’administration, une connexion écrite à la main)&nbsp;:

<!-- list: points -->
- **`Cybertrain::Password`**&nbsp;: `hash(plain)` produit un condensat
  PBKDF2-HMAC-SHA256 salé qui enregistre ses propres paramètres
  (`$pbkdf2-sha256$i=100000$salt$key`), `verify?(plain, digest)` en vérifie un
  en temps constant et ne lève jamais d’exception sur un condensat mal formé,
  et `needs_rehash?(digest)` dit quand un condensat est en retard sur le
  `Password.iterations` actuel. Pour une action de connexion&nbsp;:
  - `verify_serialized(plain, digest)` est `verify?` un à la fois par
    processus (un Mutex). Un hachage prend environ 0,2&nbsp;s de CPU&nbsp;;
    une rafale de tentatives en parallèle occuperait tous les workers, alors
    qu’avec cette méthode elles font la queue et les autres workers continuent
    de servir les pages.
  - `dummy_digest` est le condensat d’un mot de passe aléatoire, créé une fois
    par processus au coût actuel. Vérifiez par rapport à lui quand l’adresse
    est inconnue, pour que le temps de réponse ne révèle pas quelles adresses
    ont un compte&nbsp;:
    `Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)`.
  - `session_key(digest)` est un HMAC du condensat du mot de passe sous
    `secret_key_base`&nbsp;; gardez-le dans la session à la connexion et
    vérifiez-le avec
    `session_key_matches?(session[:password_key], user.password_digest)` à
    chaque requête. Un changement de mot de passe crée un nouveau condensat,
    donc toute session commencée avant lui est déconnectée.
  - `iterations` vaut `Password::TEST_ITERATIONS` (1&nbsp;000) quand
    `Cybertrain.config.test?`, pour que les suites de tests ne paient pas le
    coût de production par utilisateur&nbsp;; les condensats enregistrent leur
    nombre d’itérations, donc rien d’autre ne change.
- **La session** (`session[:key]`, un cookie signé)&nbsp;: `clear` la vide
  (jeton CSRF compris) à la déconnexion, et `config.session_absolute_max_age`
  (deux semaines&nbsp;; `0` la désactive) borne la vie entière d’une session,
  quelle que soit la fréquence de son usage&nbsp;: le cookie enregistre quand
  il a été écrit pour la première fois, un cookie plus ancien que cela se
  charge comme une session vide, donc un cookie copié ne peut pas être rejoué
  indéfiniment. `session.restart_lifetime!` relance le décompte (à la
  connexion).
- **`Controller#local_path?(text)` et
  `safe_redirect_path(text, fallback)`**&nbsp;: un chemin venu de la requête
  (un paramètre `return_to`, une page mémorisée) n’est la cible d’une
  redirection que s’il commence par `/` mais pas par `//` ni `/\`, ne contient
  que de l’ASCII imprimable et fait au plus 2&nbsp;048 octets&nbsp;:
  `redirect_to safe_redirect_path(params[:return_to], "/"), status: :see_other`.
- **`skip_before_action(name, only:, except:)`** sur une classe de contrôleur
  retire un `before_action` hérité pour certaines actions&nbsp;; le
  `allow_unauthenticated_access` généré n’en est qu’une enveloppe d’une ligne.
- **`cybertrain generate authentication`** écrit, comme du code qui appartient
  à l’application&nbsp;: les migrations et modèles `users` et `sessions`,
  `SessionsController`, `RegistrationsController`, leurs vues et le partiel de
  navigation, le bloc d’`ApplicationController` (`resume_session`,
  `require_authentication`, `start_new_session_for`, `terminate_session`,
  `after_authentication_url`) et `test/authentication.rb`. Ce code utilise
  tout ce que contient cette liste&nbsp;: `User.authenticate_by` vérifie avec
  `verify_serialized` et le condensat factice, `start_new_session_for`
  enregistre la clé du mot de passe et relance la durée de vie,
  `resume_session` met fin à une ligne Session dont la clé ne correspond plus
  ou qui est plus ancienne que `session_absolute_max_age`, et
  `after_authentication_url` est `safe_redirect_path`. Pour garder connecté le
  navigateur qui a changé un mot de passe, enregistrez la nouvelle clé après
  la sauvegarde&nbsp;:
  `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`.
  La conception&nbsp;: [docs/design.md](../design.md) D25.

</details>

### Mettre à jour les tests

Tout test de l’[étape 12](#test) qui attend un formulaire, en soumet un ou
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
> Lancez `cybertrain spin test` comme à l’[étape 12](#test)&nbsp;;
> `test/authentication.rb` et ce test utilisent SQLite, donc leurs instantanés
> viennent du binaire compilé. `examples/blog` s’arrête avant cette étape. Les
> tentatives de connexion sont soumises à une limitation de débit, comme dans
> le générateur de Rails&nbsp;: `SessionsController` déclare `rate_limit to:
> 10, within: 3 * 60, only: [:create]`, dix tentatives par adresse du client
> toutes les trois minutes, puis retour au formulaire avec "Try again later."
> jusqu’à la fin de la fenêtre. Non générée&nbsp;: la réinitialisation du mot
> de passe (CyberTrain n’a pas de mailers).

<!-- step 14 #attachments stage: Vous écrivez · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Ajouter une image de couverture

> [!WHY]
> Un article peut porter une image. Même partage des rôles que pour la
> connexion&nbsp;: le framework analyse `multipart/form-data` et stocke les
> octets, et une seule commande écrit le reste comme du code qui appartient à
> l’application, à la place du `has_one_attached` d’Active Storage.

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
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 13 wrote [:index, :show]; the generator added :cover
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

L’étape 13 a rendu toutes les pages privées, et l’image d’une page d’article
publique est récupérée depuis `/articles/1/cover`. Le générateur rend le
téléchargement exactement aussi public que la page de l’article&nbsp;: puisque
`allow_unauthenticated_access` contient `:show`, il ajoute `:cover` à cette
liste, comme dans la première ligne ci-dessus, et les visiteurs qui peuvent
lire l’article voient son image. Si la page de l’article demande une
connexion, le téléchargement aussi. Tout ce que `set_article` fait pour
limiter les articles qu’un utilisateur peut voir limite aussi le
téléchargement.

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
> Lancez `cybertrain spin test` comme à l’[étape 12](#test)&nbsp;; le test
> utilise SQLite, donc son instantané vient du binaire compilé.
> `examples/blog` s’arrête avant cette étape. Pas encore pris en charge&nbsp;:
> plusieurs fichiers par champ, S3 ou un autre stockage distant, les variantes
> d’image, et l’envoi de gros corps en flux vers le disque (le corps entier
> est lu en mémoire, jusqu’à `max_body_bytes`).

<!-- step 15 #ship stage: Exécution · `dist/blog` -->
## Compiler pour le déploiement

> [!WHY]
> Une seule commande compile l’application dans un dossier `dist/` déployable,
> avec toutes les vues intégrées.

```shell terminal — blog/
cybertrain build
```

Elle écrit `dist/`&nbsp;: le binaire de l’application avec toutes les vues
intégrées, plus les fichiers qu’il utilise, à côté de lui. Elle lance
`spin run gen -- --embed-views`, `spin build blog` et `spin run gen` (qui
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
`CYBERTRAIN_SECRET_KEY_BASE`&nbsp;; à titre d’illustration&nbsp;:

```shell terminal — hôte de production
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` applique les migrations compilées dans le binaire, et
`./blog db status` affiche leur état&nbsp;; `PORT` définit le port. Gardez le
même secret d’un redémarrage à l’autre&nbsp;: le changer met fin à toutes les
sessions.

`Cybertrain::Config` lit d’abord l’environnement&nbsp;; `config/app.rb` a le
dernier mot&nbsp;:

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
  `config/app.rb` que si la production est vraiment en http simple).
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
image à chaque modification, vérifie le contrôle de santé, la création d’un
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
- Les sessions ne contiennent que des String, dans un cookie signé HMAC.
- SQLite uniquement, via la FFI de Spinel.
- Pas de backtraces&nbsp;: les erreurs affichent la classe, le message, la
  ligne de requête et le nom/la ligne du template.
- Un attribut mal orthographié dans une vue s’affiche vide au lieu de lever
  une erreur&nbsp;; c’est une lacune connue.
- Les associations viennent uniquement des clés étrangères du schéma&nbsp;;
  pas de `has_many :through`, `includes`, `pluck`, `dependent:`, d’enums, de
  STI ni d’associations polymorphes.
- Pas de `namespace`, de `respond_to`/formats, de `constraints` ni de
  `mount`&nbsp;; `render json:` est minimal.
- Dans un modèle généré par scaffold, seul le premier champ string reçoit une
  validation de présence par défaut.
- Le générateur utilise un balayage lexical (des regex), pas un parseur, sur
  `app/controllers` et `app/models`.
- Les vues sont intégrées à la compilation&nbsp;: une modification qui ne
  touche que les vues nécessite `cybertrain build` et un redémarrage avant
  d’atteindre la production.
- Compilez `dist/` sur le même OS et le même CPU que la machine qui
  l’exécute&nbsp;: le binaire est lié à la SQLite du système.
- `SPINEL_WORKERS` vaut `1` par défaut.
- Seul Spinel `2026.10.27.7020` est testé.

<!-- step + #differences -->
## Différences avec Rails

> [!WHY]
> Le tableau complet du README, en un seul endroit.

<!-- table: cmp -->
| Rails | CyberTrain |
|---|---|
| `rails console` | Pas de console — Spinel n’a pas d’`eval` |
| Modifiez le code, l’application en cours d’exécution le prend en compte | Le Ruby demande une recompilation&nbsp;; en développement, `cybertrain server` s’en charge pour vous (recompilation, arrêt, `execv`) |
| Modifiez une vue, aucun rechargement nécessaire | Pareil — en développement, les vues sont analysées depuis le disque à chaque requête |
| `def new` | `def new_action` (`new` masquerait `Klass.new(ctx)`) |
| `before_action { do_thing }` (`self` implicite) | `before_action { |c| c.do_thing }` — pas d’`instance_exec` sur un bloc stocké, donc les callbacks reçoivent explicitement le contrôleur/l’enregistrement |
| `resources :posts do resources :comments end` | `resources :posts do |posts| posts.resources :comments end` — les blocs imbriqués reçoivent le mapper explicitement |
| ERB est compilé en méthode&nbsp;; n’importe quel objet, n’importe quelle méthode | Interprété selon une grammaire/table de dispatch fixe |
| La session contient n’importe quel objet sérialisé (marshal) | Valeurs de session de type String uniquement, cookie signé HMAC |
| De nombreux adaptateurs de base de données | SQLite uniquement, via FFI |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enums, STI, associations polymorphes | Non implémenté&nbsp;; les associations viennent uniquement des clés étrangères du schéma |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Non implémenté — noms plats, `render json:` uniquement |
| Backtrace complète lors d’une exception | Classe, message, ligne de requête, nom/ligne du template — Spinel n’expose pas de backtraces |
| Rack, ses middlewares, et n’importe quelle gem d’un `Gemfile` | Pas de compatibilité Rack&nbsp;; un petit ensemble fixe de middlewares&nbsp;; le `spin-index` propre à Spinel, limité à ce qui compile avec son sous-ensemble de Ruby |
| minitest / RSpec | `Cybertrain::Test` — les runners fondés sur la réflexion ne peuvent pas fonctionner avec une compilation AOT |
| `bin/rails generate authentication`, `has_secure_password` | `cybertrain generate authentication` écrit la même structure, plus une page d’inscription faute de console&nbsp;; `has_secure_password` est écrit en toutes lettres dans le modèle User au-dessus de `Cybertrain::Password` (PBKDF2)&nbsp;; pas de réinitialisation du mot de passe (pas de mailers) |
| Mailers, jobs, ActionCable, asset pipeline, i18n | Non développé (hors du MVP) |
<!-- table-foot: Liste non exhaustive. -->

<!-- step → #where-next -->
## Pour aller plus loin

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — L’application terminée, avec ses tests.
- [**CyberTrain sur GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Le code source, le README et les versions publiées.
- [**Référence de l’API**](site:api/index.html) — Chaque classe et méthode qu’utilise une application, avec des exemples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Les spikes et les contraintes du compilateur qu’ils ont révélées.
- [**Spinel**](https://github.com/matz/spinel) — Le compilateur Ruby AOT de matz.
- [**Accueil CyberTrain**](site:index.html) — Présentation, fonctionnalités et fonctionnement.
