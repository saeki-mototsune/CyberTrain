---
source_sha256: 8bf1e8b4b6f49c71977f7962ba570bf0d29cc5af86a5dd089c93108a8e865203
---
# HTTP sortant, flux WebSocket et e-mail

## HTTP sortant

Une application qui appelle un autre serveur (un webhook, un webhook entrant
Slack, une API tierce) utilise `Cybertrain::HttpClient`. Il n’est pas inclus
dans `require "cybertrain"`&nbsp;; requérez-le là où il est utilisé, ainsi que la
couche TLS dès qu’une URL est en https&nbsp;:

```ruby
require "json"
require "cybertrain/http_client"
require "cybertrain/net/tls"   # uniquement pour https:// ; lie la libssl du système

client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15, max_body: 1 << 20)
begin
  res = client.post(ENV["SLACK_WEBHOOK_URL"], JSON.generate({ "text" => "Deployed" }),
                    content_type: "application/json")
  Cybertrain.logger.warn("slack answered #{res.status}") unless res.success?
rescue Cybertrain::HttpClient::Error => e
  Cybertrain.logger.warn("slack: #{e.message}")   # nomme hôte:port, jamais le chemin
end

res = client.get("https://api.example.com/v1/status", headers: { "Authorization" => "Bearer #{token}" })
res.status              # 200
res.header("ETag")      # noms dans n’importe quelle casse ; res.headers les a en minuscules
res.body                # les octets, codage chunked retiré
```

Pourquoi il existe&nbsp;: le `Net::HTTP` de Spinel effectue la poignée de main
TLS et chaque lecture après le premier octet par des appels C bloquants, et
chacun occupe un worker OS — qui, avec le `SPINEL_WORKERS=1` par défaut, est le
serveur web tout entier — aussi longtemps qu’il plaît à un point d’accès qui ne
répond plus. `HttpClient` ne bloque jamais un worker sur le réseau&nbsp;:

- **Chaque attente est bornée.** La connexion (un connect non bloquant&nbsp;; le
  `TCPSocket.new` de Spinel ignore `connect_timeout:`), chaque étape de la
  poignée de main TLS, chaque lecture et chaque écriture attendent au plus
  `timeout` secondes (5 par défaut), et la requête entière au plus `deadline`
  secondes (15 par défaut). Au-delà de l’une ou l’autre,
  `HttpClient::TimeoutError`. Les lectures passent par un tampon d’octets
  alimenté par `read_nonblock`, donc les octets déjà reçus ne sont jamais
  attendus.
- **La résolution de noms bloque.** `getaddrinfo` n’a pas de forme non
  bloquante dans le runtime&nbsp;: le thread qui fait la requête attend le DNS
  (en général quelques millisecondes, mais un résolveur mort peut prendre le
  délai du système, environ 5&nbsp;s par tentative). Le délai `deadline` compte
  ce temps mais ne peut pas l’interrompre.
- **Les destinations non publiques sont refusées** avant tout envoi&nbsp;:
  loopback (`127.0.0.0/8`, `::1`), privées (`10/8`, `172.16/12`,
  `192.168/16`, `fc00::/7`), lien local (`169.254/16`, qui inclut les services
  de métadonnées des clouds, `fe80::/10`), non spécifiées (`0.0.0.0/8`, `::`),
  multicast, broadcast, CGNAT (`100.64/10`), les plages réservées à la
  documentation et aux bancs d’essai, ainsi que les formes IPv4-mappées, NAT64
  et 6to4 de celles-ci (`Cybertrain::Net::Address.blocked_reason`). Le nom
  d’hôte est résolu une seule fois, et ce sont les adresses obtenues qui sont
  vérifiées et appelées (rien n’est résolu à nouveau), de sorte qu’un nom qui se
  résout en adresse privée (une entrée de `/etc/hosts`, un DNS rebinding) est
  refusé comme l’adresse littérale&nbsp;; le certificat TLS est tout de même
  vérifié par rapport au nom. La vérification se fait par adresse&nbsp;: une
  adresse refusée est sautée, et la requête n’échoue que lorsque toutes les
  adresses sont refusées. `HttpClient::BlockedAddressError` en donne la raison.
  Pour appeler un service de votre propre réseau, ou un serveur local dans un
  test, définissez `c.http_allow_private =
  true` dans `config/app.rb` (ou `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`), ou passez
  `allow_private: true` à `HttpClient.new`&nbsp;; laissez-le désactivé dès
  qu’une URL peut venir d’un utilisateur.
