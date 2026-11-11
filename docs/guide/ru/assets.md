---
source_sha256: f33d41101fb56e6a4ccb2fd65374062a590ba781adb2baf79d57aef2a6aefb2c
---
# Ассеты

Таблицы стилей, изображения и JavaScript в раскладке Rails 8: `spin run gen` записывает их с дайджестом в `public/assets/`, переписывает ссылки `url()` в CSS и компилирует манифест и import map в бинарник; теговые хелперы пишут пути с дайджестом, а сервер кэширует их на год.

## Исходники и логические пути

```text app/
app/assets/stylesheets/application.css    application.css
app/assets/images/logo.svg                logo.svg
app/javascript/application.js             application.js
app/javascript/controllers/hello.js       controllers/hello.js
vendor/javascript/chart.js                chart.js
```

Каждый каталог непосредственно в `app/assets/` — это корень, как и `app/javascript/` и `vendor/javascript/`: логический путь файла — его путь под корнем (правая колонка выше), то есть имя, которое принимают хелперы. Логический путь, найденный под двумя корнями, останавливает `spin run gen`, который называет оба файла. Скрытые файлы (`.keep`) и каталоги-симлинки под корнем пропускаются, но корень, сам являющийся симлинком (`app/assets`, `app/javascript`, `vendor/javascript`), останавливает gen, который называет его; файл-симлинк читается, если он остаётся внутри своего дерева, а ссылка, ведущая наружу или в никуда, останавливает gen. Путь с пробелом или управляющим символом отклоняется. Отдельная сборка CSS (Sass, Tailwind) может писать в `app/assets/builds/`, это такой же корень, как другие.

## Дайджесты и хранение

`spin run gen` записывает каждый файл как `public/assets/<имя>-<дайджест>.<расш>`, где дайджест — первые 8 шестнадцатеричных символов SHA-256 содержимого (короткий дайджест Propshaft): `application.css` становится `application-1a2b3c4d.css`. `gen/assets.rb` содержит таблицу из логических путей в пути с дайджестом в виде сгенерированного `case`, import map и её предзагрузки и компилируется в бинарник, так что программе нужен рядом только `public/assets/`. Изменённый файл получает новое имя; старый никогда не перезаписывается.

Старые дайджесты сохраняются, чтобы страница, загруженная до деплоя, или старый процесс, ещё работающий во время поэтапного деплоя, нашли то, что называет их HTML: для каждого логического пути gen хранит текущий дайджест и два предыдущих и удаляет более старые файлы, как `assets:clean` в Propshaft хранит три версии. История — это `public/assets/.manifest` (строка на логический путь: путь, затем до трёх дайджестов), поэтому `gen/assets.rb` остаётся чистой функцией исходников, а `spin run gen -- --check` сравнивает только его. `public/assets/` — результат сборки: `.gitignore`, который пишет `cybertrain new`, содержит `/public/assets/`, а gen запускают `cybertrain build` и сборка образа.

Цикл разработки следит за `app/assets/**`, `app/javascript/**` и `vendor/javascript/**`, поэтому сохранённая таблица стилей снова запускает gen, и следующая страница загружает новый дайджест.

## `url()` в CSS

`url()` в таблице стилей, который называет ассет, переписывается на путь с дайджестом, как это делает компилятор Propshaft, а таблица стилей получает дайджест после файлов, которые она называет, поэтому её собственный дайджест меняется, когда меняется используемое ею изображение:

```css
.brand { background: url("logo.svg") no-repeat; }
/* in public/assets/application-1a2b3c4d.css: */
.brand { background: url("/assets/logo-8177afd7.svg") no-repeat; }
```

Путь разрешается относительно **логического** каталога таблицы стилей (ведущий `/` начинает от корней): из `application.css` `logo.svg` — это логический `logo.svg`, а `../images/logo.svg` поднимается выше корней и ассетом не является. `?query` или `#fragment` сохраняется после пути с дайджестом. Цели `data:`, `http:`, `https:`, `//`, `#` и `%23` остаются как есть; любая другая цель, которая не является ассетом, остаётся как написана, с предупреждением от gen. Цикл таблиц стилей, называющих друг друга, останавливает gen (`CSS url() cycle: a.css -> b.css -> a.css`).

## Хелперы

