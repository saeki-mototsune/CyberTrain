---
source_sha256: 019e957af0a2a00fb7686104bf189fa14278c410e3ed256eaa217aad03e76a19
path: tutorial.html
title: "Начало работы: блог"
description: "Соберите блог из Rails Getting Started — статьи с комментариями — на CyberTrain: скаффолды, миграции, вложенные маршруты, тесты на Cybertrain::Test и сборка для развёртывания командой cybertrain build."
og_title: "Начало работы с CyberTrain: блог"
og_description: "Повторяет Getting Started самого Rails: блог со статьями и комментариями, построенный на CyberTrain и Spinel."
og_image: tutorial.png
crumb: "Учебник"
nav: tutorial
toc_title: "Шаги 00–15"
meta:
  - term: "Что нужно"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, заголовки SQLite 3 (Spinel `2026.10.27.7020` установится сам) <a class="meta-link" href="#requirements">Шаг 00</a>'
  - term: "Начало"
    text: "`gem install cybertrain`"
  - term: "Результат"
    text: "`dist/blog`"
---

# Начало работы: блог

Повторяет
[Getting Started](https://guides.rubyonrails.org/getting_started.html) самого
Rails: блог со статьями и комментариями. Вы создадите скаффолд статей,
добавите валидации, вложите в статьи комментарии, напишете тест, который
прогоняет приложение внутри процесса, добавите вход, прикрепите загруженную
картинку и соберёте приложение в готовый к развёртыванию каталог `dist/`.
Готовое приложение — [`examples/blog`](../../examples/blog); оно проверяется в
CI на Linux и macOS.


<!-- step 00 #requirements stage: Подготовка · Ruby, `cc`, SQLite -->
## Требования

> [!WHY]
> CyberTrain компилируется через Spinel в C, поэтому ему нужны инструменты C и
> заголовки SQLite; команда `cybertrain` — это гем, поэтому ей нужен Ruby.

<!-- list: checklist -->
- Ruby 3.2+ и RubyGems — только для команды `cybertrain`; приложения никогда
  не запускаются на CRuby. Для сборки Spinel также нужен gem `prism`: в Ruby 3.3
  и новее он входит в поставку; на Ruby 3.2 выполните `gem install prism`
  (нужны заголовки разработки Ruby, `ruby-dev` в Debian/Ubuntu).
  `cybertrain doctor` это проверяет.
- Spinel `2026.10.27.7020` — релиз форка
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel), в
  котором исправления, нужные CyberTrain, появляются раньше, чем в основном
  проекте; с другими версиями не тестировался. Вручную его устанавливать не
  нужно: первая команда, которой он нужен, собирает этот релиз в
  `~/.cybertrain` (несколько минут, один раз), если `spinel` этого релиза ещё
  нет в `PATH`.
- Инструменты C (`cc` или компилятор, указанный в `CC`) и `make`, а также
  `git` и `curl` — для сборки Spinel, который компилирует каждую программу в
  C.
- Заголовки и библиотеки SQLite 3 и zlib: `libsqlite3-dev` и `zlib1g-dev` в
  Debian/Ubuntu; на macOS входят в Xcode command line tools.
- Заголовки OpenSSL (`libssl-dev`) необязательны: без них Spinel собирается
  без своего пакета `openssl`, который CyberTrain не использует.

`cybertrain doctor` проверяет эти инструменты и заголовки, а также установку
Spinel; если чего-то обязательного не хватает, она также выводит команду
установки для вашей платформы.

<details><summary>Как CyberTrain устанавливает Spinel — Что происходит, когда команде впервые нужен `spin`</summary>

`cybertrain new`, `db`, `server`, `build` и `spin` сначала ищут Spinel
`2026.10.27.7020`: `spinel` и `spin` этого релиза, уже доступные в `PATH`;
иначе — копию в `~/.cybertrain/spinel/2026.10.27.7020/`; иначе собирают эту
копию из релизного тега Spinel (`git clone`, `make deps`, `make -j`,
`make install`) — один раз, за несколько минут. Лог пишется в
`~/.cybertrain/log/spinel-2026.10.27.7020-build.log`; если не хватает
инструмента, нужного для сборки, `cybertrain` ещё до её начала сообщает,
какого именно, и выводит команду установки для вашей платформы.

`cybertrain setup` делает то же самое по запросу (`--force` пересобирает копию
в `~/.cybertrain`) и, если используется именно её копия, выводит строку,
добавляющую её в ваш `PATH`, чтобы запускать `spin` самостоятельно:

```shell терминал — любой каталог
export PATH="$HOME/.cybertrain/bin:$PATH"
```

В `~/.cybertrain/bin` лежат ссылки `spinel` и `spin` на используемый релиз.
Если этого каталога нет в `PATH`, `cybertrain spin ARGS...` запускает `spin`
этого релиза из любого каталога. `CYBERTRAIN_HOME` заменяет `~/.cybertrain`, а
`CYBERTRAIN_SPINEL_HOME=PREFIX` вместо этого использует Spinel, установленный
в `PREFIX` (это должен быть тот же релиз). `spinel` другого релиза в `PATH`
никогда не используется и не затрагивается.

</details>

> [!NOTE]
> Негде устанавливать? [Песочница](site:playground.html) открывает этот блог в
> GitHub Codespace, где шаги 02, 03, 04 и 07 уже выполнены.

<!-- step 01 #install stage: Подготовка · CLI `cybertrain` -->
## Установка CLI

> [!WHY]
> `cybertrain` — команда, которая создаёт приложения, генерирует скаффолды
> ресурсов, выполняет миграции, запускает сервер и собирает.

Первая строка устанавливает её из RubyGems. Остальное — весь учебник в двух
словах; шаги ниже разбирают его по одной команде.

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">терминал &mdash; любой каталог, затем&nbsp;blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Код: терминал &mdash; любой каталог, затем blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># при первом запуске устанавливает Spinel 2026.10.27.7020 (несколько минут)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># продакшен: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

Команда `cybertrain` написана на обычном Ruby, и гем запускает её под CRuby
(3.2 или новее); ни фреймворка, ни Spinel в геме нет. Её команды (их выводит
`cybertrain help`):

