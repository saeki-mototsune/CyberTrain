---
source_sha256: be6250416c64d3c07e705f9e3e4f04987365dbf6031cea8793a97c0452d9885f
---
# Как это работает

**Генерация кода при сборке.** `spin run gen` (`bin/gen.rb`) выполняет
DSL `create_table` из `db/schema.rb` и DSL `Routes.draw` из `config/routes.rb`,
чтобы получить *данные* таблиц и маршрутов, и отдельно проводит **лексическое
сканирование** (регулярными выражениями, а не парсером — Spinel не предоставляет
его во время выполнения) файлов `app/controllers/**/*.rb` и `app/models/**/*.rb`
в поисках присваиваний `@ivar =`, имён `before_action`/`after_action`/`rescue_from ... with:`
и `def` без аргументов. По этим данным он пишет в `gen/` простой, читаемый Ruby:
`gen/models/<name>.rb` (аксессоры, приведения типов, finder-методы, ассоциации,
выведенные из внешних ключей), `gen/routes.rb` (таблица маршрутов, диспетчер,
хелперы `*_path`/`*_url`), `gen/controllers.rb` (`view_assigns` и `run_callback`
для каждого контроллера), `gen/migrations.rb`, `gen/views.rb` (таблица встроенных
представлений, пустая, если сборка не для развёртывания) и `gen/app.rb`
(манифест `require_relative`). `gen/` коммитится, а не попадает в gitignore —
у `spin build`/`spin test` нет хука, чтобы сначала выполнить генерацию, поэтому
закоммиченный результат уже должен быть тем, что компилируется. CI заново
запускает `spin run gen` и падает при наличии различий, так что устаревший
сгенерированный код не может попасть в основную ветку.

**Представления интерпретируются, а не компилируются.** Файлы
`app/views/**/*.html.erb` выглядят как ERB из Rails, но во время запроса
разбираются в AST, который затем обходит интерпретатор, проходящий по дереву.
Откуда берётся исходный текст, зависит от режима: в режиме разработки (и в
тестах) движок читает `app/views/` с диска, а в режиме разработки заново
разбирает шаблон, когда тот меняется, поэтому правки представлений не требуют
пересборки. `cybertrain build` запускает `spin run gen -- --embed-views`, который
записывает исходный текст каждого шаблона в `gen/views.rb` как таблицу строк для
этого единственного `spin build`, а затем снова запускает `spin run gen`, чтобы
вернуть закоммиченную пустую таблицу; продакшен-бинарник отображает только эту
таблицу (разбирая каждый шаблон один раз) и отказывается запускаться, если она
пуста (`error: views are not embedded in this binary`). В Spinel нет `eval`,
поэтому это замкнутая грамматика (литералы, обращения к `@ivar`/локальным
переменным, вызовы через фиксированные таблицы диспетчеризации для каждого
типа, `if`/`unless`, `each`/`each_with_index`/блок одного хелпера), а не
настоящий Ruby. Полная грамматика, хелперы и пробелы:
[docs/guide/template-language.md](template-language.md).

**HTTP-сервер.** `Cybertrain::Server` — HTTP/1.1 на обычном Ruby:
`TCPServer#accept` плюс один зелёный поток Spinel на соединение (планирование
M:N, без GVL), типизированные `Request`/`Response`, без слоя Rack. Он вызывает `HttpHandler` (`call(request) -> Response`); `ContextHandler` связывает его со стеком middleware, поэтому HTTP-слой (`cybertrain/http/`, а также `Params` и `Logger`) не зависит от остального фреймворка; это обеспечивает `script/check-http-layer` в CI. TLS/HTTP/2
оставлены обратному прокси. `SPINEL_WORKERS` по умолчанию равен `1` — спайки
показали, что при такой нагрузке, ограниченной вводом-выводом, на 100
одновременных соединениях это быстрее и без зависаний.

