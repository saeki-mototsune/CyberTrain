---
source_sha256: d98dfd28dfd1249b9c4db726377bcf36bb504e62f2f74284cbab8f3eca23bfd3
---
# Тестирование приложения

Тесты приложения — это классы в духе Rails в каталоге `test/`, и
`cybertrain test` запускает их все как одну скомпилированную программу.
Minitest и RSpec находят тестовые методы через рефлексию, чего
AOT-компилятор сделать не может, поэтому `spin run gen` переписывает каждый
тестовый класс в обычные методы и записывает одну таблицу диспетчеризации
по всем тестам.

## Как написать тест

`cybertrain new` записывает `test/test_helper.rb`; каждый тестовый файл,
как в Rails, начинается с его подключения:

```ruby test/test_helper.rb
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # Вспомогательные методы для всех тестов пишутся здесь.
end
```

```ruby test/models/article_test.rb
require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "title must be present" do
    article = Article.new(body: "a body long enough to pass length")
    assert_not article.save
    assert_includes article.errors.full_messages, "Title can't be blank"
  end
end
```

```ruby test/controllers/articles_controller_test.rb
require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", text: @article.title
  end

  test "creates an article" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough" } }
    end
    assert_redirected_to article_path(Article.last)
  end
end
```

Базовых классов три, те же, что в Rails: `ActiveSupport::TestCase`
(модели, задачи, почтовики — всё, что обходится без запроса),
`ActionDispatch::IntegrationTest` (запросы,
[Интеграционные тесты](#integration-tests)) и `ViewComponent::TestCase`
(`render_inline`, [Тестирование потоков и компонентов](#testing-streams-and-components)).
Приложение может положить свой базовый класс в `test/test_helper.rb` или
`test/support/` и наследоваться от него. Вспомогательные методы, константы
и `private` пишутся в теле класса, как в Rails; каждый тест выполняется на
новом экземпляре, поэтому переменные экземпляра, заданные в `setup`,
принадлежат этому тесту. `fixtures :all` и `require "test_helper"`
принимаются и сами ничего не делают: для каждого теста загружаются все
фикстуры.

Каждый тест выполняется в таком порядке:

1. все таблицы очищаются, включая таблицы фреймворка (задачи, кэш,
   сообщения Turbo, расписания, фиды, аренды), и id снова начинаются с 1;
2. вставляются фикстуры ([Фикстуры](#fixtures));
3. сбрасываются `Mailer.deliveries`, счётчики ограничения частоты и
   `I18n.locale`, а часовой пояс становится тем, что настроен в
   `config/app.rb`;
4. `setup` (сначала суперкласса; несколько блоков `setup do` по порядку);
5. тело теста, если до него ничего не упало;
6. `teardown`, всегда: после упавшей проверки, исключения или упавшего
   setup (несколько блоков `teardown do` в обратном порядке, затем
   суперкласса);
7. часы снова идут по реальному времени, и каждый приёмник, запущенный
   тестом, останавливается.

Rails вместо этого откатывает каждый тест в транзакции. Здесь это не
подходит: у SQLite в этом фреймворке нет точек сохранения, поэтому
собственная `transaction` теста завершила бы внешнюю, а потоки задач
используют другие соединения, которые не увидели бы строки теста.

## Запуск тестов

```sh
cybertrain test                                         # все тесты
cybertrain test test/controllers                        # файлы в каталоге
cybertrain test test/models/article_test.rb             # один файл
cybertrain test -n "creates an article"                 # один тест по имени
cybertrain test -n test_creates_an_article              # или по имени метода
cybertrain test -n /article/                            # тесты, в имени которых есть "article"
```

`cybertrain test` выполняет `SPIN_DEBUG=1 spin run gen` (gen собирается в
отладочном режиме spin, как его собирает любая команда CLI), который
записывает `gen/tests.rb` (программу) и переписанную копию каждого
тестового класса в `gen/test/`; обе коммитятся вместе с остальным `gen/`.
Затем он компилирует `gen/tests.rb` в `build/test/tests` (релизная
сборка), если какой-либо вход новее этого бинарника, и запускает его. В
программу входят все `test/**/*_test.rb` и все остальные `test/*.rb`,
кроме `test/test_helper.rb`; в `test/support/` (его подключает хелпер) и
`test/fixtures/` тестов нет. Перед первым тестом программа удаляет
`storage/test.sqlite3`, мигрирует новую базу и загружает на ней приложение
(без потоков задач, планировщика и фидов: задачи тест выполняет сам).
`CYBERTRAIN_TEST_DATABASE` указывает вместо неё другой файл. Поскольку
программа удаляет файл, на котором тестирует, она помечает каждую
созданную ею базу (`PRAGMA application_id`, собственное значение) и удаляет
или очищает существующий файл, только если на нём есть эта метка, если это
`storage/test.sqlite3` самого приложения (как бы ни был записан путь) или если файл пуст. Всё остальное отклоняется с
кодом выхода 2, ничего не удаляя: `cybertrain test refuses to delete <path>: not a database cybertrain test created; delete it yourself or name another file`. Файл с именем
`development.sqlite3` или `production.sqlite3` (в любом регистре) или тот
же файл, что `storage/development.sqlite3` или `storage/production.sqlite3`,
отклоняется как `cybertrain test refuses to delete <path>: it is the development database` (или `production`). Имя должно быть путём к
файлу: `:memory:` и URI `file:` отклоняются (`cybertrain test refuses CYBERTRAIN_TEST_DATABASE ":memory:": name the test database by its file path (not :memory: or a file: URI)`). После обновления
файл, который вы раньше указывали в `CYBERTRAIN_TEST_DATABASE`, не имеет
метки и отклоняется один раз: удалите его (вместе с `-wal` и `-shm`), и
`cybertrain test` создаст помеченный; стандартному `storage/test.sqlite3`
ничего не нужно. Путь, который становится символической ссылкой, пока база
создаётся, отклоняется с кодом выхода 2: `cybertrain test refuses <path>: it became a symlink while the test database was created (nothing was marked or migrated); remove it and run again`. Очистка перед каждым тестом
затрагивает только таблицы основной базы, никогда — TEMP- или
присоединённую таблицу с тем же именем. Известные ограничения: метка
переживает `cp` тестовой базы, поэтому копия, названная как тестовая база
(или к которой подключается тест), очищается; прогон, убитый между
созданием файла и его пометкой, оставляет непомеченный файл по указанному
вами пути, который в следующий раз отклоняется (удалите его); каталог на
месте `storage/test.sqlite3` вызывает исключение, когда программа его
удаляет.

Программа готовит тестовое окружение, как в Rails, если только
`config/app.rb` не задаёт то же самое сам: защита от подделки запросов
выключена, журнал запросов молчит (уровень `:none`, который всё равно пишет
строки ошибок), строки лога текстовые (экспортированный
`CYBERTRAIN_LOG_FORMAT` не читается), отчёты об ошибках в Sentry не
отправляются (экспортированный `CYBERTRAIN_SENTRY_DSN` опустошается), письма
хранятся в `Mailer.deliveries`
(`:test`) и `force_ssl` выключен (переменные
`CYBERTRAIN_MAIL_DELIVERY_METHOD` и `CYBERTRAIN_FORCE_SSL` для тестов не читаются, даже если
некорректны), загрузки пишутся в `tmp/test_uploads/`, который очищается при
каждом запуске, а проверки хоста нет (экспортированная `CYBERTRAIN_HOSTS` её
не включает). `www.example.com`, хост хелперов `*_url`, всегда входит в
разрешённые хосты.

```text вывод — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:14)
         Expected change of 1, got 0 (from 2 to 2)
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

Заголовок на файл, строка на тест, затем итоги, без времени выполнения.
Указанная строка — это строка `test "..."` теста: у скомпилированной
программы нет трассировки стека, поэтому строка упавшей проверки
неизвестна. Код выхода — 1, если какой-то тест упал, 0 в противном случае
и 2 для аргументов, которые команда не принимает. То, что печатает сам
тестируемый код (строка вывода команды), появляется между строками тестов.
Тест, setup, teardown или хук, бросивший `NotImplementedError`, другую
`ScriptError` или `SystemStackError`, — это `ERR`, как и любое другое
исключение, и прогон продолжается; завершают его только `Interrupt`,
`SystemExit` и `NoMemoryError`. Под Spinel настоящее переполнение стека
по-прежнему завершает процесс ошибкой сегментации: до раннера доходит только
`SystemStackError`, брошенный самим кодом.

Аргументы: `-n NAME` оставляет тест с таким именем или именем метода, а
`-n /TEXT/` — тесты, имя или имя метода которых содержит TEXT как простой
текст (`.`, `?` и `()` означают сами себя). TEXT с одним из
`^ $ \ * + [ ] { } |` отклоняется с кодом выхода 2, потому что это не
регулярное выражение: `-n /^test_create/: the text between the slashes is
a plain substring of the test name, not a regexp (^ would be looked for as
itself); write the text to look for (-n /test_create/)`. Файл или каталог
оставляют свои тесты; `FILE:LINE` отклоняется (`line filters are not
supported; give the file, and -n for the name`); `--` завершает опции.
Фильтр, который не оставляет ни одного теста, выводит `no test matched the
filter` перед итогами и завершается с кодом 0. Добавление или удаление
файла в `test/` компилирует программу заново.

**Чего стоит изменение.** Аргумент-файл и `-n` выбирают, какие тесты
запускать, а не что компилировать: программа всегда содержит все тесты,
поэтому смена фильтра использует тот же бинарник, а правка любого теста
(или чего-либо ещё, из чего собрана программа) заново компилирует всю
программу, предварительно пересобрав `bin/gen`. Измерено 2026-11-12 и
2026-11-13 на общей облачной машине с 4 vCPU (на вашей машине цифры будут
другими): 149 тестов examples/blog в 21 файле скомпилировались в первый раз
примерно за 527 с (весь первый запуск занял 656 с, бинарник — 10,2 МБ), а
последующий `cybertrain test test/controllers` без изменений использовал
тот же бинарник и начался примерно через 1 с (собственный запуск блога,
2026-11-13); приложение блога с тремя тестовыми файлами на восемь тестов
компилировалось от 162 до 233 с при пике около 2,2 ГБ памяти в бинарник
на 8,1 МБ (2026-11-12). Напишите несколько тестов,
прежде чем запускать их, а работая над одним, сужайте запуск, а не сборку.

`gen/tests.rb` отклоняется, и `cybertrain test` завершается с кодом 1,
причиной и без компиляции, когда два тестовых или вспомогательных файла
определяют один и тот же метод или константу верхнего уровня (в одной
программе они слились бы в одно: перенесите общий хелпер в
`test/support/` или внутрь класса), а также в остальных случаях из раздела
[Что gen отклоняет в тестовом классе](#what-gen-refuses-in-a-test-class).

## Фикстуры

```yaml test/fixtures/users.yml
alice:
  email_address: alice@example.com
  admin: true
```

```yaml test/fixtures/articles.yml
one:
  title: First post
  body: A body long enough to pass the length check.
  author: alice
  created_at: 2026-11-01 09:00:00

two:
  id: 42
  title: Second post
  body: Another body long enough.
  author: alice
```

`test/fixtures/<table>.yml` имеет форму Rails: метки, под ними столбцы. gen
читает файлы при запуске тем же подмножеством YAML, что и
[словари](i18n.md#dictionaries), и отклоняет с `файл:строка` файл, который
не является таблицей из `db/schema.rb`, ключ, который не является ни
столбцом, ни `belongs_to` модели, ERB (`<%` где угодно: `eval` нет; время
относительно текущего задайте в `setup` или через `travel_to`), значение
не того типа, что у столбца (несуществующую дату, целое за пределами 64
бит, `yes` для булева), две метки с одним id и метку `belongs_to`, которая
не указывает ни на одну строку файла родителя. `DEFAULTS`, как и в Rails, —
не строка.

- Строка без `id:` получает id, который Rails вычисляет для её метки
  (`ActiveRecord::FixtureSet.identify`), поэтому у метки тот же id, что и в
  приложении на Rails. `author: alice` записывает в `author_id` id alice.
- Дата и время — в UTC. Опущенные в строке `created_at` и `updated_at`
  получают время часов в момент вставки строки перед каждым тестом.
- `articles(:one)` возвращает `Article.find` этой строки; неизвестная
  метка вызывает `Cybertrain::Test::FixtureNotFound`. Одна метка за вызов.
- Фикстура проверяется при запуске gen, но её ошибка останавливает только
  прогон тестов: `spin run gen` (а значит, и `cybertrain db migrate`, к
  которому фикстура скаффолда появляется раньше) продолжает работу, а
  `cybertrain test` выводит `test/fixtures/<table>.yml:<строка>: ...` и
  завершается с кодом 1.
- Как и в Rails, фикстура, указывающая на родителя, не даёт этого родителя
  удалить: как только в `comments.yml` есть `article: one`, тест скаффолда
  «should destroy article» падает на внешнем ключе. Объявите
  `has_many :comments, dependent: :destroy`, направьте дочерние фикстуры
  на другую строку (`article: two`) или удаляйте строку, на которую
  ничего не ссылается.
- Нет: `fixtures :articles` (загружается каждый файл),
  `articles(:one, :two)`, полиморфных меток (`commentable: one (Article)`;
  пишите столбцы `_id` и `_type`), меток `has_and_belongs_to_many`, якорей
  и псевдонимов.

## Интеграционные тесты

`ActionDispatch::IntegrationTest` отправляет запросы загруженному
приложению внутри процесса, без сокета, с новым хранилищем cookie для каждого
теста:

- `get`, `post`, `patch`, `put`, `delete`, `head` (путь, `params: {}`,
  `headers: {}`), как их пишет Rails. Каждый возвращает
  `Cybertrain::Response` (Rails возвращает статус), который также доступен
  как `response` (`response.body`, `response.status`,
  `response.header(name)`).
- `params:` принимает вложенные Hash и отправляет их так, как отправляет
  форма (`article[title]=New`); значением может быть String, Symbol, число,
  `true` / `false`, nil, Date или Time (отправляются как текст, который
  столбец прочитает обратно), так что тест скаффолда может отправить
  значения записи как есть. Array отклоняется.
- `fixture_file_upload("cover.png", "image/png")` в `params:` у `post`,
  `patch` или `put` отправляет запрос как multipart; файл читается из
  `test/fixtures/files/`.
- `headers:` принимает имя заголовка или форму Rails `HTTP_ACCEPT`.
- Хелперы путей из `config/routes.rb` работают, как в контроллере. Хелпер
  `*_url` пишет `http://www.example.com/...`; URL на этом хосте
  запрашивается по своему пути, и `assert_redirected_to` сравнивает любую
  из двух форм. URL на другом хосте отклоняется.
- `cookies` — хранилище cookie теста, `Cybertrain::Test::ClientCookies`:
  `cookies[:user]` или `cookies["user"]` (сырое значение, ещё в
  процентной кодировке), `[]=`, `key?`, `delete`, `keys`, `size`, `empty?`
  и `to_h`. Cookie, у которого `Max-Age` или `Expires` прошёл по часам, в
  том числе после `travel_to` за этот момент, исчезает (`Max-Age` важнее
  `Expires`); cookie, записанный тестом через `[]=`, не истекает никогда.
  Нечитаемый `Max-Age` (`Max-Age=abc`) игнорируется, а отрицательный делает
  cookie истёкшим. В отличие от Rails, у него нет `each`, `length`,
  `include?`, `fetch` и `==`: перенесённый тест читает для этого
  `cookies.to_h`.
- `follow_redirect!` запрашивает `Location` последнего ответа (без его
  `#fragment`); после ответа, который не является перенаправлением, он
  валит тест: `follow_redirect!: the last response was 200, not a redirect
  (3xx with a Location)`.
- `assert_response(:success)` (или любой
  символ статуса, или число; `:error` означает ровно 500, тогда как Rails
  принимает любой 5xx), `assert_redirected_to(path)`, `assert_select`,
  `assert_turbo_stream`.
- Нет: `session`, `flash`, `assigns`, `request`, `host!` и `as:`.
  Проверяйте вместо этого страницу (`assert_select`, `response.body`).

**Защита от подделки запросов** в тестах выключена, если `config/app.rb` не
задаёт `csrf`, как в тестовом окружении Rails, поэтому `post` не нужен
токен. Тест самой проверки включает её для нескольких запросов:

```ruby
test "a form without the token is refused" do
  with_forgery_protection do
    post articles_path, params: { article: { title: "x" } }
    assert_response :forbidden
  end
end
```

Внутри блока форме нужен `authenticity_token` страницы, которую запросил
тест; когда блок заканчивается, всё возвращается назад, даже если проверка внутри упала,
а то, что задал сам тест (корень загрузок, пояс, локаль, уровень журнала),
сохраняется.

**Вход.** `cybertrain generate authentication` записывает
`test/support/session_test_helper.rb`, включённый в каждый интеграционный
тест: `sign_in_as users(:one)` (пароль пользователей из фикстур —
`"password"`; `remember: true` отмечает «Оставаться в системе»),
`sign_out`,
`authenticity_token_in(response.body)` (токен первой формы страницы, для
запросов внутри `with_forgery_protection`) и `open_session` — второй браузер со своими cookie
(`phone = open_session`, затем `phone.sign_in_as users(:two)` и
`phone.get ...`). Каждый запрос приходит с `127.0.0.1`; тест, которому
нужен другой адрес клиента, создаёт свой
`client = Cybertrain::Test::Client.new(Cybertrain::Test.app)` и задаёт
`client.peer_address = "203.0.113.7"` (собственные методы клиента —
`client.get(path, headers)` и `client.post(path, fields, headers)`).

## Проверки

`assert`, `assert_not` (`refute`), `assert_equal`, `assert_not_equal`,
`assert_nil`, `assert_not_nil`, `assert_includes`, `assert_not_includes`,
`assert_empty`, `assert_not_empty`, `assert_match` / `assert_no_match`
(Regexp или String как подстрока), `assert_in_delta(expected, actual,
delta = 0.001)`, `assert_nothing_raised { }` и `flunk` — как в Minitest.
`assert_equal` падает с текстом Minitest (`Expected: 1` и `  Actual: 0` на
двух строках), как и более новые проверки; `assert_includes`,
`assert_nil` и `flunk` сохраняют собственные, более короткие тексты.
`assert` и `refute` принимают сообщение вторым аргументом. Формы с блоком
принимают лямбду, переданную позиционно:

```ruby
assert_difference -> { Article.count }, 1 do
  post articles_path, params: { article: { title: "New", body: "A body long enough" } }
end
assert_no_difference(-> { Article.count }) { post articles_path, params: { article: { title: "" } } }
assert_changes(-> { article.reload.title }, from: "Old", to: "New") { article.update(title: "New") }

message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
assert_includes message, "999"
```

- `assert_raises` принимает класс (подкласс тоже подходит, как в
  Minitest), часть имени класса строкой (`assert_raises("RecordNotFound")`)
  или ничего (любой StandardError) и возвращает **сообщение** исключения, а
  не само исключение: там, где в Rails пишут `error = assert_raises(X) { }`
  и затем `error.message`, используйте возвращённую String. Под Spinel
  метод возвращает один тип, а тесты читают именно сообщение.
- Проверки с блоком возвращают nil, а не значение блока.
- Нет: `assert_predicate` (для него нужен вычисляемый `send`: пишите
  `assert article.valid?`), строковых выражений в `assert_difference` (им
  нужен `eval`), Array или Hash выражений и аргумента-сообщения у остальных проверок.
  Из имён Minitest `refute_*` есть только `refute`: пишите `assert_not_equal`,
  `assert_not_nil` и другие формы `assert_not_*`; вызов `refute_equal`
  останавливает сборку тестовой программы, так как его никто не определяет.

## Путешествие во времени

```ruby
test "a remembered session survives day 15" do
  sign_in_as users(:one), remember: true
  travel_to 15.days.from_now do
    get root_path
    assert_response :success
  end
end

test "the cache entry expires" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 5.minutes)
  travel 6.minutes
  assert_nil Cybertrain::Cache.read("k")
end
```

`travel_to(time)`, `travel(seconds)`, `freeze_time` и `travel_back` —
хелперы Rails: каждый останавливает часы и отбрасывает доли секунды; с
блоком прежнее время возвращается, когда блок заканчивается (даже с
исключением), без блока путешествие длится до `travel_back` или конца
теста. За ним следует всё, чему фреймворк ставит время: `Time.current`,
`Time.now` в тестовой программе, метки времени записей, истечение кэша,
ограничения частоты, срок жизни сессии, `run_at` задач, истечение токенов,
планировщик. Ожидания и таймауты (чтение потоков, приёмники) остаются на
реальном времени, поэтому остановленные часы никогда их не подвешивают. В
продакшене `Time.now` — системные часы: код, который должен следовать
путешествию, читает `Time.current`, как и советует Rails. `Time.now` возвращает местное время в `TZ` процесса,
как встроенный метод, а `Time.current` — в UTC. `travel_to` принимает Time,
а не Date, и `Time.zone.local` нет: записывайте момент через
`Time.utc(...)`. Планировщик сохраняет то, что помнит (последнее
восстановление, время следующих запусков), при путешествии во времени;
тест, который путешествует, пока работают потоки планировщика или
воркеров, не поддерживается.

Длительности — это целые секунды: `5.minutes` — это `300`, а `2.weeks.ago`
и `3.days.from_now` возвращают Time на часах. `1.month` нет (у месяца нет
длины в секундах): при выполнении это `NoMethodError`. Используйте
календарные методы Time: `Time.current.months_ago(1)`,
`advance(months: 1)`, `beginning_of_day`, `end_of_month`, `yesterday`
([Время и часовой пояс](models.md#times-and-the-time-zone)). `advance`
прибавляет часы, минуты и секунды как прошедшее время, после календарной
части, и принимает целые числа; реальные часы сохраняют микросекунды.

## Тестирование потоков и компонентов

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "Alice"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
```

`render_inline(component, content: "")` и `render_inline(partial:,
locals: {})` рендерят вне всякого запроса, возвращают HTML (Rails
возвращает фрагмент Nokogiri и принимает содержимое блоком) и сохраняют его
для `assert_select`. Хелпер, которому нужен запрос, вызывает
`Cybertrain::Views::OutsideRequest`.

`assert_select(selector, equality = nil, count:, minimum:, maximum:,
text:)` проверяет последний `render_inline` или ответ этого теста (без них
падает: «No response yet») и возвращает найденные элементы:

- Селекторы: тег, `.class`, `#id`, `[attr]`, `[attr="v"]`, составные
  (`a.btn[href="/x"]`), комбинаторы потомка и ребёнка (`>`) и список
  (`h1, h2`). Псевдоклассы, `+` и `~`, другие операторы атрибутов, обратная косая черта
  (`assert_select: CSS escapes (\) are not supported`) и форма с вложенным
  блоком падают с `assert_select: <feature> is not supported`.
- `text:` — это String, сравниваемая с текстом каждого элемента, или
  Regexp, применяемый к нему. В тексте каждая последовательность пробельных
  символов становится одним пробелом, а края обрезаются (Rails только
  обрезает края). Вторым аргументом может быть позиционная форма Rails:
  текст (String или Regexp), количество (Integer) или `true` / `false`;
  количество может
  быть и Range вроде `2..3`; количество, заданное там и ещё в `count:`,
  `minimum:` или `maximum:`, отклоняется, как и отрицательный,
  перевёрнутый или не имеющий обоих концов Range (`assert_select: a Range count needs both ends (got 2..)`).
- HTML читается так, как написан, без исправлений, которые сделал бы
  браузер (и Nokogiri за `assert_select` в Rails): `table > tr` совпадает
  с таблицей, написанной без `<tbody>`, `p > div` совпадает с `<p><div>`, а
  пропущенный закрывающий тег (`<li>a<li>b`, `<p>a<p>b`) или
  самозакрывающийся `<div/>` валит проверку с указанием позиции. Шаблоны
  самого фреймворка читаются все.

Трансляция — это строка `cybertrain_messages`, поэтому проверки потоков
читают таблицу, без поллера и сокета:

```ruby
test "a new comment is broadcast and answered with a Turbo Stream" do
  article = articles(:one)
  payloads = assert_broadcasts(article, 1) do
    post article_comments_path(article), params: { comment: { commenter: "Dave", body: "Hi" } },
                                         headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end
  assert_includes payloads[0], 'target="comments"'
  assert_turbo_stream action: "append", target: "comments"
end
```

`assert_broadcasts(stream, count) { }` считает, что было отправлено в поток
(имя или запись) за время блока или, без блока, с начала теста, и
возвращает содержимое; `assert_no_broadcasts(stream)` требует, чтобы не
было ничего. `assert_turbo_stream(action:, target:, count: 1)` читает
последний ответ, который должен быть `text/vnd.turbo-stream.html`, или
последний `render_inline`. Чтобы прочитать живой поток, как браузер,
`client.get_stream(path, events: n)` у `Cybertrain::Test::Client`
выполняет потоковый ответ в памяти ([Реальное время](realtime.md)).

## Тестирование почты

В `cybertrain test` `Cybertrain.config.mail_delivery_method` равен `:test`,
если `config/app.rb` не задаёт его сам: `deliver_now`, `Mailer.deliver` и задача `deliver_later` проверяют
сообщение и сохраняют его в `Cybertrain::Mailer.deliveries` вместо
подключения, а список очищается перед каждым тестом. Тестовая программа
даёт письмам отправителя `from@example.com`, когда приложение его не
задаёт.

```ruby
test "a reset mails a link" do
  assert_emails 1 do
    post passwords_path, params: { email_address: users(:one).email_address }
  end
  mail = Cybertrain::Mailer.deliveries.last
  assert_equal "Reset your password", mail.mail_subject
  assert_includes mail.mail_body, "/passwords/"
end
```

`assert_emails(count) { }` считает письма, отправленные блоком; письмо,
поставленное в очередь в блоке через `deliver_later`, сначала отправляется,
а упавшая почтовая задача валит проверку со своей ошибкой.
`assert_no_emails { }` требует, чтобы писем не было. Читатели сообщения —
`mail_to`, `mail_from`, `mail_subject`, `mail_body` и `mail_html`. Тест
самого пути SMTP задаёт `Cybertrain.config.mail_delivery_method = :smtp` и
возвращает `:test` в `teardown` (настройка не сбрасывается между тестами),
как в разделе [Тестирование исходящих вызовов](#testing-outbound-calls).
Вне тестового окружения `:test` запускается с предупреждением, и письма не
отправляются.

## Тестирование задач

```ruby test/jobs/notify_comment_job_test.rb
require "test_helper"

class NotifyCommentJobTest < ActiveSupport::TestCase
  test "a comment queues its notification, which runs" do
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    assert_enqueued_jobs 1, "NotifyCommentJob"
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id }
    assert_equal 1, perform_enqueued_jobs
    assert_no_enqueued_jobs
  end

  test "the jobs a block queues run at once" do
    performed = perform_enqueued_jobs { ReminderJob.perform_in(3600, { "id" => 1 }) }
    assert_equal 1, performed
  end
end
```

- `assert_enqueued_jobs(count, kind = "")` считает задачи в очереди (одного
  вида, если он указан); `assert_no_enqueued_jobs(kind = "")` требует,
  чтобы их не было.
- `assert_enqueued_with(kind, args)` требует задачу этого вида в очереди,
  аргументы которой содержат каждый указанный ключ с равным значением
  (`"comment_id" => 7` совпадает с JSON-значением `7`; `comment_id: 7`
  тоже работает).
- `perform_enqueued_jobs { }`, встроенная форма Rails, выполняет блок,
  затем каждую задачу, поставленную в очередь в нём, и задачи, которые
  ставят они, независимо от их `run_at`, и возвращает, сколько их
  выполнилось. Задача, бросившая исключение, валит тест со своим классом и
  ошибкой и не повторяется; задача, которую приложение отбрасывает
  (`discard_on`), считается выполненной.
- `perform_enqueued_jobs(now = Time.current)` без блока выполняет по одной
  каждую задачу, срок которой наступил к `now`, пока такие есть. Повтор,
  назначенный на потом, остаётся в очереди: переместитесь за него через
  `travel` или передайте более поздний `now`. Обе формы валят тест после
  10 000 задач (задача, которая снова ставит себя в очередь).
- `clear_enqueued_jobs` удаляет задачи из очереди;
  `WelcomeJob.perform_now(args)` выполняет одну задачу напрямую, и
  исключение доходит до теста.
- Плановые задачи выполняются по одному такту через
  `Cybertrain::Scheduler.run_due(Time.current.to_i)` (секунды эпохи).

## Тестирование исходящих вызовов

Когда тестируемый код отправляет веб-хук ([Исходящий HTTP](external-services.md#outbound-http))
или письмо по SMTP ([Отправка почты](external-services.md#sending-e-mail)),
тест принимает его внутри процесса: `Cybertrain::Test::HttpReceiver` и
`Cybertrain::Test::SmtpReceiver` слушают на `127.0.0.1`, записывают то,
что пришло, и отвечают заготовленным ответом. Приёмник, запущенный в
тесте, останавливается после него, даже если тест упал.

```ruby test/integration/signup_hook_test.rb
require "test_helper"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

class SignupHookTest < ActiveSupport::TestCase
  setup do
    Cybertrain.config.http_allow_private = true   # иначе HttpClient отклоняет loopback
  end

  teardown do
    Cybertrain.config.http_allow_private = false
    Cybertrain.config.mail_delivery_method = :test
  end

  test "a sign-up posts a webhook" do
    hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    hook.start                                   # занимает свободный порт и возвращает его
    SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # код приложения
    req = hook.received_request                  # ждёт не больше 5 с; nil, если ничего не пришло
    assert_equal "POST", req.http_method
    assert_equal "/hooks/signup", req.http_target
    assert_equal "application/json", req.http_header("Content-Type")
    assert_includes req.http_body, "ann@example.com"
  end

  test "a refused recipient is reported" do
    Cybertrain.config.mail_delivery_method = :smtp
    smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
    port = smtp.start
    mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
    assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
    mail = smtp.received_message
    assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
                 mail.transcript.first(3)
    assert_not mail.delivered?
  end
end
```

`HttpReceiver.new` принимает заготовленные `status:`, `headers:`, `body:` и
`chunked:` (`respond_with` меняет их между запросами); запрос возвращается
как `ReceivedRequest` (`http_method`, `http_target`, `http_path`,
`http_headers` с именами в нижнем регистре, `http_header(name)`,
`http_body` с декодированным chunked-телом). `SmtpReceiver` разыгрывает 220,
EHLO (с 8BITMIME, если не `eight_bit_mime: false`, и с AUTH PLAIN при
`auth: true`), MAIL, RCPT, DATA и QUIT; `reject:` проваливает любой из
`:greeting`, `:ehlo`, `:mail`, `:rcpt`, `:data` или `:message` с заданным
ответом. У `ReceivedMessage` есть `envelope_from`, `envelope_recipients`,
`message_data` (с отменённым dot-stuffing), `message_header(name)`,
`message_body` и `transcript` команд; для HTML-письма `message_parts`
декодирует его в `"subject"`, `"text"` и `"html"`. Оба принимают одно
соединение, если `max:` не указывает больше (`received_requests` /
`received_messages` возвращают все). Каждое ожидание ограничено: приёмник
сдаётся после `accept_window:` (10 с) без соединения, молчащий клиент
отключается после `read_timeout:` (5 с), а `stop` (его можно вызвать
дважды) завершает поток и закрывает порт, так что приёмник никогда не
заберёт соединение более позднего теста. Приёмник, запущенный вне теста
(в начале файла), за вас не останавливается.

Фид тестируется так же, с `Cybertrain::Test::WebSocketReceiver`,
WebSocket-сервером на `127.0.0.1`, работающим по сценарию: каждое
соединение проигрывает список `Cybertrain::Test::WsStep` (`"accept"`,
`"send_text"`, `"expect"`, `"silent"`, `"close"`, `"drop"`,
`"echo_until_close"`, ...), а кадры, отправленные клиентом, возвращаются
без маски из `ws_received`.

```ruby test/integration/trades_feed_test.rb
require "test_helper"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # константа: блоки не видят локальных переменных

# Блоки пишутся в методе, где используются их параметры.
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

class TradesFeedTest < ActiveSupport::TestCase
  test "a trade message is stored" do
    rx = Cybertrain::Test::WebSocketReceiver.new
    rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                  Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
    rx.start
    subscribe_trades(rx.url("/trades"))
    Cybertrain::WebSocket.start!               # тестовая программа никогда не запускает фиды
    # ... опрашивать TICKS не дольше нескольких секунд ...
    Cybertrain::WebSocket.stop!
    assert_equal ["tick"], TICKS
    assert_equal "subscribe", rx.ws_received[0].rec_data
  end
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` делает задержки
переподключения точными. `test/websocket_integration.rb` в этом
репозитории показывает полный тест.

## Тестирование журнала и отчётов об ошибках

`X-Request-Id` ответа — это идентификатор запроса. Чтобы читать строки лога,
тест даёт `Cybertrain.logger` объект `StringIO` на время работы, за которой
наблюдает, и потом возвращает логгер на место, в отдельном методе (под Spinel
`rescue` или `ensure` вокруг `yield` пишется в простом методе):

```ruby test/integration/logging_test.rb
require "test_helper"
require "stringio"

class LoggingTest < ActionDispatch::IntegrationTest
  test "a comment's job logs the request's id" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Ann", body: "Hi" } }
    rid = response.header("X-Request-Id").to_s
    log = StringIO.new
    perform_jobs_logging_to(log)
    assert_includes log.string, "] [#{rid}] new comment "
  end

  private

  def perform_jobs_logging_to(io)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end
end
```

Время в начале строки меняется от запуска к запуску (заморозьте его через
`freeze_time`, чтобы сравнить), поэтому сравнивайте то, что после него:
уровень, теги и сообщение. Журнал запросов приложения в тестах молчит
(`log_level :none`), но строка `ERROR` упавшей задачи пишется и тогда; тест,
который выполняет падающую задачу, перехватывает логгер, как выше, иначе
строка появится среди строк тестов.

Отчёты об ошибках идут в `Cybertrain::Test::SentryReceiver` — Sentry на
`127.0.0.1`, который загружает `cybertrain/test_help`. `cybertrain test`
игнорирует экспортированный DSN, поэтому тест присваивает его сам и потом
возвращает прежний. Пример запускает `NotifyCommentJob` из examples/blog,
который бросает собственный `NotifyCommentJob::CommentGone`, когда
переданного комментария больше нет, и отбрасывает себя ([Retries and discards](background-and-operations.md#retries-and-discards)); задача из
учебника только пишет в лог, поэтому сначала добавьте ей этот `find_by`,
класс и `discard_on CommentGone`:

```ruby test/integration/error_reporting_test.rb
require "test_helper"

class ErrorReportingTest < ActionDispatch::IntegrationTest
  setup do
    @sentry = Cybertrain::Test::SentryReceiver.new
    @sentry.start
    @saved_dsn = Cybertrain.config.sentry_dsn
    @saved_private = Cybertrain.config.http_allow_private
    Cybertrain.config.sentry_dsn = @sentry.dsn                # http://public@127.0.0.1:<port>/1
    Cybertrain.config.http_allow_private = true               # иначе HttpClient отклоняет loopback
  end

  teardown do
    Cybertrain.config.sentry_dsn = @saved_dsn
    Cybertrain.config.http_allow_private = @saved_private
  end

  test "a job whose comment is gone is discarded and reported" do
    NotifyCommentJob.perform_later("comment_id" => 999_999, "article_id" => articles(:one).id)
    perform_enqueued_jobs                                       # отбрасывание не валит тест
    event = @sentry.received_events(1)[0]                      # ждёт не более 5 с
    assert_equal "NotifyCommentJob", event.sentry_field("transaction")
    assert_equal "NotifyCommentJob::CommentGone", event.sentry_field("exception.values.0.type")
  end
end
```

`SentryReceiver.new(status: 200, max: 50, accept_window: 10.0)` отвечает на
каждый конверт, как Sentry (другой `status:`, например 429, изображает
отказывающий Sentry); `dsn(project = "1", prefix = "")` — DSN, который
отправляет на него, а `received_events(count, wait = 5.0)` возвращает то, что
пришло. Каждый элемент — `Cybertrain::Test::SentryEnvelope`: `sentry_path`,
`sentry_auth` (`X-Sentry-Auth`), `sentry_content_type`, `sentry_body` (три
строки JSON), `sentry_field("a.b.0.c")` для поля события (`""`, если его
нет) и `sentry_header_field(name)` для заголовка конверта. Ключ `extra`, в
котором есть точка (`job.attempt`), нельзя прочитать через `sentry_field`,
который делит путь по точкам: читайте его из `sentry_body`. Приёмник,
запущенный в тесте, останавливается после него, как и остальные.

Подписчик, добавленный в тесте, убирается перед следующим тестом (тот, что
добавил `config/app.rb`, остаётся), а перед каждым тестом репортёр доставляет
то, что ещё в очереди, и забывает своё окно устранения дублей, так что один и
тот же сбой в двух тестах попадает в отчёт в обоих.
`Cybertrain.error.drain_reports` ждёт (не более 2 с) отчёты из очереди — для
теста, который читает, что получил подписчик:

```ruby
# В начале файла теста:
REPORTS_SEEN = Array.new(0) { "" }
class SeenReports < Cybertrain::ErrorSubscriber
  def report(event)
    REPORTS_SEEN << event.error_class
    nil
  end
end

# В тесте:
Cybertrain.error.subscribe(SeenReports.new)
get "/articles/999999"
Cybertrain.error.drain_reports
assert_equal 0, REPORTS_SEEN.size             # о 404 не сообщается
```

## Что gen отклоняет в тестовом классе

gen переписывает тестовый класс в методы: `test "shows it" do` становится
`def test_shows_it` (символ ASCII вне `[A-Za-z0-9_]` превращается в `_`, любой другой — в
`_u<hex>_` (код символа строчными, закрытый `_`), так что `"ログ"` даёт
`test__u30ed__u30b0_`, а `"café x"` — `test_caf_ue9__x`; `-n` принимает и имя
метода, и написанное имя), а блоки `setup do` и `teardown do`
становятся методами `setup` и `teardown`, которые вызывают `super`. То, что переписывание не может перенести в
точности, приводит к отказу от файла — никогда молча неверная копия или
потерянный тест:

- имя теста, которое не является простым строковым литералом
  (интерполяция), или имя с экранированием, которое gen не читает (`\u`,
  `\x`, `\c`, `\C`, `\M` или восьмеричное: напишите сам символ; `\n`,
  `\t` и `\"` читаются);
- два теста, имена методов которых совпадают в одном классе, включая
  `def test_x`;
- и `setup do`, и `def setup` в одном классе (то же для `teardown`), а
  также `def setup` или `def teardown` без `super` в классе, родитель
  которого — базовый класс приложения (его блоки `setup do` не
  выполнились бы);
- `def test_x` с параметрами или после `private` или `protected` (Minitest
  выполняет только публичные тестовые методы);
- `setup { }` и `setup :name` (пишите `setup do ... end`) и параметры
  блока у `test`, `setup` или `teardown`;
- `next`, `break` или `redo` в теле теста, setup или teardown, в том числе
  внутри `if`, `unless`, `case` или `begin` этого тела (используйте
  `return`), и `return <value>` (каждый возвращает nil);
- тестовый класс, вложенный в другой класс или модуль, тестовый класс,
  открытый дважды, и `setup do` в повторно открытом
  `ActiveSupport::TestCase` (напишите базовый класс приложения с
  `setup do` и наследуйтесь от него);
- строка `test`, `setup` или `teardown`, которую gen не может разместить в
  теле класса (внутри условия, цикла, строки или heredoc), однострочная
  форма, которая не заканчивается `end`, `end`, за которым идёт код, и
  отступы, смешивающие табуляции и пробелы;
- `require_relative`, аргумент которого не строковый литерал.

Отклонённый файл не останавливает `spin run gen`, поэтому сервер
разработки, `cybertrain db migrate` и `cybertrain build` продолжают
работать: gen записывает `gen/tests.rb`, который только выводит причину, а
`cybertrain test` без компиляции выводит `<path>:<line>: <reason>` и
завершается с кодом 1. Исправьте названную строку. `test "name" do` можно
писать и как `test"name"` или с табуляцией. `test "x" do`, написанный после
`private`, не отклоняется, но становится приватным методом копии и падает
при выполнении, тогда как Rails его выполняет: держите тесты выше `private`. Другие известные
ограничения: имя, содержащее текст `_u3042_`, получает то же имя метода,
что и имя с `"あ"` на его месте (в одном классе gen отклоняет такую пару);
`def setup` в модуле не проверяется на `super`; класс на два уровня ниже
базового класса приложения обязан вызывать `super`, даже если этот базовый
класс не определяет `setup`; а пока тестовый файл отклонён,
`spin run gen -- --check` не сравнивает устаревшие копии в `gen/test/` (CI
тогда падает на `cybertrain test`).

`cybertrain test` так же отклоняет `test`, `setup` или `teardown` верхнего уровня в
`test/test_helper.rb` или `test/support/` (они никогда не выполнились бы),
`def render_inline` верхнего уровня (он заменил бы метод фреймворка),
`assert_select ... do` и `render_inline ... do`, а также повторяющиеся
хелперы верхнего уровня из раздела [Запуск тестов](#running-the-tests).
Файл в форме класса выполняется только через `cybertrain test`: под
`spin test` тело его класса вызывает «class-form tests run with
`cybertrain test FILE`».

## Форма верхнего уровня

Прежняя форма — блоки `test` на верхнем уровне файла — продолжает работать
и в `cybertrain test` (как здесь, с приложением и фикстурами программы), и
под `cybertrain spin test`:

```ruby test/legacy.rb
require "test_helper"

setup do
  Cybertrain.config.http_allow_private = true
end

teardown do
  Cybertrain.config.http_allow_private = false
end

test "shows an article" do
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  res = client.get("/articles/#{articles(:one).id}")
  assert_response res, :success
  assert_includes res.body, articles(:one).title
end

Cybertrain::Test.run!
```

Блоки `setup do` и `teardown do` верхнего уровня выполняются до и после
каждого теста своего файла. `cybertrain spin test` компилирует каждый
`test/*.rb` в отдельную программу и сравнивает её вывод с
`test/<name>.rb.expected`; там нет ни очистки, ни фикстур (им нужен список
таблиц gen), а `Cybertrain::Test.run!` выполняет тесты файла. В
`cybertrain test` тесты файла выполняются вместе с остальными, после
очистки и фикстур, а `run!` ничего не делает. Под `spin test` никто не
загружает приложение для файла, поэтому такой файл загружает его сам, как
это делали вспомогательные файлы 0.4 (`AppTest.boot`, `BlogTest.boot`), и
фикстур не использует. `Cybertrain::Test::Client` управляет приложением с
хранилищем cookie, включая CSRF (`client.get`, `client.post(path, fields,
headers)`, `client.follow_redirect!`, `client.response` и формы с двумя
аргументами `assert_response res, :ok` и `assert_redirected_to res, path`).
Снимок теста, который обращается к SQLite, берётся из скомпилированного
бинарника: `script/regen-snapshot test/<name>.rb` в репозитории
фреймворка или
`rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`.

## Обновление с 0.4

- Добавьте `test/test_helper.rb`, как показано выше, и уберите из
  вспомогательного файла то, что он делал при загрузке (`AppTest.boot`,
  `BlogTest.boot`, миграцию базы): тестовая программа загружается на новой
  базе перед первым тестом, а повторная загрузка лишь отнимает время.
- Замените шаг CI `spin test` на `cybertrain test`.
- Два файла, определяющих один и тот же хелпер или константу верхнего
  уровня (по `new_client` в каждом, как их писали генераторы 0.4),
  отклоняются вместе: перенесите хелпер в `test/support/` или
  переименуйте один из них.
- Перед каждым тестом все таблицы очищаются, поэтому более поздний тест
  уже не может полагаться на строки, созданные предыдущим: перенесите
  такие данные в фикстуры или в `setup`.
- Точки подмены часов удалены: `Cybertrain::Cache.clock=`,
  `Cache.system_clock`, `RateLimit.current_time=`, `SessionStore#fixed_now=`,
  `Application.status_now=` и `Background.supervisor_clock=`. Используйте
  `travel_to`, `travel` или `freeze_time`, блок которых возвращает время
  без вашего собственного `ensure`.
- Почта в тестах хранится в `Cybertrain::Mailer.deliveries`; тест,
  читающий письма на `Test::SmtpReceiver`, сначала задаёт
  `Cybertrain.config.mail_delivery_method = :smtp`.
- Тест хелпера, написанный `generate helper` версии 0.4, определяет
  `render_inline(source)` верхнего уровня, который конфликтует с методом
  фреймворка: переименуйте его в этом файле в `render_helper_template`,
  вместе с вызовами.
- `1.month.ago` пишется `Time.current.months_ago(1)`.
- `assert_equal` падает с двухстрочным текстом Minitest; снимок
  проходящего теста не меняется.
- `cybertrain generate authentication`, запущенный снова, записывает тесты
  в форме классов и называет каждый старый файл, который они заменяют
  (`test/authentication.rb`, `test/support/app_test.rb`, ...); `--force`
  их удаляет.
- Тест, который искал строку лога целиком, с уровнем в квадратных скобках
  в начале, ищет уровень и сообщение по отдельности (`" ERROR "` и
  `"password reset mail not sent: "`): теперь строка начинается со времени и
  может нести идентификатор запроса
  ([Журнал](background-and-operations.md#logs)).
- Экспортированные `CYBERTRAIN_LOG_FORMAT` или `CYBERTRAIN_SENTRY_DSN` больше
  не доходят до тестов; чтобы тестировать с ними, задайте их в
  `config/app.rb` или присвойте DSN в тесте.

## Непрерывная интеграция

`cybertrain new` записывает для приложения `.github/workflows/ci.yml`. Он
вызывает действие `setup-cybertrain` этого репозитория
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
закреплённое на теге релиза CLI; действие устанавливает заголовки SQLite,
zlib и OpenSSL и Ruby, читает из `spin.lock` коммит фреймворка, на котором
зафиксировано приложение, получает фреймворк на этом коммите и запускает
его `cybertrain doctor` и `cybertrain setup` (с `~/.cybertrain/spinel`,
кэшируемым по релизу Spinel и образу раннера). Затем workflow проверяет,
что `spin.lock` актуален (`spin lock && git diff --exit-code spin.lock`) и
`gen/` свеж (`SPIN_DEBUG=1 spin run gen -- --check`), и запускает
`cybertrain test`. Когда шаги тулчейна меняются, меняется действие, а не
копия каждого приложения. Коммит читается из `spin.lock`, поэтому workflow
предполагает git-зависимость по умолчанию; приложение, созданное с
`--path`, передаёт действию checkout фреймворка как `framework-path`.
