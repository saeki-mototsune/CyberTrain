---
source_sha256: e9f54a9f55d52674351fe3c7cbf908b9cea71747715df0fbfc08f2bb15e41506
---
# Requêtes

Ce qu’un contrôleur reçoit d’une requête et ce que le framework vérifie avant de l’exécuter&nbsp;: les routes et leurs formats, `respond_to`, les concerns et `helper_method`, les paramètres forts, les téléchargements et le cache HTTP, les cookies et la session chiffrée, la limitation du débit et l’adresse du client derrière un proxy, l’identifiant de requête, la Content Security Policy, `force_ssl` et le contrôle des hôtes, les en-têtes paramétrés, et la façon dont les chaînes de requête et les corps de requête sont analysés et bornés.

## Routage

`config/routes.rb` utilise le DSL de routage de Rails&nbsp;; `spin run gen` l’évalue et écrit `gen/routes.rb` (la table des routes, le répartiteur et les helpers `*_path` / `*_url`). Au premier niveau, un appel n’a pas besoin de receveur&nbsp;; un bloc imbriqué nomme le receveur qu’il reçoit, car Spinel n’évalue sans receveur que le premier niveau de `Routes.draw`&nbsp;:

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
end
```

`namespace :admin` préfixe les chemins par `/admin` et les helpers par `admin_` (`admin_articles_path`, `admin_article_path(article)`), et ses contrôleurs sont `Admin::ArticlesController` dans `app/controllers/admin/articles_controller.rb`, avec leurs vues dans `app/views/admin/articles/`. Les namespaces s’imbriquent. Un contrôleur dans un namespace peut s’écrire en imbrication (`module Admin` / `class ArticlesController < ApplicationController`) ou sous la forme compacte (`class Admin::ArticlesController`, une fois `module Admin` défini)&nbsp;; l’analyse lit les deux. `jobs_page` dans un namespace prend son préfixe.

`scope` change une partie à la fois, et les trois se combinent comme dans Rails&nbsp;:

```ruby
scope "/dashboard" do |s|          # le préfixe de chemin seulement
  s.get "/stats", to: "stats#show"
end
scope module: "billing" do |s|     # le module du contrôleur seulement : Billing::InvoicesController
  s.resources :invoices
end
scope "/v1", as: "v1" do |v|       # le chemin et le préfixe des helpers : v1_about_path
  v.get "/about", to: "pages#about"
end
```

`namespace` et `scope` s’emploient hors des blocs `resources` (gen les refuse à l’intérieur).

### Ressources singulières, `controller:` et `param:`

`resource` (au singulier) prend un bloc et `controller:`, comme `resources`. Le bloc ajoute des routes de membre et des ressources imbriquées, avec les chemins et les noms de Rails&nbsp;:

```ruby
resource :profile, controller: "pages", only: [:show] do |r|
  r.get :refresh, on: :member       # GET /profile/refresh, refresh_profile_path
end
resources :indicators, param: :key  # /indicators/:key, params[:key]
```

`on: :member` et `on: :collection` placent une route personnalisée comme le font les blocs `member` et `collection`&nbsp;; une ressource singulière n’a pas de collection. `param: :key` nomme le segment de membre (`params[:key]`), et les ressources imbriquées en dessous utilisent `:indicator_key`&nbsp;; `indicator_path(ind)` lit toujours `ind.to_param`, que le modèle redéfinit pour renvoyer la clé. Les segments `:id` et `:x_id` d’une route personnalisée gardent leurs anciens noms d’argument de helper (`get "/users/:id"` donne `user_path(user)`).

### Redirections et chaînes de requête

`get "/old", to: redirect("/new")` répond 301 (`redirect("/new", status: 302)` pour un autre code)&nbsp;; `%{name}` dans la cible est la valeur du segment, échappée&nbsp;: `get "/old-posts/:id", to: redirect("/posts/%{id}")`. Une route de redirection n’a pas de helper sauf si elle indique `as:`. La forme à bloc de `redirect` n’est pas prise en charge&nbsp;; une action de contrôleur calcule une cible.

Les arguments mot-clé d’un helper de chemin vont dans la chaîne de requête, dans l’ordre donné et échappés&nbsp;: `article_path(a, page: 2)` vaut `/articles/3?page=2`, une valeur nil omet sa clé, un Array donne `key[]=v` par élément et une valeur Hash lève `ArgumentError`. `format: :json` ajoute l’extension (`/articles/3.json`) et `anchor: "c4"` le fragment (`#c4`, en dernier). Les mots-clés ne remplissent jamais un segment de chemin&nbsp;: les segments sont des arguments positionnels (`post_path(3)`, pas `post_path(id: 3)`). `url_for("/x", format: :csv)` ajoute les mêmes options à une String.

