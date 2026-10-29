---
source_sha256: 8139d87863b139634224e836699b97e3b4ccaddcbe6af45562216a3f8e30208d
---
# Requêtes

Ce qu’un contrôleur reçoit d’une requête et ce que le framework vérifie avant de l’exécuter&nbsp;: la limitation du débit et l’adresse du client derrière un proxy, les en-têtes paramétrés, et la façon dont les chaînes de requête et les corps de requête sont analysés et bornés.

## Limitation du débit et adresse du client

`rate_limit` dans un contrôleur plafonne la fréquence à laquelle un client peut
appeler certaines actions, compté avant l’exécution de l’action&nbsp;:

```ruby
class SessionsController < ApplicationController
  # une 303 vers le formulaire, avec flash[:alert], une fois la limite atteinte
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
end
```

Chaque déclaration compte au plus `to` requêtes toutes les `within` secondes
pour chaque adresse de client et chaque contrôleur (une fenêtre fixe qui
s’ouvre avec la première requête), puis répond 429 avec un en-tête
`Retry-After`, ou redirige quand `redirect_to:` est fourni. `within:` est en
secondes, `only:`/`except:` prennent des Array, et il n’y a pas de bloc
`with:`. Les compteurs vivent dans le processus, dans une table d’au plus
10&nbsp;000 adresses (quand elle est pleine, les fenêtres expirées puis les plus
anciennes font de la place)&nbsp;: ils sont donc perdus au redémarrage, et chaque
processus compte de son côté. Chaque requête vers une action limitée prend un
verrou&nbsp;: nommez les actions avec `only:`. Dans un test,
`Cybertrain::RateLimit.reset_all!` oublie tous les compteurs et
`Cybertrain::RateLimit.current_time = n` fige l’horloge (`-1` la rétablit).

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
