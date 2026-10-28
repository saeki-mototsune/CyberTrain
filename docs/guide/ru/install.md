---
source_sha256: 9a5740659170a925b518396b038b184107f4e771c1df3a8e10fa880824e90247
---
# Установка cybertrain

## Попробовать в браузере

[Откройте песочницу в GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1),
чтобы попробовать cybertrain, ничего не устанавливая: в браузере открывается VS Code,
где уже есть Spinel 2026.10.27.7020, CLI `cybertrain` и созданный блог из
[учебника](tutorial.md) (`cybertrain new blog`, скаффолд статей, корневой маршрут и
первая миграция, собранные один раз, чтобы сервер запускался без компиляции), его
сервер разработки работает в терминале, а приложение со списком статей открыто
в новой вкладке браузера. Приложение — git-репозиторий с одним коммитом, поэтому
Source Control показывает, что вы меняете. `PLAYGROUND.md` в приложении перечисляет,
что попробовать, от правки представления до продолжения учебника с комментариев (шаг 08).
Правка представления видна при следующей перезагрузке страницы; правка Ruby — это
полная пересборка, около минуты, после которой сервер перезапускается сам; вкладка
приложения сама не перезагружается. `cybertrain new` работает там без сети.

- Нужен аккаунт GitHub, и codespace расходует вашу собственную квоту Codespaces:
  бесплатный план GitHub включает 120 ядро-часов и 15 ГБ-месяцев хранилища в
  месяц — около 60 часов на 2-ядерной машине по умолчанию, которую использует
  песочница. По умолчанию GitHub останавливает простаивающий codespace через
  30 минут; его хранилище учитывается, пока вы его не удалите.
- Если VS Code спросит, доверяете ли вы авторам файлов в этой папке, выберите
  «Trust Folder & Continue»: только тогда запускается терминал сервера.
- Если вкладка приложения не открылась (блокировщик всплывающих окон, или
  codespace был остановлен и перезапущен), нажмите «Open in Browser» в
  уведомлении VS Code для порта 3000 или в представлении Ports либо щёлкните с
  Ctrl по URL приложения в терминале `server`. `PLAYGROUND.md` показывает, где
  что находится.
- Тот же образ запускается локально (он опубликован для linux/amd64; на arm64
  соберите его из рабочей копии):

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Затем откройте http://localhost:3000. [playground/README.md](../../playground/README.md)
  описывает образ, его сборку и настройку Codespaces.

## Требования