## Formats et `respond_to`

Chaque route accepte une extension facultative sur son dernier segment&nbsp;: `/articles/3.json` donne `params[:id] == "3"` et `request.format == :json`. Dans une route qui prend un format, un segment dynamique ne capture jamais de `.` (le défaut de Rails), donc `/articles/3.json.bak` est une 404. Une route dont un segment contient un point pour sa propre raison indique `format: false` (sur `get` et les autres verbes, `resources`, `resource` et `root`)&nbsp;:

```ruby
get "/files/:name", to: "files#show", format: false   # /files/report.v2 a pour name "report.v2"
```

`request.format` est un Symbol&nbsp;: celui de l’extension, parmi les types enregistrés de Rails (`:html`, `:json`, `:csv`, `:xml`, `:pdf`, `:turbo_stream`, …&nbsp;; `jpg` donne `:jpeg`, `htm` `:html`, `txt` `:text`), et `:unknown` pour toute autre extension. Sans extension, il vient de `Accept`&nbsp;: `:turbo_stream` quand il liste `text/vnd.turbo-stream.html`, `:json` quand il liste `application/json` et pas `text/html` avant, `:html` sinon (un type avec `q=0` est écarté).

```ruby
def show
  @article = Article.find(params[:id])
  respond_to do |format|
    format.html
    format.json { render json: @article.as_json }
    format.turbo_stream
  end
end
```

Le collecteur (`Cybertrain::FormatCollector`) a `html`, `json`, `turbo_stream`, `csv`, `xml`, `text` et `any`. La première déclaration qui correspond exécute son bloc aussitôt, si bien que le bloc voit les variables d’instance de l’action&nbsp;; une déclaration sans bloc rend le template de l’action pour ce format (`show.html.erb` dans le layout, `show.turbo_stream.erb` sans). Quand aucune ne correspond, la réponse est `406 Not Acceptable`. `any` correspond à tout format sauf `:unknown`. Turbo soumet un formulaire en demandant `text/vnd.turbo-stream.html, text/html`&nbsp;: une telle requête a le format `:turbo_stream`, et une action sans `format.turbo_stream` répond par son `format.html`, comme dans Rails (une extension `.turbo_stream` ne demande que ce format). Le même repli couvre tout `Accept` qui liste `text/html` ou `*/*` à côté d’un format autre que html&nbsp;: un client qui envoie `application/json, text/plain, */*` à une action qui n’a qu’un template html reçoit le html, pas une 406. Le repli exécute le bloc une seconde fois, pour html, donc une instruction du bloc autre que les lignes `format.` s’exécute deux fois&nbsp;: gardez dans le bloc les seules lignes `format.`. Une entrée avec `q=0` refuse son type&nbsp;: `application/json, text/html;q=0` ne reçoit pas de html, qu’il y ait `*/*` à côté ou non.

Une réponse dont le format vient de `Accept` (pas d’extension, un en-tête `Accept` envoyé) porte `Vary: Accept`, fusionné dans le `Vary` que l’action a posé, pour qu’un navigateur ou un cache ne serve jamais le html d’une URL à une requête de son JSON ou de son Turbo Stream&nbsp;; un chemin avec extension n’en reçoit pas.

Sans `respond_to`, une action rend `<action>.<format>.erb` quand il existe (`create.turbo_stream.erb`, sans layout, avec le type de contenu du format) et répond 406 sinon&nbsp;; le html ne change pas. JSON n’a pas de templates&nbsp;: une action répond en JSON avec `render json:`. Dans un bloc, `render :edit` rend le template du format que ce bloc a retenu (`edit.turbo_stream.erb` dans `format.turbo_stream`).

Un contrôleur construit des réponses Turbo Stream avec `turbo_stream` (le constructeur de turbo-rails&nbsp;: `replace`, `update`, `append`, `prepend`, `before`, `after`, chacun avec une cible et l’un de `partial:` avec `locals:` ou `html:`, et `remove`)&nbsp;:

