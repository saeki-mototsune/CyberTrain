---
description: Как CyberTrain-приложение собирается и запускается (генерация кода при сборке, интерпретируемые представления, HTTP-сервер, SQLite через FFI, цикл разработки) и отличия от Rails.
source_sha256: 3ea19a9855a39e6897647e65b9fee7a88f7353c122cf4574336a3c2fdade4d4e
---

# Как это работает

На этой странице объясняется, как CyberTrain-приложение собирается и запускается:
код, генерируемый при сборке, представления, интерпретируемые во время запроса,
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

`cybertrain server` в `development` (`CYBERTRAIN_ENV` по умолчанию, кроме
бинарного файла из `cybertrain build`) — это супервизор. Он работает под
CRuby, тем Ruby, который запускает команду `cybertrain`, сам держит
слушающий сокет и запускает на нём по одному дочернему процессу за раз:
сразу после изменения — приложение под CRuby, затем, когда Spinel соберёт
его в фоне, — скомпилированный бинарный файл. На правку Ruby сразу отвечает
CRuby-превью (на examples/blog быстрее чем за секунду), а потом
скомпилированная программа забирает порт себе, без каких-либо действий с
вашей стороны.

При запуске супервизор выполняет gen под CRuby (`ruby bin/gen.rb`, который
пишет тот же `gen/`, что и `spin run gen`), запускает приложение под CRuby
(`ruby -r cybertrain/preview bin/NAME.rb`) и начинает сборку. Оба
работают на `ruby` из `PATH`, том самом, который `cybertrain doctor`
проверяет на `fiddle`; это может быть не тот Ruby, на котором работает
команда `cybertrain`. Превью даёт фреймворку его FFI (SQLite, zlib) через прослойку поверх библиотеки Ruby
`fiddle`, которая один раз компилирует в `tmp/cybertrain-dev/ffi/` тот же
C, что использует бинарный файл. Первая сборка — `spin build NAME`, поэтому
приложение, не менявшееся с момента сборки бинарного файла, ничего не
компилирует, и бинарный файл начинает отвечать меньше чем через секунду.
Первая сборка при бинарном файле старше какого-то Ruby-файла и все
последующие сборки — это `spin build NAME -- --incremental`:
инкрементальная сборка Spinel, которая перекомпилирует только те единицы C,
которые затронула правка. Релиз Spinel без `--incremental` отвергает этот
флаг, и тогда сборка идёт без него. Вывод пишется в `tmp/rebuild.log`.

Супервизор опрашивает `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`,
`gen/**/*.rb` и корни ассетов (`app/assets/**`, `app/javascript/**`,
`vendor/javascript/**`) десять раз в секунду. Представления исключены (обе
среды выполнения перечитывают их с диска), как и `gen/views.rb`, пустой в
режиме разработки. Изменение отменяет идущую сборку, выполняет gen под
CRuby, заменяет дочерний процесс новым дочерним процессом CRuby и начинает
новую сборку. Когда сборка удалась и за это время ничего не изменилось,
супервизор останавливает дочерний процесс CRuby и запускает
`build/bin/NAME` на том же сокете: сначала остановка, потом запуск, а сокет
всё это время остаётся открытым, так что запрос, пришедший во время
переключения, немного подождёт и получит ответ. Ни один не отвергается.

Каждый ответ приложения несёт `X-Cybertrain-Runtime: cruby` или `spinel`, а
каждая HTML-страница — неброскую строку в правом нижнем углу:

- `CRuby preview · Spinel building…`: страницу отрисовал CRuby, пока идёт
  сборка.
- `Spinel ready — reload`: теперь отвечает скомпилированный бинарный файл;
  перезагрузите, чтобы увидеть его страницу.
- `CRuby preview · Spinel build failed`: CRuby продолжает отвечать, а
  страница показывает вывод компилятора баннером.
- `CRuby preview · Spinel binary failed`: бинарный файл не запустился или
  завершился; снова отвечает CRuby, баннер показывает, что сообщил
  бинарный файл, а следующее изменение снова соберёт и попробует его.
- `Spinel`: страницу отрисовал скомпилированный бинарный файл.
- `Source changed — reload`: файл изменился после того, как страница была
  отрисована.
- `CRuby preview`: страницу отрисовал CRuby, и ничего из перечисленного выше
  не подходит.