- **Chaque adresse résolue est essayée**, dans l’ordre donné par le résolveur,
  IPv6 comme IPv4&nbsp;: quand l’une refuse, est injoignable, réinitialise la
  connexion ou ne répond pas dans le délai `timeout`, la suivante est appelée,
  toutes dans le délai `deadline`, et quand toutes échouent, l’erreur de la
  dernière est levée. C’est ce qui fait fonctionner `localhost` sous macOS, où
  il se résout d’abord en `::1`, ce que refuse un serveur qui écoute sur
  `127.0.0.1`. `Cybertrain::Mailer` se connecte de la même façon.
- **Le TLS** est celui du paquet openssl&nbsp;: `VERIFY_PEER` par rapport au
  magasin de certificats du système d’exploitation (`SSL_CERT_FILE` /
  `SSL_CERT_DIR` le redirigent ailleurs&nbsp;; le paquet n’a pas de
  `X509::Store` pour un magasin personnalisé), vérification du nom d’hôte, SNI,
  TLS 1.2 ou plus récent. Une URL https demande un nom d’hôte&nbsp;: une adresse
  IP ne correspond pas au nom d’un certificat. Sans `require
  "cybertrain/net/tls"`, une requête https lève `HttpClient::TLSError` qui le
  signale&nbsp;; `cybertrain/http_client` seul ne lie jamais libssl.
- **Un client de notification et d’API, pas un navigateur&nbsp;:** HTTP/1.1
  avec `Connection: close`, une connexion par requête, ni keep-alive, des
  redirections seulement sur demande (ci-dessous), ni proxy, ni cookies. Les réponses
  peuvent être en `Content-Length`, en chunked ou lues jusqu’à la fermeture&nbsp;;
  les en-têtes sont plafonnés à 64&nbsp;Kio et 100 lignes, le corps à
  `max_body` (1&nbsp;Mio par défaut), au-delà de quoi
  `HttpClient::TooLargeError`. Une réponse qui n’est pas du HTTP/1.x, ou qui se
  termine trop tôt, donne `HttpClient::BadResponseError`&nbsp;; une connexion
  refusée ou réinitialisée, ou un nom qui ne se résout pas,
  `HttpClient::RefusedError`. Une connexion réinitialisée ou fermée pendant la
  poignée de main TLS (un serveur qui ne parle pas TLS) donne
  `HttpClient::TLSError` («&nbsp;TLS handshake failed&nbsp;») sur toutes les
  plateformes, comme une poignée de main qu’OpenSSL rejette. Toutes sont des
  `HttpClient::Error`.
- **Les erreurs ne contiennent jamais le chemin ni la requête**, là où une URL
  de webhook porte son secret&nbsp;: les messages ne nomment que l’hôte et le
  port. Une URL mal formée ou un en-tête contenant CR/LF est une
  `ArgumentError` qui ne la répète pas non plus. `Host`, `Connection`,
  `Content-Length` et `Transfer-Encoding` appartiennent au client&nbsp;;
  `User-Agent` vaut `cybertrain/<version>` par défaut.

La requête s’exécute sur le thread appelant, un green thread comme la requête
en cours de service, donc les autres connexions continuent d’être servies
pendant qu’elle attend. La couche socket (`cybertrain/net/socket.rb`&nbsp;:
connect borné, lectures tamponnées, écritures bornées) est séparée de la couche
HTTP pour que d’autres protocoles puissent l’utiliser. La
conception&nbsp;: [docs/design.md](../design.md) D24 et D55.

### Verbes, JSON et redirections

```ruby
client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15, redirects: 3)
res = client.request("PATCH", "https://api.example.com/v1/items/7",
                     body: JSON.generate({ "done" => true }), content_type: "application/json")
res = client.request("DELETE", "https://api.example.com/v1/items/7")
item = client.get("https://api.example.com/v1/items/7").json_hash   # {} quand le corps n’est pas un objet JSON
list = client.get("https://api.example.com/v1/items").json_array    # [] quand ce n’est pas un tableau JSON
```

- **`request(verb, url, body:, content_type:, headers:)`** envoie GET,
  POST, PUT, PATCH, DELETE ou HEAD&nbsp;; `get` et `post` restent les formes
  courantes. POST, PUT et PATCH portent toujours leur corps, DELETE seulement
  s’il n’est pas vide, GET et HEAD aucun (un corps y est une
  `ArgumentError`)&nbsp;; une réponse à HEAD n’a pas de corps.
  `Response#json_hash` et `#json_array` analysent le corps et renvoient `{}`
  ou `[]` pour tout autre contenu.