```ruby
render turbo_stream: [turbo_stream.remove(@comment), turbo_stream.update("count", html: @count.to_s)]
```

## Concerns et `helper_method`

Un concern de contrôleur est un module dans `app/controllers/concerns/`, comme dans Rails&nbsp;:

```ruby app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 20
  end
end
```

Un contrôleur qui écrit `include AdminGate` reçoit ce que déclare le bloc `included` (`before_action`, `skip_before_action`, `after_action`, `helper_method`, `rate_limit`, `rescue_from`, `layout`), à la place de l’`include` et dans l’ordre écrit, et `self.class.per_page` fonctionne dans ses actions. Les concerns peuvent inclure des concerns&nbsp;: gen les développe en profondeur d’abord, chacun une fois, et refuse un cycle en le nommant (`concern cycle: A includes B includes A`). `include A, B` inclut B d’abord, comme Ruby, donc le bloc `included` et les callbacks de B passent avant ceux de A. `around_action` est refusé (il n’y a pas de callbacks around). Les affectations `@x =` dans les méthodes d’un concern sont des variables de vue du contrôleur.

Spinel compile les blocs `included` et `class_methods`, qui ne s’exécutent jamais, donc gen les développe lui-même&nbsp;: il écrit chaque concern dans `gen/concerns/<chemin sous app/>` avec ces deux blocs vidés (les fichiers de l’application chargent ces copies), et `gen/concerns.rb` rouvre chaque classe qui l’inclut avec les déclarations insérées et un renvoi par méthode de `class_methods`. Deux règles en découlent. Une méthode de `class_methods` ne peut pas porter le nom d’une méthode d’instance du concern, d’une classe qui l’inclut ou de ses ancêtres (Spinel définirait les deux comme méthodes d’instance, spikes/NOTES.md règle 93)&nbsp;; gen la refuse en nommant les deux endroits (`fichier:ligne` de la méthode d’instance). Et un `include` d’un module qui n’est pas un concern (`include Comparable`, un nom sans fichier sous `app/*/concerns`) est laissé tel quel à Ruby, si bien qu’un nom de concern mal orthographié est une `NameError` au chargement de l’application, pas un message de gen. gen cherche un nom comme Ruby, d’abord dans les modules de la classe elle-même&nbsp;: `include Gate` dans `module Admin` inclut donc `Admin::Gate`. Un nom qui n’atteint aucun concern mais se termine par le nom d’un concern (`include Gate` quand seul `Admin::Gate` existe) arrête gen&nbsp;: Ruby inclurait un autre module ou lèverait une erreur, et le bloc `included` du concern serait perdu.

Les concerns de modèle vivent dans `app/models/concerns/` et fonctionnent de la même façon&nbsp;: leur bloc `included` peut contenir toutes les déclarations de niveau classe du modèle (`validates`, `validate`, `scope`, `belongs_to`, `has_many`, `has_one`, `encrypts`, callbacks, `normalizes`), traitées comme écrites dans le modèle à l’`include`. Les callbacks d’un concern s’exécutent après ceux du modèle du même type, et un `include` dans le bloc `included` d’un concern de modèle fait entrer ce concern. Le nom d’une méthode de `class_methods` d’un concern de modèle ne peut être ni un scope du modèle ni une méthode de classe que tout modèle a (`recent` à côté de `scope :recent`, `where`)&nbsp;; gen la refuse.

`helper_method :current_user, :admin?` dans un contrôleur, ou dans le bloc `included` d’un concern, rend ces méthodes du contrôleur appelables depuis les templates de ce contrôleur, et depuis les composants et partiels qu’ils rendent, avec leurs arguments. gen refuse un nom qui est un helper du framework, finit par `_path` ou `_url`, est défini par un module de `app/helpers`, n’a pas de `def` dans le contrôleur, ses parents ou ses concerns, ou dont un template ne peut pas passer les paramètres (`*rest`, `**opts`, `...`).

## Paramètres&nbsp;: `params.expect` et `permit` imbriqué

```ruby
def article_params
  params.expect(article: [:title, :body, tags: [], meta: [:source]])
end
# => {"title" => "Hi", "body" => "...", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
```

