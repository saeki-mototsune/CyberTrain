---
source_sha256: 66999cb2e64c8060c3a4cd7100fab0efa7c77701391e63b73ae9b4f068b1db93
title: "Tutoriel avancé&nbsp;: pousser le blog plus loin"
description: "Poursuivez le blog du Getting Started avec CyberTrain&nbsp;: un composant et un helper, des commentaires en direct avec Turbo Streams, un job d’arrière-plan, JSON, la connexion, une image de couverture envoyée et un build pour le déploiement avec cybertrain build."
og_title: "Tutoriel avancé&nbsp;: pousser plus loin le blog CyberTrain"
og_description: "Turbo, un job d’arrière-plan, JSON, la connexion, les envois de fichiers et un build déployable, ajoutés au blog du Getting Started de CyberTrain."
og_image: tutorial.png
crumb: "Tutoriel avancé"
nav: tutorial
toc_title: "Étapes 13–19"
meta:
  - term: "Prérequis"
    text: 'Le blog du [tutoriel](tutorial.md#test), jusqu’à l’étape 12'
  - term: "Point de départ"
    text: "`blog/`, avec des articles, des commentaires et des tests"
  - term: "Résultat"
    text: "`dist/blog`"
---

# Tutoriel avancé&nbsp;: pousser le&nbsp;blog plus loin

Le [tutoriel](tutorial.md) se termine sur un blog d’articles et de
commentaires. Cette page pousse la même application plus loin&nbsp;: afficher
les commentaires avec un composant, envoyer les nouveaux à toutes les pages
ouvertes avec Turbo, mettre en file un job d’arrière-plan, répondre en JSON,
ajouter la connexion, joindre une image envoyée et compiler l’application dans
un dossier `dist/` déployable. L’application à laquelle mène ce tutoriel est
[`examples/blog`](../../examples/blog), testée par la CI sous Linux et macOS.

<!-- step 13 #component stage: Vous écrivez · `app/components/`, `app/helpers/` -->
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
Chacune écrit aussi un test, sur lequel revient la fin de cette étape. La
classe est déjà ce qu’il faut au blog&nbsp;:

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

### Le test du composant

Le test généré rend `CommentComponent` avec une String là où le template
attend désormais un commentaire. Rendez plutôt le commentaire de la
fixture&nbsp;:

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` rend comme le fait une diffusion, sans requête, et
`assert_select` lit ce qu’il a rendu
([Tester les flux et les composants](testing.md#testing-streams-and-components)).
Le test du helper passe tel qu’il a été généré. Lancez-les comme à
l’[étape 12](tutorial.md#test)&nbsp;: `cybertrain test`.

<!-- step 14 #turbo stage: Exécution · Turbo Streams sur Server-Sent Events -->
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

### Tester la réponse Turbo Stream

Une requête qui demande un Turbo Stream, comme le fait la soumission d’un
formulaire par Turbo, reçoit un Turbo Stream en réponse. Ajoutez-en le test
au test des commentaires de l’[étape 12](tutorial.md#test)&nbsp;:

```ruby test/controllers/comments_controller_test.rb (extrait)
  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end
```

<!-- step 15 #job stage: Vous écrivez · `app/jobs/` -->
## Un job d’arrière-plan

> [!WHY]
> Un travail qui ne doit pas retarder la réponse, une notification par
> exemple, s’exécute à part de la requête&nbsp;: il peut commencer avant que
> la réponse soit écrite, ou après. Comme avec Active Job sur Solid Queue, un job
> est une classe dans `app/jobs/` et une ligne dans la base de données de
> l’application elle-même&nbsp;: aucun autre service.

```shell terminal — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