```erb
<%= stylesheet_link_tag "application" %>        <%# <link rel="stylesheet" href="/assets/application-1a2b3c4d.css"> %>
<%= javascript_include_tag "legacy" %>          <%# <script src="/assets/legacy-5e6f7a8b.js"></script> %>
<%= image_tag "logo.svg", alt: "CyberTrain", size: "32x32" %>
<%= asset_path "logo.svg" %>                    <%# /assets/logo-8177afd7.svg %>
```

`stylesheet_link_tag` добавляет `.css`, а `javascript_include_tag` — `.js`, когда в имени его нет; оба принимают `nonce: true`, а `stylesheet_link_tag` принимает `media:`. URL со схемой (или `//`, `data:`) пишется как есть, как и путь, начинающийся с `/`. Неизвестное логическое имя в разработке и тестах вызывает `Cybertrain::Assets::UnknownAsset` (`asset "logo.png" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)`); production один раз пишет его в лог и выводит `/assets/<имя>`. Полные сигнатуры — в [языке шаблонов](template-language.md#helpers-and-the-form-builder).

## Import map

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin "chart", to: "chart.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
```

gen читает файл как текст и никогда его не выполняет: `pin name, to:, preload:` и `pin_all_from dir, under:, preload:`, комментарии и пустые строки; любая другая строка останавливает gen. `to:` без схемы — логический путь ассета, а pin без `to:` называет `<name>.js`; `pin_all_from` закрепляет каждый файл `.js` под каталогом как `<under>/<его путь без .js>`, а `index.js` — как сам `under`. `preload:` по умолчанию true (importmap-rails 2). В лейауте

```erb
<%= javascript_importmap_tags %>
```

пишет `<script type="importmap">`, `<link rel="modulepreload">` для каждого предзагружаемого pin и `<script type="module">import "application"</script>`, каждый с nonce запроса, когда действует [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts). `bin/importmap pin` нет: скопируйте библиотеку в `vendor/javascript/` и закрепите её или закрепите URL. Turbo в комплект не входит.

## Отдача

Middleware статических файлов отдаёт файл под `/assets/`, имя которого несёт дайджест, записанный gen (текущий — из `gen/assets.rb`, или сохранённый — из `public/assets/.manifest`, прочитанного при старте), с `Cache-Control: public, max-age=31536000, immutable`; ETag не нужен, потому что файл никогда не меняется. Всё остальное в `public/`, включая файл без дайджеста, который приложение держит в `public/assets/`, сохраняет `max-age=3600`. Скрытый файл под `/assets` (`.manifest`, временный файл прерванного запуска gen) не отдаётся; скрытый файл в другом месте `public/` (`/.well-known/...`) отдаётся. Файл, реальный путь которого выходит за пределы `public/`, не отдаётся: деплой, который делает `public/assets` симлинком на каталог вне `public/` (общие каталоги Capistrano), вместо этого монтирует его туда или делает bind mount. Reverse proxy, который сам отдаёт `public/`, отправляет свои заголовки; задайте там для `/assets/` такое же годовое неизменяемое кэширование.

## Перенос `public/style.css`

Приложение, созданное до появления ассетов, отдаёт `public/style.css` как обычный файл и продолжает работать. Чтобы перенести его:

```shell терминал — каталог приложения
mkdir -p app/assets/stylesheets app/javascript
git mv public/style.css app/assets/stylesheets/application.css
echo '/public/assets/' >> .gitignore
```

В `app/views/layouts/application.html.erb` замените строку `<link rel="stylesheet" href="/style.css">` на `<%= stylesheet_link_tag "application" %>` (и добавьте `<%= csp_meta_tag %>` и `<%= javascript_importmap_tags %>`, когда появится `config/importmap.rb`), перенесите изображения, которые называет таблица стилей, в `app/assets/images/` со ссылками вида `url("logo.svg")`, затем запустите `spin run gen`.

## `asset_path` в Kamal

Деплой, который собирает свежий образ (Kamal, Docker), несёт только текущие дайджесты. В `config/deploy.yml`, который пишет `cybertrain new`, есть

```yaml
asset_path: /app/public/assets
```

поэтому Kamal на время переключения переносит файлы предыдущего релиза в новый контейнер: страница, загруженная до деплоя, всё ещё находит CSS и JavaScript, которые называет её HTML. Добавьте эту строку в более старый `config/deploy.yml`.