<!-- list: points -->
- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]`
  создаёт приложение в NAME, затем запускает в нём `spin lock` и
  `spin run gen`, при необходимости сначала устанавливая Spinel.
- `cybertrain generate scaffold NAME field:type ...` (псевдоним `g scaffold`)
  добавляет ресурс в приложение в текущем каталоге.
- `cybertrain generate authentication` добавляет в приложение в текущем
  каталоге вход по адресу почты и паролю ([шаг 13](#authentication)).
- `cybertrain generate attachment MODEL FIELD [--any]` добавляет загрузку
  файла в модель со скаффолдом в приложении в текущем каталоге
  ([шаг 14](#attachments)).
- `cybertrain db migrate` выполняет генерацию, применяет ожидающие миграции и
  генерирует снова (`spin run gen; spin run db -- migrate; spin run gen`);
  `cybertrain migration` оставлена как псевдоним.
- `cybertrain db COMMAND...` после `spin run gen` запускает любую другую
  команду базы данных: `status`, `rollback [N]` (после которой генерация
  выполняется снова), `schema:dump`, `create`.
- `cybertrain server [PORT]` выполняет генерацию, затем запускает сервер
  разработки (`spin run gen; spin run NAME` или `spin run NAME -- PORT`; порт
  по умолчанию — 3000).
- `cybertrain build` собирает NAME со встроенными `app/views/` и формирует
  `dist/` (бинарный файл, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` запускает `spin` с зафиксированным Spinel из
  любого каталога: `cybertrain spin test`,
  `cybertrain spin run gen -- --check`.
- `cybertrain setup [--force]` устанавливает Spinel `2026.10.27.7020` в
  `~/.cybertrain`, если `spinel` этого релиза ещё нет в `PATH`; `--force`
  пересобирает копию в `~/.cybertrain`.
- `cybertrain doctor` проверяет инструменты C, заголовки SQLite и установку
  Spinel.
- `cybertrain version` выводит версию (`cybertrain 0.3.1`); `cybertrain help`
  выводит справку по использованию.

> [!NOTE]
> `db`, `server` и `build` запускаются внутри приложения; NAME — это
> `[package] name` из его `spin.toml`.

<!-- step 02 #new-app stage: Вы пишете · `blog/` -->
## Создание приложения

> [!WHY]
> Вы получаете привычную для Rails структуру каталогов и три программы в
> `bin/`: `bin/blog.rb` (приложение), `bin/gen.rb` (генератор) и `bin/db.rb`
> (миграции при разработке).

```shell терминал — любой каталог
cybertrain new blog
cd blog
```

`cybertrain new` создаёт приложение, чей `spin.toml` указывает на релиз,
соответствующий CLI:

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