**SQLite через FFI.** Модели общаются с SQLite напрямую через
`ffi_func`/`ffi_lib` Spinel — без расширения на C, без гема. Пул (`SizedQueue`,
по умолчанию 4 соединения) выдаёт соединения с WAL, тайм-аутом занятости около
пяти секунд (обработчик занятости повторяет попытку каждые 100 мкс, тогда как
`busy_timeout` SQLite засыпает на миллисекунду или больше), до 64 кэшированных
подготовленных выражений и включёнными внешними ключами; каждый запрос
использует привязку параметров, а не интерполяцию. Сегодня это единственный
адаптер (PostgreSQL через FFI `libpq` отмечен как возможная будущая работа).

**Транзакции.** `Cybertrain::DB.transaction { |c| ... }` (или
`Article.transaction` — то же самое под именем из Rails) берёт соединение из
пула, выполняет `BEGIN`, передаёт соединение в блок, делает `COMMIT`, когда блок
возвращается, и откатывает транзакцию с повторным возбуждением исключения, когда
блок его возбуждает. `immediate: true` выполняет `BEGIN IMMEDIATE`, который
захватывает блокировку записи SQLite в самом начале: используйте его для
транзакции, которая сначала читает, а затем пишет, чтобы параллельный писатель
заставил её ждать на `BEGIN`, а не упасть с "database is locked" при первой
записи. Пока выполняется блок, всё в этом потоке, что идёт через пул
(`save`, `update`, `destroy`, запросы Relation, `DB.with`), использует
соединение транзакции и, следовательно, входит в транзакцию:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

`DB.transaction`, вложенный в блок, присоединяется к внешней транзакции
(фиксирует только самая внешняя; исключение в любом месте откатывает всё;
точек сохранения нет). Код, который должен держать свой `rescue` в обычном
методе, использует форму без блока: `c.begin!(immediate: true)` ... `c.commit!`
и `c.rollback!` в rescue. Она возвращает nil, а не значение блока, а
`DB.transaction`, вызванный внутри блока `DB.with` (который транзакцией не
является), получает второе соединение.

**Цикл разработки.** `cybertrain server` (`spin run gen`, затем `spin run NAME`) в
`development` (`CYBERTRAIN_ENV` по умолчанию, кроме бинарного файла из
`cybertrain build`) также опрашивает `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`
и `gen/**/*.rb` каждые полсекунды (представления исключены — движок сам их
перезагружает, — как и `gen/views.rb`, пустой в режиме разработки). Изменение запускает `spin run gen && spin build NAME -- --incremental` в
фоне (инкрементальная сборка Spinel, которая перекомпилирует только те единицы
C, которые затронула правка; релиз Spinel без `--incremental` отвергает этот
флаг, и тогда цикл собирает без него); успех запрашивает перезапуск (тот же флаг, что устанавливает внешний `kill -HUP`):
поток-монитор останавливает слушатель и дожидается завершения открытых запросов,
затем главный поток делает `execv` нового бинарного файла на том же порту и с
тем же PID, незаметно для клиента посреди сессии. Неудачная сборка продолжает
обслуживать старым бинарным файлом и показывает вывод компилятора баннером в
каждом HTML-ответе. Ничего из этого не загружается в production.