`permit` prend les mêmes formes&nbsp;: une clé autorise une String, `key: []` une liste de Strings et `key: [...]` un niveau imbriqué. Un filtre qui n’est pas un Array (`permit(meta: :source)`, `expect(article: :title)`) ou qui contient un Array (`[[:title]]`) lève `ArgumentError`&nbsp;: c’est une erreur dans le code, pas une mauvaise requête, donc pas une 400. Une valeur du mauvais genre, une clé non listée et un fichier envoyé sont écartés. `expect` renvoie le niveau sous son unique clé, et lève `Params::ParameterMissing` (répondu 400) quand cette clé est absente, du mauvais genre, ou n’autorise rien. `params.expect(:id)` lit une String et répond `{"id" => "3"}`&nbsp;; `params.expect(tags: [])` répond de même une liste non vide. Les deux renvoient `Hash{String => Object}`&nbsp;: les valeurs sont des Strings, des Arrays de Strings ou des Hash imbriqués, donc restreignez une valeur avec `Cybertrain::Cast.str` (ou `.to_s`) avant d’appeler des méthodes de String dessus.

## Téléchargements, cache HTTP et codes de statut

`send_data(bytes, filename: "report.csv", type: "text/csv", disposition: "attachment")` répond avec les octets et un `Content-Disposition` qui porte le nom à la fois entre guillemets et sous la forme `filename*` de la RFC 5987, si bien que les accents et les guillemets survivent&nbsp;; `disposition: "inline"` l’affiche dans le navigateur. Il envoie les octets sous le `type` donné, il sert donc aux données que l’application a produites&nbsp;; un fichier envoyé par un utilisateur passe par `send_blob`, qui ne laisse jamais un navigateur l’exécuter.

```ruby
def show
  @post = Post.find(params[:id])
  fresh_when etag: @post, last_modified: @post.updated_at
end

def feed
  @posts = Post.order(created_at: :desc).limit(20).to_a
  return unless stale?(etag: @posts.first)
  expires_in 300, public: true
end
```

`fresh_when` pose un `ETag` faible (tiré d’une String, ou de la table, du `to_param` et du `updated_at` d’un enregistrement) et `Last-Modified`, et répond `304 Not Modified` quand le `If-None-Match` de la requête (ou, sans lui, `If-Modified-Since`) montre que le client a la version actuelle&nbsp;; `stale?` fait de même et renvoie si l’action doit faire son rendu. Seuls GET et HEAD reçoivent une 304. `Cache-Control` vaut `max-age=0, private, must-revalidate` (`public` avec `public: true`) sauf si `expires_in seconds` a d’abord posé `max-age=<seconds>`. Il n’y a pas d’ETag automatique sur les autres réponses. `If-None-Match: *` correspond à ce que l’action a validé, un `ETag` ou seulement un `Last-Modified`.

L’ETag est fait de la clé que vous donnez, du format de la requête et d’une empreinte du build (les empreintes des assets et l’import map, et les vues dans un binaire `cybertrain build`)&nbsp;: le html et le JSON d’une même URL n’en partagent donc jamais, et un déploiement qui change les assets ou les vues fait revalider tous les clients. Deux conséquences. En développement, sans `--embed-views`, les templates sont lus sur le disque et ne sont pas dans l’empreinte&nbsp;: une modification de vue peut encore recevoir une `304` jusqu’à ce qu’un enregistrement change ou que la page soit rechargée sans sa copie en cache. Et la clé nomme ce que la page montre, pas qui la voit&nbsp;: un contenu qui diffère selon l’utilisateur doit mettre l’utilisateur dans la clé (`etag: "posts/#{@post.id}-#{@post.updated_at.to_i}-#{current_user.id}"`), sinon il est montré à la mauvaise personne. Ne rendez pas `public` une page qui porte un nonce CSP (`content_security_policy` avec nonces, `javascript_importmap_tags`)&nbsp;: un cache partagé donne à chaque visiteur la même page, donc le même nonce, qui ne protège alors plus rien.

`status:` et `head` acceptent tous les symboles de Rack (`:unauthorized`, `:payment_required`, `:unprocessable_content`, `:too_many_requests`, …, avec les anciens `:unprocessable_entity` et `:payload_too_large` comme alias), et les phrases de statut sont celles de la RFC 9110 (413 "Content Too Large", 422 "Unprocessable Content").

## Cookies et session

