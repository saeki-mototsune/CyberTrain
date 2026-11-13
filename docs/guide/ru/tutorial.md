---
source_sha256: a6c97cf345f62630191ed3673c8515eacc0aa0c2f47281c2440566d491e82c94
path: tutorial.html
title: "Начало работы: блог"
description: "Соберите блог из Rails Getting Started — статьи с комментариями — на CyberTrain: скаффолды, миграции, вложенные маршруты, живые комментарии через Turbo, фоновая задача, тесты на Cybertrain::Test и сборка для развёртывания командой cybertrain build."
og_title: "Начало работы с CyberTrain: блог"
og_description: "Повторяет Getting Started самого Rails: блог со статьями и комментариями, построенный на CyberTrain и Spinel."
og_image: tutorial.png
crumb: "Учебник"
nav: tutorial
toc_title: "Шаги 00–19"
meta:
  - term: "Что нужно"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, заголовки SQLite 3, zlib и OpenSSL (Spinel установится сам) <a class="meta-link" href="#requirements">Шаг 00</a>'
  - term: "Начало"
    text: "`gem install cybertrain`"
  - term: "Результат"
    text: "`dist/blog`"
---

# Начало работы: блог

Повторяет
[Getting Started](https://guides.rubyonrails.org/getting_started.html) самого
Rails: блог со статьями и комментариями. Вы создадите скаффолд статей,
добавите валидации, вложите в статьи комментарии, будете рассылать новые
комментарии на все открытые страницы через Turbo, поставите в очередь фоновую
задачу, ответите в JSON, напишете тесты, которые прогоняют приложение внутри
процесса, добавите вход, прикрепите загруженную картинку и соберёте приложение
в готовый к развёртыванию каталог `dist/`. Приложение, в которое всё это
вырастает, — [`examples/blog`](../../examples/blog); оно проверяется в CI на
Linux и macOS.


<!-- step 00 #requirements stage: Подготовка · Ruby, `cc`, SQLite -->
## Требования

> [!WHY]
> CyberTrain компилируется через Spinel в C, поэтому ему нужны инструменты C и
> заголовки SQLite; команда `cybertrain` — это гем, поэтому ей нужен Ruby.

<!-- list: checklist -->
- Ruby 3.2+ и RubyGems — только для команды `cybertrain`; приложения никогда
  не запускаются на CRuby. На Ruby 3.2 также `gem install prism`.
- Spinel в релизе, который фиксирует CyberTrain (его выводит `cybertrain doctor`), — релиз форка
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel), в
  котором исправления, нужные CyberTrain, появляются раньше, чем в основном
  проекте; с другими версиями не тестировался. Вручную его устанавливать не
  нужно: первая команда, которой он нужен, собирает этот релиз в
  `~/.cybertrain` (несколько минут, один раз), если `spinel` этого релиза ещё
  нет в `PATH`.
- Инструменты C (`cc` или компилятор, указанный в `CC`) и `make`, а также
  `git` и `curl` — для сборки Spinel, который компилирует каждую программу в
  C.
