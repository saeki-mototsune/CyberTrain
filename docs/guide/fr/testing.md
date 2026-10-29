---
source_sha256: b84259bcc4f0afd4ba917077642cbc181416a59a524e9e5dc26ec8a76530afb7
---
# Tester une application

Les tests d’une application sont de simples programmes Spinel sous `test/`,
comme ceux du framework lui-même&nbsp;:

```ruby
require_relative "support/blog_test"   # l’application, BLOG et Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Assertions&nbsp;: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. Pour les contrôleurs
et les parcours HTTP complets, `Cybertrain::Test::Client` pilote une application
dans le même processus (sans socket) avec une cookie jar, de sorte que les
sessions et le CSRF se comportent comme derrière un navigateur&nbsp;:

```ruby
require_relative "support/blog_test"   # l’application, BLOG et Cybertrain::Test

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

Les deux extraits partent du helper de l’exemple,
[`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb)&nbsp;:
copiez-le dans le `test/support/` d’une application, où les fichiers sont
requis, pas exécutés. Il migre une base `storage/test.sqlite3` neuve, démarre
l’application sous le nom `BLOG`, charge `Cybertrain::Test` et son client, et
lit le jeton CSRF du dernier formulaire rendu (`BlogTest.form_token`). Terminez
chaque fichier de test par `Cybertrain::Test.run!`&nbsp;;
`examples/blog/test/articles.rb` et `comments.rb` montrent le modèle complet.

Chaque requête qu’envoie un client de test vient de `127.0.0.1`
(`request.remote_addr`, donc `request.loopback?` est vrai). Pour voir ce qu’une
page fait pour un visiteur sur une autre machine, définissez
`client.peer_address = "203.0.113.7"` avant la requête.

Lancez les tests avec `cybertrain spin test`&nbsp;: il compile chaque
`test/*.rb` en un programme distinct et compare (diff) sa sortie (stdout et
stderr ensemble) à `test/<name>.rb.expected`. Régénérez avec `cybertrain spin test --regen
test/<name>.rb`&nbsp;; les tests FFI/base de données ne peuvent pas tourner sous
CRuby, leur snapshot vient donc plutôt du binaire compilé&nbsp;: `rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1` (`cybertrain spin test` sort avec un code non nul
tant que le snapshot est périmé, il est donc suivi de `;` et non de `&&`&nbsp;; la
vérification `[ -x ]` saute la capture si la compilation a échoué, ce qui
conserve l’ancien snapshot&nbsp;; dans la copie du dépôt du framework,
`script/regen-snapshot test/<name>.rb` fait exactement cela et affiche le résumé
du diff).

## Tester les appels sortants

Quand le code testé envoie un webhook ([HTTP sortant](external-services.md#outbound-http))
ou un e-mail ([Envoyer des e-mails](external-services.md#sending-e-mail)), le
test le reçoit dans le même processus&nbsp;: `Cybertrain::Test::HttpReceiver` et
`Cybertrain::Test::SmtpReceiver` écoutent sur `127.0.0.1`, enregistrent ce qui
arrive et répondent par une réponse préparée. Le fichier part du même
helper que plus haut, `support/blog_test`, et requiert lui-même
`cybertrain/mailer`&nbsp;: `require "cybertrain"` ne le charge pas.

```ruby
require_relative "support/blog_test"   # l’application, BLOG et Cybertrain::Test
require "cybertrain/mailer"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

test "a sign-up posts a webhook" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  hook.start                                   # se lie à un port libre et le renvoie
  Cybertrain.config.http_allow_private = true  # sinon HttpClient refuse le loopback
  SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # le code de l’application
  req = hook.received_request                  # attend 5 s au plus ; nil si rien n’est arrivé
  hook.stop
  assert_equal "POST", req.http_method
  assert_equal "/hooks/signup", req.http_target
  assert_equal "application/json", req.http_header("Content-Type")
  assert_includes req.http_body, "ann@example.com"
end

test "a refused recipient is reported" do
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
  port = smtp.start
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
  assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
  mail = smtp.received_message
  smtp.stop
  assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
               mail.transcript.first(3)
  refute mail.delivered?
end

Cybertrain::Test.run!
```

`HttpReceiver.new` prend les `status:`, `headers:`, `body:` et `chunked:` de la
réponse préparée (`respond_with` les change entre deux requêtes)&nbsp;; la
requête revient sous forme de `ReceivedRequest` (`http_method`, `http_target`,
`http_path`, `http_headers` avec des noms en minuscules, `http_header(name)`,
`http_body` avec un corps chunked décodé). `SmtpReceiver` joue 220, EHLO (avec
8BITMIME sauf si `eight_bit_mime: false`, AUTH PLAIN avec `auth: true`), MAIL,
RCPT, DATA et QUIT&nbsp;; `reject:` fait échouer l’une des étapes `:greeting`,
`:ehlo`, `:mail`, `:rcpt`, `:data` ou `:message` avec la réponse donnée. Un
`ReceivedMessage` contient l’`envelope_from`, les `envelope_recipients`, le
`message_data` (dot-stuffing défait), `message_header(name)`, `message_body` et
le `transcript` des commandes. Tous deux acceptent une seule connexion, sauf si
`max:` en indique davantage (`received_requests` / `received_messages` les
renvoient toutes). Chaque attente est bornée&nbsp;: un récepteur abandonne après
`accept_window:` (10&nbsp;s) sans connexion, un client silencieux après
`read_timeout:` (5&nbsp;s), et `stop` (qu’on peut appeler deux fois sans risque)
termine et rejoint le thread du récepteur et ferme son port, de sorte qu’un
récepteur ne prend jamais la connexion d’un test ultérieur. Ils n’ont besoin
que de la bibliothèque socket de Ruby, pas d’openssl.

Un flux se teste de la même façon avec `Cybertrain::Test::WebSocketReceiver`,
un serveur WebSocket scripté sur `127.0.0.1`&nbsp;: chaque connexion joue une
liste de `Cybertrain::Test::WsStep` (`"accept"`, `"send_text"`, `"expect"`,
`"silent"`, `"close"`, `"drop"`, `"echo_until_close"`, ...), et les trames
envoyées par le client reviennent démasquées depuis `ws_received`.

```ruby
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # une constante : les blocs ne voient pas les variables locales

# Les blocs sont écrits dans une méthode, où leurs paramètres sont utilisés,
# et non dans le bloc du test.
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

test "a trade message is stored" do
  rx = Cybertrain::Test::WebSocketReceiver.new
  rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
  rx.start
  subscribe_trades(rx.url("/trades"))
  Cybertrain::WebSocket.start!               # Test::Client ne démarre jamais les flux
  # ... interroger TICKS pendant quelques secondes au plus ...
  Cybertrain::WebSocket.stop!
  assert_equal ["tick"], TICKS
  assert_equal "subscribe", rx.ws_received[0].rec_data
  rx.stop
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` rend les délais de nouvelle
tentative exacts. `test/websocket_integration.rb`, dans ce dépôt, montre un test
complet.

## Intégration continue

`cybertrain new` écrit `.github/workflows/ci.yml` pour l’application. Il appelle
l’action `setup-cybertrain` de ce dépôt
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
épinglée au tag de version de la CLI, qui installe les en-têtes SQLite, zlib et
OpenSSL ainsi que Ruby, lit dans `spin.lock` le commit du framework sur lequel
l’application est verrouillée, récupère le framework à ce commit et lance ses
`cybertrain
doctor` et `cybertrain setup` (avec `~/.cybertrain/spinel` mis en cache par
version de Spinel et par image de runner). Le workflow vérifie ensuite que
`spin.lock` est à jour (`spin lock && git diff --exit-code spin.lock`) et que
`gen/` est frais (`spin run gen -- --check`), et lance `spin test` dès que
`test/` contient un programme de test. Quand les étapes de la chaîne d’outils
changent, c’est l’action qui change, pas la copie de chaque application. Le
commit est lu dans `spin.lock`, donc le workflow suppose la dépendance git par
défaut&nbsp;; une application créée avec `--path` passe la copie du dépôt du
framework à l’action via `framework-path`.