```ruby
cookies[:theme] = "dark"
cookies[:theme] = { value: "dark", expires: Time.now + 86_400, same_site: "Strict" }
cookies.permanent[:locale] = "ja"
cookies.signed[:user_id] = "5"     # lisible par le client, pas modifiable
cookies.encrypted[:card] = "4242"  # ni lisible ni modifiable
cookies.signed[:user_id]           # => "5", ou nil s’il a été modifié
cookies.delete(:theme)
```

Une écriture prend une String, ou un Hash avec `value:`, `expires:` (un Time), `max_age:`, `path:`, `httponly:`, `secure:` et `same_site:`. Les cookies sont écrits `Path=/`, `HttpOnly` et `SameSite=Lax`, et `Secure` quand le cookie de session l’est (en production, ou avec `force_ssl`), sauf si l’écriture dit autre chose. `permanent` écrit un `Max-Age` de 20 ans. Une valeur signée est un HMAC-SHA256 sous une clé dérivée de `secret_key_base`&nbsp;; une valeur chiffrée est de l’AES-256-GCM sous une autre&nbsp;; chacune est liée au nom de son cookie, si bien qu’elle ne se vérifie ni ne s’ouvre sous un autre nom, et une valeur modifiée se lit nil. Une valeur lue après une écriture dans la même requête est celle écrite. Sous la jar, `Cybertrain::Cookies.serialize(name, value, expires: time)` construit une valeur `Set-Cookie`&nbsp;; omettre `expires:` (sa valeur par défaut est `Cybertrain::Cookies::NO_EXPIRES`, pas nil, pour une raison propre à Spinel&nbsp;: voir la règle 109 de spikes/NOTES.md) ou passer nil n’écrit pas d’`Expires`.

Le cookie de session est chiffré et authentifié en AES-256-GCM, comme le cookie store de Rails, sous sa propre clé dérivée de `secret_key_base`&nbsp;: le client ne peut ni le lire ni le modifier. Un cookie qui ne se déchiffre pas (modifié, étranger ou un ancien cookie signé) se charge comme une session vide, de même qu’un cookie de plus de 4096 octets&nbsp;; une session dont le cookie dépasserait 4096 octets, ou un cookie du jar dont le `name=value` les dépasse, lève `Session::CookieOverflow` à l’écriture. Les valeurs restent des Strings. Changer `secret_key_base` déconnecte tout le monde, comme avant.

## Limitation du débit et adresse du client

`rate_limit` dans un contrôleur plafonne la fréquence à laquelle un client peut
appeler certaines actions, compté avant l’exécution de l’action. Il demande
`require "cybertrain/rate_limit"` (qui charge le cache) dans `bin/<app>.rb`
et `bin/db.rb`&nbsp;; `cybertrain generate authentication` l’ajoute&nbsp;:

```ruby
class SessionsController < ApplicationController
  # une 303 vers le formulaire, avec flash[:alert], une fois la limite atteinte
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
  rate_limit to: 5, within: 60, only: [:create], by: :account_key, with: :slow_down, name: "account"
end
```

Chaque déclaration compte au plus `to` requêtes par fenêtre de `within` secondes pour chaque client et chaque contrôleur, puis répond 429 avec un en-tête `Retry-After` (les secondes restantes de la fenêtre), ou redirige quand `redirect_to:` est fourni. Les autres options nomment des méthodes du contrôleur&nbsp;: `by:` la clé (`:client_ip` par défaut, `:remote_addr` pour le pair de la connexion, ou une méthode comme `account_key`, dont un nil ou un `""` lève une erreur plutôt que de compter tous les clients ensemble), `with:` ce qu’il faut répondre à la place (quand elle ne rend rien, la 429 suit), `if:` / `unless:` quand la limite s’applique (une requête écartée n’est pas comptée). Un contrôleur avec deux limites donne à chacune son propre `name:` (gen refuse une seconde limite du même nom dans un contrôleur, ceux de ses parents compris, et un nom contenant `:`). `within:` est en secondes et `only:`/`except:` prennent des Array.