## Отличия от Rails

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
| `Article.transaction { ... }` возвращает значение блока; `raise ActiveRecord::Rollback`; точки сохранения `requires_new: true` | `Article.transaction { \|c\| ... }` (= `Cybertrain::DB.transaction`) передаёт в блок соединение и возвращает nil; выходят из неё, возбуждая исключение (после отката оно возбуждается повторно); вложенные вызовы присоединяются к внешней транзакции, точек сохранения нет. `immediate: true` для `BEGIN IMMEDIATE` SQLite. `c.transaction { }` нельзя вызвать на переданном `c` под Spinel: вкладывайте `DB.transaction` или используйте `c.begin!` / `c.commit!` / `c.rollback!` |
| `has_many :through`, `includes`, `dependent:`, enum, STI, полиморфные ассоциации | Не реализовано; ассоциации выводятся только из внешних ключей схемы |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Типизированные варианты для одного столбца, потому что у метода Spinel один тип возвращаемого значения: `pluck_str` / `pluck_int` / `pluck_float` (только один столбец), `sum_int` / `sum_float`, `count_by(:a)` (`Hash{String => Integer}`) и `count_by_sql(expr)` для выражений; `Model.upsert(attrs, conflict:, update:)` принимает выражения `DO UPDATE SET` как текст SQL и не выполняет валидаций, колбэков и временных меток; `relation.increment(:col, by: n)`; `where_like(:col, text)` экранирует `\`, `%` и `_` за вас. См. [Запросы помимо `where`](models.md#querying-beyond-where) |
| Любое имя столбца; ассоциация может затенить `errors` | Имя столбца должно быть идентификатором ASCII (`[A-Za-z_][A-Za-z0-9_]*`): схема с не-ASCII именем столбца (`名前`, `prénom`) генерировалась под CRuby до PR #10, а теперь `spin run gen` её отвергает, поэтому при обновлении переименуйте столбец (имя вроде `first-name` никогда не было именем метода). Столбец, названный как метод, который сгенерированный класс или фреймворк вызывает у записи (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...), или как ключевое слово Ruby (`end`, `class`, `begin`), генерируется под именем `<column>_column` (`hash_column`: читатель, писатель и ivar) с примечанием в сгенерированном файле; его имя в SQL продолжает работать в `read_attribute`, params и `attributes["hash"]`, а шаблон достаёт его под любым из имён (`post.hash`, `post.hash_column`), кроме `errors` и `to_param`, которые шаблон разрешает как методы модели, поэтому там используйте `post.errors_column`; API запросов (`where`, `order`, `find_by`) всегда принимает имя столбца в SQL (`Post.where(hash: 1)`), а имя в Ruby — это только читатель/писатель и имя в шаблоне. Столбец, названный как другой метод Object (`display`, `tap`, `methods`), генерируется под своим именем с примечанием. `cybertrain generate scaffold` отвергает ключевые слова и зарезервированные имена (ему пришлось бы вызывать переименованный читатель) и принимает затеняющее имя с примечанием, как и генератор. Ассоциация, чьё простое имя уже занято столбцом, другой ассоциацией или методом `Model`, выдаётся под запасным именем с комментарием в сгенерированном файле: `<table>_as_<column stem>` для `has_many` (`comments_as_article`), `<stem>_as_<column>` для `belongs_to` (`author_as_author_id`) |
| `namespace`, форматы/`respond_to`, `constraints`, `mount` | Не реализовано — плоские имена, только `render json:` |
| `rescue StandardError` перехватывает неудачный `JSON.parse` | Под Spinel `JSON::ParserError` не является `StandardError`: коду приложения нужно `rescue JSON::ParserError, StandardError`. Сервер перехватывает его в крайнем случае и отвечает 500 |
| `skip_forgery_protection` в API-контроллере | CSRF — это middleware, который выполняется до маршрутизации, поэтому API исключается по пути: `c.csrf_exempt_prefixes = ["/api/"]` в `config/app.rb`. Тогда контроллер должен сам аутентифицировать вызывающих (ключ API в заголовке), и ни один маршрут с аутентификацией через сессию не должен попадать под этот префикс |
| Rack оставляет тело запроса в gzip как есть | Тело, отправленное с `Content-Encoding: gzip` (SDK или API-клиент, когда тело больше нескольких килобайт), — это `request.decoded_body`, распакованное один раз через системную zlib с ограничением размера результата (по умолчанию 10 МиБ; эндпоинт, ожидающий больше, передаёт своё, `request.decoded_body(limit)`): повреждённое тело или кодировка, отличная от gzip/identity, — это `Cybertrain::BodyUndecodable`, тело, которое распаковалось бы сверх лимита, — `Cybertrain::BodyTooLarge`; оба — `QueryInvalid`, на которые отвечается 400; `request.body` остаётся байтами в том виде, в каком они отправлены |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` принимает только списки `column [ASC\|DESC]` (каждый столбец берётся в кавычки) и на всё остальное возбуждает `ArgumentError` (500: строка принадлежит разработчику); данные запроса должны сначала пройти через список разрешённых значений, например `SORTS = { "title" => "title", "newest" => "created_at DESC" }` и `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`, потому что корректно оформленный терм всё равно может назвать отсутствующий столбец (500 от SQLite) или столбец, по которому клиенту нельзя сортировать; сырой текст ORDER BY идёт через `order_sql` (`Post.order_sql("lower(title)")`, также у relation), который никогда не должен видеть данных запроса. `limit`/`offset` у `delete_all` соблюдается (подзапрос), а параметры запроса вкладываются не более чем на 32 уровня / 4096 пар (сверх этого — 400). `Query.parse`, `Query.value_of`, `Query.decode` и `request.form_value` / `query_value` возбуждают `Cybertrain::QueryMalformed` (`StandardError` в `Cybertrain::QueryInvalid`, а не `ArgumentError`) на некорректной percent-последовательности в обеих средах выполнения (`Cookies.parse` по-прежнему сохраняет сырое значение). Они возбуждают его и на недопустимой последовательности байтов UTF-8 — сырой (каким бы ни был тег String) или percent-кодированной (Rails тоже отвечает 400 на недопустимую кодировку параметра), — как и на сыром байте, который дополнила бы только escape-последовательность (`a=\xC3%A9`); `Cookies.parse` сохраняет такое значение сырым, а путь с недопустимой последовательностью (сырой или percent-декодированной в сегменте) — тоже 400 (`request.path_segments`; некорректная escape-последовательность в пути остаётся буквальной — 404 из-за несовпадения). Код приложения, который перехватывал `ArgumentError` вокруг них, должен вместо этого перехватывать `Cybertrain::QueryInvalid` (примечание к обновлению). Запрос не хранит собственного дерева параметров (Router строит `params`, middleware читает один ключ); приложение, которому нужно всё дерево, разбирает его само, `Query.parse(request.utf8_query_string)`, и владеет результатом |
| Полный бэктрейс при исключении | Класс, сообщение, строка запроса, имя/строка шаблона — Spinel не предоставляет бэктрейсов |
| Rack, его middleware и любой гем в `Gemfile` | Нет совместимости с Rack; небольшой фиксированный набор middleware; собственный `spin-index` Spinel, ограниченный тем, что компилируется в рамках его подмножества Ruby |
| minitest / RSpec | `Cybertrain::Test` — раннеры на основе рефлексии не могут работать при AOT-компиляции |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` пишет ту же структуру (User, Session, SessionsController, before_action) и вдобавок страницу регистрации, раз консоли, где можно создать пользователя, нет; `has_secure_password` расписан методами модели User поверх `Cybertrain::Password` (PBKDF2-HMAC-SHA256 на Ruby: bcrypt потребовал бы библиотеку на C, с которой компонуется бинарный файл, а `String#crypt` на macOS не поддерживает bcrypt). Сброса пароля нет (нет мейлеров); попытки входа ограничиваются `rate_limit` (подсчёт на процесс; см. [Ограничение частоты запросов](requests.md#rate-limiting-and-the-client-address)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment post cover` записывает в приложение пять столбцов `cover_*` в таблице-владельце и методы модели (`cover_file=`, `cover_url`, ...); файлы лежат на диске в `storage/uploads/` и отдаются сгенерированным действием через `send_blob`. Один файл на поле, только локальный диск, без вариантов и прямых загрузок |
| `skip_before_action :x` | То же самое для именованных before-колбэков (у колбэка-блока нет имени, которое можно пропустить); `skip_after_action` нет |
| `resource :session` | Те же шесть маршрутов к `SessionsController`; вложение в него не поддерживается |
| `get "/x"`, затем `post "/x"` | Оба допустимы: выведенное имя второго маршрута уже занято, поэтому он остаётся без имени, как в Rails; повторяющийся `as:` по-прежнему ошибка |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, данные часовых поясов из ActiveSupport | `Cybertrain::TimeZone.find("Asia/Tokyo")` читает системные файлы TZif (`/usr/share/zoneinfo` или `TZDIR`) и преобразует целые секунды эпохи Unix (`utc_offset_at`, `utc_to_local`, `local_to_utc`); `Time.zone` на запрос и `l(time, zone:)` пока нет ([Часовые пояса](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` для вебхуков и API: каждое ожидание ограничено, непубличные адреса назначения по умолчанию отвергаются, без редиректов и keep-alive (см. [Исходящий HTTP](external-services.md#outbound-http)); `Net::HTTP` из Spinel блокирует весь сервер на зависшем собеседнике |
| Action Mailer (`deliver_later`, классы мейлеров, представления) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` отправляет простой текст по SMTP (STARTTLS, неявный TLS или открытым текстом на loopback; AUTH PLAIN; каждое ожидание ограничено); без шаблонов, HTML, вложений и очереди (см. [Отправка электронной почты](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, повторяющиеся задачи | `Cybertrain::Job.handle(kind) { \|payload\| ... }` и `Job.enqueue(kind, payload, run_at:)` (полезная нагрузка String в таблице `cybertrain_jobs`, повтор с нарастающей задержкой, затем `failed`), `Cybertrain::Scheduler.every(seconds, name) { ... }`; один поток в обслуживающем процессе, `CYBERTRAIN_WORKER=0` в остальных ([Фоновая работа](background-and-operations.md#background-work)) |
| Клиент ActionCable, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url).on_message { \|conn, data\| ... }` держит поток подключённым, пока работает сервер (переподключения, пинги, обнаружение тишины), `Cybertrain::WebSocket::Client` — для одного синхронного соединения; только исходящие, каждое ожидание ограничено (см. [Потребление потоков WebSocket](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` — массив строк, сопоставляемых по подстроке без учёта регистра (без Regexp и лямбд); применяется к логу запросов и странице ошибок в режиме разработки ([Фильтруемые параметры](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (маршрут к контроллеру) | `GET /up` встроен и получает ответ до статических файлов, сессии и маршрутизатора, поэтому никакой `before_action` не выполняется; он опрашивает базу данных и последний такт фонового обработчика: `200 ok` или `503` ([Эксплуатация](background-and-operations.md#operations-backups-vacuum-health-check)) |
| Задачи `bin/rails db:...` для резервных копий (встроенных нет) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, режим 0600, переименование на место) и `./<app> db vacuum` |
| ActionCable (сервер), asset pipeline, i18n | Не сделано (за рамками MVP, `docs/design.md` §2.3) |

Список не исчерпывающий — более полная запись в `docs/design.md` §8 ("What was deliberately left out").

## Производительность

[docs/benchmark.md](../benchmark.md) сравнивает examples/blog с тем же блогом,
написанным на Rails 8.1, — [bench/rails_blog](../../bench/rails_blog) (те же
представления, маршруты, модели и схема), оба в режиме production; каждый
сервер привязан к одним и тем же ядрам CPU одной облачной VM с 4 vCPU, а
нагрузку подаёт wrk с двух других. Медианы трёх 10-секундных прогонов, записаны 2026-10-09:

| 1 ядро CPU, 16 соединений | CyberTrain 0.2.1 | Rails 8.1.4 (YJIT, Puma) | |
| --- | --: | --: | --: |
| `GET /articles` (30 статей) | 2,641 req/s | 468 req/s | 5.6x |
| `GET /articles/1` (10 комментариев, 12 форм) | 2,450 req/s | 201 req/s | 12.2x |
| `POST /articles/2/comments` | 1,507 req/s | 390 req/s | 3.9x |
| `GET /style.css` | 13,300 req/s | 5,127 req/s | 2.6x |
| Память после нагрузки (RSS) | 10.6 MB | 126 MB | |
| От запуска до первого ответа | 0.02 s | 1.3 s | |
| Что нужно серверу | 2.5 MB (один бинарный файл) | 109 MB (Ruby, 69 гемов, приложение) | |

С jemalloc в обоих (`allocator = "jemalloc"` в spin.toml; продакшен-образ Rails
загружает его заранее) соотношения — от 2,8 до 14,6. На двух ядрах отрыв
сокращается до 2,0–5,5: второй воркер Puma удваивает Rails, тогда как
`SPINEL_WORKERS=2` добавляет CyberTrain от 9 до 58 % (на многоядерном сервере
задайте его равным числу ядер; по умолчанию он равен 1). Кроме того, бинарный
файл нужно собрать (`cybertrain build` занял там около трёх минут). В
docs/benchmark.md есть задержки, все конфигурации, методика и то, что было
оптимизировано, чтобы прийти к этому; `bench/run` повторяет измерение, а
`bench/report` выводит его таблицы.
