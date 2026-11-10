---
source_sha256: 378c380bd86a043bfdd256bb49608526e657c62c86a8ef0c691c0288e5b5bcb2
---
# Temps réel : des flux vers le navigateur

Poussez des changements vers les pages ouvertes sans rechargement&nbsp;: des
Turbo Streams sur Server-Sent Events ou WebSocket, une diffusion depuis une
action, un job ou un flux, et les mêmes flux pour votre propre JavaScript.

## Comment une diffusion atteint une page

Une page s’abonne à un ou plusieurs flux nommés&nbsp;; n’importe quelle partie
de l’application diffuse vers un flux par son nom&nbsp;; chaque page abonnée
reçoit le message en un dixième de seconde environ.

- **Les flux ont des noms.** Un nom est un texte court quelconque
  (`"alerts"`), ou un enregistrement, dont le nom est sa table et son id
  (`"articles:12"`, `Cybertrain::Stream.name_for(@article)`).
- **Une diffusion est une ligne.** `Cybertrain::Stream.broadcast(name, payload)`
  insère une ligne dans `cybertrain_messages`, une table que le framework crée
  lui-même dans la base de données de l’application. Dans une
  `DB.transaction`, le message ne part que si la transaction est validée.
  Parce que c’est une ligne, une diffusion fonctionne depuis tout processus
  qui partage la base&nbsp;: une requête, un job dans un processus `worker`,
  un callback de flux, une `Main.command`.
- **Chaque processus web interroge la table.** Un thread par processus
  `server` (le poller des flux) lit les nouvelles lignes toutes les
  `stream_poll_ms` (100&nbsp;ms) et remet chacune aux navigateurs que ce
  processus tient. Il supprime une fois par minute les lignes plus vieilles
  que `stream_retention` (60&nbsp;secondes).
