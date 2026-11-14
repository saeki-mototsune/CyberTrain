---
source_sha256: 2b56112469f77822eff135a926be5aadaa4c4f8c9e6c75c262213c049b39f367
---
# Реальное время: потоки в браузер

Отправляйте изменения на открытые страницы без перезагрузки: Turbo Streams
поверх Server-Sent Events или WebSocket, рассылка из действия, задачи или
фида, и те же потоки для вашего собственного JavaScript.

## Как рассылка доходит до страницы

Страница подписывается на один или несколько именованных потоков; любая
часть приложения рассылает сообщение в поток по его имени; каждая
подписанная страница получает его примерно за десятую долю секунды.

- **У потоков есть имена.** Имя — любой короткий текст (`"alerts"`) или
  запись, чьё имя — её таблица и id (`"articles:12"`,
  `Cybertrain::Stream.name_for(@article)`).
- **Рассылка — это строка таблицы.** `Cybertrain::Stream.broadcast(name, payload)`
  вставляет строку в `cybertrain_messages`, таблицу, которую фреймворк сам
  создаёт в базе данных приложения. Внутри `DB.transaction` сообщение
  уходит, только если транзакция зафиксирована. Раз это строка, рассылка
  работает из любого процесса с той же базой: из запроса, из задачи в
  процессе `worker`, из колбэка фида, из `Main.command`.
- **Каждый веб-процесс опрашивает таблицу.** Один поток на процесс `server`
  (опросчик потоков) каждые `stream_poll_ms` (100 мс) читает новые строки и
  передаёт каждую браузерам, которые держит этот процесс. Раз в минуту он
  удаляет строки старше `stream_retention` (60 секунд).