- **Les redirections** ne sont suivies que sur demande&nbsp;: `redirects: 3`
  suit jusqu’à trois `301`, `302`, `303`, `307` ou `308` munies d’un
  `Location` (un `Location` relatif se résout par rapport à l’URL courante),
  et la suivante lève `HttpClient::TooManyRedirectsError`. La valeur par
  défaut, `0`, renvoie une 3xx telle quelle. Chaque saut est vérifié comme le
  premier (adresses non publiques refusées), un saut de https vers http est
  une `BlockedAddressError`, une `303` (et une `301` ou `302` qui répond à un
  POST) devient un GET sans corps, et le `deadline` couvre tous les sauts
  ensemble. Les en-têtes `Authorization`, `Cookie` et `Proxy-Authorization`
  ne sont pas envoyés à une autre origine (schéma, hôte ou port), comme le
  font les navigateurs et curl. Un `Location` qui n’est pas une URL http(s)
  en ASCII simple est une `BadResponseError`.

### Réponses en flux et volumineuses

Avec un bloc, le corps n’est pas conservé&nbsp;: chaque morceau est passé au
bloc dès son arrivée (une trame chunked, jusqu’à 1&nbsp;Mio à la fois, ou ce
qu’a livré une lecture) et la `Response` revient avec un corps vide.
`max_body` ne s’applique pas alors&nbsp;; `timeout` et `deadline`, si, donc
donnez un long `deadline:` à un long flux. `get_to_file` écrit le flux dans
un fichier&nbsp;:

```ruby
client = Cybertrain::HttpClient.new(deadline: 600, redirects: 3)
client.get("https://example.com/export.ndjson") { |chunk| Importer.feed(chunk) }

res = client.get_to_file("https://example.com/dump.csv", "tmp/dump.csv")
Cybertrain.logger.info("#{res.bytes_written} bytes") if res.success?
```

- Un corps 2xx est écrit dans `path.part` au fil de son arrivée et renommé
  en `path` une fois complet, si bien qu’un téléchargement de 78&nbsp;Mo ne
  séjourne jamais en mémoire et qu’un lecteur ne voit jamais un demi-fichier.
  Tout autre statut final (une page 404, une 503) n’atteint jamais le
  disque&nbsp;: vérifiez `res.success?`, `path` reste tel quel. En cas d’erreur,
  le `.part` est supprimé. Un corps 2xx vide (un `204`) remplace bien le
  fichier par un fichier vide.
- Une exception levée par le bloc parvient telle quelle à l’appelant.

### gzip

Le client demande et décompresse les corps gzip quand le support gzip est
chargé&nbsp;: `require "cybertrain"` le charge, donc dans une application
chaque requête envoie `Accept-Encoding: gzip` (sauf si vous envoyez votre
propre en-tête `Accept-Encoding`) et un corps `Content-Encoding: gzip`
revient décompressé. Un programme qui ne requiert que
`cybertrain/http_client` ajoute `require "cybertrain/http/gzip_ffi"` (il lie
zlib)&nbsp;; sans lui, une réponse gzip est une `BadResponseError` qui nomme ce
fichier. Un corps conservé est limité par `max_body` sur le fil et une fois
décompressé (`TooLargeError` au-delà)&nbsp;; un corps en flux est décompressé
morceau par morceau, 64&nbsp;Kio au plus chacun, sans limite totale, comme un
corps en flux non compressé. Les en-têtes de la `Response` sont ceux reçus&nbsp;:
`Content-Encoding: gzip` et le `Content-Length` du fil restent alors que
`body` est le texte décompressé. Tout autre `Content-Encoding` (`br`,
`deflate`) est une `BadResponseError`&nbsp;; un corps gzip tronqué ou corrompu
en est une aussi.

### Server-Sent Events

`Cybertrain::Sse::Parser` transforme les morceaux d’une réponse
`text/event-stream` en flux en événements (il n’est pas dans
`require "cybertrain"`)&nbsp;:

```ruby
require "cybertrain/sse"

parser = Cybertrain::Sse::Parser.new
client = Cybertrain::HttpClient.new(deadline: 180)   # tout le flux doit tenir dans le deadline
client.request("POST", "https://api.example.com/v1/chat", body: payload, content_type: "application/json") do |chunk|
  parser.feed(chunk) { |event| Answer.append(event.event_data) unless event.event_data == "[DONE]" }
end
parser.finish { |event| Answer.append(event.event_data) }   # un dernier événement que le flux n’a pas terminé par une ligne vide
```

- Chaque `Sse::Event` a `event_name` (`"message"` quand le flux n’en envoie
  pas), `event_data` (les lignes `data:` jointes par un saut de ligne),
  `event_id` (le dernier `id:` envoyé par le flux, qui se reporte sur les
  événements suivants) et `event_retry_ms` (un `retry:` donné depuis
  l’événement précédent, 0 sinon).
- Le parseur suit les règles du WHATWG&nbsp;: les lignes se terminent par CR,
  LF ou CRLF, coupées n’importe où entre deux morceaux&nbsp;; une ligne qui
  commence par `:` est un commentaire&nbsp;; une ligne vide distribue
  l’événement s’il avait des données. `finish` passe au bloc un événement
  resté inachevé à la fin du flux.