Les compteurs vivent dans `Cybertrain::Cache`, dans la base de données de l’application, si bien que tous les processus qui servent l’application comptent ensemble et que les compteurs survivent à un redémarrage&nbsp;; les fenêtres sont fixes et alignées sur l’horloge (`now / within`). `store: :memory` garde l’ancien compteur par processus&nbsp;: chaque processus compte de son côté, dans une table d’au plus 10&nbsp;000 clés (quand elle est pleine, les fenêtres expirées puis les plus anciennes font de la place), perdue au redémarrage, avec une fenêtre qui s’ouvre à la première requête d’une clé et un verrou pris par chaque requête vers une action limitée (nommez les actions avec `only:`). Dans un test, `Cybertrain::RateLimit.reset_all!` oublie tous les compteurs (les tables en mémoire et les lignes de limitation du cache&nbsp;; `cybertrain test` le fait avant chaque test), et les deux stores lisent l’horloge du framework, si bien que `travel 1.minute` ou `travel_to` fait passer un test au-delà d’une fenêtre ([Voyager dans le temps](testing.md#time-travel)).

### L’adresse du client derrière un proxy

L’adresse comptée est `request.client_ip` (`by: :remote_addr` compte plutôt le
pair de la connexion). C’est `request.remote_addr`, sauf si
`config.trusted_proxy` est activé (`CYBERTRAIN_TRUSTED_PROXY=1`) **et** que la
connexion vient du loopback, c’est-à-dire d’un reverse proxy sur le même hôte
(nginx, Caddy, kamal-proxy)&nbsp;; c’est alors la dernière adresse de
`X-Forwarded-For`, celle que le proxy a ajoutée. Les entrées précédentes sont
ce que le client a envoyé et ne sont jamais utilisées, et une dernière entrée
vide, plus longue que 45 octets ou qui n’est pas de l’ASCII imprimable donne
`remote_addr`. Sans ce réglage, tous les visiteurs derrière un tel proxy
partagent son adresse, et dix mauvais mots de passe bloquent tout le
monde&nbsp;; avec lui, un client qui se connecte directement depuis ailleurs ne
peut toujours pas choisir sa propre adresse. `request.loopback?` indique si la
connexion vient de cette machine (127.0.0.0/8, `::1`, `::ffff:127.x.x.x`), pour
les pages que seul un opérateur sur le serveur doit atteindre&nbsp;; derrière un
proxy sur le même hôte, toute requête vient du loopback&nbsp;: vérifiez donc
aussi `client_ip` dans ce cas. Conception&nbsp;: [docs/design.md](../design.md)
D26.

Un proxy qui atteint l’application par un réseau, et non par le loopback, est
plutôt listé par adresse&nbsp;: `config.trusted_proxies`, issu de
`CYBERTRAIN_TRUSTED_PROXIES`, prend des adresses IPv4 ou IPv6 ou des CIDR
séparés par des virgules (`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`,
ou un seul `172.18.0.2`). Une connexion venant de l’un d’eux reçoit le même
traitement qu’une connexion loopback ci-dessus&nbsp;: la dernière adresse de
`X-Forwarded-For`, validée de la même façon. Une entrée IPv4 correspond aussi à
la forme IPv4-mappée de ses adresses (`::ffff:172.18.0.2`), et le `%zone` d’un
pair est ignoré. Une entrée qui n’est ni une adresse ni un CIDR, ou dont le
préfixe dépasse `/32` (IPv4) ou `/128` (IPv6), arrête le serveur au démarrage.
`CYBERTRAIN_TRUSTED_PROXY=1` est le raccourci de `127.0.0.0/8,::1`, et les deux
s’additionnent.

C’est le cas de Kamal&nbsp;: kamal-proxy tourne dans son propre
conteneur Docker et se connecte depuis son adresse sur le réseau Docker, donc le
`config/deploy.yml` qu’écrit `cybertrain new` définit
`CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` (la plage par défaut de
Docker&nbsp;; changez-la si vos réseaux en utilisent une autre,
`docker network inspect kamal`). Laissez `proxy.forward_headers` de Kamal non
défini&nbsp;: avec `ssl: true`, kamal-proxy définit lui-même `X-Forwarded-For`
au lieu de transmettre celui du client. Ne listez que des réseaux depuis
lesquels les clients ne peuvent pas se connecter&nbsp;: toute personne à
l’intérieur d’un réseau listé peut choisir l’adresse que compte une limite de
débit.

## L’identifiant de requête

Chaque requête a un identifiant, `request.request_id`&nbsp;: un UUID de
version 4 que crée le framework, ou le `X-Request-Id` qu’a envoyé un proxy de
confiance (la confiance ci-dessus, et 1 à 255 lettres ASCII, chiffres et traits
d’union&nbsp;; toute autre valeur est écartée, jamais modifiée). La réponse le
renvoie dans `X-Request-Id`, pages d’erreur et 403 du contrôle des hôtes
compris, et chaque ligne journalisée pendant la requête le porte comme
étiquette&nbsp;:

```ruby
def export
  ExportJob.perform_later("user_id" => current_user.id)   # les lignes du job portent aussi cet identifiant
  Cybertrain.logger.info("export queued for #{request.request_id}")
  head :accepted
end
```

`c.log_tags` choisit ce que montre chaque ligne, et les lignes et les rapports
d’erreur d’un job portent l’identifiant de la requête qui l’a mis en file
([Identifiants de requête](background-and-operations.md#request-ids)).

## Content Security Policy, `force_ssl` et hôtes

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

La politique est désactivée tant que `config/app.rb` n’en déclare pas, comme dans Rails. Ensuite chaque réponse porte `Content-Security-Policy` (`Content-Security-Policy-Report-Only` avec `c.content_security_policy_report_only = true`), avec un nonce neuf par requête dans les directives à nonce&nbsp;; une 304 n’en porte pas, si bien qu’une page en cache garde le nonce avec lequel ses scripts ont été écrits. `csp_meta_tag`, `javascript_tag(nonce: true)`, `javascript_importmap_tags` et `stylesheet_link_tag(nonce: true)` écrivent ce nonce ([Le langage de templates](template-language.md#helpers-and-the-form-builder)). Les Symbols sont les mots-clés et les schémas (`:self` donne `'self'`, `:data` donne `data:`)&nbsp;; une source String contenant une espace, `;`, `,` ou un caractère de contrôle est refusée dès sa déclaration. Un contrôleur ajuste une copie pour ses actions, et ses sous-classes en héritent&nbsp;:

```ruby
class EmbedController < ApplicationController
  content_security_policy do |p|
    p.frame_ancestors "https://partner.example"
  end
end
```

Chaque réponse porte aussi `Permissions-Policy: camera=(), microphone=(), geolocation=()` sauf si elle pose la sienne&nbsp;; `c.permissions_policy` remplace la valeur, `""` n’en envoie aucune.

`CYBERTRAIN_FORCE_SSL=1` (`config.force_ssl`) redirige http vers https, en 301 pour GET et HEAD et en 307 pour le reste, et ajoute `Strict-Transport-Security: max-age=63072000; includeSubDomains` aux réponses https. Derrière un proxy qui termine TLS, une requête est https quand elle dit `X-Forwarded-Proto: https`, un en-tête lu quoi que dise `trusted_proxy` (un client qui le falsifie ne saute que sa propre redirection). `request.base_url` ne le croit que d’un proxy de confiance&nbsp;: définissez donc aussi `CYBERTRAIN_TRUSTED_PROXY` ou `CYBERTRAIN_TRUSTED_PROXIES`, sinon les URL que l’application construit restent en http. La redirection prend son hôte dans un `Host` bien formé (un `Host` mal formé donne une 400), et un GET ou HEAD http du chemin de santé n’est jamais redirigé. Avec `force_ssl`, la session et le cookie jar écrivent des cookies `Secure`.

Le contrôle des hôtes étend la garde de développement&nbsp;: `CYBERTRAIN_HOSTS` (des noms d’hôte séparés par des virgules, sans schéma, port ni joker) est ajouté à `allowed_hosts`, après les noms du loopback, dans tous les environnements. Le développement contrôle comme avant&nbsp;; la production et les tests ne contrôlent que si `CYBERTRAIN_HOSTS` est défini. Un `Host` refusé répond 403 `Blocked host` et est journalisé&nbsp;; un GET ou HEAD du chemin de santé passe quel que soit le Host, si bien qu’un répartiteur de charge qui sonde par adresse atteint toujours le contrôle de santé.

## En-têtes paramétrés

Les clients d’API envoient souvent des en-têtes `Scheme k1=v1, k2="v2"`
(`Authorization:
Digest ...`, un `X-Example-Auth` propre à un fournisseur) ou des listes
`k1=v1;k2=v2, k3` (`Forwarded`, `Prefer`). `request.header_params(name)` en
analyse un en un `Hash` qui associe des noms en minuscules à des valeurs, pour
qu’un contrôleur d’API n’ait pas à le découper à la main&nbsp;:

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

`,` et `;` séparent tous deux les paramètres, et la première occurrence d’un
nom l’emporte&nbsp;; une valeur entre guillemets est débarrassée de ses
guillemets (`\"` et `\\` défaits), une valeur sans guillemets est débarrassée
des espaces qui l’entourent, et un nom sans `=` est associé à `""`. Un mot de
schéma initial (`Digest`, `Bearer`) n’est pas un paramètre&nbsp;:
`request.header_scheme(name)` le renvoie (`""` s’il n’y en a pas). Un en-tête
absent ou plus long que 8&nbsp;Kio donne `{}`. Les valeurs sont les octets tels
qu’envoyés, jamais décodés depuis le pourcent et pas forcément de l’UTF-8
valide. Un identifiant `Bearer <token>` ou `Basic <base64>` n’est pas un
paramètre&nbsp;: vérifiez le schéma, puis lisez l’identifiant dans
`request.header("authorization")`. Conception&nbsp;:
[docs/design.md](../design.md) D31.

## Chaînes de requête et corps

`Query.parse`, `Query.value_of`, `Query.decode` et `request.form_value` / `query_value` lèvent `Cybertrain::QueryMalformed` (une `StandardError` sous `Cybertrain::QueryInvalid`, pas une `ArgumentError`), à laquelle il est répondu 400, sur&nbsp;:

- un échappement pourcent mal formé, sur les deux runtimes&nbsp;;
- une séquence d’octets UTF-8 invalide, brute (quel que soit le tag de la String) ou encodée en pourcent (Rails répond de même 400 pour un encodage de paramètre invalide)&nbsp;;
- un octet brut que seul un échappement compléterait (`a=\xC3%A9`).

`Cookies.parse` garde plutôt une telle valeur brute. Un chemin avec une séquence invalide (brute, ou décodée depuis le pourcent dans un segment) donne aussi une 400 (`request.path_segments`)&nbsp;; un échappement mal formé dans un chemin reste littéral, une 404 faute de correspondance. Les paramètres de requête s’imbriquent sur 32 niveaux et 4096 paires au plus, et donnent une 400 au-delà. Note de mise à niveau&nbsp;: le code d’application qui faisait `rescue ArgumentError` autour de ces appels doit plutôt faire `rescue Cybertrain::QueryInvalid`.

La requête ne garde pas d’arbre de paramètres à elle (le Router construit `params`, le middleware lit une seule clé)&nbsp;; une application qui veut l’arbre entier l’analyse elle-même, `Query.parse(request.utf8_query_string)`, et possède le résultat.

Rack laisse un corps de requête gzip tel quel. Ici, un corps envoyé avec `Content-Encoding: gzip` (un SDK ou un client d’API au-delà de quelques kilo-octets) est `request.decoded_body`, décompressé une fois via la zlib du système sous un plafond de taille de sortie&nbsp;: 10&nbsp;Mio par défaut, et un point d’accès qui attend davantage passe le sien, `request.decoded_body(limit)`. Un corps corrompu ou un encodage autre que gzip/identity donne `Cybertrain::BodyUndecodable`, un corps qui dépasserait la limite une fois décompressé `Cybertrain::BodyTooLarge`, deux `QueryInvalid` auxquelles il est répondu 400. `request.body` reste les octets tels qu’envoyés.

## Mettre à jour une application écrite pour 0.4

Ce qui change pour une application écrite pour 0.4 (la liste complète est la section 14 de [la conception](../superpowers/specs/2026-11-10-phase4-web-layer-design.md))&nbsp;:

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
- `allow_unauthenticated_access` est désormais une méthode du framework&nbsp;; celle que le générateur de 0.4 a écrite dans `ApplicationController` fonctionne toujours et l’emporte. Relancer `cybertrain generate authentication` ajoute la réinitialisation du mot de passe, le verrouillage, «&nbsp;rester connecté&nbsp;», la page de compte et les administrateurs, et affiche des diffs pour les fichiers que 0.4 a écrits ([Mettre à jour depuis 0.4](authentication.md#upgrading-from-04)).
- Chaque réponse porte `X-Request-Id`, et le `X-Request-Id` d’un proxy n’est utilisé que si le proxy est de confiance&nbsp;; chaque ligne de journal change de forme ([Mettre à jour les journaux et les rapports d’erreur depuis 0.4](background-and-operations.md#upgrading-logs-and-error-reports-from-04)).