Elle écrit `app/jobs/notify_comment_job.rb`, avec la ligne `retry_on` que
demandait l’option et un `perform` vide, ainsi qu’un test, et ajoute
`require "cybertrain/jobs"` à `bin/blog.rb` et `bin/db.rb`, et décommente le
rôle `worker` de `config/deploy.yml` ([étape 19](#ship)). Complétez
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

Postez un commentaire&nbsp;: le journal du serveur montre le job qui s’exécute,
ici après la réponse (un thread de jobs peut aussi prendre la ligne avant que
la réponse soit écrite, si bien que l’ordre des lignes peut varier), ses lignes marquées du job et de l’identifiant de la requête
qui l’a mis en file&nbsp;:

```text sortie — cybertrain server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started POST "/articles/1/comments" for 127.0.0.1
2026-11-14T09:30:00.122Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 2ms
2026-11-14T09:30:00.950Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] new comment 1 on article 1
2026-11-14T09:30:00.951Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 1 (NotifyCommentJob) done
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
  `./blog jobs`, ou sur la page des jobs, à `/admin/jobs`&nbsp;: la ligne
  `jobs_page` commentée de `config/routes.rb` nomme `require_admin`, une
  méthode qu’écrit le générateur de l’[étape 17](#authentication), et c’est ce
  générateur qui monte la page pour vous
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
> L’expression cron est lue dans le fuseau `CYBERTRAIN_SCHEDULER_TZ` (par défaut le
> `time_zone` de l’application, UTC s’il n’est pas réglé), et un seul processus à la fois exécute la planification
> ([Les tâches planifiées](background-and-operations.md#scheduled-tasks)).

### Tester qu’un commentaire met le job en file

Le test du job écrit par le générateur passe tel quel. Ajoutez au test des
commentaires un test qui vérifie que `create` met le job en file, puis
l’exécute&nbsp;:

```ruby test/controllers/comments_controller_test.rb (extrait)
  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end
```

Un test ne lance aucun thread de jobs, donc un job en file attend que le
test l’exécute (`perform_enqueued_jobs`)&nbsp;; les autres assertions sur les
jobs sont dans [Tester les jobs](testing.md#testing-jobs).

<!-- step 16 #json stage: Vous écrivez · `app/controllers/` -->
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

Il écrit les migrations et les modèles `users` et `sessions`, le concern `Authentication`, qu’il inclut dans `ApplicationController`, les contrôleurs et les vues de la connexion, de l’inscription, de la réinitialisation du mot de passe et de la page de compte, un mailer, la commande `./blog user`, et des tests. Il ajoute aussi les routes (dont la page des jobs à `/admin/jobs`, pour les administrateurs), un partial `sessions/_nav` en haut du layout, et un réglage `base_url` dans `config/app.rb`, par lequel commencent les liens des courriels. Il ajoute enfin à `bin/blog.rb` et `bin/db.rb` les lignes des sous-systèmes que son code utilise : `cybertrain/jobs` (la page des jobs et le thread qui envoie les courriels), `cybertrain/mailer`, `cybertrain/mailer/later` (les courriels partent avec `deliver_later`) et `cybertrain/rate_limit` (les tentatives de connexion sont limitées, plus bas). Chaque fichier est listé dans [Authentification](authentication.md#generating-it).

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

> [!RULE] has_secure_password est écrit en toutes lettres
> ### `has_secure_password` est écrit en toutes lettres
>
> CyberTrain n’a pas de macro `has_secure_password`. Le générateur écrit ce
> qu’elle définirait dans le modèle `User`, comme du code qui appartient à
> l’application&nbsp;: `password=`, `authenticate` et
> `User.authenticate_by(email_address:, password:)`. Les mots
> de passe sont hachés par `Cybertrain::Password`, du PBKDF2-HMAC-SHA256 en
> Ruby, 100&nbsp;000 itérations par défaut (environ 0,2&nbsp;s une fois
> compilé)&nbsp;: bcrypt demanderait que le binaire lie une bibliothèque C.
> Augmentez le coût avec `Cybertrain::Password.iterations = 600_000` dans
> `config/app.rb`&nbsp;; `User#authenticate` refait le hachage de chaque
> utilisateur à sa connexion.

### Mettre à jour les tests

Tout test de l’[étape 12](tutorial.md#test) qui ouvre un formulaire, en soumet un ou
atteint une action autre que `index` et `show` tombe désormais sur la page de
connexion. Le générateur a écrit `test/fixtures/users.yml` (`one` et `two`,
dont le mot de passe est `"password"`) et
`test/support/session_test_helper.rb`, dont `test/test_helper.rb` donne maintenant le `sign_in_as` à chaque test
d’intégration, et il a ajouté la connexion au `setup` du test des articles
(il affiche `insert test/controllers/articles_controller_test.rb (sign_in_as users(:one))`)&nbsp;;
vous trouverez donc&nbsp;:

```ruby test/controllers/articles_controller_test.rb (extrait)
  setup do
    sign_in_as users(:one)
    @article = articles(:one)
  end
```

Le test des commentaires n’a pas de `setup` auquel le générateur puisse
ajouter la connexion, et chaque action de `CommentsController` (create et
destroy) demande maintenant un utilisateur connecté, donc chacun de ses
quatre tests aussi&nbsp;; donnez-lui-en un&nbsp;:

```ruby test/controllers/comments_controller_test.rb (extrait)
class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end
```

Un scaffold généré désormais se connecte de lui-même.

> [!NOTE]
> Les propres tests du générateur (`test/controllers/sessions_controller_test.rb`,
> `registrations_controller_test.rb`, `passwords_controller_test.rb`,
> `accounts_controller_test.rb`, `test/integration/remember_me_test.rb`,
> `lockout_test.rb`, `admin_test.rb`, [Tests](authentication.md#testing))
> s’exécutent avec les autres sous `cybertrain test`, en déplaçant
> l’horloge avec `travel_to` pour vérifier le jour 15 et le jour 30. Les
> tentatives de connexion sont limitées comme dans le générateur de
> Rails&nbsp;: dix par adresse cliente toutes les trois minutes, comptées dans
> la base de données de l’application, si bien que tous les processus
> comptent ensemble&nbsp;; derrière un reverse proxy, configurez les
> [proxys de confiance](requests.md#rate-limiting-and-the-client-address).
> `examples/blog` fait cette étape avec `--invite-only` et réserve ses pages
> `/admin` aux administrateurs.

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
l’étape 17. Le téléchargement n’exécute pas non plus le code de `def show`, et
ce `show` en a (il prépare un commentaire vide pour le formulaire et choisit un
format)&nbsp;: le générateur s’arrête donc, sauf si `--show-checks-nothing`
indique que ce code ne restreint personne, ce qui est le cas ici&nbsp;:

```ruby app/controllers/articles_controller.rb (extrait)
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell terminal — blog/
cybertrain generate attachment article cover --show-checks-nothing   # pour un nouveau modèle : generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                                                # ajoute les colonnes cover_* à articles
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
le générateur émet tout de même un avertissement, parce que ce `show` a du code qui lui est
propre&nbsp;:

```text sortie — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

Ici, ce code construit un commentaire et choisit un format&nbsp;; il ne refuse
personne, il n’y a donc rien à recopier dans `cover`. S’il refusait quelqu’un
(`head 404 if @article.draft?`), la place de cette vérification serait un
`before_action` listant à la fois `:show` et `:cover`, que le générateur sait
lire. La déplacer ne viderait pas ce `show`, qui construit toujours le
commentaire et choisit le format&nbsp;: le générateur s’arrêterait encore. Il
faut alors le lancer avec un `show` vide, ou avec `--show-checks-nothing` une
fois vérifié que le code resté dans `show` ne restreint personne.

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
> Le code placé dans `def show`, il ne peut pas lire ce qu’il vérifie&nbsp;: il
> s’arrête donc de la même façon, sauf si `--show-checks-nothing` s’en porte
> garant, et avertit alors. Avec un `show` vide, il ajoute de lui-même `:cover` à
> `allow_unauthenticated_access` là où `:show` figure&nbsp;; avec du code dans
> `show`, il ne touche pas à cette ligne, et sans `:cover` à cet endroit
> l’image exige une connexion.

> [!RULE] has_one_attached est écrit en toutes lettres
> ### `has_one_attached` est écrit en toutes lettres
>
> Il n’y a ni `has_one_attached` ni table d’attachements partagée&nbsp;: les
> types admis, les tailles et qui peut télécharger diffèrent d’une application
> à l’autre, donc le générateur écrit les méthodes en toutes lettres,
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
a aussi écrit `test/integration/article_cover_attachment_test.rb` et l’image
`test/fixtures/files/cover.png`, qui testent tout le parcours et se
connectent d’abord, puisque l’application a maintenant un `User`. Comme
`:cover` est public ici, il vérifie qu’un visiteur peut télécharger l’image,
et il remplit le corps avec `"A article."`, allongé jusqu’au minimum de
10&nbsp;caractères de l’[étape 05](tutorial.md#validations).

> [!NOTE]
> Lancez `cybertrain test` comme à l’[étape 12](tutorial.md#test) (mesuré le
> 2026-11-13, le blog du tutoriel compte alors 83 tests et 870 assertions).
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
  poller des flux des étapes 14 et 15&nbsp;: un seul processus constitue un
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
- La surveillance des fichiers, l’aperçu CRuby et la boucle de recompilation
  ne tournent jamais en production. Un `cybertrain server` en cours
  d’exécution ne régénère et ne redémarre rien tant que `cybertrain build`
  détient `tmp/cybertrain-build.lock`.

`cybertrain new` écrit aussi une configuration
[Kamal 2](https://kamal-deploy.org). Le `Dockerfile` exécute
`cybertrain setup` et `cybertrain build` dans une étape de build Ubuntu et
copie `dist/` dans une étape allégée de la même version, qui applique les
migrations au démarrage puis écoute sur `0.0.0.0:3000`. À côté se trouvent
`.dockerignore`, `config/deploy.yml` (kamal-proxy avec Let&rsquo;s Encrypt en
façade, le contrôle de santé sur `public/up.html`, le fichier SQLite sur un
volume monté en `/app/storage`, et le rôle `worker` que l’étape 15 a
décommenté&nbsp;: un second conteneur de la même image qui exécute
`./blog worker`&nbsp;; le rôle web exécute aussi les jobs sauf si
`CYBERTRAIN_WORKER` vaut 0) et `.kamal/secrets`, qui lit
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
  ligne&nbsp;; pas de `has_many :through`, d’enums, de STI ni
  d’associations polymorphes.
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
- [**Déployer**](site:deploy.html) — Comment l’application compilée tourne en production&nbsp;: Kamal, ou systemd derrière Caddy.
- [**Authentification**](authentication.md) — Réinitialisation du mot de passe, confirmation, verrouillage, rester connecté, page de compte et administrateurs.
- [**Internationalisation**](i18n.md) — Dictionnaires, `t` et `l`, et une locale par requête.
- [**Guides**](index.md) — Une page par sujet&nbsp;: modèles, requêtes, templates, temps réel, tâches de fond, tests.
- [**CyberTrain sur GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Le code source, le README et les versions publiées.
- [**Référence de l’API**](site:api/index.html) — Chaque classe et méthode qu’utilise une application, avec des exemples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Les spikes et les contraintes du compilateur qu’ils ont révélées.
- [**Spinel**](https://github.com/matz/spinel) — Le compilateur Ruby AOT de matz.
- [**Accueil CyberTrain**](site:index.html) — Présentation, fonctionnalités et fonctionnement.