- Il ne fixe aucune limite à une ligne ou à un événement&nbsp;: le `deadline`
  de la requête borne le flux dans le temps, pas en mémoire. Des morceaux
  binaires donnent un `event_data` binaire&nbsp;; fixez l’encodage vous-même.

## Consommer des flux WebSocket

Une application qui écoute un flux extérieur (cotations de marché, télémétrie
d’appareils, flux d’événements) pendant que le serveur tourne s’y abonne avec
`Cybertrain::WebSocket.subscribe`. Comme le client HTTP, il n’est pas inclus
dans `require "cybertrain"`&nbsp;; requérez-le là où l’abonnement est écrit,
ainsi que la couche TLS pour `wss://`. Il charge le sous-système des feeds (le
rôle `feeds`, le contrôle de santé des feeds), donc une application sur
`cybertrain/core` n’a besoin d’aucune autre ligne&nbsp;:

```ruby
# config/app.rb (ou un fichier que bin/<app>.rb requiert avant Cybertrain::Main.run)
require "json"
require "cybertrain/websocket"
require "cybertrain/net/tls"   # uniquement pour wss:// ; lie la libssl du système

Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"],
    headers: { "Authorization" => "Bearer #{ENV["FEED_TOKEN"]}" },
    stale_after: 30)
  .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe", "channel" => "trades" })) }
  .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
```

Requérir `cybertrain/websocket` enregistre les flux auprès de
`Cybertrain::Background`, que `Application#serve` démarre après le scheduler et
arrête à l’extinction&nbsp;: il n’y a donc rien à appeler. Chaque abonnement
reçoit un thread. Celui-ci se connecte, exécute `on_open` (envoyez-y votre
message d’abonnement&nbsp;: il s’exécute de nouveau après chaque reconnexion),
puis passe chaque message à `on_message` avec la `Connection` (`send_text`,
`send_binary`, `close`, et `last_opcode`, `:text` ou `:binary`). Les blocs
reçoivent leurs arguments et ne peuvent pas utiliser `self` (Spinel n’a pas
d’`instance_eval`).

