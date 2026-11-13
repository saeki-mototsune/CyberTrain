---
description: Как CyberTrain-приложение собирается и запускается (генерация кода при сборке, необязательные подсистемы, интерпретируемые представления, HTTP-сервер, SQLite через FFI, цикл разработки) и отличия от Rails.
source_sha256: f22dcd005dd90c45c00770da96f33164e05a94aa11d052f1ae901236b279ca91
---

# Как это работает

На этой странице объясняется, как CyberTrain-приложение собирается и запускается:
код, генерируемый при сборке, подсистемы, которые требует приложение,
представления, интерпретируемые во время запроса,
HTTP-сервер, SQLite через FFI и цикл разработки, а затем таблица отличий
от Rails. [Раздел о производительности](site:index.html#performance) на главной
странице сравнивает результат с тем же блогом, написанным на Rails 8.1. Методика,
все цифры и способ повторить измерение — в [docs/benchmark.md](../benchmark.md).

## Генерация кода при сборке

`spin run gen` (`bin/gen.rb`) выполняет DSL `create_table` из `db/schema.rb` и
DSL `Routes.draw` из `config/routes.rb`, чтобы получить *данные* таблиц и
маршрутов. Отдельно он проводит **лексическое сканирование** (регулярными
выражениями, а не парсером — Spinel не предоставляет его во время выполнения)
файлов `app/controllers/**/*.rb` и `app/models/**/*.rb` в поисках присваиваний
`@ivar =`, имён `before_action`/`after_action`/`rescue_from ... with:`, строк
`helper_method`, `layout` и `rate_limit`, `include` concerns и `def` без
аргументов. Он ставит дайджест на файлы в `app/assets/`, `app/javascript/` и
`vendor/javascript/`, читает `config/importmap.rb` как текст и читает словари
в `config/locales/` собственным читателем YAML.

По этим данным он пишет в `gen/` простой, читаемый Ruby:

- `gen/models/<name>.rb`: аксессоры, приведения типов, finder-методы, ассоциации, выведенные из внешних ключей;
- `gen/routes.rb`: таблица маршрутов, диспетчер, хелперы `*_path`/`*_url`;
- `gen/controllers.rb`: `view_assigns`, `run_callback`, таблица `helper_method` и `controller_layout` для каждого контроллера;
- `gen/concerns.rb` и `gen/concerns/**`: блоки `included` concerns, вставленные в каждый включающий класс, и модули concerns с опустошёнными блоками ([Concerns](requests.md#concerns-and-helper_method));
- `gen/assets.rb`: пути ассетов с дайджестом и import map ([Ассеты](assets.md)), а файлы с дайджестом — в `public/assets/`;
- `gen/locales.rb`: словари приложения в виде двух Hash, которые читает `I18n.t` ([Интернационализация](i18n.md#dictionaries));
- `gen/migrations.rb`;
- `gen/views.rb`: таблица встроенных представлений, пустая, если сборка не для развёртывания;
- `gen/app.rb`: манифест `require_relative`.

`gen/` коммитится, а не попадает в gitignore: у `spin build` и `spin test` нет
хука, чтобы сначала выполнить генерацию, поэтому закоммиченный результат уже
должен быть тем, что компилируется. CI заново запускает `spin run gen` и падает
при наличии различий, так что устаревший сгенерированный код не может попасть
в основную ветку.

## Подсистемы

Spinel компилирует каждый метод каждого файла, который требует программа,
вызывается он или нет, а анализ всей программы занимает большую часть каждой
сборки. Поэтому части фреймворка, которые приложению могут быть не нужны,
вынесены отдельно, и `bin/<app>.rb` перечисляет те, что оно использует, как
`config/application.rb` в Rails перечисляет railtie:

| Строка | Загружает |
| --- | --- |
| `require "cybertrain/core"` | HTTP, маршрутизацию, контроллеры, модели, представления и хелперы (среди них `turbo_frame_tag`, `dom_id`, `render turbo_stream:` и `format.turbo_stream`), ассеты, сессии, CSRF, CSP, консоль, `db` и `migrate` |
| `require "cybertrain/jobs"` | `Job` и классы задач, `Scheduler` (`every`, `cron`), роль `worker`, команду `jobs` и страницу задач |
| `require "cybertrain/streams"` | `Stream.broadcast_*`, конечную точку потоков (SSE и WebSocket), `Controller#turbo_stream`, хелперы `turbo_stream_from`, `turbo_stream`, `signed_stream_name` и `stream_source_path` |
| `require "cybertrain/feeds"` | `Background`, роль `feeds` и её проверку здоровья; её загружает `require "cybertrain/websocket"` (`WebSocket.subscribe`) |
| `require "cybertrain/mailer"` | `Mailer.deliver` |
| `require "cybertrain/mailer/later"` | `Mailer.deliver_later`; загружает почту и задачи |
| `require "cybertrain/cache"` | `Cache` |
| `require "cybertrain/rate_limit"` | `rate_limit` в контроллерах; загружает кэш |
| `require "cybertrain"` | всё перечисленное |

Каждая строка загружает ядро, и порядок строк не важен: фреймворк запускает
и останавливает подсистемы в собственном фиксированном порядке. В приложении,
созданном scaffold, одно ядро компилирует 2 205 методов вместо 2 767
и анализируется 38 с вместо 52 с; полная сборка занимает 83 с вместо 108 с,
а правка контроллера — около 47 с вместо 65 с
([docs/performance-next.md](../performance-next.md)).

`cybertrain new` пишет `require "cybertrain/core"` в `bin/<app>.rb` и в
`bin/db.rb` (он загружает `config/app.rb`, поэтому ему нужны те же строки).
`cybertrain generate job` добавляет в оба файла `require "cybertrain/jobs"`,
а `generate authentication` — четыре строки, которые использует его код
(`cybertrain/jobs`, `cybertrain/mailer`, `cybertrain/mailer/later` и
`cybertrain/rate_limit`: страница заданий, письма через `deliver_later`, вход
с ограничением частоты); остальные строки добавляете вы. В приложении, написанном до разделения, стоит
`require "cybertrain"`, которая по-прежнему загружает всё: оно собирается
и работает как раньше, а быстрее его сборку делает замена этой строки на ядро
и нужные строки.

Недостающая строка обнаруживается до запуска приложения:

<!-- list: points -->
- Код на Ruby, который называет недостающую подсистему (`ReportJob.perform_later`,
  `Cybertrain::Stream.broadcast_append_to`, `Cybertrain::Mailer.deliver`,
  `rate_limit to:`), не компилируется; ошибка называет константу или метод,
  а таблица выше — нужную строку.
- Представление, вызывающее хелпер подсистемы, останавливает `spin run gen`
  (и `spin run gen -- --check`) с кодом выхода 1:
  `app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb`.
  Шаблон, отрисованный несмотря на это, выбрасывает `undefined helper 'turbo_stream_from'`.
- `./<app> worker`, `./<app> jobs` и `./<app> feeds` печатают, например,
  `the worker role needs require "cybertrain/jobs" in bin/<app>.rb` и
  завершаются с кодом 1.
- `/up` сообщает только о загруженном: без задач не проверяет, не завис ли
  воркер, без фидов — не зависли ли фиды.

Без задач кэш сам удаляет просроченные строки: первая запись процесса и первая
запись после каждого `cache_prune_interval` удаляют до тысячи таких строк.
С задачами это делает, как и раньше, плановая задача `"cybertrain cache
prune"` ([Хранилище кэша](background-and-operations.md#the-cache-store)).

Два случая gen не обнаруживает: строка `jobs_page` в `config/routes.rb` без
`cybertrain/jobs` даёт ошибку компиляции сгенерированного контроллера, а не
сообщение gen, а задача, чей `retry_on` или `discard_on` называет ошибку
`Cybertrain::Mailer`, заставляет сгенерированный `gen/app.rb` самому требовать
`cybertrain/mailer`.

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
- `cybertrain build` запускает `SPIN_DEBUG=1 spin run gen -- --embed-views`, который записывает исходный текст каждого шаблона в `gen/views.rb` как таблицу строк для этого единственного `spin build`, а затем снова запускает `SPIN_DEBUG=1 spin run gen`, чтобы вернуть закоммиченную пустую таблицу.
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
- тайм-аутом занятости около пяти секунд, который выжидается в `sleep` зелёного потока (сначала 100 мкс, затем до 1 мс), так что соединение, держащее блокировку, продолжает работать даже на одном воркере; скрипт схемы ждёт внутри SQLite (собственный `busy_timeout` SQLite засыпает на миллисекунду или больше);
- до 64 кэшированных подготовленных выражений;
- включёнными внешними ключами.

Как транзакция берёт одно из этих соединений и что на нём выполняется:
[Транзакции](models.md#transactions).

## Цикл разработки

`cybertrain server` (`SPIN_DEBUG=1 spin run gen`; `spin build NAME --
--incremental`, если какой-то Ruby-файл новее `build/bin/NAME`; затем `spin
run NAME`) в `development`
(`CYBERTRAIN_ENV` по умолчанию, кроме бинарного файла из `cybertrain build`)
также опрашивает `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`,
`gen/**/*.rb` и корни ассетов (`app/assets/**`, `app/javascript/**`,
`vendor/javascript/**`) каждые полсекунды. Представления исключены (движок сам их
перезагружает), как и `gen/views.rb`, пустой в режиме разработки.

Изменение запускает `SPIN_DEBUG=1 spin run gen && spin build NAME --
--incremental` в фоне: инкрементальная сборка Spinel, которая перекомпилирует
только те единицы C, которые затронула правка. Релиз Spinel без `--incremental`
отвергает этот флаг, и тогда цикл собирает без него. CLI и цикл собирают gen, а CLI ещё и
`bin/db.rb`, в отладочном режиме spin (`SPIN_DEBUG=1`, `-O0`): они работают
миллисекунды, а gen компилируется за малую долю времени, которое занимает
`-O2`; приложение всегда собирается в режиме release.

Успех запрашивает перезапуск (тот же флаг, что устанавливает внешний
`kill -HUP`): поток-монитор останавливает слушатель и дожидается завершения
открытых запросов, затем главный поток делает `execv` нового бинарного файла на
том же порту и с тем же PID, незаметно для клиента посреди сессии. Неудачная
сборка продолжает обслуживать старым бинарным файлом и показывает вывод
компилятора баннером в каждом HTML-ответе. Пересборки пропускаются, пока
`cybertrain build` держит `tmp/cybertrain-build.lock`. Ничего из этого не
загружается в production.

## Отличия от Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`, `rails dbconsole` | `./<app> console` вычисляет язык выражений шаблонов над моделями (в Spinel нет `eval`, так что это не Ruby); `./<app> dbconsole` открывает `sqlite3` ([Консоль](background-and-operations.md#the-console)) |
| `config/application.rb` требует railtie, которые использует приложение | `bin/<app>.rb` и `bin/db.rb` требуют `cybertrain/core` и [подсистемы](#subsystems), которые использует приложение; `require "cybertrain"` — это все они |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` в `bin/<app>.rb`: `./<app> name ARGS` запускает её с подключённой базой данных |
| Правите код — запущенное приложение подхватывает изменения | Ruby требует пересборки; в режиме разработки `cybertrain server` делает это за вас (пересборка, остановка, `execv`) |
| Правите представление — перезагрузка не нужна | Так же — в режиме разработки представления разбираются с диска при каждом запросе |
| `def new` | `def new_action` (`new` затенил бы `Klass.new(ctx)`) |
| `before_action { do_thing }` (неявный `self`) | `before_action { \|c\| c.do_thing }` — для сохранённого блока нет `instance_exec`, поэтому колбэки получают контроллер/запись явно |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — вложенные блоки получают маппер явно |
| ERB компилируется в метод; любой объект, любой метод | Интерпретируется по фиксированной грамматике/таблице диспетчеризации ([Язык шаблонов](template-language.md)) |
| Сессия хранит любой сериализуемый через Marshal объект | Значения сессии — только строки (String), в cookie, зашифрованной AES-256-GCM, как cookie store в Rails ([Cookies и сессия](requests.md#cookies-and-the-session)) |
| Множество адаптеров баз данных | Только SQLite, через FFI |
| `Article.transaction { ... }` возвращает значение блока; `raise ActiveRecord::Rollback`; точки сохранения `requires_new: true` | `Article.transaction { \|c\| ... }` передаёт в блок соединение и возвращает nil; выходят из неё, возбуждая исключение; вложенные вызовы присоединяются к внешней транзакции, точек сохранения нет ([Транзакции](models.md#transactions)) |
| `has_many :through`, enum, STI, полиморфные ассоциации | Не реализовано; `has_many`, `has_one` и `belongs_to` выводятся из внешних ключей или однострочных объявлений, с `dependent:`, `counter_cache:` и одним уровнем `includes` ([Ассоциации](models.md#associations)) |
| `pluck(:a)`, `maximum(:a)`, `group(:a).sum(:b)`, `upsert`, `update_counters`, `where(created_at: t1..t2)` | Типизированные варианты, потому что у метода Spinel один тип возвращаемого значения: `pluck_int` и ему подобные, `maximum_int`, `sum_float_by`, `upsert`, `increment(:col, by: n)`; диапазон Time — это `where_between` ([Запросы помимо `where`](models.md#querying-beyond-where)) |
| Любое имя столбца; ассоциация может затенить `errors` | Только идентификаторы ASCII; столбец, названный как метод фреймворка или ключевое слово Ruby, генерируется как `<column>_column`, конфликтующая ассоциация — под запасным именем ([Имена столбцов](models.md#column-names)) |
| `namespace`, `scope`, форматы и `respond_to` | То же ([Маршрутизация](requests.md#routing), [Форматы](requests.md#formats-and-respond_to)); JSON отдаётся через `render json:` (без шаблонов jbuilder) |
| `constraints`, `mount`, glob-сегменты | Не реализовано |
| `ActiveSupport::Concern`, включаемый во время выполнения | Concerns в `app/controllers/concerns` и `app/models/concerns`, которые `spin run gen` разворачивает во включающие классы; `include` называет concern, а метод `class_methods` не может называться так же, как метод экземпляра ([Concerns](requests.md#concerns-and-helper_method)) |
| `rescue StandardError` перехватывает неудачный `JSON.parse` | Под Spinel `JSON::ParserError` не является `StandardError`: коду приложения нужно `rescue JSON::ParserError, StandardError`. Сервер перехватывает его в крайнем случае и отвечает 500 |
| `skip_forgery_protection` в API-контроллере | CSRF выполняется до маршрутизации, поэтому API исключается по пути, `c.csrf_exempt_prefixes = ["/api/"]`, и сам аутентифицирует вызывающих ([Конфигурация](configuration.md#configuration-and-environment-variables)) |
| Rack оставляет тело запроса в gzip как есть | Тело с `Content-Encoding: gzip` — это `request.decoded_body`, распакованное с ограничением в 10 МиБ; повреждённое или слишком большое — 400; `request.body` остаётся как отправлено ([Строки запроса и тела](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` принимает только списки `column [ASC\|DESC]`; данные запроса проходят через список разрешённых значений, сырой SQL — через `order_sql` ([Порядок](models.md#ordering)). Некорректные или слишком глубоко вложенные параметры — 400 ([Строки запроса и тела](requests.md#query-strings-and-bodies)) |
| Полный бэктрейс при исключении | Класс, сообщение, строка запроса, имя/строка шаблона — Spinel не предоставляет бэктрейсов |
| Rack, его middleware и любой гем в `Gemfile` | Нет совместимости с Rack; небольшой фиксированный набор middleware; собственный `spin-index` Spinel, ограниченный тем, что компилируется в рамках его подмножества Ruby |
| minitest / RSpec | `Cybertrain::Test` — раннеры на основе рефлексии не могут работать при AOT-компиляции |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` пишет ту же структуру плюс страницу регистрации; пароли используют PBKDF2-HMAC-SHA256 (bcrypt потребовал бы библиотеку на C; `String#crypt` на macOS не поддерживает bcrypt); сброс пароля, подтверждение, блокировка и «оставаться в системе» тоже генерируются, как их добавил бы Devise ([Аутентификация](authentication.md)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` пишет пять столбцов `cover_*` и методы модели; файлы лежат на локальном диске в `storage/uploads/` и отдаются через `send_blob`; один файл на поле, без вариантов и прямых загрузок ([Добавление обложки](tutorial.md#attachments)) |
| `skip_before_action :x` | То же самое для именованных before-колбэков (у колбэка-блока нет имени, которое можно пропустить); `skip_after_action` нет |
| `resource :session` | Те же шесть маршрутов к `SessionsController`; вложение в него не поддерживается |
| `get "/x"`, затем `post "/x"` | Оба допустимы: выведенное имя второго маршрута уже занято, поэтому он остаётся без имени, как в Rails; повторяющийся `as:` по-прежнему ошибка |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, данные часовых поясов из ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` читает системные файлы TZif (`/usr/share/zoneinfo` или `TZDIR`) и преобразует целые секунды эпохи Unix (`utc_offset_at`, `utc_to_local`, `local_to_utc`); `Time.zone` на запрос и `l(time, zone:)` пока нет ([Часовые пояса](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` для вебхуков и API: каждое ожидание ограничено, непубличные адреса назначения по умолчанию отвергаются, редиректы только по просьбе, потоковые и gzip-ответы, парсер Server-Sent Events, без keep-alive (см. [Исходящий HTTP](external-services.md#outbound-http)); `Net::HTTP` из Spinel блокирует весь сервер на зависшем собеседнике |
| Action Mailer (`deliver_later`, классы мейлеров, представления) | `Cybertrain::Mailer.deliver(to:, subject:, body:, html:)` отправляет по SMTP простой текст или `multipart/alternative` с HTML-частью, отрисованной из частичного шаблона (`Views.render_mail`) (STARTTLS, неявный TLS или открытым текстом на loopback; AUTH PLAIN; каждое ожидание ограничено); `Mailer.deliver_later` отправляет его из встроенной задачи; мейлер — это модуль в `app/mailers`, методы которого возвращают `Cybertrain::MailMessage` (`deliver_later`, `deliver_now`), как сгенерированный `PasswordsMailer`; без вложений (см. [Отправка электронной почты](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, повторяющиеся задачи, Mission Control | Классы задач в `app/jobs` (`< Cybertrain::Job::Base`, `perform(args)` с Hash значений JSON, `perform_later`, `retry_on`, `discard_on`, `limits_concurrency` с ключом), `Job.handle(kind)` как короткая форма; `Scheduler.every` и `Scheduler.cron` с часовым поясом и расписанием, хранящимся в базе; страница задач (`jobs_page` в маршрутах) и `./<app> jobs`; `job_threads` потоков на процесс, на сервере или в процессах `./<app> worker`, доставка хотя бы один раз ([Фоновая работа](background-and-operations.md#background-work)) |
| `Rails.cache.fetch(key, expires_in:, race_condition_ttl:)` | `Cybertrain::Cache.fetch` в базе SQLite приложения, с теми же параметрами; значения — String, для остального `fetch_hash`, `fetch_array` и `fetch_int`; без хранилища в памяти или Redis ([Хранилище кэша](background-and-operations.md#the-cache-store)) |
| Клиент ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` держит поток подключённым, пока работает сервер (переподключения, пинги, обнаружение тишины); `WebSocket::Client` — для одного синхронного соединения; только исходящие ([Потребление потоков WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` — массив строк, сопоставляемых по подстроке без учёта регистра (без Regexp и лямбд); применяется к логу запросов и странице ошибок в режиме разработки ([Фильтруемые параметры](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (маршрут к контроллеру) | `GET /up` встроен и получает ответ до статических файлов, сессии и маршрутизатора, поэтому никакой `before_action` не выполняется; он проверяет базу данных, обработчик фоновых задач и фиды WebSocket: `200 ok` или `503` ([Эксплуатация](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Задачи `bin/rails db:...` для резервных копий (встроенных нет) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, режим 0600, переименование на место) и `./<app> db vacuum` |
| Action Cable, `turbo_stream_from`, `broadcast_append_to` | Те же имена хелперов поверх подписанных потоков, доставляемых через Server-Sent Events или WebSocket из одной таблицы SQLite; без классов каналов ([Реальное время](realtime.md)) |
| Propshaft, importmap-rails | Та же раскладка (`app/assets`, `app/javascript`, `vendor/javascript`, `config/importmap.rb`), `spin run gen` ставит дайджест и пишет в `public/assets/`; без `bin/importmap pin`, Turbo в комплект не входит ([Ассеты](assets.md)) |
| i18n в Rails, словари rails-i18n, `I18n.t`, `t(".title")` | Тот же API и ключи, английский и японский встроены; `config/locales/*.yml` компилируются `spin run gen` из подмножества YAML (без якорей, псевдонимов и тегов), списки — через `I18n.translate_list` ([Интернационализация](i18n.md)) |

<!-- table-foot: Список не исчерпывающий: более полная запись в `docs/design.md` §8 («What was deliberately left out»). -->