- **Le navigateur se connecte à un seul point d’entrée**,
  `/cybertrain/stream`, en Server-Sent Events (`EventSource`) ou en
  WebSocket, avec un jeton signé qui nomme les flux qu’il a le droit de lire
  ([Noms de flux signés](#signed-stream-names)).

Il n’y a rien à démarrer&nbsp;: `./<app> server` fait tourner le poller et
sert le point d’entrée. `config.stream_path = ""` désactive toute la
fonctionnalité.

## Turbo Streams

[Turbo](https://turbo.hotwired.dev) met une page à jour à partir d’éléments
`<turbo-stream action="append" target="comments">`, comme le font les
applications Rails 8. Chargez Turbo dans le layout (il n’y a pas d’asset
pipeline&nbsp;: un CDN ou une copie dans `public/`), et abonnez une page avec
`turbo_stream_from`&nbsp;:

```erb app/views/layouts/application.html.erb (extrait)
<head>
  <%= csrf_meta_tags %>
  <script type="module" src="https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/dist/turbo.es2017-esm.js"></script>
</head>
```

```erb app/views/articles/show.html.erb (extrait)
<%= turbo_stream_from @article %>
<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render "comments/comment", comment: comment %>
  <% end %>
</div>
```

`turbo_stream_from` prend des Strings et des enregistrements, autant que
voulu, et écrit un seul élément `<turbo-stream-source>` dont l’URL porte un
seul jeton pour tous. Turbo l’ouvre comme un `EventSource`&nbsp;;
`turbo_stream_from @article, ws: true` donne à la place une URL `ws://`
(`wss://` derrière HTTPS), que Turbo ouvre comme un WebSocket. Dans les deux
cas, la page n’a besoin d’aucun JavaScript de votre part. Turbo ne rouvre
pas un WebSocket perdu (coupure réseau, redémarrage du serveur)&nbsp;: cette
page ne reçoit plus rien jusqu’à son rechargement, là où un `EventSource` se
reconnecte tout seul et rejoue ce qu’il a manqué. Gardez la valeur par défaut
sauf besoin de WebSocket, ou reconnectez depuis votre propre JavaScript
(`&after=`, ci-dessous).

Diffusez ensuite depuis l’action qui a changé quelque chose&nbsp;:

```ruby app/controllers/comments_controller.rb (extrait)
def create
  @comment = Comment.new(comment_params)
  @comment.article_id = @article.id
  if @comment.save
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           partial: "comments/comment", locals: { comment: @comment })
  end
  redirect_to article_path(@article), status: :see_other
end
```

`broadcast_append_to(stream, target:, ...)` rend le contenu, l’enveloppe dans
un élément `<turbo-stream>` et le diffuse. Le contenu est l’un de
`partial:` avec `locals:` (rendu par `Cybertrain::Views.render_partial`),
`component:` (un [composant de vue](template-language.md#components)) ou
`html:` (échappé sauf s’il s’agit d’une `SafeString`). La cible est un id
DOM, ou un enregistrement, dont l’id DOM est `dom_id(record)`
(`"comment_7"`). Les autres fonctionnent de la même façon&nbsp;:
`broadcast_replace_to`, `broadcast_update_to`, `broadcast_prepend_to`,
`broadcast_before_to`, `broadcast_after_to`,
`broadcast_remove_to(stream, target:)` et `broadcast_refresh_to(stream)`
(Turbo&nbsp;8 recharge la page avec le morphing).

Turbo transforme aussi les liens et les formulaires en requêtes fetch (Turbo
Drive). Le scaffold répond déjà comme Turbo l’attend&nbsp;: une redirection en
303 après un formulaire réussi, et 422 avec le formulaire à nouveau après un
échec.

### Répondre à un formulaire par un Turbo Stream

Un formulaire que Turbo soumet accepte `text/vnd.turbo-stream.html`. Pour
répondre par un flux plutôt que par une redirection, rendez l’élément
vous-même&nbsp;; `Cybertrain::Turbo` les construit (`replace`, `update`,
`append`, `prepend`, `before`, `after`, `remove`, `refresh`)&nbsp;:

```ruby
def destroy
  @comment = Comment.where(article_id: @article.id).find(params[:id])
  @comment.destroy
  if request.header("accept").to_s.include?("text/vnd.turbo-stream.html")
    render html: Cybertrain::Turbo.remove(@comment), content_type: "text/vnd.turbo-stream.html"
  else
    redirect_to article_path(@article), status: :see_other
  end
end
```

### Diffuser depuis un job, une tâche ou un flux

Une diffusion n’a besoin d’aucune requête, donc un job peut en rendre et en
envoyer une&nbsp;:

```ruby config/app.rb (extrait)
Cybertrain::Job.handle("price_refresh") do |payload|
  item = Item.find(Cybertrain::Cast.int(payload))
  item.refresh_price!
  Cybertrain::Stream.broadcast_replace_to("prices", target: item,
                                          partial: "items/price", locals: { item: item })
end
```

Le partial est rendu par `Cybertrain::Views.render_partial`, qui rend sans
requête&nbsp;: les helpers de chemin (`item_path(item)`) fonctionnent, et les
helpers qui ont besoin d’une requête (`csrf_token`, `params`, `flash`,
`request_path`, `*_url`) lèvent `Cybertrain::Views::OutsideRequest` (voir
[Rendre hors d’une requête](template-language.md#rendering-outside-a-request)).
Un job tourne dans un processus `worker` aussi bien que dans un serveur, et
la ligne qu’il écrit atteint les pages de tous les serveurs.

## Server-Sent Events depuis JavaScript

Pour une page que Turbo ne pilote pas (un graphique, un téléscripteur),
demandez les flux en JSON. `stream_source_path` donne le chemin du point
d’entrée avec le jeton et `mode=json`, et `signed_stream_name` le jeton
seul&nbsp;:

```erb app/views/dashboards/show.html.erb (extrait)
<div id="price" data-src="<%= stream_source_path "prices", "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("price");
  const source = new EventSource(el.dataset.src);
  source.addEventListener("prices", (event) => {
    const message = JSON.parse(event.data);   // {"stream":"prices","id":42,"data":"..."}
    el.textContent = JSON.parse(message.data).price;
  });
  source.addEventListener("alerts", (event) => console.log(JSON.parse(event.data).data));
</script>
```

En `mode=json`, chaque message est un événement nommé d’après son flux, dont
les données sont `{"stream": ..., "id": ..., "data": ...}` avec la charge
utile dans `data` (diffusez du JSON sous forme de String&nbsp;:
`Stream.broadcast("prices", JSON.generate({ "price" => 12.5 }))`). Dans le
`mode=raw` par défaut, la charge utile part telle quelle, comme un simple
événement `message`, ce que lit Turbo.

Le navigateur se reconnecte tout seul quand la connexion tombe, et envoie
l’id du dernier événement qu’il a vu (`Last-Event-ID`). Le point d’entrée
rejoue alors d’abord chaque message de ces flux dont l’id est plus grand et
qui est encore dans la table (dans la limite de `stream_retention`), si bien
que rien n’est perdu entre-temps. Une page absente plus longtemps devrait se
recharger. Avant l’arrivée de son premier événement, le navigateur n’a pas
d’id à envoyer&nbsp;: une connexion qui tombe dans cette fenêtre ne rejoue
rien, et ce que la page a rendu au chargement reste son état jusqu’à la
diffusion suivante. Une ligne de commentaire (`: ping`) part après 15&nbsp;secondes de
silence pour que les proxies gardent la connexion ouverte.

## WebSocket depuis JavaScript

La même URL répond à un WebSocket. Une page en tire une URL `ws://` ou
`wss://`. Passez le chemin et les jetons par des attributs `data-`, comme
ici&nbsp;: un `<%= %>` à l’intérieur d’un élément `<script>` est échappé en
HTML, et le navigateur ne le décode pas à cet endroit (`&amp;` atteindrait
le serveur).

```erb app/views/dashboards/show.html.erb (extrait)
<div id="ticker" data-src="<%= stream_source_path "prices" %>" data-alerts="<%= signed_stream_name "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("ticker");
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  const socket = new WebSocket(scheme + location.host + el.dataset.src);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.stream) console.log(message.stream, message.id, message.data);
  });
  socket.addEventListener("open", () => {
    socket.send(JSON.stringify({ subscribe: el.dataset.alerts }));
  });
</script>
```

Avec `mode=json`, chaque message est une trame texte qui contient la même
enveloppe `{"stream", "id", "data"}`, et la page peut changer de flux en
cours de connexion en envoyant une trame texte JSON&nbsp;:

| La page envoie | Le serveur répond |
| --- | --- |
| `{"subscribe":"<token>"}` | `{"subscribed":["prices","alerts"]}`&nbsp;: tous les flux que la connexion lit désormais |
| `{"unsubscribe":"<token>"}` | `{"unsubscribed":["alerts"]}` |
| un jeton qui ne se vérifie pas | `{"error":"bad token"}` |
| tout le reste | `{"error":"bad message"}` |

Une connexion en `mode=json` peut aussi s’ouvrir sans jeton et s’abonner par
message&nbsp;; celle qui ne lit toujours aucun flux au bout de 15&nbsp;secondes
est fermée (code 1008). Un WebSocket n’a pas de `Last-Event-ID`&nbsp;: pour
rattraper son retard après une reconnexion, ajoutez
`&after=<the last id you saw>` à l’URL. Le serveur envoie un ping après
chaque silence de 15&nbsp;secondes et répond aux pings&nbsp;; les trames
binaires de la page sont ignorées. Codes de fermeture&nbsp;: 1000 quand le
serveur s’arrête, 1008 pour un mauvais jeton, 1009 pour une trame au-delà de
`stream_max_message`, 1013 quand le processus est plein ou que la page a pris
trop de retard.

## Diffuser en continu depuis une action

Une action peut garder sa propre réponse ouverte, comme le fait
`ActionController::Live` de Rails&nbsp;: `stream` exécute le bloc après
l’action, sur le thread de la connexion, et lui donne le socket sous la forme
d’un `Cybertrain::Sink`.

```ruby app/controllers/reports_controller.rb (extrait)
def progress
  stream do |out|
    10.times do |i|
      out.write(Cybertrain::SSE.event(JSON.generate({ "done" => i * 10 }), event: "progress", id: i.to_s))
      break if out.wait_closed(1)   # vrai quand le client est parti
    end
  end
end
```

`stream(content_type: "text/event-stream", status: :ok)` répond avec
`Transfer-Encoding: chunked` et ferme la connexion quand le bloc rend la
main. `SSE.event(data, event: "", id: "", retry_ms: 0)` met en forme un
événement&nbsp;; `out.closed?` devient vrai une fois le client parti, et les
écritures suivantes ne font rien. Le bloc ne doit toucher ni à la session, ni
au flash, ni aux en-têtes&nbsp;: ils sont partis avec l’en-tête de la
réponse.

## Noms de flux signés

Une page ne peut lire un flux qu’avec un jeton qui le nomme. Le jeton est
formé des noms de flux et d’une signature HMAC-SHA256 faite avec une clé
dérivée de `secret_key_base` pour les seuls flux (comme
`turbo/signed_stream_verifier_key` dans Rails), si bien qu’un jeton n’est
jamais un cookie de session valide&nbsp;; le point d’entrée vérifie la signature et ne lit ni
la session ni la base de données. C’est le modèle de Turbo&nbsp;: qui pouvait
rendre la page pouvait lire ses flux. Les jetons n’expirent pas&nbsp;;
changer `secret_key_base` les invalide tous, et une page restée ouverte à
travers ce déploiement ne reçoit plus rien (un `EventSource` tient le 403
pour définitif) jusqu’à son rechargement.

<!-- list: points -->
- Un flux propre à un utilisateur est un flux nommé d’après
  l’enregistrement de cet utilisateur, `turbo_stream_from @user`
  (`"users:7"`), rendu seulement sur les pages de cet utilisateur.
  Quiconque obtient le jeton peut lire ce flux, tant que le secret ne change
  pas.
- Les jetons n’expirent pas. Changer `CYBERTRAIN_SECRET_KEY_BASE` invalide
  tous les jetons (et toutes les sessions).
- Le jeton voyage dans l’URL, donc le journal d’accès d’un reverse proxy
  l’enregistre. Le journal des requêtes du framework l’écrit `[FILTERED]`&nbsp;;
  désactivez la journalisation du proxy pour `/cybertrain/stream`, ou gardez
  ces journaux aussi privés que les flux.
- Un jeton invalide ou absent donne un 403 en SSE, et une fermeture en 1008
  juste après la poignée de main en WebSocket.
- Un nom fait de 1 à 200&nbsp;octets, sans caractère de contrôle ni
  virgule&nbsp;; un jeton porte au plus 16&nbsp;noms, une connexion au plus 64.

## Limites et réglages

Réglez-les dans `config/app.rb` (`c.stream_poll_ms = 250`)&nbsp;; le démarrage
s’arrête avec un message pour une valeur hors limites.

| Réglage | Défaut | Ce qu’il fait |
| --- | --- | --- |
| `stream_path` | `"/cybertrain/stream"` (`CYBERTRAIN_STREAM_PATH`) | Le chemin du point d’entrée&nbsp;; `""` désactive les flux |
| `stream_poll_ms` | `100` | La fréquence à laquelle chaque processus serveur lit les nouveaux messages (au moins 10) |
| `stream_retention` | `60` | Les secondes pendant lesquelles un message reste dans la table, et donc jusqu’où une reconnexion peut rattraper |
| `stream_ping_interval` | `15` | Les secondes de silence avant un ping&nbsp;; aussi le temps qu’une écriture vers un client peut attendre |
| `stream_max_connections` | `1000` | Flux ouverts par processus&nbsp;; au-delà, SSE reçoit 503 et WebSocket une fermeture en 1013 |
| `stream_max_message` | `65536` | Octets d’une trame WebSocket venant de la page (fermeture en 1009 au-delà) |
| `stream_max_backlog` | `1000` | Messages en attente pour un client lent avant qu’il soit lâché (il se reconnecte et rejoue) |

Chaque flux ouvert occupe une connexion, et son green thread, tant que la
page est ouverte. Derrière nginx, l’en-tête `X-Accel-Buffering: no` de la
réponse désactive la mise en tampon&nbsp;; pour WebSocket, le proxy doit
transmettre `Upgrade` et `Connection` (Caddy et kamal-proxy le font).

## Quel processus fait quoi

<!-- list: points -->
- **`./<app> server`** fait tourner le poller et le point d’entrée,
  toujours, même avec `CYBERTRAIN_WORKER=0`&nbsp;: il livre aux navigateurs
  qu’il tient. Tant que le poller ne tourne pas, le point d’entrée répond 503
  (`stream poller is not running`)&nbsp;; `serve` le démarre avant
  d’ouvrir le port, si bien qu’un processus servi ne le montre jamais.
- **`./<app> worker`** et **`./<app> feeds`** ne servent pas de HTTP et ne
  font tourner aucun poller. Leurs diffusions sont des lignes, que les
  serveurs livrent ([Rôles des processus](background-and-operations.md#process-roles)).
- Plusieurs serveurs sur une même base livrent chacun chaque message à leurs
  propres navigateurs, dans le même ordre et avec les mêmes ids.

Tester le flux d’une page&nbsp;: [Tester les flux et les
composants](testing.md#testing-streams-and-components). La
conception&nbsp;: [docs/design.md](../design.md) D36 et D37.

## Santé des flux

Un [flux WebSocket](external-services.md#consuming-websocket-feeds) tourne
souvent dans un processus `feeds`, qui ne sert pas de HTTP&nbsp;; sa santé
passe donc par la base&nbsp;: le superviseur de chaque processus qui exécute
des flux écrit une ligne par abonnement dans `cybertrain_feeds` toutes les
`feed_status_interval` secondes (10). La table appartient au framework (créée
à la première utilisation, laissée hors de `db/schema.rb`). `GET /up` dans un
processus `server` la lit et répond `503 feed stale` quand, pour une ligne
quelconque&nbsp;:

<!-- list: points -->
- l’éditeur est périmé&nbsp;: la ligne a été écrite pour la dernière fois il
  y a plus de `health_feed_stale` secondes (180,
  `CYBERTRAIN_HEALTH_FEED_STALE`), donc le processus qui exécute le flux est
  mort, bloqué ou a perdu sa base&nbsp;; ou
- le flux est silencieux&nbsp;: la ligne est récente, mais le flux n’a ni livré
  de message ni répondu à un ping depuis aussi longtemps (un flux qui n’a
  jamais rien reçu compte depuis son démarrage).

Les deux sont vérifiés séparément, si bien qu’un éditeur vivant ne cache
jamais un flux silencieux. `CYBERTRAIN_HEALTH_FEEDS=0` (ou `false`) désactive
ce contrôle, pour un flux légitimement calme plus longtemps que le seuil ou
un déploiement qui surveille ses flux autrement. Une table illisible laisse
`/up` à 200 et journalise une seule ligne `[WARN]` jusqu’à ce qu’elle soit de
nouveau lisible.

`./<app> feeds status` affiche les lignes pour un opérateur, une ligne par
flux&nbsp;:

```console
$ ./blog feeds status
trades  connected  web-1:4242  last activity 3s ago  restarts 0  updated 4s ago
```

<!-- list: points -->
- Une ligne a pour clé le seul nom du flux&nbsp;: deux processus qui exécutent
  le même flux écrasent mutuellement leur ligne, raison de plus pour
  exécuter chaque flux dans un seul processus.
- Un flux que vous supprimez ou renommez laisse sa ligne, et `/up` la
  signale périmée une fois qu’elle est vieille&nbsp;: supprimez la ligne
  (`./<app> dbconsole`, puis `DELETE FROM cybertrain_feeds WHERE name =
  'trades';`).
- Un flux nommé `status` ne peut pas être démarré seul avec
  `./<app> feeds status`, qui affiche la table à la place&nbsp;;
  `./<app> feeds` (tous les flux) l’exécute quand même.
- `/up` ne redémarre rien. Kamal ne l’interroge que pour le rôle web
  pendant un déploiement, et Docker redémarre un conteneur quand son
  processus se termine, ce que fait un processus `feeds` après des morts
  répétées d’un flux&nbsp;; donnez au rôle une politique de redémarrage
  ([Rôles des processus](background-and-operations.md#process-roles)).

La conception&nbsp;: [docs/design.md](../design.md) D56.