- Spinel `2026.10.27.7020` (`Cybertrain::SPINEL_TAG`, тот же релиз, что и
  `SPINEL_TAG` в [.github/workflows/ci.yml](../../.github/workflows/ci.yml)) —
  релиз [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), форка matz/spinel, в котором исправления,
  нужные cybertrain, появляются раньше, чем в релизе основного проекта;
  с другими версиями не тестировался. Вручную его устанавливать не нужно:
  команда `cybertrain` собирает этот релиз в `~/.cybertrain`, когда он впервые
  понадобится (`cybertrain setup` делает это по запросу), если только `spinel`
  этого релиза уже нет в `PATH`, — см. [Установка CLI](#installing-the-cli).
- Для его сборки: инструменты C (`cc` или компилятор, указанный в `CC`) и `make`
  — Spinel компилирует каждую программу в C, — а также `git` и `curl`.
- Заголовки и библиотека SQLite 3 (`libsqlite3-dev` в Debian/Ubuntu; на macOS
  входят в Xcode command line tools) — модели используют FFI Spinel напрямую,
  а не гем.
- Заголовки и библиотека zlib (`zlib1g-dev` в Debian/Ubuntu; в macOS SDK) —
  тела запросов в gzip (`request.decoded_body`) распаковываются через
  системную zlib, привязанную тем же способом.
- Ruby 3.2+ и RubyGems — только для команды `cybertrain` (приложения никогда
  не запускаются на CRuby). Для сборки Spinel также нужен gem `prism`, который
  в Ruby 3.3 и новее входит в поставку; на Ruby 3.2 выполните `gem install prism`
  (нужны заголовки разработки Ruby, `ruby-dev` в Debian/Ubuntu). `cybertrain doctor`
  это проверяет.
- Заголовки OpenSSL (`libssl-dev`) необязательны: без них Spinel собирается
  без своего пакета `openssl`, который cybertrain не использует. На macOS
  приложению, которому нужен `openssl`, требуется OpenSSL из Homebrew (keg-only)
  в путях компилятора: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- Пакет разработки jemalloc (`libjemalloc-dev`; `brew install jemalloc`)
  необязателен: он нужен приложению, только когда в его `spin.toml` указано
  `allocator = "jemalloc"`, что `cybertrain new` записывает закомментированным.
  Его стоит включить для продакшена: в 1,1–1,4 раза больше запросов в секунду на
  examples/blog ([docs/benchmark.md](../benchmark.md)).

`cybertrain doctor` проверяет эти инструменты и заголовки, а также установку
Spinel; если чего-то обязательного не хватает, она также выводит команду
установки для вашей платформы.

У фреймворка нет отдельного средства запуска тестов; он тестирует себя сам.
`spin` поставляется со Spinel, а `cybertrain spin` запускает копию, которую
устанавливает `cybertrain`, не трогая `PATH` (или добавьте эту копию в `PATH`
строкой `export PATH=...`, которую выводит `cybertrain setup`, и вызывайте
`spin` напрямую):

```sh
cybertrain spin test
```

компилирует и запускает каждую программу в `test/` и сравнивает её вывод с
закоммиченным снимком `test/<name>.rb.expected` — minitest/RSpec не могут
работать под Spinel, поскольку они находят тестовые методы через рефлексию, а
у AOT-компилятора во время выполнения нечему рефлексировать. `cybertrain spin test
--regen test/<name>.rb` перезаписывает снимок по выводу CRuby; несколько тестов,
которые обращаются к SQLite через FFI, берут свой снимок из скомпилированного
бинарного файла ([spikes/NOTES.md](../../spikes/NOTES.md), правило 23);
`script/regen-snapshot test/<name>.rb` выполняет этот шаг «собрать, затем
снять вывод» за вас и выводит статистику изменений.

## Установка CLI

```sh
gem install cybertrain
cybertrain new blog    # при первом запуске также устанавливает Spinel (несколько минут)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # продакшен: dist/
```

Команда `cybertrain` написана на обычном Ruby, и гем запускает её под CRuby
(3.2 или новее); ни фреймворка, ни Spinel в геме нет. Её команды (их выводит
`cybertrain help`):

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` создаёт приложение в NAME, затем запускает в нём `spin lock` и
  `spin run gen`, при необходимости сначала устанавливая Spinel.
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
  [Добавление загрузки файла](tutorial.md#attachments)). Поле скаффолда `cover:attachment` делает то же самое.
- `cybertrain db migrate` выполняет генерацию, применяет ожидающие миграции и
  генерирует снова (`spin run gen; spin run db -- migrate; spin run gen`);
  `cybertrain migration` оставлена как псевдоним.
- `cybertrain db COMMAND...` после `spin
  run gen` запускает любую другую команду базы данных: `status`, `rollback [N]`
  (после которой генерация выполняется снова), `schema:dump`, `create`.
- `cybertrain server [PORT]` выполняет генерацию, затем запускает сервер
  разработки (`spin run gen; spin run NAME` или `spin run NAME -- PORT`; порт
  по умолчанию — 3000).
- `cybertrain build` собирает NAME со встроенными `app/views/` и формирует
  `dist/` (бинарный файл, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` запускает `spin` с зафиксированным Spinel из
  любого каталога (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` устанавливает Spinel `2026.10.27.7020` в
  `~/.cybertrain`, если `spinel` этого релиза ещё нет в `PATH`;
  `--force` пересобирает копию в `~/.cybertrain`.
- `cybertrain doctor` проверяет инструменты C, заголовки SQLite и установку
  Spinel.
- `cybertrain version` выводит версию.

`db`, `server` и `build` запускаются внутри приложения; NAME — это
`[package] name` из его `spin.toml`.

Каждая команда, которая запускает `spin` (`new`, `db`, `server`, `build`, `spin`),
сначала убеждается, что доступен Spinel релиза из `Cybertrain::SPINEL_TAG`.
`spinel` в `PATH` (вместе с `spin`), чей `spinel --version` сообщает этот
релиз, используется как есть; иначе используется копия, которую `cybertrain`
хранит в `~/.cybertrain/spinel/2026.10.27.7020/`; иначе `cybertrain`
собирает эту копию из релизного тега `Cybertrain::SPINEL_REPOSITORY`
(`git clone`, `make deps`, `make -j`, `make install PREFIX=...`) — один раз,
за несколько минут. Лог сборки —
`~/.cybertrain/log/spinel-2026.10.27.7020-build.log` (если шаг завершается
сбоем, выводятся его последние строки); если не хватает инструмента, нужного
для сборки, `cybertrain` ещё до её начала сообщает, какого именно, и выводит
команду установки для вашей платформы. `spinel` другого релиза в `PATH`
никогда не используется и не затрагивается: `cybertrain` держит собственную
копию (и сообщает об этом, когда её устанавливает).

`cybertrain setup` делает то же самое по запросу и, если используется именно
её копия, выводит строку, добавляющую её в `PATH`, чтобы запускать `spin`
самостоятельно (в `~/.cybertrain/bin` лежат ссылки `spinel` и `spin` на
используемый релиз, поэтому строка переживает смену релиза; команде `cybertrain spin ...`
`PATH` вообще не нужен):

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

Две переменные окружения переопределяют всё это: `CYBERTRAIN_HOME` заменяет
`~/.cybertrain` (путь без пробелов, кавычек, `$` и `:`, которые не принимают
Makefile Spinel и `PATH`), а `CYBERTRAIN_SPINEL_HOME=PREFIX` принудительно
задаёт существующую установку — тогда `cybertrain` использует `spinel` и `spin`
из `PREFIX/bin` (или из самого `PREFIX`, если `spinel` лежит прямо в нём) и
останавливается с ошибкой, если это не тот релиз.

`cybertrain new` записывает приложение, чей `spin.toml` указывает на релиз,
соответствующий CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`), проверяет,
что Spinel установлен, затем запускает `spin lock` (spin загружает фреймворк
в свой кэш `~/.cache/spin/packages/` и фиксирует коммит в
`spin.lock`) и `spin run gen` — примерно так же, как `rails new` запускает
`bundle install`, — и выводит следующие шаги. Ничего из фреймворка в приложение
не копируется; закоммитьте `spin.toml` и `spin.lock`. Если не удаётся
установить Spinel или выполнить один из двух шагов `spin`, файлы остаются,
`new` завершается с кодом 1 и выводит, что запустить после устранения причины
(для Spinel: `cybertrain setup`, затем `cybertrain spin
lock && cybertrain spin run gen` в новом каталоге).

`--skip-spin` только записывает файлы: без установки Spinel, без `spin lock`,
без `spin run gen`. `--path DIR` вместо этого делает зависимостью локальную
копию репозитория, `--git URL [--ref R]` — фреймворк по адресу URL (на ветке
или теге R), а `--version V` — версию из индекса, когда cybertrain появится в
`spin-index`. Указывайте только один из `--path`, `--version` и `--git`;
`--ref` требует `--git`.

Работая над самим cybertrain, запускайте CLI из рабочей копии (`spin install`
собирает `bin/cybertrain.rb` в `~/.local/bin/cybertrain`; `ruby -I.
bin/cybertrain.rb` тоже работает) и создавайте приложения на её основе командой
`cybertrain new NAME --path ~/src/cybertrain` (где бы ни лежала рабочая копия).