- **Браузер подключается к одной точке входа**, `/cybertrain/stream`, через
  Server-Sent Events (`EventSource`) или WebSocket, с подписанным токеном,
  который называет потоки, доступные ему для чтения
  ([Подписанные имена потоков](#signed-stream-names)).

Запускать ничего не нужно: `./<app> server` запускает опросчик и обслуживает
точку входа. `config.stream_path = ""` выключает всю функцию.

## Turbo Streams

[Turbo](https://turbo.hotwired.dev) обновляет страницу по элементам
`<turbo-stream action="append" target="comments">`, как это делают
приложения на Rails 8. Подключите Turbo в макете (конвейера ресурсов нет:
CDN или копия в `public/`) и подпишите страницу с помощью
`turbo_stream_from`. Широковещательным рассылкам, конечной точке потоков
и хелперам потоков нужна строка `require "cybertrain/streams"` в
`bin/<app>.rb` и `bin/db.rb`; без неё `spin run gen` остановится на первом
`turbo_stream_from` и назовёт строку ([Подсистемы](how-it-works.md#subsystems)):

```erb app/views/layouts/application.html.erb (фрагмент)
<head>
  <%= csrf_meta_tags %>
  <script type="module" src="https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/dist/turbo.es2017-esm.js"></script>
</head>
```

```erb app/views/articles/show.html.erb (фрагмент)
<%= turbo_stream_from @article %>
<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render "comments/comment", comment: comment %>
  <% end %>
</div>
```

`turbo_stream_from` принимает строки и записи, сколько угодно, и выводит
один элемент `<turbo-stream-source>`, чей URL несёт один токен для всех них.
Turbo открывает его как `EventSource`; `turbo_stream_from @article, ws: true`
вместо этого даёт URL `ws://` (`wss://` за HTTPS), который Turbo открывает
как WebSocket. В обоих случаях странице не нужен ваш JavaScript. Потерянный
WebSocket (обрыв сети, перезапуск сервера) Turbo заново не открывает: такая
страница не получает обновлений, пока её не перезагрузят, тогда как
`EventSource` переподключается сам и повторяет пропущенное. Оставьте вариант
по умолчанию, если WebSocket не нужен, или переподключайтесь из своего
JavaScript (`&after=`, ниже).

Затем разошлите сообщение из действия, которое что-то изменило:

```ruby app/controllers/comments_controller.rb (фрагмент)
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

`broadcast_append_to(stream, target:, ...)` отрисовывает содержимое,
оборачивает его в элемент `<turbo-stream>` и рассылает. Содержимое — одно
из: `partial:` с `locals:` (отрисовывается `Cybertrain::Views.render_partial`),
`component:` ([компонент представления](template-language.md#components))
или `html:` (экранируется, если это не `SafeString`). Цель — DOM id или
запись, чей DOM id — `dom_id(record)` (`"comment_7"`). Остальные работают
так же: `broadcast_replace_to`, `broadcast_update_to`,
`broadcast_prepend_to`, `broadcast_before_to`, `broadcast_after_to`,
`broadcast_remove_to(stream, target:)` и `broadcast_refresh_to(stream)`
(Turbo 8 перезагружает страницу с морфингом).

Turbo также превращает ссылки и формы в запросы fetch (Turbo Drive).
Scaffold уже отвечает так, как ожидает Turbo: редирект с 303 после успешной
формы и 422 с формой снова после неудачной.

### Ответ на форму через Turbo Stream

Форма, которую отправляет Turbo, принимает `text/vnd.turbo-stream.html`.
Чтобы ответить потоком вместо редиректа, отрисуйте элемент сами; их строит
`Cybertrain::Turbo` (`replace`, `update`, `append`, `prepend`, `before`,
`after`, `remove`, `refresh`):

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

### Рассылка из задачи, периодической задачи или фида

Рассылке не нужен запрос, поэтому задача может отрисовать и отправить её:

```ruby config/app.rb (фрагмент)
Cybertrain::Job.handle("price_refresh") do |payload|
  item = Item.find(Cybertrain::Cast.int(payload))
  item.refresh_price!
  Cybertrain::Stream.broadcast_replace_to("prices", target: item,
                                          partial: "items/price", locals: { item: item })
end
```

Партиал отрисовывает `Cybertrain::Views.render_partial`, который работает
без запроса: хелперы путей (`item_path(item)`) работают, а хелперы, которым
нужен запрос (`csrf_token`, `params`, `flash`, `request_path`, `*_url`),
возбуждают `Cybertrain::Views::OutsideRequest` (см. [Отрисовка вне
запроса](template-language.md#rendering-outside-a-request)). Задача
выполняется и в процессе `worker`, и на сервере, а строка, которую она
пишет, доходит до страниц всех серверов.

## Server-Sent Events из JavaScript

Для страницы, которой управляет не Turbo (график, бегущая строка),
запрашивайте потоки в JSON. `stream_source_path` даёт путь точки входа с
токеном и `mode=json`, а `signed_stream_name` — только токен:

```erb app/views/dashboards/show.html.erb (фрагмент)
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

В `mode=json` каждое сообщение — событие с именем своего потока, данные
которого — `{"stream": ..., "id": ..., "data": ...}`, с полезной нагрузкой в
`data` (рассылайте JSON как String: `Stream.broadcast("prices",
JSON.generate({ "price" => 12.5 }))`). В режиме по умолчанию `mode=raw`
нагрузка уходит как есть, обычным событием `message`, — это то, что читает
Turbo.

Когда соединение рвётся, браузер переподключается сам и отправляет id
последнего увиденного события (`Last-Event-ID`). Тогда точка входа сначала
повторно отправляет все сообщения этих потоков с бо́льшим id, которые ещё
есть в таблице (в пределах `stream_retention`), так что ничего из
промежутка не теряется. Странице, отсутствовавшей дольше, стоит
перезагрузиться. До прихода первого события браузеру нечего отправить в
качестве id, поэтому соединение, оборвавшееся в этом окне, ничего не
получает повторно: то, что страница отрисовала при загрузке, остаётся её
состоянием до следующей рассылки. После 15 секунд тишины уходит строка комментария
(`: ping`), чтобы прокси держали соединение открытым.

## WebSocket из JavaScript

Тот же URL отвечает и на WebSocket. Страница строит из него URL `ws://` или
`wss://`. Передавайте путь и токены через атрибуты `data-`, как здесь:
`<%= %>` внутри элемента `<script>` экранируется как HTML, а браузер там его
не декодирует (на сервер пришло бы `&amp;`).

```erb app/views/dashboards/show.html.erb (фрагмент)
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

В `mode=json` каждое сообщение — один текстовый фрейм с тем же конвертом
`{"stream", "id", "data"}`, и страница может менять свои потоки во время
соединения, отправляя текстовый фрейм JSON:

| Страница отправляет | Сервер отвечает |
| --- | --- |
| `{"subscribe":"<token>"}` | `{"subscribed":["prices","alerts"]}`: все потоки, которые соединение теперь читает |
| `{"unsubscribe":"<token>"}` | `{"unsubscribed":["alerts"]}` |
| токен, который не проходит проверку | `{"error":"bad token"}` |
| что угодно другое | `{"error":"bad message"}` |

Соединение в `mode=json` может также открыться без токена и подписаться
сообщением; соединение, которое через 15 секунд всё ещё не читает ни одного
потока, закрывается (код 1008). У WebSocket нет `Last-Event-ID`: чтобы
наверстать после переподключения, добавьте к URL
`&after=<the last id you saw>`. Сервер отправляет ping после каждых 15
секунд тишины и отвечает на ping; двоичные фреймы от страницы
игнорируются. Коды закрытия: 1000, когда сервер останавливается, 1008 для
плохого токена, 1009 для фрейма больше `stream_max_message`, 1013, когда
процесс заполнен или страница слишком отстала.

## Потоковая передача из действия

Действие может держать открытым собственный ответ, как это делает
`ActionController::Live` в Rails: `stream` выполняет блок после действия, в
потоке соединения, и передаёт ему сокет как `Cybertrain::Sink`.

```ruby app/controllers/reports_controller.rb (фрагмент)
def progress
  stream do |out|
    10.times do |i|
      out.write(Cybertrain::SSE.event(JSON.generate({ "done" => i * 10 }), event: "progress", id: i.to_s))
      break if out.wait_closed(1)   # true, когда клиент ушёл
    end
  end
end
```

`stream(content_type: "text/event-stream", status: :ok)` отвечает с
`Transfer-Encoding: chunked` и закрывает соединение, когда блок
возвращается. `SSE.event(data, event: "", id: "", retry_ms: 0)` форматирует
одно событие; `out.closed?` становится true, как только клиент ушёл, и
последующие записи ничего не делают. Блок не должен трогать сессию, flash
или заголовки: они ушли вместе с началом ответа.

## Подписанные имена потоков

Страница может читать поток только с токеном, который его называет. Токен —
это имена потоков и подпись HMAC-SHA256, сделанная ключом, выведенным из
`secret_key_base` только для потоков (как `turbo/signed_stream_verifier_key`
в Rails), поэтому токен никогда не подходит как cookie сессии; точка входа проверяет подпись и не читает ни сессию, ни базу данных. Это
модель Turbo: тот, кто мог отрисовать страницу, мог читать её потоки. Токены
не истекают; смена `secret_key_base` делает недействительными все, и
страница, открытая через такой деплой, перестаёт получать обновления
(`EventSource` считает 403 окончательным), пока её не перезагрузят.

<!-- list: points -->
- Поток для одного пользователя — это поток, названный по записи этого
  пользователя, `turbo_stream_from @user` (`"users:7"`), отрисованный только
  на страницах этого пользователя. Любой, кто заполучит токен, может читать
  этот поток, пока секрет не меняется.
- Токены не истекают. Смена `CYBERTRAIN_SECRET_KEY_BASE` делает
  недействительными все токены (и все сессии).
- Токен передаётся в URL, поэтому журнал доступа обратного прокси его
  записывает. Собственный журнал запросов фреймворка пишет его как
  `[FILTERED]`; выключите журналирование прокси для `/cybertrain/stream` или
  держите эти журналы такими же закрытыми, как потоки.
- Плохой или отсутствующий токен — это 403 для SSE и закрытие с 1008 сразу
  после рукопожатия для WebSocket.
- Имя — от 1 до 200 байт без управляющих символов и запятых; токен несёт не
  больше 16 имён, соединение — не больше 64.

## Ограничения и настройки

Задаются в `config/app.rb` (`c.stream_poll_ms = 250`); при значении вне
диапазона запуск останавливается с сообщением.

| Настройка | По умолчанию | Что делает |
| --- | --- | --- |
| `stream_path` | `"/cybertrain/stream"` (`CYBERTRAIN_STREAM_PATH`) | Путь точки входа; `""` выключает потоки |
| `stream_poll_ms` | `100` | Как часто каждый серверный процесс читает новые сообщения (не меньше 10) |
| `stream_retention` | `60` | Сколько секунд сообщение остаётся в таблице, а значит, насколько далеко может наверстать переподключение |
| `stream_ping_interval` | `15` | Секунды тишины до ping; также сколько может ждать одна запись клиенту |
| `stream_max_connections` | `1000` | Открытых потоков на процесс; сверх этого SSE получает 503, а WebSocket — закрытие с 1013 |
| `stream_max_message` | `65536` | Байт в одном фрейме WebSocket от страницы (сверх — закрытие с 1009) |
| `stream_max_backlog` | `1000` | Сообщений в ожидании для одного медленного клиента, после чего он отключается (он переподключается и получает повтор) |

Каждый открытый поток занимает одно соединение и его зелёный поток, пока
страница открыта. За nginx заголовок ответа `X-Accel-Buffering: no`
выключает буферизацию; для WebSocket прокси должен пропускать `Upgrade` и
`Connection` (Caddy и kamal-proxy пропускают).

## Какой процесс что делает

<!-- list: points -->
- **`./<app> server`** всегда запускает опросчик и точку входа, в том числе
  с `CYBERTRAIN_WORKER=0`: он доставляет сообщения браузерам, которые
  держит. Пока опросчик не работает, точка входа отвечает 503
  (`stream poller is not running`); `serve` запускает его до открытия порта,
  так что обслуживающий процесс этого никогда не показывает.
- **`./<app> worker`** и **`./<app> feeds`** не обслуживают HTTP и не
  запускают опросчик. Их рассылки — это строки, которые доставляют серверы
  ([Роли процессов](background-and-operations.md#process-roles)).
- Несколько серверов на одной базе каждый доставляют каждое сообщение своим
  браузерам, в одном и том же порядке и с одними и теми же id.

Тестирование потока страницы: [Тестирование потоков и
компонентов](testing.md#testing-streams-and-components). Устройство:
[docs/design.md](../design.md) D36 и D37.

## Состояние фидов

[Фид WebSocket](external-services.md#consuming-websocket-feeds) часто
работает в процессе `feeds`, который не обслуживает HTTP, поэтому его
состояние передаётся через базу данных: супервизор каждого процесса,
выполняющего фиды, каждые `feed_status_interval` секунд (10) пишет по одной
строке на подписку в `cybertrain_feeds`. Таблица принадлежит фреймворку
(создаётся при первом использовании, не входит в `db/schema.rb`). `GET /up`
в процессе `server` читает её и отвечает `503 feed stale`, когда для
какой-нибудь строки:

<!-- list: points -->
- устарел издатель: строка в последний раз была записана больше
  `health_feed_stale` секунд назад (180, `CYBERTRAIN_HEALTH_FEED_STALE`), то
  есть процесс, выполняющий фид, умер, завис или потерял базу данных; или
- фид молчит: строка свежая, но фид столько же времени не доставлял
  сообщений и не отвечал на ping (фид, который никогда ничего не получал,
  считается от своего запуска).

Оба условия проверяются отдельно, так что живой издатель никогда не скрывает
молчащий фид. Учитываются только строки фидов, на которые приложение всё ещё
подписано: все роли выполняют один и тот же бинарный файл, поэтому строка,
чьё имя не регистрирует ни один `subscribe` (фид, который вы удалили или
переименовали), игнорируется. `health_feed_stale` должен быть больше
`feed_status_interval`, иначе каждая строка устаревала бы между двумя
записями, и загрузка такое значение отклоняет. `CYBERTRAIN_HEALTH_FEEDS=0`
(или `false`) отключает эту
проверку — для фида, который законно молчит дольше порога, или для
развёртывания, которое следит за фидами иначе. Нечитаемая таблица оставляет
`/up` на 200 и пишет в лог одну строку `WARN`, пока таблица снова не станет
читаемой.

`./<app> feeds status` печатает строки для оператора, по одной на фид:

```console
$ ./blog feeds status
trades  connected  web-1:4242  last activity 3s ago  restarts 0  updated 4s ago
```

<!-- list: points -->
- Ключ строки — только имя фида: два процесса, выполняющие один и тот же фид,
  перезаписывают строки друг друга, и это ещё одна причина выполнять каждый
  фид в одном процессе.
- Процесс `feeds`, остановленный штатно (TERM или INT: развёртывание,
  уменьшение числа экземпляров), удаляет записанные им строки, так что
  роль, остановленная намеренно, перестаёт учитываться. Процесс, который
  упал или завершился после повторяющихся смертей фида, оставляет их
  устаревать, и именно об этом сообщает `/up`.
- Фид, который вы удалили или переименовали, оставляет свою строку; `/up`
  её игнорирует, а `feeds status` помечает её `(not registered)`; удалите её,
  когда захотите (`./<app> dbconsole`, затем `DELETE FROM cybertrain_feeds
  WHERE name = 'trades';`).
- `status` не может быть именем фида: `subscribe("status", ...)` бросает
  ArgumentError, потому что `./<app> feeds status` печатает таблицу.
- `/up` ничего не перезапускает. Kamal опрашивает его только для роли web во
  время развёртывания, а Docker перезапускает контейнер, когда его процесс
  завершается, что процесс `feeds` и делает после повторяющихся смертей
  фида; задайте роли политику перезапуска
  ([Роли процессов](background-and-operations.md#process-roles)).

Проектное решение: [docs/design.md](../design.md) D56.