Строка сама поддерживает себя в актуальном состоянии; страницы приложения
никогда не перезагружаются сами, так что заполняемая форма не пропадёт.
Когда gen завершается с ошибкой или приложение не может запуститься под
CRuby (например, `SyntaxError`), супервизор сам отвечает на каждый запрос
страницей 503, которая показывает ошибку и то, чего он ждёт; эта страница,
собственная страница супервизора, сама обновляется каждые 2 с, пока
дочерний процесс не сможет ответить, а сохранение, исправляющее ошибку,
возвращает приложение. Пока
`cybertrain build` держит `tmp/cybertrain-build.lock`, ничего не
перегенерируется и не перезапускается; сервер наверстает, когда блокировка
исчезнет. Супервизор хранит свои файлы в `tmp/cybertrain-dev/`; на одно
приложение работает один супервизор, а Ctrl-C останавливает сборку,
дочерний процесс и сервер.

Чего превью не показывает:

- Компилируется ли код. Это скажет фоновая сборка, когда закончится.
- Различия сред выполнения, записанные в
  [spikes/NOTES.md](../../spikes/NOTES.md) (иерархия исключений, кодировки
  String на сокетах, `Float#round` на суженном Float и остальное). Они
  проявляются, как только начинает отвечать бинарный файл.
- Время и конкурентность: у CRuby есть GVL и потоки ОС, а `SPINEL_WORKERS`
  для него ничего не значит.

Фоновая работа (задания, планировщик, поллер потоков, WebSocket-фиды)
выполняется в том дочернем процессе, который отвечает, поэтому правка
перезапускает её дважды, в CRuby и затем в бинарном файле, а клиенты
Server-Sent Events и WebSocket переподключаются дважды. Страница, которая
работает в превью, готова, только когда её отдаёт и бинарный файл, и
считаются только скомпилированные тесты (`spin test`).

`cybertrain server --spinel` вместо этого запускает скомпилированный цикл,
как и `spin run NAME`, набранный напрямую, и нативный CLI, который
собирает `spin install`: `SPIN_DEBUG=1 spin run gen`; `spin build NAME --
--incremental`, если какой-то Ruby-файл новее `build/bin/NAME`; затем `spin
run NAME`. Бинарный файл сам опрашивает те же файлы каждые полсекунды, при
изменении запускает в фоне `SPIN_DEBUG=1 spin run gen && spin build NAME
-- --incremental` и в случае успеха останавливает слушатель, дожидается
завершения открытых запросов и делает `execv` нового бинарного файла на том
же порту и с тем же PID; неудачная сборка продолжает обслуживать старым
бинарным файлом и показывает вывод компилятора баннером в каждом
HTML-ответе, а пересборки пропускаются, пока `cybertrain build` держит свою
блокировку. CLI и этот цикл собирают gen, а CLI ещё и `bin/db.rb`, в
отладочном режиме spin (`SPIN_DEBUG=1`, `-O0`): они работают миллисекунды, а
gen компилируется за малую долю времени, которое занимает `-O2`; приложение
всегда собирается в режиме release. Когда превью не может работать,
`cybertrain server` выводит одну строку, начинающуюся с `preview
unavailable:`, и запускает скомпилированный цикл. Так бывает, когда
`CYBERTRAIN_ENV` задаёт окружение, отличное от `development`, когда
фреймворк приложения старше превью (в нём нет `cybertrain/preview.rb` или
`cybertrain/dev/supervision.rb`), когда в `PATH` нет `ruby` или когда этот
`ruby` не удаётся запустить, он не отвечает за 10 с или не может загрузить
`fiddle` (`cybertrain doctor` это проверяет). Ничего из этого не
загружается в production.

## Отличия от Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`, `rails dbconsole` | `./<app> console` вычисляет язык выражений шаблонов над моделями (в Spinel нет `eval`, так что это не Ruby); `./<app> dbconsole` открывает `sqlite3` ([Консоль](background-and-operations.md#the-console)) |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` в `bin/<app>.rb`: `./<app> name ARGS` запускает её с подключённой базой данных |
| Правите код — запущенное приложение подхватывает изменения | Изменения Ruby видны сразу через CRuby-превью; скомпилированный бинарный файл забирает порт, когда его сборка завершится (`cybertrain server`) |
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