- Заголовки и библиотеки SQLite 3, zlib и OpenSSL: `libsqlite3-dev`,
  `zlib1g-dev` и `libssl-dev` в Debian/Ubuntu. На macOS SQLite и zlib входят в
  Xcode command line tools, а OpenSSL ставится из Homebrew
  (`brew install openssl@3`, затем два пути, которые приведены в
  [Требованиях](install.md#requirements)).

`cybertrain doctor` проверяет всё это и выводит команду установки для того,
чего не хватает. Полный список и что необязательно:
[Требования](install.md#requirements); где оказывается Spinel и как
использовать другую установку: [как устанавливается Spinel](install.md#how-spinel-is-installed).

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
<span class="ln cmd">cybertrain new blog          <span class="c"># при первом запуске устанавливает Spinel (несколько минут)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># продакшен: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

[Все команды](install.md#the-cybertrain-command) с их параметрами перечислены
в руководстве по установке.

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
соответствующий CLI (X.Y.Z — то, что выводит `cybertrain version`):

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }
```

Затем она проверяет, что Spinel установлен (в первый раз это означает сборку
зафиксированного релиза Spinel в `~/.cybertrain`: несколько минут, один раз; см.
[шаг 00](#requirements)), и запускает `spin lock` (spin загружает фреймворк в
свой кэш `~/.cache/spin/packages/` и фиксирует коммит в `spin.lock`) и
`SPIN_DEBUG=1 spin run gen` (gen собирается в отладочном режиме spin) —
примерно так же, как `rails new` запускает `bundle install`,
— так что `cybertrain server` сразу работает. В конце она выводит следующие
шаги. Ничего из фреймворка в приложение не копируется; закоммитьте `spin.toml`
и `spin.lock`.

> [!NOTE]
> Если не удаётся установить Spinel или выполнить один из двух шагов `spin`,
> файлы остаются, `new` завершается с кодом 1 и выводит, что запустить после
> устранения причины (для Spinel: `cybertrain setup`, затем
> `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen` в новом каталоге).
> `--skip-spin` только записывает файлы; `--path DIR` вместо этого делает
> зависимостью локальную копию репозитория, `--git URL [--ref R]` — фреймворк
> по адресу URL (на ветке или теге R), а `--version V` — версию из индекса,
> когда `cybertrain` появится в `spin-index`.

Имена приложений состоят из строчных букв, цифр и `_` и начинаются с буквы.
Сгенерированное дерево:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb  config/locales/en.yml  .env.example
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/  app/jobs/
  app/assets/stylesheets/application.css  app/assets/images/
  app/javascript/application.js  config/importmap.rb
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/  .github/workflows/ci.yml
  Dockerfile  config/deploy.yml  .kamal/secrets
```

`bin/blog.rb` — единственная точка входа приложения, программа, которую
компилирует `spin build blog`: `./blog` обслуживает запросы, `./blog migrate`
и `./blog db status` управляют базой данных. `bin/gen.rb` запускает генератор
(`spin run gen`), а `bin/db.rb` запускает мигратор во время разработки (его
использует `cybertrain db migrate`, потому что `bin/blog.rb` не
скомпилируется, пока первая миграция не сгенерирует `gen/models/`). В `gen/`
уже лежит то, что записал `spin run gen`, в том числе `views.rb` —
закоммиченная пустая таблица встроенных представлений.

И `bin/blog.rb`, и `bin/db.rb` начинаются с `require "cybertrain/core"`:
фреймворк без необязательных подсистем (задач, Turbo Streams, почты, кэша
и остального), что делает каждую сборку короче. Шаги ниже, которым нужна
подсистема, добавляют её строку ([Подсистемы](how-it-works.md#subsystems)).

Лейаут подключает `app/assets/stylesheets/application.css` через
`stylesheet_link_tag` и загружает `app/javascript/application.js` через import
map из `config/importmap.rb` с помощью `javascript_importmap_tags`;
`spin run gen` записывает оба файла с дайджестом в `public/assets/`, который
исключён из git (см. [Ассеты](assets.md)). В `.env.example` перечислены
переменные, которые читает приложение, `.github/workflows/ci.yml` запускает
тесты на GitHub
([Непрерывная интеграция](testing.md#continuous-integration)), а последняя
строка дерева — конфигурация Kamal из [шага 19](#ship).

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

Она создаёт миграцию, модель, контроллер, пять представлений (`index`,
`show`, `new`, `edit`, `_form`), файл фикстур и тесты ([шаг 16](#test)) и
вставляет `resources :articles` в
`config/routes.rb`. Типы полей: `string`, `text`, `integer`, `float`,
`boolean`, `date`, `datetime`, `references` и `attachment` (загруженный файл,
[шаг 18](#attachments)); по умолчанию — `string`. `cybertrain g scaffold` из
быстрого старта — та же самая команда.

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
  # jobs_page "/admin/jobs", before_action: :require_admin
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
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

У `class Article` суперкласс не указан: суперкласс `Cybertrain::Model`,
столбцы и finder-методы берутся из `gen/models/article.rb`. Неудачное
сохранение выдаёт сообщения вроде «Title can't be blank», «Title has already
been taken» и «Body is too short (minimum is 10 characters)». Остальные
валидаторы (`format`, `inclusion`, `numericality`, ...) описаны в
[Валидациях](models.md#validations).

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
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen (gen и db в отладочном режиме)
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
=> Booting cybertrain X.Y.Z
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- Заново запускайте `cybertrain spin run gen` и коммитьте `gen/` после
  изменения схемы, маршрутов, колбэков и переменных экземпляра контроллера
  либо модели, хелпера, компонента или задачи либо ассета. Сервер разработки
  делает это за вас, а `cybertrain spin run gen -- --check` перечисляет
  устаревшее, ничего не записывая.
- Порт меняется так: `cybertrain server 4000` (или `PORT=4000`).
- `cybertrain db` добавляет `--`, который нужен `spin run db` перед
  аргументами; `cybertrain db status` и другие команды базы данных работают
  так же.

> [!RULE] Правило Spinel: консоль — не Ruby
> ### Консоль — не Ruby
>
> У `rails console` нет точного аналога: в Spinel нет `eval`.
> `cybertrain spin run blog -- console` (`./blog console` после сборки)
> вычисляет выражения шаблонов над моделями, например
> `Article.where(title: "x").count`, а `dbconsole` открывает `sqlite3`
> ([Консоль](background-and-operations.md#the-console)). Изменения в Ruby требуют
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
этого достаточно, чтобы `Article`/`Comment` получили ассоциацию:
`spin run gen` выводит `Article#comments` и `Comment#article` из внешнего ключа.
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

> [!NOTE]
> Оставленный запущенным `cybertrain server` пересобирает приложение, как
> только скаффолд запишет свои файлы, ещё до появления таблицы, и пишет в лог
> `Build failed; still serving the previous build (see tmp/rebuild.log)`. Он
> пересоберёт его снова, когда `cybertrain db migrate` перезапишет
> `db/schema.rb`.

> [!EXAMPLE] Удаление статьи с комментариями
> ### Удаление статьи с комментариями
>
> Внешний ключ не даёт удалить статью, у которой ещё есть комментарии.
> Объявите ассоциацию, как в Rails, и `destroy` сначала удалит их в своей
> транзакции:
>
> ```ruby app/models/article.rb (фрагмент)
>   # each comment's own destroy runs, callbacks included
>   has_many :comments, dependent: :destroy
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
  # jobs_page "/admin/jobs", before_action: :require_admin
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
    @comment = @article.comments.find(params[:id])
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

  belongs_to :article
end
```

Объявленный `belongs_to` к тому же делает комментарий без статьи
невалидным («Article can't be blank») раньше, чем его отвергнет база.

> [!NOTE]
> `Article#comments` — это relation комментариев, поэтому рельсовый
> `@article.comments.find(params[:id])` работает в `destroy` как есть, а
> комментарий под чужой статьёй возвращает 404.

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

Затем выведите комментарии и форму в конце страницы статьи и замените форму
комментария, созданную скаффолдом:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<h2>Comments</h2>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>

<h2>Add a comment:</h2>
<%= render "comments/form", comment: @comment %>

<%# app/views/comments/_form.html.erb %>
<%# locals: (comment:) %>
<%= form_with(model: [@article, comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

Партиал комментария:

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

### Куда ведут форма и кнопка

И `button_to ... [@article, comment]`, и
`form_with(model: [@article, comment])` разрешаются по одному и тому же
правилу `[parent, child]`: новый дочерний объект направляется во вложенную
коллекцию (`article_comments_path`), сохранённый — во вложенный элемент
(`article_comment_path`); оба хелпера генерируются в `gen/routes.rb` из
вложенного блока `resources` выше. Форма получает свой комментарий как
локальную переменную, чтобы [шаг 13](#turbo) мог отрисовать её заново с новым
комментарием.

> [!RULE] Представления — замкнутая грамматика
> ### Представления — замкнутая грамматика, а не Ruby
>
> В Spinel нет `eval`, поэтому шаблоны интерпретируются по фиксированной
> грамматике. У `link_to` нет опции `method:`; используйте `button_to`. `each`
> принимает один или два параметра блока. Комментарий strict locals вроде
> `<%# locals: (comment:) %>` не допускает значений по умолчанию. Партиал
> получает копию окружения вызывающего кода, поэтому `@article` виден в
> `comments/_form`.

> [!EXAMPLE] Список с числом комментариев и фильтром по дате
> ### Список с числом комментариев и фильтром по дате
>
> examples/blog выводит сначала новые статьи с числом комментариев — двумя
> запросами при любом числе статей — и фильтрует их по дате:
>
> ```ruby app/models/article.rb (фрагмент) · app/controllers/articles_controller.rb (фрагмент)
>   scope :recent, -> { order(created_at: :desc) }
>
>   def index
>     articles = Article.recent.includes(:comments)
>     from = Cybertrain::Cast.date_or_nil(params[:from])   # nil, если не YYYY-MM-DD
>     unless from.nil?
>       articles = articles.where_between(:created_at, Time.utc(from.year, from.month, from.day), nil)
>     end
>     @articles = articles.to_a
>   end
> ```
>
> В представлении `article.comments.size` отвечает по предзагруженным
> комментариям. Рельсовый `where(created_at: from..)` здесь пишется как
> `where_between`, потому что Spinel не строит Range из Time ([Условия и
> поиск](models.md#conditions-and-finders)).

<!-- step 12 #component stage: Вы пишете · `app/components/`, `app/helpers/` -->
## Компонент и хелпер

> [!WHY]
> Начиная со следующего шага комментарий отрисовывается в двух местах: на
> странице и в рассылке, за которой не стоит никакой запрос. Компонент — класс
> с шаблоном рядом — отрисовывается одинаково в обоих случаях; хелпер — это
> метод, который может вызвать любой шаблон.

```shell терминал — blog/
cybertrain generate component comment comment   # имя, затем атрибуты: один, тоже comment
cybertrain generate helper comments
```

Первая пишет `app/components/comment_component.rb` — с одним именованным
аргументом на каждый атрибут — и его шаблон; вторая пишет пустой
`CommentsHelper`. Каждая пишет ещё и тест, к которому вернётся
[шаг 16](#test). Класс уже такой, какой нужен блогу:

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

Замените сгенерированный шаблон разметкой комментария и добавьте в хелпер его
единственный метод:

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # Имя комментатора в <strong>, экранированное: <%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

Затем отрисуйте компонент там, где страница отрисовывала партиал, и удалите
`app/views/comments/_comment.html.erb`:

```erb app/views/articles/show.html.erb (фрагмент)
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- Шаблон видит переменные экземпляра компонента как локальные (`comment`), а
  его публичные методы без параметров — по имени. Ему передаётся только
  комментарий, без `@article` страницы, поэтому путь для кнопки строится из
  `comment.article_id`.
- `dom_id(comment)` — это `comment_7` для комментария с id 7: id элемента, на
  который нацелены рассылки следующего шага.
- Компонент называют так же, как партиал, — по его имени в snake_case без
  `_component`: шаблоны не могут называть константы.
- `Cybertrain::Html.tag` экранирует содержимое и возвращает `SafeString`,
  который шаблон выводит как есть; обычный `String`, возвращённый хелпером,
  экранируется.

> [!RULE] Правило Spinel: хелперы и компоненты — сгенерированная диспетчеризация
> ### Хелперы и компоненты — сгенерированная диспетчеризация
>
> Шаблоны не умеют `send`, поэтому `spin run gen` читает `app/helpers/` и
> `app/components/` как текст и пишет диспетчеризацию в `gen/helpers.rb` и
> `gen/components.rb`. Параметры хелпера именованы (никаких `*rest` и
> `**opts`), а его аргументы приходят как значения шаблона — поэтому
> `comment_author` сужает свой аргумент через `case ... when Comment`.
> Остальное — в [Хелперах приложения](template-language.md#application-helpers)
> и [Компонентах](template-language.md#components).

<!-- step 13 #turbo stage: Запуск · Turbo Streams поверх Server-Sent Events -->
## Живые комментарии через Turbo

> [!WHY]
> Комментарий, отправленный в одном браузере, должен появиться на каждой
> открытой странице этой статьи без перезагрузки. Как и в приложении на
> Rails 8, это Turbo Streams, и ничего не нужно ни устанавливать, ни запускать
> рядом с сервером.

### Подключение Turbo

`cybertrain new` оставил обе строки закомментированными; раскомментируйте их:

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

`javascript_importmap_tags` в лейауте пишет import map и
`import "application"`, так что теперь Turbo работает на каждой странице
([Import map](assets.md#the-import-map)).

Серверная часть Turbo Streams — подсистема: добавьте её строку под строкой
ядра в `bin/blog.rb` и ту же строку в `bin/db.rb`. Без неё `spin run gen`
остановится на `turbo_stream_from` ниже и назовёт нужную строку.

```ruby bin/blog.rb (фрагмент)
require "cybertrain/core"
require "cybertrain/streams"
```

### Подписка страницы

Дайте списку и форме по id и подпишите страницу на поток статьи:

```erb app/views/articles/show.html.erb (фрагмент)
<h2>Comments</h2>

<%= turbo_stream_from @article %>

<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render component: "comment", comment: comment %>
  <% end %>
</div>

<h2>Add a comment:</h2>

<div id="comment_form">
  <%= render "comments/form", comment: @comment %>
</div>
```

### Рассылка и ответ

`create` рассылает сохранённый комментарий, а затем отвечает браузеру, который
его отправил; `destroy` сообщает остальным страницам, что элемент нужно
убрать:

```ruby app/controllers/comments_controller.rb (фрагмент)
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Каждая страница, подписанная через turbo_stream_from @article, добавляет комментарий.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    @new_comment = Comment.new   # пустая форма, которую вернёт на место create.turbo_stream.erb
    respond_to do |format|
      format.turbo_stream   # app/views/comments/create.turbo_stream.erb
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    target = Cybertrain::Html.dom_id(@comment)   # читаем до того, как destroy очистит id
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end
```

```erb app/views/comments/create.turbo_stream.erb
<%= turbo_stream.append "comments", html: render(component: "comment", comment: @comment) %>
<%= turbo_stream.update "comment_form", partial: "comments/form", locals: { comment: @new_comment } %>
```

Откройте одну статью в двух окнах и отправьте комментарий в одном: он появится
в обоих, а форма, из которой он отправлен, вернётся пустой.

### Что происходит

<!-- list: points -->
- `turbo_stream_from @article` пишет элемент `<turbo-stream-source>` для
  потока `articles:<id>` с подписанным токеном. Turbo открывает его как
  `EventSource` на `/cybertrain/stream`, который сервер уже обслуживает.
- Рассылка — это строка в `cybertrain_messages`, таблице, которую фреймворк
  создаёт сам. Каждый серверный процесс опрашивает её и передаёт строку
  страницам, которые он держит, примерно за десятую долю секунды.
- Turbo отправляет форму, запрашивая Turbo Stream, поэтому
  `format.turbo_stream` отрисовывает `create.turbo_stream.erb` без лейаута.
  Обычная отправка формы, с выключенным JavaScript, идёт через `format.html` и
  получает редирект, как раньше.
- Окно, отправившее комментарий, получает его дважды — в ответе и в рассылке —
  и показывает один раз: Turbo заменяет элемент с тем же id.

Подробнее, включая WebSocket и потоки для вашего собственного JavaScript:
[Реальное время](realtime.md#turbo-streams).

> [!NOTE]
> Здесь Turbo загружается с jsDelivr. Чтобы отдавать его самостоятельно,
> скопируйте `turbo.es2017-esm.js` в `vendor/javascript/` и укажите его в pin
> через `to: "turbo.es2017-esm.js"`. Если вы включите Content Security Policy,
> закомментированную в `config/app.rb`, её `script_src` должен разрешать тот
> источник, с которого отдаётся Turbo
> ([Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)).

<!-- step 14 #job stage: Вы пишете · `app/jobs/` -->
## Фоновая задача

> [!WHY]
> Работа, которая не должна задерживать ответ, например уведомление,
> выполняется после него. Как и в Active Job на Solid Queue, задача — это
> класс в `app/jobs/` и строка в собственной базе данных приложения: никаких
> других сервисов.

```shell терминал — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

Она пишет `app/jobs/notify_comment_job.rb` — со строкой `retry_on`, которую
запросила опция, и пустым `perform` — и тест, а в `bin/blog.rb` и `bin/db.rb`
добавляет `require "cybertrain/jobs"`. Заполните `perform`; здесь он
только пишет в лог, а настоящее приложение отправило бы письмо:

```ruby app/jobs/notify_comment_job.rb
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
```

Поставьте её в очередь из `create`, как только комментарий сохранён:

```ruby app/controllers/comments_controller.rb (фрагмент)
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Каждая страница, подписанная через turbo_stream_from @article, добавляет комментарий.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

Отправьте комментарий — и в логе сервера будет видно, что задача выполняется
после ответа:

```text вывод — cybertrain server
[INFO] Started POST "/articles/1/comments" for 127.0.0.1
[INFO] Completed 200 in 2ms
[INFO] new comment 1 on article 1
[INFO] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` — это Hash, переданный в `perform_later`; он хранится как JSON и
  читается обратно с ключами-строками (String): передавайте id, а не записи, и
  сужайте значения через `Cybertrain::Cast`. `perform_in(seconds, args)` и
  `perform_at(time, args)` ставят задачу в очередь на потом.
- Задачи — это строки `cybertrain_jobs`; их выполняют три потока задач
  обслуживающего процесса или отдельного, запущенного командой
  `./blog worker`
  ([Роли процессов](background-and-operations.md#process-roles)).
- `retry_on StandardError, wait: 30, attempts: 3` снова ставит неудачное
  выполнение в очередь через 30 секунд, всего три попытки; после этого строка
  становится `failed` и сохраняется
  ([Повторы и отбрасывание](background-and-operations.md#retries-and-discards)).
- Задача может выполниться больше одного раза (если процесс умирает посреди
  задачи, она запускается снова), поэтому пишите `perform` так, чтобы его
  можно было безопасно повторить.
- Неудавшиеся задачи просматривают, повторяют и отбрасывают командой
  `./blog jobs` или на странице, которую подключает строка
  `jobs_page` в `config/routes.rb`, если её раскомментировать (маршруты шагов
  04 и 09 её сохраняют)
  ([Страница задач](background-and-operations.md#the-jobs-page-and-the-jobs-command)).

> [!RULE] Правило Spinel: политики задач читаются как текст
> ### Политики задач читаются как текст
>
> `spin run gen` читает каждый класс в `app/jobs/` и пишет его вторую половину
> в `gen/jobs.rb`: `perform_later` и каждый `retry_on` в виде ветки `rescue`.
> Поэтому `retry_on`, `discard_on` и `limits_concurrency` занимают по одной
> строке и принимают литеральные значения: `wait: 30`, а не `wait: 30.seconds`
> и не лямбду.

> [!EXAMPLE] Удаление выполненных задач каждую ночь
> ### Удаление выполненных задач каждую ночь
>
> Каждый комментарий оставляет после себя строку `done`. `config/app.rb`
> заканчивается закомментированной задачей по расписанию, которая удаляет
> такие строки недельной давности; раскомментируйте её:
>
> ```ruby config/app.rb (фрагмент)
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> Выражение cron читается в часовом поясе `CYBERTRAIN_SCHEDULER_TZ` (по
> умолчанию — `time_zone` приложения, UTC, если он не задан), а расписание в каждый момент выполняет только один процесс
> ([Задачи по расписанию](background-and-operations.md#scheduled-tasks)).

<!-- step 15 #json stage: Вы пишете · `app/controllers/` -->
## Ответ в JSON

> [!WHY]
> Одно действие может обслуживать и страницу, и API: `respond_to`, как в
> Rails.

```ruby app/controllers/articles_controller.rb (фрагмент)
  def index
    @articles = Article.all.to_a
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:as_json) }
    end
  end

  def show
    @comment = Comment.new
    respond_to do |format|
      format.html
      format.json { render json: @article.as_json }
    end
  end
```

```console терминал — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- Формат берётся из расширения (`/articles.json`) или, если его нет, из
  заголовка `Accept`. На формат, которого действие не перечисляет, например
  `/articles.xml`, приходит ответ `406 Not Acceptable`.
- `format.html` без блока отрисовывает шаблон действия, как раньше.
- `as_json` — это столбцы записи, время в ISO 8601, UTC. У JSON нет шаблонов:
  действие отвечает им через `render json:`.
- Оставляйте в блоке только строки `format.`: когда запрос откатывается к
  html, блок выполняется второй раз.

`/articles/1.json` — это одна статья, из такого же блока в `show`. Всё о
форматах: [Форматы и `respond_to`](requests.md#formats-and-respond_to).

<!-- step 16 #test stage: Сборка · `cybertrain test` -->
## Тестирование

> [!WHY]
> minitest и RSpec находят тесты через рефлексию, чего AOT-компилятор
> сделать не может. Тем не менее тесты — это классы Rails: `spin run gen`
> переписывает их в одну программу, которую `cybertrain test` компилирует
> и запускает.

### Что записали генераторы

Скаффолды шагов 03 и 08 записали скаффолд-тесты Rails:
`test/fixtures/articles.yml` и `comments.yml` (строки `one` и `two`, с
которых начинается каждый тест), `test/models/article_test.rb` и
`comment_test.rb` («the fixture is valid»), а также
`test/controllers/articles_controller_test.rb` и
`comments_controller_test.rb` (по запросу на действие). Шаг 12 записал
`test/components/comment_component_test.rb` и
`test/helpers/comments_helper_test.rb`, шаг 14 —
`test/jobs/notify_comment_job_test.rb`, а `cybertrain new` —
`test/test_helper.rb`, который подключает каждый файл, и
`test/integration/health_test.rb`, запрос к `/up`. Трём из них нужно
догнать блог, каким он стал с тех пор.

### Фикстуры, проходящие валидации

Образцовые значения скаффолда (`MyString`, `MyText`) не проходят проверки
[шага 05](#validations): две статьи с одинаковым заголовком и тексты короче
десяти символов. Дайте статьям настоящие значения:

```yaml test/fixtures/articles.yml
one:
  title: Hello Rails
  body: I am on Rails! This is my first article.

two:
  title: Second article
  body: Another article, with no comments.
```

Тест создания отправляет собственный заголовок фикстуры, который теперь
занят; дайте ему новый:

```ruby test/controllers/articles_controller_test.rb (отрывок)
  test "should create article" do
    assert_difference(-> { Article.count }, 1) do
      post articles_url, params: { article: { body: @article.body, title: "A new title" } }
    end

    assert_redirected_to article_url(Article.last)
  end
```

Строки `comments.yml` принадлежат `article: one`. Как и в Rails, фикстура,
указывающая на статью, не даёт эту статью удалить, поэтому «should destroy
article» падает на внешнем ключе, если `Article` не объявляет
`has_many :comments, dependent: :destroy` (врезка в конце
[шага 08](#scaffold-comment)). Если вы этого не сделали, добавьте его в
`app/models/article.rb`, как в examples/blog:

```ruby app/models/article.rb (отрывок)
  has_many :comments, dependent: :destroy
```

### Комментарии под своей статьёй

Тест комментариев из скаффолда запрашивает маршруты, которые
[шаг 09](#nested-routes) вложил в статьи; их хелперы теперь —
`article_comments_path` и `article_comment_path`. Замените его:

```ruby test/controllers/comments_controller_test.rb
require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  test "a comment is added to its article" do
    article = articles(:one)
    assert_difference(-> { Comment.count }, 1) do
      post article_comments_path(article), params: { comment: { commenter: "Dave", body: "First!" } }
    end
    assert_redirected_to article_path(article)
  end

  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end

  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

Тест не запускает потоков задач, поэтому задача в очереди ждёт, пока её не
выполнит тест (`perform_enqueued_jobs`). Защита от подделки запросов в
тестах выключена, как в Rails, так что `post` не нужен токен.

### Компонент

Тест шага 12 рендерит `CommentComponent` со String там, где шаблон теперь
ожидает комментарий. Отрендерите вместо этого комментарий из фикстуры:

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` рендерит так же, как трансляция, без запроса, а
`assert_select` читает то, что он отрендерил. Остальные проверки:
[Тестирование приложения](testing.md#assertions),
[Тестирование задач](testing.md#testing-jobs) и
[Тестирование потоков и компонентов](testing.md#testing-streams-and-components).

### Запуск тестов

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

Первый запуск компилирует все тесты в одну программу, что занимает
минуты (149 тестов examples/blog — около девяти на облачной машине с
4 vCPU); запуск без изменений не компилирует тестовую программу заново: он
может один раз пересобрать gen (`build gen`, несколько секунд), а затем
начинается меньше чем за секунду. Файл или `-n` выбирают,
какие тесты запускать, а не что компилировать: правка любого теста
компилирует программу заново. Каждый файл выводит заголовок, каждый тест —
строку (`ok`, или `FAIL` и `ERR` со строкой теста и сообщением), затем итоги, а между ними — то, что печатает сам тестируемый код
(например, строка вывода команды); код выхода — 1, если что-то упало.
По измерению 2026-11-13 блог из руководства на этом шаге выполняет 17
тестов и 25 проверок.

> [!NOTE]
> Перед каждым тестом все таблицы очищаются, а фикстуры вставляются
> заново, поэтому тесты не зависят друг от друга. `gen/tests.rb` и
> `gen/test/` генерируются: коммитьте их вместе с остальным `gen/`.

<!-- step 17 #authentication stage: Вы пишете · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
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

Генератор пишет миграции и модели `users` и `sessions`, concern `Authentication`, который он включает в `ApplicationController`, контроллеры и представления для входа, регистрации, сброса пароля и страницы учётной записи, почтовик, команду `./blog user` и тесты. Ещё он добавляет маршруты, partial `sessions/_nav` в начало макета и настройку `base_url` в `config/app.rb`, с которой начинаются ссылки в письмах. Наконец, он добавляет в `bin/blog.rb` и `bin/db.rb` строки подсистем, которые использует его код: `cybertrain/jobs` (страница заданий и поток, отправляющий письма), `cybertrain/mailer`, `cybertrain/mailer/later` (письма уходят через `deliver_later`) и `cybertrain/rate_limit` (попытки входа ограничены по частоте, см. ниже). Все файлы перечислены в разделе [Аутентификация](authentication.md#generating-it).

```ruby app/controllers/concerns/authentication.rb (фрагмент)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
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

  <div id="comment_form">
    <%= render "comments/form", comment: @comment %>
  </div>
<% end %>
```

Кнопка «Destroy comment» остаётся в компоненте комментария для всех: рассылка
отрисовывает его один раз для всех зрителей, без запроса, а значит, и без
текущего пользователя. Посетителя, который на неё нажмёт, отправят на страницу
входа, поскольку `CommentsController` не открывает ни одного действия; новые
комментарии по-прежнему доходят до страницы посетителя, потому что поток — не
действие контроллера.

Запустите сервер и откройте `http://127.0.0.1:3000/sign_up`, чтобы создать первого пользователя. У генератора Rails нет страницы регистрации, и первого пользователя создают в консоли; CyberTrain пишет `RegistrationsController`, так что первый пользователь регистрируется в браузере. Для приложения только по приглашениям запустите генератор с `--invite-only`: страницы регистрации нет, а первый пользователь появляется из `./blog user EMAIL` или со страницы `/setup`, которую можно открыть только с машины самого сервера ([Регистрация или только по приглашению](authentication.md#sign-up-or-invite-only)).

Страница входа также ссылается на сброс пароля по почте, а навигация — на страницу учётной записи; о них, а также о блокировке, «оставаться в системе», `--confirmable` и администраторах рассказывает руководство [Аутентификация](authentication.md). Письму сброса нужны настройки SMTP, а в продакшене — `BLOG_BASE_URL` ([Ссылки в письмах](authentication.md#links-in-mails)).

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

### Обновление тестов

Тесты из [шага 16](#test), которые открывают форму, отправляют её или
обращаются к действию помимо `index` и `show`, теперь упираются в страницу
входа. Генератор записал `test/fixtures/users.yml` (`one` и `two`, пароль
`"password"`) и `test/support/session_test_helper.rb`, чей `sign_in_as` `test/test_helper.rb` теперь даёт каждому
интеграционному тесту, а в `setup` теста статей он уже добавил вход
(печатает `insert test/controllers/articles_controller_test.rb (sign_in_as users(:one))`),
так что вы увидите:

```ruby test/controllers/articles_controller_test.rb (отрывок)
  setup do
    sign_in_as users(:one)
    @article = articles(:one)
  end
```

У теста комментариев нет `setup`, в который генератор мог бы добавить
вход, а каждое действие `CommentsController` (create и destroy) теперь
требует вошедшего пользователя, поэтому и каждый из четырёх его тестов;
дайте его:

```ruby test/controllers/comments_controller_test.rb (отрывок)
class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end
```

Скаффолд, сгенерированный с этого момента, входит сам.

> [!NOTE]
> Собственные тесты генератора (`test/controllers/sessions_controller_test.rb`,
> `registrations_controller_test.rb`, `passwords_controller_test.rb`,
> `accounts_controller_test.rb`, `test/integration/remember_me_test.rb`,
> `lockout_test.rb`, `admin_test.rb`, [Тестирование](authentication.md#testing))
> выполняются вместе с остальными в `cybertrain test`, двигая часы через
> `travel_to`, чтобы проверить 15-й и 30-й день. Попытки входа
> ограничиваются, как в генераторе Rails: десять с одного адреса клиента
> за три минуты, со счётом в базе данных приложения, так что все процессы
> считают вместе; за обратным прокси настройте
> [доверенные прокси](requests.md#rate-limiting-and-the-client-address).
> `examples/blog` проходит этот шаг с `--invite-only` и делает свои
> страницы `/admin` доступными только администраторам.

<!-- step 18 #attachments stage: Вы пишете · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Добавление обложки

> [!WHY]
> У статьи может быть картинка. Разделение то же, что и во входе: фреймворк
> разбирает `multipart/form-data` и хранит байты, а остальное одна команда
> пишет в виде кода, которым владеет приложение, вместо `has_one_attached` из
> Active Storage.

Картинка будет показана на странице статьи, которую посетители могут читать с
шага 17, поэтому её скачивание тоже должно быть им открыто. Перед запуском
генератора добавьте `:cover` в список, который написал шаг 17:

```ruby app/controllers/articles_controller.rb (фрагмент)
  allow_unauthenticated_access only: [:index, :show, :cover]
```

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
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 17 wrote [:index, :show]; you added :cover
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

Скачивание находит свою статью через `set_article`, как и `show`, поэтому всё,
что `set_article` делает для ограничения видимых пользователю статей,
ограничивает и скачивание. Среди своих строк генератор выводит предупреждение,
потому что в этом `show` есть собственный код:

```text вывод — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

Здесь этот код создаёт комментарий и выбирает формат; он никому не отказывает,
так что переносить в `cover` нечего.

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

> [!NOTE]
> Генератор переносит правила доступа `show` на скачивание, но только те,
> которые может прочитать: колбэки. Если какой-нибудь `before_action`, кроме
> `set_article`, перечисляет `:show` без нового действия, генератор
> останавливается с сообщением
> `cannot preserve show's authorization for :cover` и ничего не пишет. Что
> проверяет код внутри `def show`, он прочитать не может — отсюда и
> предупреждение. При пустом `show` он сам добавляет `:cover` в
> `allow_unauthenticated_access` там, где перечислен `:show`; если в `show`
> есть код, он эту строку не трогает, а без `:cover` в ней изображение требует
> входа.

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
Генератор также записал `test/integration/article_cover_attachment_test.rb`
и картинку `test/fixtures/files/cover.png`; тест проверяет
весь сценарий и сначала выполняет вход, раз в приложении есть `User`.
Поскольку здесь `:cover` открыт, тест проверяет, что посетитель может скачать
обложку, а текст статьи заполняет строкой `"A article."`, дополненной до
минимума в 10 символов из [шага 05](#validations).

> [!NOTE]
> Запускайте `cybertrain test`, как в [шаге 16](#test) (по измерению
> 2026-11-13 блог из руководства тогда выполняет 83 теста и 870 проверок).
> В `examples/blog` этот шаг тоже есть, а его JSON не включает столбцы
> `cover_*` (`Article#public_json`). Пока не сделано: несколько
> файлов на поле, S3 и другое удалённое хранилище, варианты изображений и
> потоковая запись больших тел на диск (тело читается в память целиком, до
> `max_body_bytes`).

<!-- step 19 #ship stage: Запуск · `dist/blog` -->
## Сборка для развёртывания

> [!WHY]
> Одна команда собирает приложение в готовый к развёртыванию каталог `dist/`
> со всеми встроенными представлениями.

```shell терминал — blog/
cybertrain build
```

Она записывает `dist/`: бинарный файл приложения со всеми встроенными
представлениями и рядом с ним файлы, которые он использует. Она запускает
`SPIN_DEBUG=1 spin run gen -- --embed-views`, `spin build blog` и
`SPIN_DEBUG=1 spin run gen` (который
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
это). Задайте `CYBERTRAIN_SECRET_KEY_BASE` (его выводит и
`cybertrain secret`); для примера:

```shell терминал — продакшен-сервер
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` применяет миграции, вкомпилированные в бинарный файл, а
`./blog db status` показывает их состояние; `PORT` задаёт порт. Не меняйте
секрет между перезапусками: его смена завершает все сессии. `./blog help`
перечисляет остальные команды бинарного файла, среди них `worker`, `jobs`,
`console` и `db backup`.

`Cybertrain::Config` сначала читает переменные окружения; `config/app.rb` их
переопределяет. Переменные, с которыми сталкивается первое развёртывание (все:
[Конфигурация](configuration.md#configuration-and-environment-variables)):

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
  http). За таким прокси `CYBERTRAIN_FORCE_SSL=1` перенаправляет http на
  https, а `CYBERTRAIN_HOSTS` называет хосты, на которые отвечает приложение
  ([хосты и `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)).
- Обслуживающий процесс выполняет также задачи, задачи по расписанию и
  опросчик потоков из шагов 13 и 14: один процесс — это всё развёртывание.
  `./blog worker` выносит задачи в отдельный процесс
  ([Роли процессов](background-and-operations.md#process-roles)).
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
образ при каждом релизе и убеждается, что проходит проверка
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
- Сессии хранят только строки (String) в зашифрованной cookie.
- Только SQLite, через FFI Spinel.
- Бэктрейсов нет: ошибки показывают класс, сообщение, строку запроса и
  имя/строку шаблона.
- Атрибут с опечаткой в представлении вызывает исключение
  (`undefined method 'titel' for Article`); столбец, в котором `nil`,
  выводится пустым.
- Ассоциации выводятся из внешних ключей или однострочных объявлений; нет
  `has_many :through`, вложенного `includes`, enum, STI и полиморфных
  ассоциаций.
- Нет `constraints` и `mount`; JSON отдаётся через `render json:` (шаблонов
  JSON нет).
- В модели, созданной скаффолдом, валидацию присутствия по умолчанию получает
  только первое строковое поле.
- Генератор обрабатывает `app/controllers`, `app/models`, `app/helpers`,
  `app/components` и `app/jobs` лексическим сканированием (регулярными
  выражениями), а не парсером.
- Задачи выполняются хотя бы один раз, а рассылка доходит только до страниц,
  открытых в момент её отправки или переподключившихся в течение минуты.
- Представления встраиваются при сборке: даже изменение только в представлении
  требует `cybertrain build` и перезапуска, прежде чем оно попадёт в
  production.
- Собирайте `dist/` на той же ОС и том же процессоре, что и у машины, где он
  будет работать: бинарный файл компонуется с системной SQLite.
- `SPINEL_WORKERS` по умолчанию равен `1`.
- Протестирован только зафиксированный релиз Spinel (`Cybertrain::SPINEL_TAG`).
- Другие отличия от Rails, в одной таблице: [Отличия от Rails](how-it-works.md#differences-from-rails).

<!-- step → #where-next -->
## Что дальше

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — Приложение, в которое вырастает этот учебник, вместе с тестами.
- [**Аутентификация**](authentication.md) — Сброс пароля, подтверждение, блокировка, «оставаться в системе», страница учётной записи и администраторы.
- [**Интернационализация**](i18n.md) — Словари, `t` и `l` и локаль для каждого запроса.
- [**Руководства**](index.md) — По странице на тему: модели, запросы, шаблоны, реальное время, фоновая работа, тестирование.
- [**CyberTrain на GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Исходный код, README и релизы.
- [**Справочник API**](site:api/index.html) — Все классы и методы, которые использует приложение, с примерами.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Спайки и обнаруженные ими ограничения компилятора.
- [**Spinel**](https://github.com/matz/spinel) — AOT-компилятор Ruby от matz.
- [**Главная CyberTrain**](site:index.html) — Обзор, возможности и как это работает.
