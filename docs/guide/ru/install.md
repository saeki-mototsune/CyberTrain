---
source_sha256: c032393ee1441a62fcb16089fd5dd57ffbf4c06b5032ca07d5dd2f103da52cde
---
# Установка

Что CyberTrain нужно на вашей машине, как установить команду `cybertrain`, все её
команды и как она сама устанавливает за вас Spinel и фреймворк.

> [!NOTE]
> Чтобы попробовать CyberTrain, ничего не устанавливая, откройте [песочницу](site:playground.html):
> GitHub Codespaces открывает в вашем браузере, в VS Code, блог из учебника, команду `cybertrain` и
> зафиксированный релиз Spinel. Тот же образ запускается и локально под Docker.

## Требования

- Spinel в релизе из `Cybertrain::SPINEL_TAG`
  ([cybertrain/version.rb](../../cybertrain/version.rb); его выводит `cybertrain doctor`, и
  `SPINEL_TAG` CI в [.github/workflows/ci.yml](../../.github/workflows/ci.yml) тот же) —
  релиз [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), форка matz/spinel, в котором исправления,
  нужные CyberTrain, появляются раньше, чем в релизе основного проекта;
  с другими версиями не тестировался. Вручную его устанавливать не нужно:
  команда `cybertrain` собирает этот релиз в `~/.cybertrain`, когда он впервые
  понадобится (`cybertrain setup` делает это по запросу), если только `spinel`
  этого релиза уже нет в `PATH`, — см. [Как устанавливается Spinel](#how-spinel-is-installed).
- Для его сборки: инструменты C (`cc` или компилятор, указанный в `CC`) и `make`
  — Spinel компилирует каждую программу в C, — а также `git` и `curl`.
- Заголовки и библиотека SQLite 3 (`libsqlite3-dev` в Debian/Ubuntu; на macOS
  входят в Xcode command line tools) — модели используют FFI Spinel напрямую,
  а не гем.
- Заголовки и библиотека zlib (`zlib1g-dev` в Debian/Ubuntu; в macOS SDK) —
  тела запросов в gzip (`request.decoded_body`) распаковываются через
  системную zlib, привязанную тем же способом.
- Заголовки и библиотека OpenSSL (`libssl-dev` в Debian/Ubuntu) — их линкует
  каждое приложение: cookie сессии и `cookies.encrypted` шифруются AES-256-GCM
  через пакет `openssl` Spinel, который Spinel собирает, только когда заголовки
  есть. На macOS установите OpenSSL из Homebrew (`brew install openssl@3`),
  он keg-only, и добавьте его в пути компилятора:
  `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- Ruby 3.2+ и RubyGems — для команды `cybertrain` и для CRuby-превью сервера
  разработки, которому нужна ещё библиотека Ruby `fiddle` (ей нужен
  libffi); без `fiddle` `cybertrain server` запускает только
  скомпилированный цикл. Развёрнутое приложение никогда не запускается на
  CRuby. На Ruby 3.2 для сборки Spinel также нужен gem `prism` (ниже).

`cybertrain doctor` проверяет эти инструменты и заголовки, загружает ли
`ruby` из `PATH` библиотеку `fiddle`, а также установку Spinel; если чего-то
обязательного не хватает, она также выводит команду установки для вашей
платформы (отсутствие `fiddle` не считается: сервер всё равно работает,
скомпилированным).

<details><summary>Ещё пакеты — prism на Ruby 3.2; jemalloc, необязателен</summary>

- Для сборки Spinel нужен gem `prism`, который в Ruby 3.3 и новее входит в
  поставку; на Ruby 3.2 выполните `gem install prism` (нужны заголовки
  разработки Ruby, `ruby-dev` в Debian/Ubuntu). `cybertrain doctor` это
  проверяет.
- Spinel, собранный до установки заголовков OpenSSL, не имеет пакета
  `openssl`, и сборка приложения тогда не удаётся; когда заголовки появятся,
  выполните `cybertrain setup --force`, чтобы пересобрать его. Тот же пакет
  обслуживает TLS (`require "cybertrain/net/tls"`) и зашифрованные столбцы
  (`encrypts`).
- Пакет разработки jemalloc (`libjemalloc-dev`; `brew install jemalloc`)
  необязателен: он нужен приложению, только когда в его `spin.toml` указано
  `allocator = "jemalloc"`, что `cybertrain new` записывает закомментированным.
  Прежде чем полагаться на него в продакшене, измерьте на своём приложении: на
  examples/blog замер 2026-10-09 дал в 1,3–1,4 раза больше запросов в секунду
  на динамических страницах, а последний замер — разницу в несколько процентов
  на страницах (POST на одном ядре: на 18% больше)
  ([docs/benchmark.md](../benchmark.md)).

</details>

## Установка CLI

```shell терминал — любой каталог
gem install cybertrain
cybertrain doctor
```

Первая строка устанавливает команду из RubyGems, а вторая проверяет
[требования](#requirements); [учебник](tutorial.md#install) продолжает отсюда, от
`cybertrain new` до `cybertrain build`.

## Команда `cybertrain`

`cybertrain help` выводит эти команды:

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` создаёт приложение в NAME, затем запускает в нём `spin lock` и
  `SPIN_DEBUG=1 spin run gen`, при необходимости сначала устанавливая Spinel
  (CLI собирает gen и `bin/db.rb` в отладочном режиме spin).
- `cybertrain generate scaffold NAME field:type ... [parent:references] [--any]`
  (псевдоним `g scaffold`) добавляет ресурс в приложение в текущем каталоге;
  поле `parent:references` — это столбец `parent_id`, а `--any` относится
  к полю-вложению (ниже).
- `cybertrain generate authentication [--invite-only] [--confirmable] [--force]`
  добавляет в него вход по адресу почты и паролю: таблицы users и sessions,
  модели `User` и `Session`, concern `Authentication`, который включает
  `ApplicationController`, контроллеры и представления входа, регистрации,
  сброса пароля и учётной записи, маршруты, страницу задач за
  `require_admin`, нужные ему строки подсистем в `bin/<app>.rb` и
  `bin/db.rb` и тесты. `--invite-only` убирает страницу регистрации,
  `--confirmable` требует, чтобы новая учётная запись подтвердила адрес по
  почте до входа, а `--force` перезаписывает файлы, для которых повторный
  запуск иначе только печатает diff ([Аутентификация](authentication.md)).
- `cybertrain generate attachment MODEL FIELD [--any]` добавляет загрузку файла
  в модель со скаффолдом: пять столбцов метаданных, методы и колбэки модели,
  действие для скачивания, маршрут, поле формы и тест (см.
  [Добавление обложки](advanced-tutorial.md#attachments)). Поле скаффолда `cover:attachment` делает то же самое.
- `cybertrain generate helper NAME [--force]` добавляет
  `app/helpers/NAME_helper.rb`, модуль, методы которого после `spin run gen`
  может вызывать любой шаблон, и тест
  ([Хелперы приложения](template-language.md#application-helpers)).
- `cybertrain generate component NAME [attr[:type] ...] [--force]` добавляет
  компонент представления: `app/components/NAME_component.rb`, его шаблон и
  тест ([Компоненты](template-language.md#components)).
- `cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]`
  добавляет `app/jobs/NAME_job.rb` и тест, а в `bin/<app>.rb` и `bin/db.rb` —
  `require "cybertrain/jobs"`
  ([Фоновая работа](background-and-operations.md#background-work)).
- `cybertrain db migrate` выполняет генерацию, применяет ожидающие миграции и
  генерирует снова (`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db --
  migrate; SPIN_DEBUG=1 spin run gen`);
  `cybertrain migration` оставлена как псевдоним.
- `cybertrain db COMMAND...` после `SPIN_DEBUG=1 spin
  run gen` запускает любую другую команду базы данных: `status`, `rollback [N]`
  (после которой генерация выполняется снова), `schema` (записывает
  `db/schema.rb` по базе данных как она есть, без миграций), `schema:dump`,
  `create`, `backup` и `vacuum`
  ([Эксплуатация](background-and-operations.md#operations-backups-vacuum-health-check))
  и `normalize`
  ([Дата-время и `db normalize`](models.md#datetimes-and-db-normalize)).
- `cybertrain server [PORT] [--spinel]` запускает сервер разработки (по
  умолчанию — порт приложения, `PORT` или `c.port`, 3000, если они не заданы). Сразу после изменения приложение работает под CRuby,
  пока Spinel собирает его в фоне, а когда сборка удаётся, порт забирает
  скомпилированный бинарный файл; ответы приложения несут
  `X-Cybertrain-Runtime: cruby` или `spinel` ([Цикл
  разработки](how-it-works.md#the-development-loop)). `--spinel` запускает
  только скомпилированный цикл, где каждое изменение ждёт своей сборки
  (`SPIN_DEBUG=1 spin run gen`; `spin build NAME -- --incremental`, если
  какой-то Ruby-файл новее `build/bin/NAME`; `spin run NAME` или `spin run
  NAME -- PORT`).
- `cybertrain build` собирает NAME со встроенными `app/views/` и формирует
  `dist/` (бинарный файл, `public/`, `storage/`, `tmp/`).
- `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` выполняет генерацию,
  компилирует все тесты из `test/` в одну программу (только когда что-то
  изменилось) и запускает её, оставляя тесты, названные аргументами (см.
  [Тестирование приложения](testing.md#running-the-tests)).
- `cybertrain spin ARGS...` запускает `spin` с зафиксированным Spinel из
  любого каталога (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain secret [--hex]` выводит новый случайный секрет для
  `CYBERTRAIN_SECRET_KEY_BASE`; с `--hex` — новый ключ для
  `CYBERTRAIN_ENCRYPTION_KEY`. Оба состоят из 64 шестнадцатеричных цифр.
- `cybertrain setup [--force]` устанавливает зафиксированный релиз Spinel в
  `~/.cybertrain`, если `spinel` этого релиза ещё нет в `PATH`;
  `--force` пересобирает копию в `~/.cybertrain`.
- `cybertrain doctor` проверяет все [требования](#requirements): `git`,
  `make`, `curl`, компилятор C, заголовки SQLite, zlib и OpenSSL, гем
  `prism`, загружает ли Ruby `fiddle` (он нужен CRuby-превью) и установку
  Spinel.
- `cybertrain version` выводит версию, `cybertrain help` — этот список.

`generate`, `db`, `server`, `build` и `test` запускаются внутри приложения;
NAME — это `[package] name` из его `spin.toml`.

## Как устанавливается Spinel

Каждая команда, которая запускает `spin` (`new`, `db`, `server`, `build`, `test`,
`spin`),
сначала убеждается, что доступен Spinel релиза из `Cybertrain::SPINEL_TAG`.
`spinel` в `PATH` (вместе с `spin`), чей `spinel --version` сообщает этот
релиз, используется как есть; иначе используется копия, которую `cybertrain`
хранит в `~/.cybertrain/spinel/<SPINEL_TAG>/`; иначе `cybertrain` собирает эту
копию из релизного тега `Cybertrain::SPINEL_REPOSITORY` (`git clone`,
`make deps`, `make -j`, `make install PREFIX=...`) — один раз, за несколько
минут, записывая лог в `~/.cybertrain/log/spinel-<SPINEL_TAG>-build.log`
(если шаг завершается сбоем, выводятся его последние строки).

Если не хватает инструмента, нужного для сборки, `cybertrain` ещё до её начала
сообщает, какого именно, и выводит команду установки для вашей платформы. `spinel` другого
релиза в `PATH` никогда не используется и не затрагивается: `cybertrain` держит
собственную копию (и сообщает об этом, когда её устанавливает).

`cybertrain setup` делает то же самое по запросу и, если используется именно
её копия, выводит строку, добавляющую её в `PATH`, чтобы запускать `spin`
самостоятельно:

```shell терминал — любой каталог
export PATH="$HOME/.cybertrain/bin:$PATH"
```

В `~/.cybertrain/bin` лежат ссылки `spinel` и `spin` на используемый релиз,
поэтому строка переживает смену релиза; команде `cybertrain spin ...` `PATH`
вообще не нужен.

<details><summary>Переменные окружения — `CYBERTRAIN_HOME` переносит `~/.cybertrain`, `CYBERTRAIN_SPINEL_HOME` использует существующую установку</summary>

Две переменные окружения переопределяют всё это:

- `CYBERTRAIN_HOME` заменяет `~/.cybertrain` (путь без пробелов, кавычек, `$` и `:`, которые не принимают Makefile Spinel и `PATH`).
- `CYBERTRAIN_SPINEL_HOME=PREFIX` принудительно задаёт существующую установку: тогда `cybertrain` использует `spinel` и `spin` из `PREFIX/bin` (или из самого `PREFIX`, если `spinel` лежит прямо в нём) и останавливается с ошибкой, если это не тот релиз.

Третья, `CYBERTRAIN_KEEP_SRC=1`, сохраняет исходный код Spinel, клонированный
для сборки (`~/.cybertrain/src/spinel-<SPINEL_TAG>/`), вместо того чтобы
удалить его после сборки.

</details>

## Гем и фреймворк

`gem install cybertrain` устанавливает команду, а не фреймворк. Гем — это
команда `cybertrain`, обычный Ruby, который работает на вашей машине под CRuby
(3.2 или новее) и вызывает за вас инструмент Spinel `spin`; ни фреймворка, ни
Spinel в геме нет. Фреймворк — это пакет Spinel, от которого зависит ваше
приложение в `spin.toml`: Spinel заранее компилирует его вместе с вашим кодом,
и именно он попадает в поставку. Бинарный файл в `dist/` работает без Ruby,
гема и Spinel. Под CRuby код приложения, фреймворк в том числе, работает
только в разработке:
`cybertrain server` отдаёт CRuby-превью приложения, пока порт не заберёт
скомпилированный бинарный файл.

### Что записывает `cybertrain new`

`cybertrain new` записывает приложение, чей `spin.toml` указывает на релиз,
соответствующий CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }`, где
X.Y.Z — то, что выводит `cybertrain version`), проверяет,
что Spinel установлен, затем запускает `spin lock` (spin загружает фреймворк
в свой кэш `~/.cache/spin/packages/` и фиксирует коммит в
`spin.lock`) и `SPIN_DEBUG=1 spin run gen` — примерно так же, как `rails new` запускает
`bundle install`, — и выводит следующие шаги. Ничего из фреймворка в приложение
не копируется; закоммитьте `spin.toml` и `spin.lock`. `bin/<app>.rb` и
`bin/db.rb` требуют `cybertrain/core` — фреймворк без необязательных
подсистем; генераторы, которым нужна подсистема, добавляют её строку
([Подсистемы](how-it-works.md#subsystems)). Кроме того, он пишет `AGENTS.md` —
инструкции для ИИ-агентов, пишущих код (чем приложение отличается от Rails и
какие проверки выполнить, прежде чем считать изменение готовым), — и
`CLAUDE.md`, который подключает его для Claude Code.

Если не удаётся установить Spinel или выполнить один из двух шагов `spin`, файлы
остаются, `new` завершается с кодом 1 и выводит, что запустить после устранения
причины (для Spinel: `cybertrain setup`, затем
`cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen` в новом каталоге).

Четыре параметра меняют то, что она записывает и запускает:

- `--skip-spin` только записывает файлы: без установки Spinel, без `spin lock`, без `spin run gen`.
- `--path DIR` вместо этого делает зависимостью локальную копию репозитория
  (`--path ~/src/cybertrain`, где бы ни лежала копия, при работе над самим
  CyberTrain).
- `--git URL [--ref R]` делает зависимостью фреймворк по адресу URL (на ветке или теге R).
- `--version V` делает зависимостью релиз V из `spin-index`
  (`cybertrain = "V"`), когда фреймворк там появится: см.
  [Версия из индекса](#an-index-version).

Указывайте только один из `--path`, `--version` и `--git`; `--ref` требует `--git`.

### Версия из индекса

`spin-index` — это список пакетов, в котором spin ищет имя. Фреймворка в нём
пока нет: до тех пор `spin lock` в приложении, созданном с `--version`,
отвечает `not in the index: cybertrain`, а зависеть от релиза следует через
тег, который `new` записывает по умолчанию. Когда фреймворк там появится,
`cybertrain new NAME --version X.Y.Z` запишет `cybertrain = "X.Y.Z"`, spin
найдёт коммит этого релиза в индексе, а `spin.lock` зафиксирует те же три
вещи, что и для тега (версию, репозиторий и коммит), поэтому все команды и
процесс CI, который записывает `new`, работают так же, как по умолчанию. Три
вещи отличаются от того, чего заставляет ждать `Gemfile`:

- **Указывайте один релиз.** Из релизов, удовлетворяющих ограничению, spin
  выбирает самый младший, а не самый новый: `"~> X.Y"` — это самый младший
  релиз в индексе от X.Y до следующей мажорной версии (в пределах X.Y
  остаётся только `"~> X.Y.Z"`), и он остаётся тем же, когда выходят
  следующие. Поэтому пишите точную
  версию, ту, что печатает `cybertrain version`; если V записана иначе,
  `new` печатает примечание.
- **Spinel по-прежнему ставит команда `cybertrain`.** Запись в индексе не
  называет релиз Spinel. Фреймворк написан для одного релиза и проверен на
  нём: это тот, который собирает `cybertrain setup`, и его устанавливает
  команда `cybertrain` той же версии. Просто `spin add cybertrain` в
  проекте, который собирается другим Spinel, не проверялся.
- **spin читает собственную копию индекса.** Он клонирует индекс один раз,
  в `~/.cache/spin/`, и `spin lock` эту копию не обновляет;
  `spin search cybertrain` обновляет её и печатает самый новый релиз.

### Перевод приложения на новый релиз

Гем и фреймворк выпускаются из одного тега, поэтому их версии совпадают: гем
X.Y.Z создаёт приложения, зависящие от фреймворка `vX.Y.Z`. Чтобы перевести
приложение на новый релиз, обновите гем, укажите в `spin.toml` новый тег, затем
выполните в приложении:

```shell терминал — каталог приложения
rm spin.lock
cybertrain spin lock
cybertrain spin run gen
```

`spin lock` сохраняет коммит, зафиксированный для git-зависимости, каким бы
ни стал `ref` в `spin.toml`, поэтому сначала удаляется файл блокировки. В
приложении с другими зависимостями можно вместо этого удалить из `spin.lock`
только таблицы `[lock.cybertrain]` и `[lock.spinel-http]` (HTTP-слой, от
которого зависит фреймворк) и сохранить остальные фиксации.

Приложению, которое зависит от [версии из индекса](#an-index-version), `rm`
не нужен, потому что там `spin lock` сам переносит фиксацию:
сначала выполните `cybertrain spin search cybertrain`, чтобы обновить копию
индекса у spin, затем замените версию в строке `cybertrain =` файла
`spin.toml` на новый релиз и выполните `cybertrain spin lock` и `cybertrain spin run gen`.

Команда проверяет, что версии совпадают. Прежде чем `server`, `build`, `db`,
`test` или `generate` запустит spin или запишет файл, она сравнивает версию
фреймворка, которую собрал бы spin, то есть зафиксированную в `spin.lock`
приложения, со своей собственной (`cybertrain version`): релиз Spinel,
которым компилируется приложение, определяет команда, а не приложение, а её
шаблоны и генераторы написаны для её же релиза фреймворка. Если версии
различаются, команда останавливается с кодом 1:

```text вывод — cybertrain build
error: this application's framework is cybertrain X.Y.Z (spin.lock), but this cybertrain command is A.B.C.
The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either
  gem install cybertrain -v X.Y.Z    # the command the application is on
or point the cybertrain dependency in spin.toml at A.B.C (ref = "vA.B.C"), then relock from nothing (spin lock keeps a locked git commit)
  rm spin.lock && cybertrain spin lock
```

Сделайте одно из двух. `cybertrain spin ...` не проверяется, поэтому
`cybertrain spin lock` выполняется всегда. С
версией из индекса сообщение называет `cybertrain = "A.B.C"` и один только
`cybertrain spin lock`; spin собирает зафиксированный релиз, лишь пока
`spin.toml` его допускает, поэтому версия, названная в `spin.toml`,
сравнивается сразу, как только она расходится с фиксацией, а диапазон
(`"~> X.Y"`), который больше не допускает зафиксированный релиз, отклоняется,
пока не выполнен `cybertrain spin lock`. Приложение, зависящее от локальной
копии фреймворка (`path = ...`), не проверяется. Приложение без `spin.lock`
сверяется с релизом, который назван в его `spin.toml` (`"X.Y.Z"` или
`ref = "vX.Y.Z"`); ветка, коммит или диапазон релиза не называют, поэтому
проверки нет.

Повторная фиксация зависимостей — один из шагов обновления. Весь порядок действий
и то, что каждый релиз меняет для приложения, описаны в разделе [Обновление](upgrading.md).
