---
source_sha256: 73e63b06a3c0e42694f5489b74b58f65464e506bfc88c1ba18759c91bd5771dd
---
# Конфигурация

## Конфигурация и переменные окружения

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

`Cybertrain::Config` сначала читает переменные окружения; `config/app.rb` их переопределяет:

| Переменная | Атрибут | По умолчанию |
| --- | --- | --- |
| `CYBERTRAIN_ENV` | `env` | `"development"`; `"production"` в бинарном файле из `cybertrain build` (также `"test"`) |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | обязательна в production; в dev/test генерируется автоматически в `tmp/secret_key` |
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`; `0.0.0.0` слушает на всех интерфейсах (контейнеры) |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | Режим разработки принимает `localhost`, `127.0.0.1`, `[::1]`; разделённые запятыми точные имена хостов расширяют этот список (без схемы, порта и подстановочных знаков). Другие хосты получают 403 до статических файлов, сессий, маршрутизации и диагностики. Это не связано с адресом прослушивания; production и test не применяют эту защиту режима разработки |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`; также `Strict` или `None` (`None` всегда добавляет `Secure`); любое другое значение останавливает сервер при запуске |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`; `1` или `true` добавляет `Partitioned` (и `Secure`) |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`; `1` или `true` делает `request.client_ip` (то, что засчитывает `rate_limit`) последним адресом `X-Forwarded-For` соединения с loopback — для обратного прокси на том же хосте (см. [Ограничение частоты запросов](requests.md#rate-limiting-and-the-client-address)); сокращение для `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`; разделённые запятыми адреса IPv4/IPv6 или CIDR (`172.16.0.0/12,10.0.0.0/8`), для соединений с которых `request.client_ip` берётся из последнего адреса `X-Forwarded-For`, — для прокси, доступного по сети, например kamal-proxy в его контейнере; неверная запись останавливает сервер при запуске |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`: наибольшая страница, которую выдаёт `params.page_number` и принимает `Relation#page` (см. [Постраничный вывод](models.md#pagination)); значение, не являющееся числом не более чем из 18 цифр, или меньше 1 заменяется значением по умолчанию |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`; разделённые запятыми имена заменяют список. Значение параметра, имя которого содержит одно из них (без учёта регистра ASCII: `password` совпадает и с `user[password]`), записывается как `[FILTERED]` в лог запросов и на страницу ошибок режима разработки; `[]` в `config/app.rb` это отключает |
| `CYBERTRAIN_WORKER` | `worker` | `true`; `0` или `false` не даёт этому процессу выполнять задачи по расписанию и фоновые задачи (см. [Фоновая работа](background-and-operations.md#background-work)); `scheduler_interval` (1 с), `job_poll_interval` (5 с) и `job_max_attempts` (5) задаются в `config/app.rb` |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`; путь встроенной проверки работоспособности (см. [Эксплуатация](background-and-operations.md#operations-backups-vacuum-health-check)); пустое значение её отключает; значение без ведущего `/` останавливает сервер при запуске. `health_worker_stale` (300 с) задаётся в `config/app.rb` |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`; `1` или `true` позволяет `Cybertrain::HttpClient` подключаться к loopback, частным и другим непубличным адресам (см. [Исходящий HTTP](external-services.md#outbound-http)) |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`; SMTP-сервер, через который отправляет `Cybertrain::Mailer` (см. [Отправка электронной почты](external-services.md#sending-e-mail)) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`: порт режима — 587 для `starttls`, 465 для `tls`, 25 для `none`; всё, кроме значений от 1 до 65535, считается 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`: без AUTH; если задано, мейлер аутентифицируется через AUTH PLAIN |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`; секрет, никогда не пишется в лог, в стартовый баннер и в сообщения об ошибках |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`: отправитель, которого использует `Mailer.deliver`, когда ему не передан `from:` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`; также `tls` (неявный TLS) или `none` (открытый текст, учётные данные — только на loopback); обоим режимам TLS нужен `require "cybertrain/net/tls"` |

Используйте `None` (вместе с `CYBERTRAIN_SESSION_PARTITIONED=1`) только для
приложения, которое показывается во фрейме другого сайта; браузер должен
обращаться к приложению по HTTPS.

Другие атрибуты с фиксированными переопределяемыми значениями по умолчанию:
`views_root` (`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 недели), `session_secure` (`true` в production, что
помечает cookie сессии как `Secure`; `false` в остальных окружениях, хотя
`SameSite=None` и `Partitioned` всё равно добавляют `Secure`), `pool_size` (4),
`static_files`/`csrf` (`true`), `csrf_exempt_prefixes` (`[]`: префиксы путей,
например `"/api/"`, чьи не-GET-запросы пропускают проверку CSRF, — для
эндпоинта, который программы вызывают с собственными учётными данными; каждый
должен начинаться и заканчиваться на `/` и не быть просто `/`, иначе запуск
завершается сбоем; префикс сопоставляется с путём в том виде, в каком он
отправлен, поэтому percent-кодированное написание всё равно проверяется; ни
один другой маршрут не должен совпадать с путём под этим префиксом, а
освобождённый контроллер не должен полагаться на сессию для аутентификации,
поскольку сессия там всё равно загружается), `max_body_bytes` (10 МиБ: на более
длинное тело запроса, в том виде, в каком оно отправлено, отвечается 413 до
его чтения; увеличьте для больших загрузок; распакованный размер тела в gzip
ограничивается отдельно через `request.decoded_body(limit)`), `max_render_depth`
(12 одновременно открытых отрисовок: страница и её партиалы; увеличьте для
партиалов, которым обоснованно нужна более глубокая рекурсия; значение должно
быть не меньше 1, иначе запуск завершается сбоем). Примечание к обновлению:
вложенность отрисовки, прежде неограниченная, теперь по умолчанию ограничена 12
(страница — глубина 1, поэтому партиалы могут вкладываться на 11 уровней;
макет отрисовывается после страницы и во вложенность не входит), и приложение
с более глубоким деревом (комментарии в виде веток, меню категорий) получает
ошибку шаблона, пока не задаст `max_render_depth`. Загрузка файлов:
`max_upload_bytes` (5 МиБ на загруженный файл; не должен превышать
`max_body_bytes`), `max_multipart_parts` (128 частей, включая текстовые поля,
не более 4096), `upload_root` (`"storage/uploads"`, куда пишет
`Cybertrain::BlobStore`; создаётся при первой загрузке, а не при запуске).

**Заголовки безопасности:** каждый ответ, который пишет сервер (действия,
middleware статических файлов, страницы ошибок и страница диагностики режима
разработки, собственные 400/411/413/500 сервера и HEAD), несёт
`X-Content-Type-Options: nosniff` и `X-Frame-Options: SAMEORIGIN`, если только
ответ уже не задаёт заголовок с таким именем (в любом регистре): `Response#to_http`
добавляет их после собственных заголовков ответа и только при их отсутствии,
поэтому `response.set_header("X-Frame-Options", "DENY")` в действии отправляет
ровно ваше значение, один раз. Переключателя в `Config`, чтобы отключить их для
всего приложения, намеренно нет; встраиваемый виджет переопределяет заголовок
в собственных ответах (заголовок `Content-Security-Policy: frame-ancestors ...`
в современных браузерах имеет приоритет над `X-Frame-Options`). Из-за `nosniff`
браузеры понимают `Content-Type` буквально: middleware статических файлов знает
обычные расширения `public/` (html, css, js/mjs, изображения, включая webp и
avif, шрифты, wasm, pdf, аудио и видео, json, csv, xml), а всё остальное
отдаётся как `application/octet-stream`, то есть на скачивание; добавьте
расширение в `Cybertrain::Static::EXTENSIONS`, если приложению нужно показывать
в браузере другое. Обратный прокси, который сам отдаёт `public/`, обходит эти
заголовки (см. [docs/deploy.en.md](../deploy.en.md)). `Cybertrain::Test::Client`
вызывает приложение внутри процесса и никогда не сериализует ответ, поэтому
эти два значения по умолчанию в нём не видны; проверяйте их на `response.to_http`.

**Фильтруемые параметры:** строка `Started GET "/login?..."` в логе запросов и
страница ошибок режима разработки (её строка запроса и дамп params и тела JSON)
показывают значение каждого параметра, названного в `config.filter_parameters`,
как `[FILTERED]`, как это делает `filter_parameters` в Rails, поэтому `?token=`
в URL или пароль, отправленный в форму, которая не прошла проверку, не
появляется в логе запросов фреймворка и на странице ошибок режима разработки.
Заменяются только значения: остальная часть строки запроса пишется в лог как
отправлена (управляющие символы экранируются). Список сопоставляется по
подстроке без учёта регистра; расширьте его в `config/app.rb`
(`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`) или замените
через `CYBERTRAIN_FILTER_PARAMETERS`. Значения, которые действие пишет в лог
само, не фильтруются; там спрашивайте `Cybertrain::ParameterFilter.filter?(name)`
или `ParameterFilter.filter_query(text)`.

**Развёртывание:** `cybertrain build` создаёт `dist/`: бинарный файл `dist/NAME`
со встроенными представлениями, `dist/public/` (статические ресурсы; или
пусть их отдаёт обратный прокси), а также `dist/storage/` (по умолчанию файл
SQLite) и `dist/tmp/`. Запускайте его из `dist/` с заданной
`CYBERTRAIN_SECRET_KEY_BASE`; это production, если `CYBERTRAIN_ENV` не говорит
иного, а `./NAME migrate` применяет вкомпилированные в него миграции. Бинарный
файл говорит только на обычном HTTP/1.1; для TLS и HTTP/2 поставьте перед ним
nginx/Caddy (в production cookie сессии имеет флаг `Secure`, поэтому отдавайте
приложение по HTTPS). В production исключение даёт ответ 500, а голый ответ с
ошибкой (текстовый 404 маршрутизатора, `head :not_found`, `render plain:`)
заменяется на `public/<status>.html`, если такой файл существует; ошибки,
которые действие отрисовывает как HTML или JSON, проходят без изменений.
`SIGTERM` прекращает приём соединений, даёт уже выполняющимся запросам
завершиться (с ответом `Connection: close`; простаивающие keep-alive-соединения
закрываются сразу) и выходит, когда они закончатся, или по истечении
`drain_timeout` сервера (10 с). Цикл слежения и пересборки никогда не работает в production. [docs/deploy.en.md](../deploy.en.md)
(на японском: [docs/deploy.md](../deploy.md)) проводит через весь процесс: `cybertrain new`, сервер Ubuntu,
systemd, Caddy с HTTPS, повторные развёртывания, откаты и резервные копии.

**Kamal:** `cybertrain new` также записывает то, что нужно [Kamal 2](https://kamal-deploy.org):
`Dockerfile`, который выполняет `cybertrain setup` и `cybertrain build` на этапе
сборки в Ubuntu и копирует `dist/` в облегчённый этап того же выпуска (миграции
при запуске, затем обслуживание на `0.0.0.0:3000`), `.dockerignore`,
`config/deploy.yml` (kamal-proxy с Let's Encrypt перед приложением, проверка
работоспособности по `public/up.html`, файл SQLite на томе в `/app/storage`)
и `.kamal/secrets` (`KAMAL_REGISTRY_PASSWORD` и `CYBERTRAIN_SECRET_KEY_BASE`
из окружения). Заполните значения, помеченные `CHANGE ME`, сделайте коммит и
выполните `kamal setup`;
подробности — в [docs/deploy-kamal.md](../deploy-kamal.md) (часть 8
учебника по развёртыванию).
[examples/blog](../../examples/blog#deploying-with-kamal) содержит ту же
конфигурацию, собранную с фреймворком из этой рабочей копии.

### Настройки приложения

Собственные настройки приложения (публичный базовый URL, переключатель
функции, интервал, SMTP-хост) объявляются в том же `Config` с типом,
переменной окружения и значением по умолчанию:

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
  c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
  c.setting_bool :worker, env: "MYAPP_WORKER", default: true
  c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
end

Cybertrain.config.string_setting(:base_url)
Cybertrain.config.bool_setting(:worker)
Cybertrain.config.int_setting(:prune_interval)
```

Каждое значение читается один раз, когда `config/app.rb` выполняется при
запуске. Пустая или незаданная переменная означает значение по умолчанию.
Булево значение принимает `1`/`true` или `0`/`false`; целое — десятичные цифры
(с необязательным ведущим `-`) в пределах `min..max` (обе границы
необязательны). Любое другое значение заменяется значением по умолчанию, и в
лог пишется строка `[WARN]` об этом. Чтение необъявленного имени или имени,
объявленного с другим типом, возбуждает `ArgumentError`, как и повторное
объявление имени. Тесты меняют значение через `set_string_setting`,
`set_int_setting` и `set_bool_setting`. `./NAME help` перечисляет все
объявленные настройки с их переменными и значениями по умолчанию, а стартовый
баннер выводит текущие значения (`=> Settings: base_url="" worker=true ...`);
настройка с `secret: true` в обоих местах показывается только по имени, как
`[FILTERED]`. Аксессора `Cybertrain.config.base_url` нет: в Spinel нет
`define_method`, поэтому читатели — это типизированные методы, принимающие имя.

## Часовые пояса

Spinel не поставляется с базой данных tz, а установка `ENV["TZ"]` для
преобразования времени меняет его для всех потоков процесса.
`Cybertrain::TimeZone` вместо этого читает системные файлы часовых поясов:
`/usr/share/zoneinfo/<name>` или `$TZDIR/<name>`, если задан `TZDIR`
(в облегчённом образе контейнера установите пакет `tzdata`). Он разбирает TZif
версий 1–4 (RFC 8536), включая правило POSIX TZ, на которое «облегчённый» файл
опирается после своего последнего перехода, и кэширует каждый пояс на всё время
жизни процесса (копирование при записи, поэтому поиск из нескольких воркеров
не берёт блокировку).

Всё выражается целыми секундами эпохи Unix. *Локальная эпоха* — это показание
настенных часов, считаемое так, будто это UTC, поэтому арифметика настенного
времени — это простое сложение, а `TimeZone.civil_to_epoch` /
`TimeZone.epoch_to_civil` переводят между ней и
`[year, month, day, hour, minute, second]`:

```ruby
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
tokyo.found?                         # false для неизвестного имени: тогда пояс ведёт себя как UTC
tokyo.utc_offset_at(Time.now.to_i)   # => 32400
tokyo.abbreviation_at(Time.now.to_i) # => "JST"

# Ближайшие 09:00 в Токио:
now = Time.now.to_i
today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
```

На переходе на летнее время и обратно `local_to_utc` детерминирован: настенное
время, которое пропускает переход вперёд (02:30 в день перевода часов вперёд в
США), читается со смещением до перехода, поэтому попадает после него
(03:30 EDT); настенное время, которое повторяет переход назад, даёт более ранний
момент. `find` принимает только относительное имя из символов `A-Za-z0-9_+-./`
без пустых сегментов и сегментов `.` или `..`, поэтому имя пояса, взятое из
профиля пользователя, не может добраться до файла вне каталога поясов;
неизвестный или некорректный пояс не кэшируется, а `"UTC"` не нужен файл.
Хелперов форматирования для шаблонов (`l(time, zone:)`) пока нет.
