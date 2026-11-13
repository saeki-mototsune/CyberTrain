---
source_sha256: dcff54852c4d6fae14dd97b90f66e3dc7c39d37abc0be11123dc75a3aba5030f
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
  Его стоит включить для продакшена: в 1,1–1,4 раза больше запросов в секунду на
  examples/blog ([docs/benchmark.md](../benchmark.md)).

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
- `cybertrain generate scaffold NAME field:type ...` (псевдоним `g scaffold`)
  добавляет ресурс в приложение в текущем каталоге.
- `cybertrain generate authentication` добавляет в него вход по адресу почты и
  паролю: таблицы users и sessions, модели `User` и `Session`, контроллеры и
  представления входа и регистрации, маршруты, `before_action` в
  `ApplicationController` и тест (см. [Добавление входа](tutorial.md#authentication)).
  С `--invite-only` страницы регистрации нет: пользователи создаются командой
  `./NAME user EMAIL`, а первый — также на странице `/setup`, которая отвечает
  только машине самого сервера, с одноразовым токеном, который выводит
  предупреждение при запуске, пока не существует ни одного пользователя.
- `cybertrain generate attachment MODEL FIELD [--any]` добавляет загрузку файла
  в модель со скаффолдом: пять столбцов метаданных, методы и колбэки модели,
  действие для скачивания, маршрут, поле формы и тест (см.
  [Добавление обложки](tutorial.md#attachments)). Поле скаффолда `cover:attachment` делает то же самое.
- `cybertrain db migrate` выполняет генерацию, применяет ожидающие миграции и
  генерирует снова (`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db --
  migrate; SPIN_DEBUG=1 spin run gen`);
  `cybertrain migration` оставлена как псевдоним.
- `cybertrain db COMMAND...` после `SPIN_DEBUG=1 spin
  run gen` запускает любую другую команду базы данных: `status`, `rollback [N]`
  (после которой генерация выполняется снова), `schema:dump`, `create`.
- `cybertrain server [PORT] [--spinel]` запускает сервер разработки (порт по
  умолчанию — 3000). Сразу после изменения приложение работает под CRuby,
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
- `cybertrain spin ARGS...` запускает `spin` с зафиксированным Spinel из
  любого каталога (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` устанавливает зафиксированный релиз Spinel в
  `~/.cybertrain`, если `spinel` этого релиза ещё нет в `PATH`;
  `--force` пересобирает копию в `~/.cybertrain`.
- `cybertrain doctor` проверяет инструменты C, заголовки SQLite, загружает
  ли Ruby `fiddle` (он нужен CRuby-превью) и установку Spinel.
- `cybertrain version` выводит версию.

`db`, `server` и `build` запускаются внутри приложения; NAME — это
`[package] name` из его `spin.toml`.

## Как устанавливается Spinel

Каждая команда, которая запускает `spin` (`new`, `db`, `server`, `build`, `spin`),
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
не копируется; закоммитьте `spin.toml` и `spin.lock`.

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
- `--version V` делает зависимостью версию из индекса, когда фреймворк появится
  в `spin-index`.

Указывайте только один из `--path`, `--version` и `--git`; `--ref` требует `--git`.

### Перевод приложения на новый релиз

Гем и фреймворк выпускаются из одного тега, поэтому их версии совпадают: гем
X.Y.Z создаёт приложения, зависящие от фреймворка `vX.Y.Z`. Чтобы перевести
приложение на новый релиз, обновите гем, укажите в `spin.toml` новый тег, затем
выполните в приложении:

```shell терминал — каталог приложения
cybertrain spin lock
cybertrain spin run gen
```

Приложению, написанному для 0.4, нужно внести несколько изменений (каждая
сессия один раз завершается, линкуется OpenSSL, сегменту маршрута с точкой
нужен `format: false` и другое): см. [Обновление приложения с 0.4](requests.md#upgrading-an-application-from-04).