Затем она проверяет, что Spinel установлен (в первый раз это означает сборку
Spinel `2026.10.27.7020` в `~/.cybertrain`: несколько минут, один раз; см.
[шаг 00](#requirements)), и запускает `spin lock` (spin загружает фреймворк в
свой кэш `~/.cache/spin/packages/` и фиксирует коммит в `spin.lock`) и
`spin run gen` — примерно так же, как `rails new` запускает `bundle install`,
— так что `cybertrain server` сразу работает. В конце она выводит следующие
шаги. Ничего из фреймворка в приложение не копируется; закоммитьте `spin.toml`
и `spin.lock`.

> [!NOTE]
> Если не удаётся установить Spinel или выполнить один из двух шагов `spin`,
> файлы остаются, `new` завершается с кодом 1 и выводит, что запустить после
> устранения причины (для Spinel: `cybertrain setup`, затем
> `cybertrain spin lock && cybertrain spin run gen` в новом каталоге).
> `--skip-spin` только записывает файлы; `--path DIR` вместо этого делает
> зависимостью локальную копию репозитория, `--git URL [--ref R]` — фреймворк
> по адресу URL (на ветке или теге R), а `--version V` — версию из индекса,
> когда `cybertrain` появится в `spin-index`.

Имена приложений состоят из строчных букв, цифр и `_` и начинаются с буквы.
Сгенерированное дерево:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` — единственная точка входа приложения, программа, которую
компилирует `spin build blog`: `./blog` обслуживает запросы, `./blog migrate`
и `./blog db status` управляют базой данных. `bin/gen.rb` запускает генератор
(`spin run gen`), а `bin/db.rb` запускает мигратор во время разработки (его
использует `cybertrain db migrate`, потому что `bin/blog.rb` не
скомпилируется, пока первая миграция не сгенерирует `gen/models/`). В `gen/`
уже лежит `views.rb` — закоммиченная пустая таблица встроенных представлений.

`ApplicationController` изначально выглядит так, поэтому отсутствующая запись
через `rescue_from` превращается в 404:

```ruby app/controllers/application_controller.rb
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

<!-- step 03 #scaffold-article stage: Вы пишете · `app/`, `db/migrate/` -->
## Скаффолд статьи

> [!WHY]
> Одна команда создаёт весь CRUD-срез, как в Rails.

```shell терминал — blog/
cybertrain generate scaffold article title:string body:text
```

Она создаёт миграцию, модель, контроллер и пять представлений (`index`,
`show`, `new`, `edit`, `_form`) и вставляет `resources :articles` в
`config/routes.rb`. Типы полей: `string`, `text`, `integer`, `float`,
`boolean`, `date`, `datetime` и `references`; по умолчанию — `string`.
`cybertrain g scaffold` из быстрого старта — та же самая команда.

> [!NOTE]
> Существующие файлы никогда не перезаписываются: для каждого файла выводится
> `create`, `identical` или `exist`.

<!-- step 04 #root-route stage: Вы пишете · `config/routes.rb` -->
## Корневой маршрут

> [!WHY]
> `/` должен показывать список статей.

```ruby config/routes.rb
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

> [!NOTE]
> Маршруты читаются при сборке: `spin run gen` превращает их в
> `gen/routes.rb`. `cybertrain server`, `cybertrain db migrate` и
> `cybertrain build` запускают его за вас.

<!-- step 05 #validations stage: Вы пишете · `app/models/` -->
## Валидации модели

> [!WHY]
> Как и в руководстве Rails, добавьте валидацию длины вручную.

```ruby app/models/article.rb
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

У `class Article` суперкласс не указан: суперкласс `Cybertrain::Model`,
столбцы и finder-методы берутся из `gen/models/article.rb`. Неудачное
сохранение выдаёт сообщения вроде «Title can't be blank» и «Body is too short
(minimum is 10 characters)».

<!-- step 06 #articles-controller stage: Вы пишете · `app/controllers/` -->
## ArticlesController

> [!WHY]
> Полный CRUD в духе Rails, вплоть до strong params и связки «flash, затем
> редирект», — за исключением двух вещей, которые Spinel навязывает везде.

```ruby app/controllers/articles_controller.rb
# app/controllers/articles_controller.rb (index/show/edit are as plain as
# Rails' own scaffold; update mirrors create)
class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  def new_action   # a `new` method would shadow ArticlesController.new
    @article = Article.new
  end

  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = "Article was successfully created."
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
```

> [!RULE] Правило Spinel: new_action
> ### `new_action`, а не `new`
>
> Метод, буквально названный `new`, затенил бы `ArticlesController.new(ctx)`, с
> помощью которого фреймворк создаёт контроллер. Маршрут `GET /articles/new`
> по-прежнему ведёт к нему; вы лишь переименовываете метод. Представление
> по-прежнему называется `new.html.erb`, а `render :new` не меняется.

> [!RULE] Правило Spinel: колбэки
> ### Колбэки получают контроллер явно
>
> Для сохранённого блока нет `instance_exec`, поэтому колбэк-блок получает
> контроллер (или запись) как аргумент: `before_action { |c| c.do_thing }`, а не
> `before_action { do_thing }`. Действия и колбэки вызываются по их буквальному
> имени, никогда через `send`.

Скаффолд создаёт полный контроллер, включая также `index`, `show`, `edit`,
`update` и `destroy`; во фрагменте выше они опущены. В `index` —
`@articles = Article.all.to_a`: `.to_a` обязателен.

> [!NOTE]
> Переменные экземпляра находятся лексическим сканированием `@ivar =`, поэтому
> после добавления новой заново запустите `cybertrain spin run gen`; сервер
> разработки делает это за вас.

<!-- step 07 #run stage: Сборка, затем запуск · `gen/` &rarr; `build/bin/blog` -->
## Генерация, миграции, запуск

> [!WHY]
> Превратить схему и маршруты в `gen/`, создать базу данных SQLite, запустить
> сервер.

```shell терминал — blog/
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000; пересборка при правках Ruby, представления перезагружаются без пересборки
```

`spin run gen` читает `db/schema.rb` и `config/routes.rb`, сканирует `app/` и
записывает `gen/`; `spin run db -- migrate` применяет `db/migrate/*.rb` и
перезаписывает `db/schema.rb`. Порядок важен: первый `spin run gen` помещает
новую миграцию в `gen/migrations.rb`, который подключает `bin/db.rb`, а второй
строит модели по перезаписанному `db/schema.rb`.

`cybertrain server` выводит каждую запускаемую команду `spin`, а затем
стартовый баннер приложения. При первом запуске приложение компилируется, так
что это займёт некоторое время:

```text вывод — cybertrain server
=> Booting cybertrain 0.3.1
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- Заново запускайте `cybertrain spin run gen` и коммитьте `gen/` после
  изменения схемы, маршрутов или колбэков и переменных экземпляра контроллера
  либо модели. Сервер разработки делает это за вас.
- Порт меняется так: `cybertrain server 4000` (или `PORT=4000`).
- `cybertrain db` добавляет `--`, который нужен `spin run db` перед
  аргументами; `cybertrain db status` и другие команды базы данных работают
  так же.

> [!RULE] Правило Spinel: нет консоли
> ### Консоли нет
>
> У `rails console` нет аналога: в Spinel нет `eval`. Изменения в Ruby требуют
> пересборки, которую в режиме разработки за вас выполняет `cybertrain server`
> (пересборка, остановка, `execv`). В режиме разработки представления
> разбираются с диска при каждом запросе, поэтому правка представления не
> требует пересборки; для продакшена `cybertrain build` встраивает их в бинарный
> файл.

<!-- step 08 #scaffold-comment stage: Вы пишете · `db/migrate/`, `app/` -->
## Скаффолд комментариев

> [!WHY]
> Тип `references` даёт внешний ключ, из которого выводится ассоциация.

```shell терминал — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # скаффолд создал миграцию для таблицы comments
```

`article:references` добавляет столбец `article_id`, индекс и внешний ключ —
этого достаточно, чтобы `Article`/`Comment` получили ассоциацию; писать
`has_many`/`belongs_to` не нужно, `spin run gen` выводит её из внешнего ключа.
Получившаяся схема:

```ruby db/schema.rb (фрагмент)
  s.create_table "comments" do |t|
    t.string "commenter"
    t.text "body"
    t.integer "article_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"

  s.add_foreign_key "comments", "articles", column: "article_id"
```

Скаффолд вставляет отдельную строку `resources :comments`, которую заменит
следующий шаг.

> [!EXAMPLE] Удаление статьи с комментариями
> ### Удаление статьи с комментариями
>
> Ассоциации выводятся только из внешних ключей, а `dependent:` не реализован.
> Пример добавляет колбэк `before_destroy`, который получает запись явно:
>
> ```ruby app/models/article.rb (фрагмент)
>   # Rails' `has_many :comments, dependent: :destroy`: the foreign key
>   # would refuse to delete an article that still has comments.
>   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
> ```

<!-- step 09 #nested-routes stage: Вы пишете · `config/routes.rb` -->
## Вложенные маршруты

> [!WHY]
> В руководстве Rails комментарии вложены в статьи.

```ruby config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper explicitly (Spinel's instance_eval
  # trampoline only rewires `self` for the outermost block): `articles.resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
end
```

> [!RULE] Правило Spinel: явный маппер
> ### Вложенные блоки получают маппер явно
>
> Пишите `resources :articles do |articles|` и `articles.resources :comments`, а
> не просто `resources :comments`. Трамплин `instance_eval` в Spinel
> переназначает `self` только для самого внешнего блока.

<!-- step 10 #comments-controller stage: Вы пишете · `app/controllers/` -->
## CommentsController

> [!WHY]
> Доступны только два действия, а родительская статья берётся из URL
> (`params[:article_id]`), а не из `:id`.

```ruby app/controllers/comments_controller.rb
class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    if @comment.save
      flash[:notice] = "Comment was successfully created."
    else
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
    end
    redirect_to article_path(@article), status: :see_other
  end

  def destroy
    @comment = Comment.where(article_id: @article.id).find(params[:id])
    @comment.destroy
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:commenter, :body)
  end
end
```

Затем добавьте валидации в модель комментария:

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true
end
```

> [!NOTE]
> `Article#comments` здесь — это Array, поэтому рельсовый
> `@article.comments.find(params[:id])` превращается в
> `Comment.where(article_id: @article.id).find(params[:id])`. Комментарий под
> чужой статьёй возвращает 404.

<!-- step 11 #views stage: Запуск · `app/views/`, при разработке читаются с диска, встраиваются командой `cybertrain build` -->
## Представления и партиалы

> [!WHY]
> Страница статьи выводит список её комментариев и заканчивается формой,
> привязанной к `[@article, @comment]`.

Сначала удалите ставшие недоступными представления комментариев `index`,
`show`, `new` и `edit` и добавьте в `ArticlesController#show` пустой
`@comment`:

```ruby app/controllers/articles_controller.rb (фрагмент)
  def show
    @comment = Comment.new
  end
```

Затем выведите комментарии и форму на странице статьи:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>
<%= render "comments/form" %>

<%# app/views/comments/_form.html.erb %>
<%= form_with(model: [@article, @comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

Партиал комментария в том виде, в каком он есть в примере:

```erb app/views/comments/_comment.html.erb
<%# locals: (comment:) %>
<div class="comment">
  <p>
    <strong>Commenter:</strong>
    <%= comment.commenter %>
  </p>

  <p>
    <strong>Comment:</strong>
    <%= comment.body %>
  </p>

  <%= button_to "Destroy comment", [@article, comment], method: :delete %>
</div>
```

И `button_to ... [@article, comment]`, и
`form_with(model: [@article, @comment])` разрешаются по одному и тому же
правилу `[parent, child]`: новый дочерний объект направляется во вложенную
коллекцию (`article_comments_path`), сохранённый — во вложенный элемент
(`article_comment_path`); эти хелперы генерируются в `gen/routes.rb` из
вложенного блока `resources` выше.

> [!RULE] Представления — замкнутая грамматика
> ### Представления — замкнутая грамматика, а не Ruby
>
> В Spinel нет `eval`, поэтому шаблоны интерпретируются по фиксированной
> грамматике. У `link_to` нет опции `method:`; используйте `button_to`. `each`
> принимает один или два параметра блока. Комментарий strict locals вроде
> `<%# locals: (comment:) %>` не допускает значений по умолчанию. Партиал
> получает копию окружения вызывающего кода, поэтому `@article` виден в
> `comments/_form`.

<!-- step 12 #test stage: Сборка · `cybertrain spin test` -->
## Тестирование

> [!WHY]
> minitest и RSpec находят тесты через рефлексию, на которую AOT-компилятор не
> способен, поэтому CyberTrain поставляется с `Cybertrain::Test`.

### Тест модели

```ruby test/articles.rb (отрывок)
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Утверждения: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. В примере также
используются `assert_response` и `assert_redirected_to`.

### Полный HTTP-сценарий

```ruby test/articles.rb (отрывок)
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "POST /articles creates an article and redirects to it" do
  client = Cybertrain::Test::Client.new(BLOG)
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, BlogTest.article_path(Article.last)
  assert_response res, :see_other
end
```

`Cybertrain::Test::Client` прогоняет приложение внутри процесса (без сокета) с
хранилищем cookie, поэтому сессии и CSRF ведут себя так же, как за браузером.
Запросы без токена получают 403.

> [!COMPILE] Что опущено в отрывках
> ### Что опущено в отрывках
>
> - `support/blog_test` — это
>   [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb):
>   скопируйте его в `test/support/` вашего приложения, где файлы подключаются,
>   а не запускаются. Он применяет миграции к новой `storage/test.sqlite3`,
>   загружает приложение как `BLOG`, подключает `Cybertrain::Test` и его клиент
>   и предоставляет `BlogTest.form_token` (CSRF-токен последней отрендеренной
>   формы) и `BlogTest.article_path`.
> - Завершите файл вызовом `Cybertrain::Test.run!`: он запускает тесты и выводит
>   строки, которые сравниваются со снимком.
> - Задайте `c.log_level = :none if c.test?` в `config/app.rb`, чтобы логи
>   запросов не попадали в сравниваемый вывод.

### Запуск тестов

```shell терминал — blog/
cybertrain spin test
```

`cybertrain spin test` запускает `spin test` с зафиксированным Spinel; если
инструменты есть в `PATH` ([шаг 00](#requirements)), то же самое делает
`spin test`. Он компилирует каждый `test/*.rb` в отдельную программу и
сравнивает её вывод (stdout и stderr вместе) с закоммиченным снимком
`test/<name>.rb.expected`. Файлы в `test/support/` подключаются, а не
запускаются. Чтобы записать снимок:

```shell терминал — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` записывает снимок по выводу CRuby. Тесты, обращающиеся к SQLite
> через FFI, не могут работать под CRuby, поэтому их снимок берётся из
> скомпилированного бинарного файла (вторая строка выше). Пока снимок устарел,
> `cybertrain spin test` завершается с ненулевым кодом, поэтому после него
> стоит `;`, а не `&&`; проверка `[ -x ]` пропускает запись, если компиляция
> не удалась, и старый снимок сохраняется. Тестам, которые не могут работать
> под CRuby, этот снимок нужен, прежде чем `cybertrain spin test` сможет
> пройти; остальные тесты без снимка сравниваются с выводом CRuby.

<!-- step 13 #authentication stage: Вы пишете · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Добавление входа

> [!WHY]
> Пока что любой может изменить или удалить статью. Как
> `bin/rails generate authentication` в Rails 8, одна команда добавляет вход
> по адресу почты и паролю — в виде кода, которым владеет приложение, а не
> подключаемого движка.

```shell терминал — blog/
cybertrain generate authentication
cybertrain db migrate    # создаёт таблицы users и sessions
```

Она пишет миграции для `users` (`email_address`, `password_digest`, уникальный
индекс) и `sessions` (по строке на каждый браузер, в котором выполнен вход),
модели `User` и `Session`, `SessionsController` (`/session/new`,
`POST /session`, `DELETE /session`) и `RegistrationsController` (`/sign_up`) с
их представлениями, частичный шаблон `sessions/_nav` в начале макета, а также
`test/authentication.rb` и `test/support/app_test.rb`. Ещё она вставляет
маршруты и блок сразу после строки с объявлением класса
`ApplicationController`:

```ruby app/controllers/application_controller.rb (фрагмент)
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
```

Теперь каждое действие требует выполненного входа, а посетителя перенаправляет
на `/session/new`. Снова откройте страницы, которые может читать любой, как
это делает руководство Rails:

```ruby app/controllers/articles_controller.rb (фрагмент)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

На этих страницах `resume_session` по-прежнему выполняется, поэтому шаблоны
могут читать `@current_user`. Спрячьте то, чем посетитель воспользоваться не
может:

```erb app/views/articles/show.html.erb (фрагмент)
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>
  <%= render "comments/form" %>
<% end %>
```

Запустите сервер и откройте `http://127.0.0.1:3000/sign_up`, чтобы создать
первого пользователя. У генератора Rails нет страницы регистрации — первого
пользователя создают в консоли; в CyberTrain консоли нет, поэтому генератор
пишет `RegistrationsController`. Если в приложение попадают только по
приглашению, удалите его вместе с маршрутами.

<details><summary>Приложение только по приглашению: `--invite-only` — Без страницы регистрации; первый пользователь создаётся из командной строки или на странице, которую можно открыть только с машины сервера</summary>

Страница регистрации позволяет зарегистрироваться любому, кто добрался до
сервера, а для внутреннего инструмента такое поведение по умолчанию неверно:
кто успел раньше администратора, тот и получил учётную запись. `--invite-only`
не пишет ни `RegistrationsController`, ни ссылки на регистрацию; первый
пользователь создаётся из командной строки или на странице, которую можно
открыть только с машины самого сервера, по ссылке, которую сервер печатает при
запуске:

```shell терминал — blog/
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # затем откройте на той же машине напечатанную ссылку http://127.0.0.1:3000/setup?token=...
```

В production — из каталога, в котором запускается бинарник:

```shell терминал — продакшен-сервер
./blog user ann@example.com                        # читает пароль из stdin (одну строку)
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user ann@example.com 's3cr3t-s3cr3t'        # или аргументом (виден в ps)
```

<!-- list: points -->
- `app/commands/user_command.rb` регистрирует команду `user` через
  `Cybertrain::Main.command` (поэтому `./blog help` её показывает) и
  подключается из `bin/blog.rb`. `EMAIL [PASSWORD]` создаёт пользователя или
  задаёт пароль пользователю с этим адресом (после чего, как и после любой
  смены пароля, во всех браузерах этого пользователя выполняется выход);
  команда печатает `created ADDRESS` или `updated ADDRESS` и завершается с
  кодом 0. Без `PASSWORD` она читает одну строку стандартного ввода (с
  приглашением, если это терминал; набранное отображается) и отбрасывает
  завершающий перевод строки, так что пароль не попадает ни в `ps`, ни в
  историю оболочки. Пустой пароль, запись, не прошедшая валидацию (пароль
  короче 8 символов), или неверные аргументы печатают ошибку или строку с
  использованием и завершаются с кодом 1.
- `SetupController` (`GET`/`POST /setup`, `app/views/setup/new.html.erb`)
  создаёт первого пользователя и выполняет за него вход. Он отвечает, только
  пока нет ни одного пользователя, только с одноразовым токеном (см. ниже) и
  только соединению, у которого на другом конце сокета loopback-адрес
  (`request.loopback?`: `127.0.0.0/8` или `::1`) и в котором нет заголовка
  `X-Forwarded-For` (прокси на том же хосте делает каждый запрос
  loopback-запросом, но добавляет этот заголовок). Заголовок может закрыть
  страницу, но никогда её не откроет. Все остальные, а также запросы без
  токена или с неверным токеном, получают 404.
- Токен: `SetupController::SETUP_TOKEN`, 32 случайных шестнадцатеричных
  символа (`Cybertrain::Crypto.random_token(16)`); он создаётся при запуске
  программы и хранится до её завершения, так что после перезапуска он новый.
  `GET /setup` принимает его как `?token=`, форма возвращает его в скрытом
  поле, и оба сравнивают его за постоянное время
  (`Cybertrain::Crypto.secure_compare`). Именно он держит страницу закрытой,
  когда проверка адреса бессильна: из-за прокси на том же хосте, который не
  добавляет `X-Forwarded-For` (nginx без
  `proxy_set_header X-Forwarded-For ...`), каждый клиент выглядит как
  loopback, а токен есть только у того, кто может читать лог сервера. Строка
  `Started GET "/setup?token=..."` в логе запросов записывает его в тот же
  лог; когда пользователь уже существует, токен ничего не открывает.
- Для первого запуска за прокси на другом хосте `BLOG_SETUP_OPEN=1` (объявлена
  в `config/app.rb` через `c.setting_bool :setup_open`) снимает проверку
  адреса — по-прежнему только пока нет ни одного пользователя и только с
  токеном. Уберите её, как только пользователь появится.
- Пока нет ни одного пользователя, сервер перед запуском пишет в лог
  `[WARN] no user exists yet: run ./blog user EMAIL, or open /setup?token=<token> from this machine`
  (`UserCommand.warn_if_no_user`, вызывается из `bin/blog.rb`, когда
  `Cybertrain::Main.server?(ARGV)`; он подключается к базе ради этого
  единственного вопроса и молчит, если таблица users ещё не создана
  миграцией). Эта строка — единственное место, где печатается токен.

Сгенерированный `test/authentication.rb` проверяет и то и другое: `/setup` с
токеном и без него (`SetupController.setup_token`) или с неверным, с другого
адреса (`client.peer_address = "203.0.113.7"`), через прокси, когда
пользователь уже есть и со включённым переключателем, а также команду `user`,
запущенную внутри процесса через `Cybertrain::Main.run`. Всё это — код
приложения, который можно менять (docs/design.md D29); фреймворк предоставляет
только `request.loopback?`, `Main.command`, `Main.server?`,
`Crypto.random_token` / `Crypto.secure_compare` и `peer_address` тестового
клиента.

</details>

> [!RULE] Правило Spinel: has_secure_password
> ### `has_secure_password` расписан явно
>
> Spinel не умеет определять методы во время выполнения, поэтому модель `User`
> явно содержит то, что определил бы `has_secure_password`: `password=`,
> `authenticate` и `User.authenticate_by(email_address:, password:)`. Пароли
> хеширует `Cybertrain::Password` — PBKDF2-HMAC-SHA256 на Ruby, по умолчанию 100
> 000 итераций (около 0,2 с в скомпилированном виде): для bcrypt бинарнику
> пришлось бы линковать C-библиотеку. Стоимость повышается строкой
> `Cybertrain::Password.iterations = 600_000` в `config/app.rb`;
> `User#authenticate` заново хеширует пароль каждого пользователя при его входе.

<details><summary>Аутентификация: что даёт фреймворк — Части, из которых собран генератор; ими можно пользоваться и без него</summary>

Генератор выше пишет весь сценарий; части, из которых он собран, — это API
фреймворка, и ими можно пользоваться без него (для API-токена, пароля
администратора, входа, написанного вручную):

<!-- list: points -->
- **`Cybertrain::Password`**: `hash(plain)` создаёт дайджест
  PBKDF2-HMAC-SHA256 с солью, который хранит собственные параметры
  (`$pbkdf2-sha256$i=100000$salt$key`), `verify?(plain, digest)` проверяет
  пароль по нему за постоянное время и никогда не выбрасывает исключение на
  испорченном дайджесте, а `needs_rehash?(digest)` сообщает, отстаёт ли
  дайджест от текущего `Password.iterations`. Для действия входа:
  - `verify_serialized(plain, digest)` — это `verify?` по одному вызову за раз
    на процесс (Mutex). Хеширование занимает около 0,2 с процессорного
    времени; пачка одновременных попыток заняла бы все воркеры, а через этот
    метод они встают в очередь, и остальные воркеры продолжают отдавать
    страницы.
  - `dummy_digest` — дайджест случайного пароля, создаваемый один раз на
    процесс с текущей стоимостью. Проверяйте по нему, когда адрес неизвестен,
    чтобы по времени ответа нельзя было понять, у каких адресов есть учётные
    записи:
    `Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)`.
  - `session_key(digest)` — HMAC дайджеста пароля под `secret_key_base`;
    сохраните его в сессии при входе и проверяйте на каждом запросе через
    `session_key_matches?(session[:password_key], user.password_digest)`.
    Смена пароля создаёт новый дайджест, поэтому во всех сессиях, начатых до
    неё, выполняется выход.
  - `iterations` равно `Password::TEST_ITERATIONS` (1000), когда
    `Cybertrain.config.test?`, так что наборы тестов не платят
    production-стоимость за каждого пользователя; дайджесты хранят своё число
    итераций, поэтому больше ничего не меняется.
- **Сессия** (`session[:key]`, подписанный cookie): `clear` очищает её (вместе
  с токеном CSRF) при выходе, а `config.session_absolute_max_age` (две недели;
  `0` отключает) ограничивает всё время жизни сессии, как бы часто ею ни
  пользовались: cookie хранит момент своей первой записи, cookie старше этого
  срока загружается как пустая сессия, поэтому скопированный cookie нельзя
  воспроизводить бесконечно. `session.restart_lifetime!` начинает отсчёт
  заново (при входе).
- **`Controller#local_path?(text)` и `safe_redirect_path(text, fallback)`**:
  на путь, пришедший из запроса (параметр `return_to`, запомненная страница),
  перенаправляют, только если он начинается с `/`, но не с `//` или `/\`,
  содержит только печатаемые символы ASCII и занимает не больше 2048 байт:
  `redirect_to safe_redirect_path(params[:return_to], "/"), status: :see_other`.
- **`skip_before_action(name, only:, except:)`** в классе контроллера убирает
  унаследованный `before_action` для части действий; сгенерированный
  `allow_unauthenticated_access` — однострочная обёртка над ним.
- **`cybertrain generate authentication`** пишет в виде кода, которым владеет
  приложение: миграции и модели `users` и `sessions`, `SessionsController`,
  `RegistrationsController`, их представления и частичный шаблон навигации,
  блок в `ApplicationController` (`resume_session`, `require_authentication`,
  `start_new_session_for`, `terminate_session`, `after_authentication_url`) и
  `test/authentication.rb`. Этот код использует всё из этого списка:
  `User.authenticate_by` проверяет через `verify_serialized` и фиктивный
  дайджест, `start_new_session_for` сохраняет ключ пароля и перезапускает
  время жизни, `resume_session` завершает строку Session, ключ которой больше
  не совпадает или которая старше `session_absolute_max_age`, а
  `after_authentication_url` — это `safe_redirect_path`. Чтобы в браузере, где
  сменили пароль, вход сохранился, запишите новый ключ после сохранения:
  `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`.
  Проектное решение: [docs/design.md](../design.md) D25.

</details>

### Обновление тестов

Тесты из [шага 12](#test), которые ожидают форму, отправляют её или обращаются
к действию помимо `index` и `show`, теперь упираются в страницу входа. Сначала
выполните вход клиентом с помощью хелперов, которые генератор записал в
`test/support/app_test.rb`:

```ruby test/signed_in.rb
require_relative "support/app_test"   # written by generate authentication: APP, AppTest

test "a signed-in user creates an article" do
  client = Cybertrain::Test::Client.new(APP)
  AppTest.user("ann@example.com", "s3cr3t-s3cr3t")
  AppTest.sign_in(client, "ann@example.com", "s3cr3t-s3cr3t")
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => AppTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, "/articles/#{Article.last.id}"
end
```

> [!NOTE]
> Запускайте `cybertrain spin test`, как в [шаге 12](#test);
> `test/authentication.rb` и этот тест используют SQLite, поэтому их снимки
> берутся из скомпилированного бинарника. `examples/blog` заканчивается до
> этого шага. Не генерируются: сброс пароля (в CyberTrain нет мейлеров) и
> ограничение частоты запросов.

<!-- step 14 #attachments stage: Вы пишете · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Добавление обложки

> [!WHY]
> У статьи может быть картинка. Разделение то же, что и во входе: фреймворк
> разбирает `multipart/form-data` и хранит байты, а остальное одна команда
> пишет в виде кода, которым владеет приложение, вместо `has_one_attached` из
> Active Storage.

```shell терминал — blog/
cybertrain generate attachment article cover   # для новой модели: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # добавляет столбцы cover_* в articles
```

Она пишет миграцию, которая добавляет в `articles` пять столбцов (`cover_key`,
`cover_filename`, `cover_content_type`, `cover_byte_size`, `cover_checksum`;
сам файл в SQLite не хранится), и блок в `Article` с `cover_file=`,
`cover_attached?`, `cover_url`, валидацией и колбэками сохранения и удаления.
В `ArticlesController` она добавляет действие `cover` под
`before_action :set_article` и по одной строке в `create` и `update`:

```ruby app/controllers/articles_controller.rb (фрагмент)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 13 wrote [:index, :show]; the generator added :cover
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show (and authentication applies).
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end
  # ...
  def create
    @article = Article.new(article_params)
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
  # ...
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.update(article_params)
```

Шаг 13 закрыл все страницы, а картинка на публичной странице статьи
запрашивается с `/articles/1/cover`. Генератор делает скачивание ровно
настолько публичным, насколько публична страница статьи: раз
`allow_unauthenticated_access` перечисляет `:show`, он добавляет в этот список
`:cover`, как в первой строке выше, и посетители, которым можно читать статью,
видят и картинку. Если страница статьи требует входа, то и скачивание тоже.
Всё, что `set_article` делает для ограничения видимых пользователю статей,
ограничивает и скачивание.

Генератор также добавляет `get "/articles/:id/cover"` в `config/routes.rb`,
`multipart: true` и поле выбора файла в форму, над кнопкой отправки, а на
страницу показа — картинку, сразу после `<h1>`:

```erb app/views/articles/_form.html.erb (фрагмент)
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb (фрагмент)
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!RULE] Правило Spinel: has_one_attached
> ### `has_one_attached` расписан явно
>
> Spinel не умеет определять методы во время выполнения (нет `define_method`),
> поэтому нет ни `has_one_attached`, ни общей таблицы вложений. Генератор
> расписывает то, что она определила бы, методами с именем по полю в `Article`,
> а метаданные кладёт в пять столбцов `articles`. Они объявлены `NOT NULL`, а
> `""` и `0` означают &ldquo;ничего не прикреплено&rdquo;: из-за столбцов,
> допускающих NULL, Spinel теряет вывод типов. В SQLite лежат только метаданные
> (текстовое значение обрывается на байте NUL); байты — это файлы.

### Как отдаются файлы

<!-- list: points -->
- **Типы.** По умолчанию принимаются только PNG, JPEG, GIF и WebP размером до
  2 МБ (`COVER_TYPES` и `COVER_MAX_BYTES` в модели; `--any` принимает любой
  тип). Тип определяется по первым байтам файла и никогда не берётся от
  браузера.
- **Хранение.** Байты попадают в `storage/uploads/<2 hex>/<32 hex key>`
  (`Cybertrain::BlobStore`, права 0600). Замена файла удаляет старый, а
  удаление статьи удаляет её файл. Копируйте `storage/uploads/` вместе с
  файлом SQLite.
- **Отдача.** Файлы отдаются через `send_blob` в контроллере, никогда не из
  `public/`. Четыре типа изображений отдаются для показа в браузере; всё
  остальное скачивается (`application/octet-stream`). Каждый ответ содержит
  `X-Content-Type-Options: nosniff` и
  `Content-Security-Policy: default-src 'none'; sandbox`.
- **Параметры.** `params.nested(:article).upload(:cover)` — это
  `Cybertrain::UploadedFile` или nil, если файл не выбран. `permit` никогда не
  возвращает файлы, поэтому файл может попасть в модель только через эту явную
  строку. Токен CSRF читается из multipart-тел так же, как из любой формы.
  Повреждённое или слишком большое тело даёт 400; пределы задают
  `max_upload_bytes` и `max_multipart_parts` в `config/app.rb`, а каталог —
  `upload_root`.

Запустите сервер, откройте статью для редактирования и выберите картинку.
Генератор также записал `test/attachment_article_cover.rb`, который проверяет
весь сценарий и сначала выполняет вход, раз в приложении есть `User`.
Поскольку здесь `:cover` открыт, тест проверяет, что посетитель может скачать
обложку, а текст статьи заполняет строкой `"A article."`, дополненной до
минимума в 10 символов из [шага 05](#validations).

> [!NOTE]
> Запускайте `cybertrain spin test`, как в [шаге 12](#test); тест использует
> SQLite, поэтому его снимок берётся из скомпилированного бинарника.
> `examples/blog` заканчивается до этого шага. Пока не сделано: несколько
> файлов на поле, S3 и другое удалённое хранилище, варианты изображений и
> потоковая запись больших тел на диск (тело читается в память целиком, до
> `max_body_bytes`).

<!-- step 15 #ship stage: Запуск · `dist/blog` -->
## Сборка для развёртывания

> [!WHY]
> Одна команда собирает приложение в готовый к развёртыванию каталог `dist/`
> со всеми встроенными представлениями.

```shell терминал — blog/
cybertrain build
```

Она записывает `dist/`: бинарный файл приложения со всеми встроенными
представлениями и рядом с ним файлы, которые он использует. Она запускает
`spin run gen -- --embed-views`, `spin build blog` и `spin run gen` (который
возвращает закоммиченный пустой `gen/views.rb`, даже после сбоя или Ctrl-C), а
затем собирает:

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>скомпилированные фреймворк, контроллеры, модели и интерпретатор шаблонов со всеми встроенными представлениями</span></li>
  <li><code>dist/public/</code><span>статические ресурсы и страницы ошибок; можно отдавать их через обратный прокси</span></li>
  <li><code>dist/storage/</code><span>создаётся пустым; по умолчанию здесь файл SQLite (пересборка никогда его не очищает)</span></li>
  <li><code>dist/tmp/</code><span>создаётся пустым (пересборка никогда его не очищает)</span></li>
</ul>

Скопируйте `dist/` на машину с той же ОС и тем же процессором (бинарный файл
компонуется с системной SQLite) и запустите там. Собранный бинарный файл по
умолчанию работает в окружении production (`CYBERTRAIN_ENV` переопределяет
это). Задайте `CYBERTRAIN_SECRET_KEY_BASE`; для примера:

```shell терминал — продакшен-сервер
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` применяет миграции, вкомпилированные в бинарный файл, а
`./blog db status` показывает их состояние; `PORT` задаёт порт. Не меняйте
секрет между перезапусками: его смена завершает все сессии.

`Cybertrain::Config` сначала читает переменные окружения; `config/app.rb` их
переопределяет:

<div class="table-scroll" role="region" aria-label="Переменные окружения" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">Переменная</th><th scope="col">Атрибут</th><th scope="col">По умолчанию</th></tr></thead>
  <tbody>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_ENV</code></td><td data-label="Атрибут"><code>env</code></td><td data-label="По умолчанию"><code>"development"</code>; <code>"production"</code> в бинарном файле из <code>cybertrain build</code> (также <code>"test"</code>)</td></tr>
    <tr><td data-label="Переменная"><code>PORT</code></td><td data-label="Атрибут"><code>port</code></td><td data-label="По умолчанию"><code>3000</code></td></tr>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_DATABASE</code></td><td data-label="Атрибут"><code>database_path</code></td><td data-label="По умолчанию"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="Атрибут"><code>secret_key_base</code></td><td data-label="По умолчанию">обязательна в production; в dev/test генерируется автоматически в <code>tmp/secret_key</code></td></tr>
    <tr><td data-label="Переменная"><code>SPINEL_WORKERS</code></td><td data-label="Атрибут"><code>workers</code></td><td data-label="По умолчанию"><code>1</code></td></tr>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_HOST</code></td><td data-label="Атрибут"><code>host</code></td><td data-label="По умолчанию"><code>"127.0.0.1"</code>; <code>0.0.0.0</code> слушает на всех интерфейсах (контейнеры)</td></tr>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="Атрибут"><code>session_same_site</code></td><td data-label="По умолчанию"><code>"Lax"</code>; также <code>Strict</code> или <code>None</code> (<code>None</code> всегда добавляет <code>Secure</code>); любое другое значение останавливает сервер при запуске</td></tr>
    <tr><td data-label="Переменная"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="Атрибут"><code>session_partitioned</code></td><td data-label="По умолчанию"><code>false</code>; <code>1</code> или <code>true</code> добавляет <code>Partitioned</code> (и <code>Secure</code>)</td></tr>
  </tbody>
</table>
</div>

```ruby config/app.rb
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

<!-- list: points -->
- Сервер говорит на обычном HTTP/1.1: для TLS и HTTP/2 поставьте перед ним
  nginx или Caddy. В production cookie сессии имеет флаг `Secure`, поэтому
  отдавайте приложение по HTTPS (задавайте `c.session_secure = false` в
  `config/app.rb`, только если production действительно работает по обычному
  http).
- Без `CYBERTRAIN_SECRET_KEY_BASE` production отказывается запускаться.
- В production исключение даёт ответ 500, а голый ответ с ошибкой (текстовый
  404 маршрутизатора, `head :not_found`, `render plain:`) заменяется на
  `public/<status>.html`, если такой файл существует; `cybertrain new` создаёт
  `404.html` и `500.html`.
- `SIGTERM` прекращает приём соединений, даёт выполняющимся запросам
  завершиться и выходит, когда они закончатся, или по истечении
  `drain_timeout` сервера (10 с).
- Слежение за файлами и цикл пересборки никогда не работают в production.
  Запущенный `cybertrain server` пропускает пересборки, пока
  `cybertrain build` удерживает `tmp/cybertrain-build.lock`.

`cybertrain new` также создаёт конфигурацию для
[Kamal 2](https://kamal-deploy.org). `Dockerfile` выполняет `cybertrain setup`
и `cybertrain build` на этапе сборки в Ubuntu и копирует `dist/` в облегчённый
этап того же выпуска; при запуске образ применяет миграции, а затем слушает
`0.0.0.0:3000`. Рядом лежат `.dockerignore`, `config/deploy.yml` (kamal-proxy
с Let&rsquo;s Encrypt перед приложением, проверка работоспособности по
`public/up.html`, файл SQLite на томе в `/app/storage`) и `.kamal/secrets`,
который читает `KAMAL_REGISTRY_PASSWORD` и `CYBERTRAIN_SECRET_KEY_BASE` из
окружения. Заполните значения, помеченные `CHANGE ME`, в `config/deploy.yml`,
сделайте коммит и выполните:

```shell терминал — blog/
kamal setup    # первый раз: ставит Docker и kamal-proxy на сервер, собирает, публикует и запускает
kamal deploy   # каждое следующее развёртывание
```

Двоичный файл компилируется внутри образа, поэтому ОС всегда совпадает с
образом; задайте `builder.arch` в `config/deploy.yml` по процессору сервера.
Развёртывайте на один сервер: база данных&nbsp;&mdash; файл SQLite на томе
этого сервера. Часть 8 в
[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) (на японском;
английская версия&nbsp;&mdash;
[`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)) описывает весь процесс,
включая резервные копии.

Готовое приложение [`examples/blog`](../../examples/blog#deploying-with-kamal)
содержит ту же конфигурацию с одним отличием: оно собирается с фреймворком из
репозитория (`path = "../.."` в его `spin.toml`), поэтому его `Dockerfile` не
ставит gem, а запускает `cybertrain setup` и `cybertrain build` из рабочей
копии, а контекст сборки&nbsp;&mdash; корень репозитория
(`builder.context: ../..`; `Dockerfile.dockerignore` отправляет только
фреймворк и приложение). CI
([`blog-image.yml`](../../.github/workflows/blog-image.yml)) собирает этот
образ при каждом изменении и убеждается, что проходит проверка
работоспособности, статья создаётся через форму, контейнер корректно
останавливается, а база данных сохраняется на томе; кроме того, он загружает
`config/deploy.yml` через Kamal.

> [!NOTE]
> Как сочетаются эти части и чем Kamal отличается от сервера за Caddy,
> рассказано на [странице о развёртывании](site:deploy.html).

<!-- step + #things-to-know -->
## Что нужно знать

> [!WHY]
> Ограничения и особенности, о которых лучше знать заранее, чтобы они не
> застали вас врасплох.

<!-- list: points know -->
- Сессии хранят только строки (String) в cookie с подписью HMAC.
- Только SQLite, через FFI Spinel.
- Бэктрейсов нет: ошибки показывают класс, сообщение, строку запроса и
  имя/строку шаблона.
- Атрибут с опечаткой в представлении выводится пустым вместо исключения; это
  известный пробел.
- Ассоциации выводятся только из внешних ключей схемы; нет
  `has_many :through`, `includes`, `pluck`, `dependent:`, enum, STI и
  полиморфных ассоциаций.
- Нет `namespace`, `respond_to`/форматов, `constraints` и `mount`;
  `render json:` минимален.
- В модели, созданной скаффолдом, валидацию присутствия по умолчанию получает
  только первое строковое поле.
- Генератор обрабатывает `app/controllers` и `app/models` лексическим
  сканированием (регулярными выражениями), а не парсером.
- Представления встраиваются при сборке: даже изменение только в представлении
  требует `cybertrain build` и перезапуска, прежде чем оно попадёт в
  production.
- Собирайте `dist/` на той же ОС и том же процессоре, что и у машины, где он
  будет работать: бинарный файл компонуется с системной SQLite.
- `SPINEL_WORKERS` по умолчанию равен `1`.
- Протестирован только Spinel `2026.10.27.7020`.

<!-- step + #differences -->
## Отличия от Rails

> [!WHY]
> Полная таблица из README в одном месте.

<!-- table: cmp -->
| Rails | CyberTrain |
|---|---|
| `rails console` | Консоли нет — в Spinel нет `eval` |
| Правите код — запущенное приложение подхватывает изменения | Ruby требует пересборки; в режиме разработки `cybertrain server` делает это за вас (пересборка, остановка, `execv`) |
| Правите представление — перезагрузка не нужна | Так же — в режиме разработки представления разбираются с диска при каждом запросе |
| `def new` | `def new_action` (`new` затенил бы `Klass.new(ctx)`) |
| `before_action { do_thing }` (неявный `self`) | `before_action { |c| c.do_thing }` — для сохранённого блока нет `instance_exec`, поэтому колбэки получают контроллер/запись явно |
| `resources :posts do resources :comments end` | `resources :posts do |posts| posts.resources :comments end` — вложенные блоки получают маппер явно |
| ERB компилируется в метод; любой объект, любой метод | Интерпретируется по фиксированной грамматике/таблице диспетчеризации |
| Сессия хранит любой сериализуемый через Marshal объект | Значения сессии — только строки (String), cookie с подписью HMAC |
| Множество адаптеров баз данных | Только SQLite, через FFI |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enum, STI, полиморфные ассоциации | Не реализовано; ассоциации выводятся только из внешних ключей схемы |
| `namespace`, форматы/`respond_to`, `constraints`, `mount` | Не реализовано — плоские имена, только `render json:` |
| Полный бэктрейс при исключении | Класс, сообщение, строка запроса, имя/строка шаблона — Spinel не предоставляет бэктрейсов |
| Rack, его middleware и любой гем в `Gemfile` | Нет совместимости с Rack; небольшой фиксированный набор middleware; собственный `spin-index` Spinel, ограниченный тем, что компилируется в рамках его подмножества Ruby |
| minitest / RSpec | `Cybertrain::Test` — раннеры на основе рефлексии не могут работать при AOT-компиляции |
| `bin/rails generate authentication`, `has_secure_password` | `cybertrain generate authentication` пишет то же самое и вдобавок страницу регистрации, раз консоли нет; `has_secure_password` расписан в модели User поверх `Cybertrain::Password` (PBKDF2); сброса пароля нет (нет мейлеров) |
| Мейлеры, фоновые задачи, ActionCable, asset pipeline, i18n | Не сделано (за рамками MVP) |
<!-- table-foot: Список не исчерпывающий. -->

<!-- step → #where-next -->
## Что дальше

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — Готовое приложение вместе с тестами.
- [**CyberTrain на GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Исходный код, README и релизы.
- [**Справочник API**](site:api/index.html) — Все классы и методы, которые использует приложение, с примерами.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Спайки и обнаруженные ими ограничения компилятора.
- [**Spinel**](https://github.com/matz/spinel) — AOT-компилятор Ruby от matz.
- [**Главная CyberTrain**](site:index.html) — Обзор, возможности и как это работает.
