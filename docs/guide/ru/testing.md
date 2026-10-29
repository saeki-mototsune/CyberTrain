---
source_sha256: b84259bcc4f0afd4ba917077642cbc181416a59a524e9e5dc26ec8a76530afb7
---
# Тестирование приложения

Тесты приложения — это обычные программы Spinel в `test/`, как и собственные тесты фреймворка:

```ruby
require_relative "support/blog_test"   # приложение, BLOG и Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Утверждения: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. Для контроллеров и
полных HTTP-сценариев `Cybertrain::Test::Client` прогоняет приложение внутри
процесса (без сокета) с хранилищем cookie, поэтому сессии и CSRF ведут себя
так же, как за браузером:

```ruby
require_relative "support/blog_test"   # приложение, BLOG и Cybertrain::Test

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

Оба фрагмента начинаются с хелпера из примера,
[`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb):
скопируйте его в `test/support/` приложения, где файлы подключаются, а не
запускаются. Он выполняет миграции на свежей `storage/test.sqlite3`, запускает
приложение как `BLOG`, загружает `Cybertrain::Test` и его клиент и считывает
токен CSRF из последней отрисованной формы (`BlogTest.form_token`).
Заканчивайте каждый файл тестов вызовом `Cybertrain::Test.run!`;
`examples/blog/test/articles.rb` и `comments.rb` показывают полный шаблон.

Каждый запрос, который отправляет тестовый клиент, приходит с `127.0.0.1`
(`request.remote_addr`, поэтому `request.loopback?` истинно). Чтобы увидеть,
что страница делает для посетителя с другой машины, задайте
`client.peer_address = "203.0.113.7"` перед запросом.

Запускайте командой `cybertrain spin test`: она компилирует каждый `test/*.rb`
в отдельную программу и сравнивает её вывод (stdout и stderr вместе) с
`test/<name>.rb.expected`. Перегенерируйте снимок командой `cybertrain spin test --regen
test/<name>.rb`; тесты с FFI/базой данных не могут работать под CRuby, поэтому
их снимок берётся из скомпилированного бинарного файла: `rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1` (`cybertrain spin test` завершается с ненулевым
кодом, пока снимок устарел, поэтому за ним следует `;`, а не `&&`; проверка
`[ -x ]` пропускает снятие вывода, если компиляция не удалась, и старый снимок
сохраняется; в рабочей копии фреймворка `script/regen-snapshot test/<name>.rb`
делает ровно это и выводит статистику изменений).

## Тестирование исходящих вызовов

Когда тестируемый код отправляет вебхук ([Исходящий HTTP](external-services.md#outbound-http)) или
письмо ([Отправка электронной почты](external-services.md#sending-e-mail)), тест получает его
внутри процесса: `Cybertrain::Test::HttpReceiver` и `Cybertrain::Test::SmtpReceiver`
слушают на `127.0.0.1`, записывают то, что приходит, и отвечают заготовленным
ответом. Файл начинается с того же хелпера, что и выше, `support/blog_test`,
и сам подключает `cybertrain/mailer`: `require "cybertrain"` его не загружает.

```ruby
require_relative "support/blog_test"   # приложение, BLOG и Cybertrain::Test
require "cybertrain/mailer"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

test "a sign-up posts a webhook" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  hook.start                                   # занимает свободный порт и возвращает его
  Cybertrain.config.http_allow_private = true  # иначе HttpClient отвергает loopback
  SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # код приложения
  req = hook.received_request                  # ждёт не более 5 с; nil, если ничего не пришло
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

`HttpReceiver.new` принимает заготовленные `status:`, `headers:`, `body:` и
`chunked:` (`respond_with` меняет их между запросами); запрос возвращается как
`ReceivedRequest` (`http_method`, `http_target`, `http_path`, `http_headers` с
именами в нижнем регистре, `http_header(name)`, `http_body` с декодированным
chunked-телом). `SmtpReceiver` разыгрывает 220, EHLO (с 8BITMIME, если не
задано `eight_bit_mime: false`, и с AUTH PLAIN при `auth: true`), MAIL, RCPT,
DATA и QUIT; `reject:` проваливает любой из шагов `:greeting`, `:ehlo`, `:mail`,
`:rcpt`, `:data` или `:message` с заданным ответом. У `ReceivedMessage` есть
`envelope_from`, `envelope_recipients`, `message_data` (с отменённым
dot-stuffing), `message_header(name)`, `message_body` и `transcript` команд.
Оба принимают одно соединение, если `max:` не говорит, что больше
(`received_requests` / `received_messages` возвращают их все). Каждое ожидание
ограничено: приёмник сдаётся после `accept_window:` (10 с) без соединения,
молчащий клиент — после `read_timeout:` (5 с), а `stop` (его безопасно вызывать
дважды) завершает поток приёмника, дожидается его и закрывает его порт, поэтому
приёмник никогда не перехватит соединение более позднего теста. Им нужна только
библиотека сокетов Ruby, а не openssl.

Поток данных тестируется так же с помощью `Cybertrain::Test::WebSocketReceiver` —
сервера WebSocket по сценарию на `127.0.0.1`: каждое соединение разыгрывает
список `Cybertrain::Test::WsStep` (`"accept"`, `"send_text"`, `"expect"`,
`"silent"`, `"close"`, `"drop"`, `"echo_until_close"`, ...), а фреймы, которые
отправил клиент, возвращаются без маски из `ws_received`.

```ruby
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # константа: блоки не видят локальные переменные

# Блоки написаны в методе, где используются их параметры,
# а не внутри блока теста.
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
  Cybertrain::WebSocket.start!               # Test::Client никогда не запускает потоки
  # ... опрашивать TICKS не дольше нескольких секунд ...
  Cybertrain::WebSocket.stop!
  assert_equal ["tick"], TICKS
  assert_equal "subscribe", rx.ws_received[0].rec_data
  rx.stop
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` делает задержки повторов точными.
`test/websocket_integration.rb` в этом репозитории показывает полный тест.

## Непрерывная интеграция

`cybertrain new` пишет для приложения `.github/workflows/ci.yml`. Он вызывает
action `setup-cybertrain` из этого репозитория
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
зафиксированный на релизном теге CLI, который устанавливает заголовки SQLite,
zlib и OpenSSL и Ruby, считывает из `spin.lock` коммит фреймворка, на котором
зафиксировано приложение, загружает фреймворк на этом коммите и запускает его
`cybertrain doctor` и `cybertrain setup` (с `~/.cybertrain/spinel`,
кэшируемым по релизу Spinel и образу раннера). Затем workflow проверяет, что
`spin.lock` актуален (`spin lock && git diff --exit-code spin.lock`), а `gen/`
свежий (`spin run gen -- --check`), и запускает `spin test`, как только в
`test/` появляется тестовая программа. Когда меняются шаги установки
инструментов, меняется action, а не копия в каждом приложении. Коммит берётся
из `spin.lock`, поэтому workflow предполагает git-зависимость по умолчанию;
приложение, созданное с `--path`, передаёт рабочую копию фреймворка в action
как `framework-path`.