- **Quand ils s’exécutent.** Les flux démarrent quand le binaire sert, comme le
  scheduler ([Tâches de fond](background-and-operations.md#background-work))&nbsp;;
  les commandes `migrate`, `db ...`, `Main.command` et
  `Cybertrain::Test::Client` ne les démarrent jamais. `./<app> feeds [NAME...]`
  les fait tourner dans un processus à part, tous ou ceux nommés ([Rôles des
  processus](background-and-operations.md#process-roles)). Avec
  `CYBERTRAIN_WORKER=0` (`config.worker = false`), ils ne tournent pas dans ce
  processus (ils ne démarrent tout simplement pas&nbsp;; le seul signalement est
  la ligne «&nbsp;run elsewhere&nbsp;» du scheduler, et `WebSocket.start!`
  appelé directement journalise la sienne)&nbsp;: désactivez-le dans tous les
  processus sauf un quand plusieurs servent, sinon chacun reçoit le flux entier.
  `subscribe` doit être appelé avant le démarrage du serveur&nbsp;; on ne peut
  ni ajouter ni retirer un flux pendant qu’il tourne. Un nom est unique
  (`ArgumentError`), et un flux sans `on_message` fait échouer le démarrage
  avant que le port soit lié
  (`error: WebSocket subscription "trades" has no on_message`, code de
  sortie 1).
- **Options.** `headers:` (en-têtes supplémentaires de la poignée de main),
  `timeout:` (5 secondes par attente pendant la connexion et par écriture),
  `max_message:` (1&nbsp;Mio&nbsp;; un message plus grand ferme la connexion
  avec 1009), `ping_interval:` (15) et `stale_after:` (45), et
  `allow_private:` (comme pour `HttpClient`, ci-dessous).
- **Attente et reconnexion.** Après tout échec, le thread attend
  `min(60, 2 ** (attempt - 1))` secondes, avec 20&nbsp;% de gigue dans un sens
  ou dans l’autre&nbsp;: 1, 2, 4, ... 60. Une connexion qui a duré 60 secondes
  repart de 1. Chaque attente est bornée. `WebSocket.stop!` rend la main en
  2 secondes environ, quoi que fassent les serveurs&nbsp;: il attend au plus
  2 secondes pour l’ensemble des threads, un flux connecté envoie une fermeture
  (1000) et attend au plus 1 seconde la réponse du serveur, et le `connected?`
  de chaque flux est faux dès qu’il a rendu la main (un thread encore en train
  de fermer termine de lui-même).
- **Silence.** Un flux peut devenir muet sans jamais fermer la connexion&nbsp;:
  le thread envoie donc un ping après `ping_interval` secondes sans aucune
  trame (puis une fois par intervalle), et quand aucune trame, pong compris,
  n’est arrivée depuis `stale_after` secondes, il ferme la connexion et se
  reconnecte. `stale_after` doit être supérieur à `ping_interval`, qui doit
  valoir au moins 1 (`ArgumentError` levée par `subscribe`).
- **Erreurs dans vos blocs.** Une exception dans `on_message` est journalisée
  et la connexion reste ouverte. Une exception dans `on_open` est journalisée,
  et la connexion est fermée puis retentée, puisqu’un flux qui ne s’est pas
  abonné ne sert à rien.
- **Minuteries.** `.on_tick(seconds) { |conn| ... }` exécute un bloc toutes
  les `seconds` (un Integer, au moins 1) sur le thread du flux, entre ses
  attentes d’une seconde, que le flux soit connecté ou non&nbsp;: `conn` est la
  `Connection` tant qu’il est connecté et `nil` sinon, donc testez-le. Le
  premier appel a lieu `seconds` après le démarrage du flux&nbsp;; une
  exception est journalisée et le flux continue. Le travail qui appartient
  au flux (écrire chaque seconde ce que `on_message` a accumulé en mémoire,
  clore une bougie d’une minute) va ici, sans verrou ni tâche planifiée. Un
  seul `on_tick` par abonnement.

  ```ruby
  BUFFER = Array.new(0) { "" }   # une constante : les blocs ne voient pas les variables locales

  Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"])
    .on_message { |conn, text| BUFFER << text }
    .on_tick(1) { |conn| Trades.flush(BUFFER) }   # le code de l’app : un INSERT du lot, puis BUFFER.clear
  ```
- **Redémarrages.** Un thread superviseur vérifie chaque seconde que le
  thread de chaque flux est vivant. Un thread qui s’est terminé malgré tout
  (une exception qui n’est pas une `StandardError`, ou le runtime qui l’a
  tué) est journalisé (`[ERROR] WebSocket "trades" thread ended: ...`) et
  redémarré après `min(30, 2 ** restarts)` secondes, avec une ligne
  `[WARN]`&nbsp;; sa connexion ouverte est d’abord fermée. Le compteur de
  redémarrages ne se remet jamais à zéro, si bien qu’après cinq redémarrages
  l’attente reste de 30 secondes. Dans un processus `feeds`, un flux qui
  meurt encore après `feed_restart_limit` redémarrages (10,
  `CYBERTRAIN_FEED_RESTART_LIMIT`) en `feed_restart_window` secondes (600,
  `CYBERTRAIN_FEED_RESTART_WINDOW`) met fin au processus&nbsp;: `[FATAL] feed
  trades restarted 10 times in 600 s; exiting`, puis tous les flux sont
  arrêtés et le processus se termine avec le statut 1, pour que le
  `restart: unless-stopped` de Docker ou le `Restart=always` de systemd en
  démarre un nouveau. Un `server` qui exécute des flux ne se termine jamais à
  cause d’eux&nbsp;: il continue de les redémarrer, et `/up` signale
  `feed stale`. Une erreur dans le superviseur lui-même (une base disparue
  pendant qu’il écrivait les lignes d’état) est journalisée et la
  supervision continue.
- **Ce qui est journalisé.**

  | Quand | Niveau | Ligne |
  | --- | --- | --- |
  | démarrage | INFO | `WebSocket started: trades (wss://feed.example.com:443)` |
  | connecté | INFO | `WebSocket "trades" connected to feed.example.com:443` |
  | déconnecté | WARN | `WebSocket "trades" disconnected: Cybertrain::WebSocket::ClosedError: feed.example.com:443: closed by the server (1001) (retry in 2s)` |
  | silencieux | WARN | `WebSocket "trades" silent for 45s; reconnecting` |
  | un bloc a levé une exception | ERROR | `WebSocket "trades" on_message failed: KeyError: ...` (ou `on_open`) |

  Le chemin et la chaîne de requête ne sont jamais journalisés ni placés dans
  un message d’erreur&nbsp;: ils portent souvent un jeton.
- **Erreurs.** Toutes sont des `Cybertrain::WebSocket::Error`, avec seulement
  l’hôte et le port dans le message. Une fois la poignée de main faite, une
  connexion perdue ou une fermeture par le serveur est une `ClosedError`
  (`close_code`, `close_reason`&nbsp;; une réinitialisation ou une fin sans
  trame de fermeture donne 1006)&nbsp;; une écriture qui expire ou échoue en TLS
  reste une `TimeoutError` ou une `TLSError`. Pendant la connexion, c’est
  `RefusedError`, `TimeoutError`, `TLSError`, `BlockedAddressError` (une adresse
  non publique, refusée par défaut exactement comme dans
  [HTTP sortant](#outbound-http), avec le même réglage `allow_private:` et
  `http_allow_private`) ou `HandshakeError` (pas une 101, un
  `Sec-WebSocket-Accept` erroné, ou un serveur qui répond avec une extension ou
  un sous-protocole). `ProtocolError` (le serveur a enfreint le format des
  trames&nbsp;; le client envoie 1002) et `TooLargeError` peuvent survenir à
  tout moment.
- **Santé.** `Cybertrain::WebSocket.feed_status("trades")` renvoie un
  `Status`&nbsp;: `connected?`, `last_message_at` (secondes epoch, 0 avant le
  premier message), `reconnects`, `restarts` (par le superviseur) et
  `thread_alive?`, lus l’un après l’autre, pas comme un seul
  instantané&nbsp;; `connected?` devient vrai quand la connexion est établie,
  avant que `on_open` ne se soit exécuté. Le superviseur écrit aussi l’état
  de chaque flux dans la base toutes les `feed_status_interval` secondes
  (10), ce que lisent `GET /up` et `./<app> feeds status`, dans ce processus
  ou dans un autre&nbsp;: [Santé des flux](realtime.md#feed-health).
- **Gardez `on_message` court.** Le thread attend avec `wait_readable` ou
  `sleep`, donc un flux muet n’occupe pas de worker OS pendant qu’il attend.
  Deux choses en occupent un&nbsp;: chaque tentative de connexion résout le nom
  d’hôte avec un `getaddrinfo` bloquant (voir «&nbsp;La résolution de noms
  bloque&nbsp;» dans [HTTP
  sortant](#outbound-http)&nbsp;; avec `SPINEL_WORKERS=1`, un résolveur mort
  bloque chaque requête pendant le délai du résolveur, une fois par tentative et
  par flux, et une adresse IP dans l’URL évite la résolution), et un appel
  SQLite dans `on_message`, jusqu’à ce qu’il rende la main, comme dans une
  tâche planifiée ([Tâches
  de fond](background-and-operations.md#background-work))&nbsp;: avec
  `SPINEL_WORKERS=1`, une longue écriture bloque chaque requête. Pour un flux
  chargé, insérez une petite ligne, ou rassemblez les messages en mémoire et
  écrivez-les par lots depuis une tâche `Scheduler.every`.
- **Non développé.** Les extensions (`permessage-deflate`) et les
  sous-protocoles ne sont pas négociés. Il n’y a ni proxy, ni redirections, ni
  cookies, ni enregistrement automatique des messages (les navigateurs ont
  leur propre point d’entrée&nbsp;: [Temps réel](realtime.md)). La validité UTF-8 des trames texte n’est pas vérifiée (un
  écart par rapport à la section 8.1 de la RFC 6455)&nbsp;: les octets sont
  transmis tels qu’ils sont arrivés. La `Connection` n’est valide que pendant
  le callback&nbsp;; envoyer depuis une requête ou une tâche n’est pas pris en
  charge.

Pour une seule connexion sans la boucle de reconnexion (un script, une lecture
ponctuelle), utilisez le client synchrone&nbsp;:

```ruby
require "cybertrain/websocket"
require "cybertrain/net/tls"   # uniquement pour wss://

client = Cybertrain::WebSocket::Client.connect("wss://feed.example.com/v1", timeout: 5)
client.send_text("hello")
msg = client.receive(10)      # attend 10 s au plus ; nil si rien n’est arrivé
msg.ws_opcode                 # :text ou :binary
msg.ws_data                   # les octets
client.close
```

La conception&nbsp;: [docs/design.md](../design.md) D33 et D56.

## Envoyer des e-mails

`Cybertrain::Mailer` envoie des e-mails, en texte brut ou avec une partie
HTML, via un serveur SMTP (le serveur de soumission de votre fournisseur, ou
un relais local), tout de suite (`deliver`) ou depuis un job
(`deliver_later`, ci-dessous). `require "cybertrain"` le charge&nbsp;; une
application sur `cybertrain/core`, ou un programme sans le framework, requiert
`cybertrain/mailer` (qui n’a pas besoin de base de données&nbsp;:
`deliver_later` est dans `cybertrain/mailer/later`, qui charge aussi les jobs).
Le TLS se requiert séparément&nbsp;:

```ruby
require "cybertrain/mailer"
require "cybertrain/net/tls"   # pour starttls (par défaut) et tls ; lie la libssl du système

# Réglages issus de CYBERTRAIN_SMTP_HOST, _PORT, _USER, _PASSWORD, _FROM, _TLS :
begin
  Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello #{user.name},\n...")
rescue Cybertrain::Mailer::Error => e
  Cybertrain.logger.warn("mail: #{e.message}")   # ne contient jamais le mot de passe
end

# Ou des réglages explicites, sans passer par Config :
mailer = Cybertrain::Mailer.new(host: "smtp.example.com", port: 587, tls: "starttls",
                                user: "app", password: ENV["SMTP_PASSWORD"].to_s,
                                from: "noreply@example.com", timeout: 10, deadline: 60)
mailer.deliver(to: "a@example.com, b@example.com", subject: "Report", body: report)
```

| Variable | Attribut | Par défaut |
| --- | --- | --- |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""` (`Mailer.new` lève `ArgumentError` tant qu’il n’est pas défini) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`&nbsp;: 587 pour `starttls`, 465 pour `tls`, 25 pour `none` |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`&nbsp;: pas d’AUTH |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""` (secret) |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`&nbsp;; `tls` ou `none` |

- **Modes TLS.** `starttls` se connecte en clair, exige que le serveur propose
  STARTTLS (sinon `Mailer::TLSError`) et passe en TLS avant de dire quoi que ce
  soit d’autre&nbsp;; les octets que le serveur envoie après sa réponse à
  STARTTLS sont refusés. `tls` parle TLS dès le premier octet (port 465). Les
  deux vérifient le certificat par rapport à `host` comme le fait le client HTTP
  (donnez un nom d’hôte, pas une adresse IP), et les deux demandent
  `require "cybertrain/net/tls"`&nbsp;: sans lui, `deliver` lève
  `Mailer::TLSError` qui le signale, avant de se connecter. `none` est du texte
  en clair, pour un relais sur la même machine ou un serveur de test&nbsp;: avec
  un utilisateur configuré, il refuse (`Mailer::InsecureError`, avant de se
  connecter) sauf si l’hôte se résout en une adresse de loopback, et
  n’appelle alors que ses adresses de loopback.
- **Le mot de passe n’est jamais journalisé ni affiché.** Il n’apparaît ni dans
  la bannière de démarrage, ni dans `help`, ni dans le journal, ni dans aucun
  message d’erreur&nbsp;; il n’est envoyé qu’à l’intérieur de la commande AUTH
  PLAIN, par TLS (ou vers le loopback). Ne faites pas de `p` ni d’`inspect` sur
  un `Mailer` ou sur le `Config`, qui le contiennent.
- **Chaque attente est bornée**, comme dans [HTTP sortant](#outbound-http)&nbsp;:
  la connexion, chaque étape TLS et chaque réponse attendent au plus `timeout`
  secondes (10 par défaut), la remise entière au plus `deadline` secondes
  (60 par défaut), sinon `Mailer::TimeoutError`. La résolution de noms bloque
  le thread appelant.
- **Le dialogue&nbsp;:** le message d’accueil 220, `EHLO` (le nom est
  `helo:`, `localhost` par défaut), `STARTTLS` puis de nouveau `EHLO`,
  `AUTH PLAIN` quand un utilisateur est défini (le serveur doit proposer
  PLAIN), `MAIL FROM`, un `RCPT TO` par destinataire, `DATA`, `QUIT`. Une
  réponse avec un autre code est une `Mailer::RejectedError` dont le
  `smtp_code` est celui du serveur (421, 535, 550, ...) et dont le message
  contient l’étape et le texte du serveur. La valeur de retour est la réponse
  du serveur au message (`"250 2.0.0 Ok: queued
  as ..."`).
- **Le message&nbsp;:** `Date`, `From`, `To`, `Subject`, `MIME-Version: 1.0`,
  `Content-Type: text/plain; charset=UTF-8` (pour un message HTML, voir
  plus bas). Un sujet non ASCII est encodé selon
  la RFC 2047 (`=?UTF-8?B?...?=`, découpé entre les caractères). Les fins de
  ligne du corps deviennent CRLF et les lignes qui commencent par `.` sont
  protégées par dot-stuffing. Son `Content-Transfer-Encoding` est `7bit` pour
  l’ASCII, `8bit` (avec `MAIL FROM
  ... BODY=8BITMIME`) pour l’UTF-8 quand le serveur annonce 8BITMIME, et
  `base64` sinon ou quand une ligne dépasse 998 octets. Aucun `Message-ID`
  n’est ajouté (les serveurs de soumission en ajoutent un).
- **Ce qui est refusé** avec une `ArgumentError`, avant la connexion&nbsp;: une
  adresse qui n’est pas un simple `local@domain` en ASCII (pas de nom affiché,
  pas de `<>`, d’espaces, de virgules, de guillemets, de CR ni de LF&nbsp;; au
  plus 254 octets), un sujet contenant CR, LF ou NUL (injection d’en-têtes) ou
  de plus de 998 octets, un corps qui n’est pas de l’UTF-8 valide ou contient un
  NUL, plus de 100 destinataires. `to:` prend une adresse ou plusieurs séparées
  par des virgules.
- **Pas encore&nbsp;:** les pièces jointes et les images en ligne, les
  classes de mailer (`UserMailer.welcome(user).deliver_later`&nbsp;: un mail
  est une méthode de l’application qui appelle `deliver` ou
  `deliver_later`), les noms affichés, les en-têtes `Cc`/`Bcc` (envoyez
  plutôt à plusieurs destinataires), AUTH LOGIN/CRAM-MD5, les adresses
  SMTPUTF8, le pipelining. `deliver` s’exécute sur le thread appelant, un
  green thread comme une requête. `cybertrain generate authentication`
  n’écrit toujours pas de réinitialisation du mot de passe.

### Mail HTML

```ruby
html = Cybertrain::Views.render_mail("mail/welcome", user: user)   # app/views/mail/_welcome.html.erb
Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Welcome, #{user.name}!\n", html: html)
```

- Avec `html:`, le message est `multipart/alternative`&nbsp;: la partie texte
  (`body:`) d’abord, puis la partie HTML, chacune en `charset=UTF-8` et en
  base64 (si bien qu’aucune règle de longueur de ligne ni de dot-stuffing ne
  s’applique), entre des délimiteurs aléatoires. Les logiciels de messagerie
  affichent le HTML et se rabattent sur le texte. Sans `html:`, le message
  est le texte brut décrit plus haut, inchangé.
- `Views.render_mail(name, locals)` rend le partiel
  (`app/views/mail/_welcome.html.erb`) hors d’une requête, à l’intérieur de
  `app/views/layouts/mail.html.erb` quand ce layout existe et seul sinon&nbsp;;
  `Views.render_partial` le rend sans layout. Les valeurs sont échappées en
  HTML comme dans une page. Une partie texte peut aussi venir d’un
  partiel&nbsp;: rendez-le vous-même et passez-le comme `body:` (il affiche
  ses valeurs avec `<%== %>`, puisque `<%= %>` échappe).

### Envoyer plus tard

```ruby
Cybertrain::Mailer.deliver_later(to: user.email, subject: "Welcome", body: text, html: html)
```

`deliver_later` demande `require "cybertrain/mailer/later"` (ou
`require "cybertrain"`) dans `bin/<app>.rb` et `bin/db.rb`. Il prend les
arguments de `deliver`, les vérifie tout de suite
(une adresse ou un sujet refusé lève une exception ici et rien n’est mis en
file) et met en file le job intégré `"cybertrain mail"` avec le message
terminé&nbsp;; un thread de jobs
([Tâches de fond](background-and-operations.md#background-work)) l’envoie
avec les réglages SMTP en vigueur à ce moment-là. Rendez les corps avant
l’appel&nbsp;: le job n’a pas de contexte de vue. Il renvoie l’id du job.

- **Nouvelles tentatives.** Un délai dépassé, une connexion refusée ou une
  réponse `4xx` (greylisting, `421`, `452`) est réessayé 60 secondes plus
  tard, jusqu’à 5 tentatives, puis la ligne passe à `failed`. Une réponse
  `5xx` (une adresse qui n’existe pas, une connexion refusée) abandonne la
  ligne tout de suite&nbsp;: réessayer ne changerait pas la réponse.
- **Les erreurs aussi sont abandonnées.** Une `ArgumentError` à l’exécution
  du job est abandonnée sans rien envoyer&nbsp;: cela couvre une erreur de
  configuration (pas de `CYBERTRAIN_SMTP_HOST`, pas d’expéditeur) comme une
  charge utile modifiée dans la base. Un tel mail est perdu jusqu’à ce que
  quelqu’un lise la page des jobs ou `./<app> jobs list discarded`&nbsp;;
  corrigez la configuration, puis `./<app> jobs retry ID` le remet en file
  (il en va de même pour un échec d’authentification `535` abandonné).
- **Un message, tous les destinataires.** Un message à plusieurs
  destinataires est une seule transaction SMTP&nbsp;: quand le serveur refuse
  l’un d’eux avec une `5xx`, tout le job est abandonné et les autres ne le
  reçoivent pas non plus. Mettez en file un message par destinataire quand
  ils ne doivent pas dépendre les uns des autres.
- **Le message reste dans la base** (la charge utile de la ligne du job,
  affichée sur la page des jobs) jusqu’à ce que le job ait tourné, et aussi
  longtemps que la ligne terminée est conservée.
- Enregistrer ce job signifie que chaque processus qui exécute des jobs
  démarre ses threads de jobs, même dans une application sans classe de job
  à elle.

La conception&nbsp;: [docs/design.md](../design.md) D27 et D57.
