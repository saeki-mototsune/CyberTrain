---
description: Как CyberTrain-приложение собирается и запускается (генерация кода при сборке, интерпретируемые представления, HTTP-сервер, SQLite через FFI, цикл разработки) и все известные отличия от Rails.
source_sha256: dbc42178d5f6d75cdaeb5a45ea7c94a4462048b57ac21424a253347306264fc8
---

# Как это работает

На этой странице объясняется, как CyberTrain-приложение собирается и запускается:
код, генерируемый при сборке, представления, интерпретируемые во время запроса,
HTTP-сервер, SQLite через FFI и цикл разработки, а затем все известные отличия
от Rails. [Раздел о производительности](site:index.html#performance) на главной
странице сравнивает результат с тем же блогом, написанным на Rails 8.1. Методика,
все цифры и способ повторить измерение — в [docs/benchmark.md](../benchmark.md).

## Генерация кода при сборке

`spin run gen` (`bin/gen.rb`) выполняет DSL `create_table` из `db/schema.rb` и
DSL `Routes.draw` из `config/routes.rb`, чтобы получить *данные* таблиц и
маршрутов. Отдельно он проводит **лексическое сканирование** (регулярными
выражениями, а не парсером — Spinel не предоставляет его во время выполнения)
файлов `app/controllers/**/*.rb` и `app/models/**/*.rb` в поисках присваиваний
`@ivar =`, имён `before_action`/`after_action`/`rescue_from ... with:` и `def`
без аргументов.

По этим данным он пишет в `gen/` простой, читаемый Ruby:

- `gen/models/<name>.rb`: аксессоры, приведения типов, finder-методы, ассоциации, выведенные из внешних ключей;
- `gen/routes.rb`: таблица маршрутов, диспетчер, хелперы `*_path`/`*_url`;
- `gen/controllers.rb`: `view_assigns` и `run_callback` для каждого контроллера;
- `gen/migrations.rb`;
- `gen/views.rb`: таблица встроенных представлений, пустая, если сборка не для развёртывания;
- `gen/app.rb`: манифест `require_relative`.

`gen/` коммитится, а не попадает в gitignore: у `spin build` и `spin test` нет
хука, чтобы сначала выполнить генерацию, поэтому закоммиченный результат уже
должен быть тем, что компилируется. CI заново запускает `spin run gen` и падает
при наличии различий, так что устаревший сгенерированный код не может попасть
в основную ветку.

## Представления интерпретируются

Файлы `app/views/**/*.html.erb` выглядят как ERB из Rails, но во время запроса
разбираются в AST, который затем обходит интерпретатор, проходящий по дереву. В
Spinel нет `eval`, поэтому это замкнутая грамматика (литералы, обращения к
`@ivar`/локальным переменным, вызовы через фиксированные таблицы диспетчеризации
для каждого типа, `if`/`unless`, `each`/`each_with_index`/блок одного хелпера),
а не настоящий Ruby. Полная грамматика, хелперы и пробелы описаны в
[справочнике по языку шаблонов](template-language.md).

Откуда берётся исходный текст, зависит от режима:

- В режиме разработки (и в тестах) движок читает `app/views/` с диска, а в режиме разработки заново разбирает шаблон, когда тот меняется, поэтому правки представлений не требуют пересборки.
- `cybertrain build` запускает `spin run gen -- --embed-views`, который записывает исходный текст каждого шаблона в `gen/views.rb` как таблицу строк для этого единственного `spin build`, а затем снова запускает `spin run gen`, чтобы вернуть закоммиченную пустую таблицу.
- Продакшен-бинарник отображает только эту таблицу (разбирая каждый шаблон один раз) и отказывается запускаться, если она пуста (`error: views are not embedded in this binary`).

## HTTP-сервер

`Cybertrain::Server` — HTTP/1.1 на обычном Ruby: `TCPServer#accept` плюс один
зелёный поток Spinel на соединение (планирование M:N, без GVL), типизированные
`Request`/`Response`, без слоя Rack. TLS/HTTP/2 оставлены обратному прокси.
`SPINEL_WORKERS` по умолчанию равен `1`: спайки показали, что при такой нагрузке,
ограниченной вводом-выводом, на 100 одновременных соединениях это быстрее и без
зависаний.

Сервер вызывает `HttpHandler` (`call(request) -> Response`); `ContextHandler`
связывает его со стеком middleware, поэтому HTTP-слой (`cybertrain/http/`, а
также `Params` и `Logger`) не зависит от остального фреймворка; это обеспечивает
`script/check-http-layer` в CI.

## SQLite через FFI

Модели общаются с SQLite напрямую через `ffi_func`/`ffi_lib` Spinel — без
расширения на C, без гема. Каждый запрос использует привязку параметров, а не
интерполяцию. Сегодня это единственный адаптер (PostgreSQL через FFI `libpq`
отмечен как возможная будущая работа).

Пул (`SizedQueue`, по умолчанию 4 соединения) выдаёт соединения с:

- WAL;
- тайм-аутом занятости около пяти секунд (обработчик занятости повторяет попытку каждые 100 мкс, тогда как `busy_timeout` SQLite засыпает на миллисекунду или больше);
- до 64 кэшированных подготовленных выражений;
- включёнными внешними ключами.

Как транзакция берёт одно из этих соединений и что на нём выполняется:
[Транзакции](models.md#transactions).

## Цикл разработки

`cybertrain server` (`spin run gen`, затем `spin run NAME`) в `development`
(`CYBERTRAIN_ENV` по умолчанию, кроме бинарного файла из `cybertrain build`)
также опрашивает `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb` и
`gen/**/*.rb` каждые полсекунды. Представления исключены (движок сам их
перезагружает), как и `gen/views.rb`, пустой в режиме разработки.

Изменение запускает `spin run gen && spin build NAME -- --incremental` в фоне:
инкрементальная сборка Spinel, которая перекомпилирует только те единицы C,
которые затронула правка. Релиз Spinel без `--incremental` отвергает этот флаг,
и тогда цикл собирает без него.

Успех запрашивает перезапуск (тот же флаг, что устанавливает внешний
`kill -HUP`): поток-монитор останавливает слушатель и дожидается завершения
открытых запросов, затем главный поток делает `execv` нового бинарного файла на
том же порту и с тем же PID, незаметно для клиента посреди сессии. Неудачная
сборка продолжает обслуживать старым бинарным файлом и показывает вывод
компилятора баннером в каждом HTML-ответе. Ничего из этого не загружается в
production.

## Отличия от Rails

<!-- table: cmp -->
| Rails | cybertrain |
| --- | --- |
| `rails console` | Консоли нет — в Spinel нет `eval` |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` в `bin/<app>.rb`: `./<app> name ARGS` запускает её с подключённой базой данных |
| Правите код — запущенное приложение подхватывает изменения | Ruby требует пересборки; в режиме разработки `cybertrain server` делает это за вас (пересборка, остановка, `execv`) |
| Правите представление — перезагрузка не нужна | Так же — в режиме разработки представления разбираются с диска при каждом запросе |
| `def new` | `def new_action` (`new` затенил бы `Klass.new(ctx)`) |
| `before_action { do_thing }` (неявный `self`) | `before_action { \|c\| c.do_thing }` — для сохранённого блока нет `instance_exec`, поэтому колбэки получают контроллер/запись явно |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — вложенные блоки получают маппер явно |
| ERB компилируется в метод; любой объект, любой метод | Интерпретируется по фиксированной грамматике/таблице диспетчеризации — [docs/guide/template-language.md](template-language.md) |
| Сессия хранит любой сериализуемый через Marshal объект | Значения сессии — только строки (String), cookie с подписью HMAC |
| Множество адаптеров баз данных | Только SQLite, через FFI |
| `Article.transaction { ... }` возвращает значение блока; `raise ActiveRecord::Rollback`; точки сохранения `requires_new: true` | `Article.transaction { \|c\| ... }` передаёт в блок соединение и возвращает nil; выходят из неё, возбуждая исключение; вложенные вызовы присоединяются к внешней транзакции, точек сохранения нет ([Транзакции](models.md#transactions)) |
| `has_many :through`, `includes`, `dependent:`, enum, STI, полиморфные ассоциации | Не реализовано; ассоциации выводятся только из внешних ключей схемы |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Типизированные варианты, потому что у метода Spinel один тип возвращаемого значения: `pluck_int` и ему подобные, `sum_int`, `count_by`, `upsert`, `increment(:col, by: n)`, `where_like` ([Запросы помимо `where`](models.md#querying-beyond-where)) |
| Любое имя столбца; ассоциация может затенить `errors` | Только идентификаторы ASCII; столбец, названный как метод фреймворка или ключевое слово Ruby, генерируется как `<column>_column`, конфликтующая ассоциация — под запасным именем ([Имена столбцов](models.md#column-names)) |
| `namespace`, форматы/`respond_to`, `constraints`, `mount` | Не реализовано — плоские имена, только `render json:` |
| `rescue StandardError` перехватывает неудачный `JSON.parse` | Под Spinel `JSON::ParserError` не является `StandardError`: коду приложения нужно `rescue JSON::ParserError, StandardError`. Сервер перехватывает его в крайнем случае и отвечает 500 |
| `skip_forgery_protection` в API-контроллере | CSRF выполняется до маршрутизации, поэтому API исключается по пути, `c.csrf_exempt_prefixes = ["/api/"]`, и сам аутентифицирует вызывающих ([Конфигурация](configuration.md#configuration-and-environment-variables)) |
| Rack оставляет тело запроса в gzip как есть | Тело с `Content-Encoding: gzip` — это `request.decoded_body`, распакованное с ограничением в 10 МиБ; повреждённое или слишком большое — 400; `request.body` остаётся как отправлено ([Строки запроса и тела](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` принимает только списки `column [ASC\|DESC]`; данные запроса проходят через список разрешённых значений, сырой SQL — через `order_sql` ([Порядок](models.md#ordering)). Некорректные или слишком глубоко вложенные параметры — 400 ([Строки запроса и тела](requests.md#query-strings-and-bodies)) |
| Полный бэктрейс при исключении | Класс, сообщение, строка запроса, имя/строка шаблона — Spinel не предоставляет бэктрейсов |
| Rack, его middleware и любой гем в `Gemfile` | Нет совместимости с Rack; небольшой фиксированный набор middleware; собственный `spin-index` Spinel, ограниченный тем, что компилируется в рамках его подмножества Ruby |
| minitest / RSpec | `Cybertrain::Test` — раннеры на основе рефлексии не могут работать при AOT-компиляции |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` пишет ту же структуру плюс страницу регистрации; пароли используют PBKDF2-HMAC-SHA256 (bcrypt потребовал бы библиотеку на C; `String#crypt` на macOS его не поддерживает); сброса пароля нет ([Добавьте вход](tutorial.md#authentication)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` пишет пять столбцов `cover_*` и методы модели; файлы лежат на локальном диске в `storage/uploads/` и отдаются через `send_blob`; один файл на поле, без вариантов и прямых загрузок ([Обложка](tutorial.md#attachments)) |
| `skip_before_action :x` | То же самое для именованных before-колбэков (у колбэка-блока нет имени, которое можно пропустить); `skip_after_action` нет |
| `resource :session` | Те же шесть маршрутов к `SessionsController`; вложение в него не поддерживается |
| `get "/x"`, затем `post "/x"` | Оба допустимы: выведенное имя второго маршрута уже занято, поэтому он остаётся без имени, как в Rails; повторяющийся `as:` по-прежнему ошибка |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, данные часовых поясов из ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` читает системные файлы TZif (`/usr/share/zoneinfo` или `TZDIR`) и преобразует целые секунды эпохи Unix (`utc_offset_at`, `utc_to_local`, `local_to_utc`); `Time.zone` на запрос и `l(time, zone:)` пока нет ([Часовые пояса](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` для вебхуков и API: каждое ожидание ограничено, непубличные адреса назначения по умолчанию отвергаются, без редиректов и keep-alive (см. [Исходящий HTTP](external-services.md#outbound-http)); `Net::HTTP` из Spinel блокирует весь сервер на зависшем собеседнике |
| Action Mailer (`deliver_later`, классы мейлеров, представления) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` отправляет простой текст по SMTP (STARTTLS, неявный TLS или открытым текстом на loopback; AUTH PLAIN; каждое ожидание ограничено); без шаблонов, HTML, вложений и очереди (см. [Отправка электронной почты](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, повторяющиеся задачи | `Cybertrain::Job.handle(kind)` и `Job.enqueue(kind, payload, run_at:)` (полезная нагрузка String, повтор с нарастающей задержкой), `Cybertrain::Scheduler.every(seconds, name)`; один поток в обслуживающем процессе ([Фоновая работа](background-and-operations.md#background-work)) |
| Клиент ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` держит поток подключённым, пока работает сервер (переподключения, пинги, обнаружение тишины); `WebSocket::Client` — для одного синхронного соединения; только исходящие ([Потребление потоков WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` — массив строк, сопоставляемых по подстроке без учёта регистра (без Regexp и лямбд); применяется к логу запросов и странице ошибок в режиме разработки ([Фильтруемые параметры](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (маршрут к контроллеру) | `GET /up` встроен и получает ответ до статических файлов, сессии и маршрутизатора, поэтому никакой `before_action` не выполняется; он проверяет базу данных и обработчик фоновых задач: `200 ok` или `503` ([Эксплуатация](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Задачи `bin/rails db:...` для резервных копий (встроенных нет) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, режим 0600, переименование на место) и `./<app> db vacuum` |
| ActionCable (сервер), asset pipeline, i18n | Не сделано (за рамками MVP, `docs/design.md` §2.3) |

<!-- table-foot: Список не исчерпывающий: более полная запись в `docs/design.md` §8 («What was deliberately left out»). -->
