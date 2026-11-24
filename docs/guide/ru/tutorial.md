---
source_sha256: 6089daf50cee57c1a9721c18dbb9a850c8b9b6fdc50d6498999b523a0bb023a4
path: tutorial.html
title: "Начало работы: блог"
description: "Соберите блог из Rails Getting Started — статьи с комментариями — на CyberTrain: установка, скаффолды, валидации, миграции, комментарии, вложенные в статьи, и тесты командой cybertrain test."
og_title: "Начало работы с CyberTrain: блог"
og_description: "Повторяет Getting Started самого Rails: блог со статьями и комментариями, построенный на CyberTrain и Spinel."
og_image: tutorial.png
crumb: "Учебник"
nav: tutorial
toc_title: "Шаги 00–12"
meta:
  - term: "Что нужно"
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, заголовки SQLite 3, zlib и OpenSSL (Spinel установится сам) <a class="meta-link" href="#requirements">Шаг 00</a>'
  - term: "Начало"
    text: "`gem install cybertrain`"
  - term: "Результат"
    text: "Блог со статьями, комментариями и тестами"
---

# Начало работы: блог

Повторяет
[Getting Started](https://guides.rubyonrails.org/getting_started.html) самого
Rails: блог со статьями и комментариями. Вы установите CLI, создадите скаффолд
статей, добавите валидации, вложите в статьи комментарии и запустите тесты —
и получите работающий блог на своей машине. Затем
[продвинутый учебник](advanced-tutorial.md) развивает тот же блог дальше:
живые комментарии через Turbo, фоновая задача, JSON, вход, загруженная
картинка и сборка для развёртывания.


<!-- step 00 #requirements stage: Подготовка · Ruby, `cc`, SQLite -->
## Требования

> [!WHY]
> CyberTrain компилируется через Spinel в C, поэтому ему нужны инструменты C и
> заголовки SQLite; команда `cybertrain` — это гем, поэтому ей нужен Ruby.

<!-- list: checklist -->
- Ruby 3.2+ и RubyGems — для команды `cybertrain` и для CRuby-превью сервера
  разработки (ему нужна библиотека Ruby `fiddle`); развёрнутое приложение
  никогда не запускается на CRuby. На Ruby 3.2 также `gem install prism`.
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

Первая строка устанавливает её из RubyGems. Остальное — весь путь в двух
словах: шаги ниже разбирают его по одной команде до `cybertrain server`, а
[продвинутый учебник](advanced-tutorial.md#ship) заканчивается
`cybertrain build`.

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
и остального), что делает каждую сборку короче. Шаги продвинутого учебника,
которым нужна подсистема, добавляют её строку
([Подсистемы](how-it-works.md#subsystems)).

Лейаут подключает `app/assets/stylesheets/application.css` через
`stylesheet_link_tag` и загружает `app/javascript/application.js` через import
map из `config/importmap.rb` с помощью `javascript_importmap_tags`;
`spin run gen` записывает оба файла с дайджестом в `public/assets/`, который
исключён из git (см. [Ассеты](assets.md)). В `.env.example` перечислены
переменные, которые читает приложение, `.github/workflows/ci.yml` запускает
тесты на GitHub
([Непрерывная интеграция](testing.md#continuous-integration)), а последняя
строка дерева — конфигурация Kamal из [шага 19](advanced-tutorial.md#ship).

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
`show`, `new`, `edit`, `_form`), файл фикстур и тесты ([шаг 12](#test)) и
вставляет `resources :articles` в
`config/routes.rb`. Типы полей: `string`, `text`, `integer`, `float`,
`boolean`, `date`, `datetime`, `references` и `attachment` (загруженный файл,
[шаг 18](advanced-tutorial.md#attachments)); по умолчанию — `string`. `cybertrain g scaffold` из
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

  def new_action   # the `new` action: the generated routes call new_action
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

> [!RULE] new_action
> ### `new_action`, а не `new`
>
> Действие `new` пишется как `new_action`: сгенерированные маршруты вызывают
> его под этим именем. Метод переименовали, когда за Spinel было записано, что
> он не компилирует метод экземпляра с именем `new` рядом с
> `ArticlesController.new(ctx)`; сокращённые программы такого вида на
> закреплённом выпуске компилируются, а имя осталось как API. Маршрут `GET /articles/new`
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
cybertrain server        # http://127.0.0.1:3000; правки Ruby видны сразу (CRuby), затем скомпилированными; представлениям не нужно ни то, ни другое
```

`spin run gen` читает `db/schema.rb` и `config/routes.rb`, сканирует `app/` и
записывает `gen/`; `spin run db -- migrate` применяет `db/migrate/*.rb` и
перезаписывает `db/schema.rb`. Порядок важен: первый `spin run gen` помещает
новую миграцию в `gen/migrations.rb`, который подключает `bin/db.rb`, а второй
строит модели по перезаписанному `db/schema.rb`.

`cybertrain server` меньше чем за секунду начинает отдавать приложение из
CRuby и собирает его Spinel в фоне. Первая сборка компилирует всё приложение
и занимает несколько минут; пока она не закончится, отвечает CRuby-превью, и
каждая страница сообщает об этом в правом нижнем углу:

```text вывод — cybertrain server
=> Booting cybertrain X.Y.Z
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> preview: CRuby (0.5s)
```

Когда сборка закончится, сервер выведет `=> spinel: ready in …s; serving
the compiled binary`, и с этого момента отвечает скомпилированный бинарный
файл. После правки Ruby он выводит `Changed` и имя файла, сразу снова
отвечает из CRuby и собирает заново ([Цикл разработки](how-it-works.md#the-development-loop)).
Ctrl-C его останавливает.

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
> пересборки: в режиме разработки `cybertrain server` сразу отвечает на них из
> CRuby-превью и передаёт порт скомпилированному бинарному файлу, когда его
> сборка завершится. В режиме разработки представления
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
> Оставленный запущенным `cybertrain server` подхватывает файлы скаффолда, как
> только они записаны, ещё до появления таблицы. Новая модель `Comment` берёт
> свои столбцы из `gen/models/comment.rb`, а gen пишет его только тогда, когда
> таблица есть в `db/schema.rb`, поэтому CRuby-превью не может её загрузить
> (`NoMethodError`): сервер отвечает собственной страницей 503 с этой
> ошибкой, и сборка Spinel тоже не удаётся. Когда `cybertrain db migrate`
> перезапишет `db/schema.rb`, сервер снова начнёт отвечать.

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

  # A nested block takes the mapper as its argument: `articles.resources`,
  # not Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] Явный маппер
> ### Вложенные блоки получают маппер явно
>
> Пишите `resources :articles do |articles|` и `articles.resources :comments`, а
> не просто `resources :comments`. Эту форму ввели, когда за Spinel было
> записано, что он не компилирует вызов без получателя в блоке, вложенном в
> `instance_eval`; сокращённая программа такого вида на закреплённом выпуске
> компилируется, а явный маппер остаётся документированной формой: её пишут
> и генераторы, и тесты.

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

Скаффолд записал модель комментария с `belongs_to :article` и проверкой
наличия `commenter`, её первого строкового поля; добавьте такую же для текста:

```ruby app/models/comment.rb
class Comment
  belongs_to :article
  validates :commenter, presence: true
  validates :body, presence: true
end
```

`belongs_to`, который объявил скаффолд, к тому же делает комментарий без статьи
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
локальную переменную, чтобы [шаг 14](advanced-tutorial.md#turbo) мог отрисовать её заново с новым
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

<!-- step 12 #test stage: Сборка · `cybertrain test` -->
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
`comments_controller_test.rb` (по запросу на действие), а `cybertrain new` —
`test/test_helper.rb`, который подключает каждый файл, и
`test/integration/health_test.rb`, запрос к `/up`. Трём из них нужно
догнать блог, каким он стал с тех пор: фикстуре статей и двум тестам
контроллеров.

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

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

Защита от подделки запросов в тестах выключена, как в Rails, так что
`post` не нужен токен. Остальные проверки — в
[Тестирование приложения](testing.md#assertions).

### Запуск тестов

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

Первый запуск компилирует все тесты в одну программу, что занимает
минуты (тесты examples/blog, которых при измерении 2026-11-13 было 149, — около
девяти на облачной машине с 4 vCPU); запуск без изменений не компилирует тестовую программу заново: он
может один раз пересобрать gen (`build gen`, несколько секунд), а затем
начинается меньше чем за секунду. Файл или `-n` выбирают,
какие тесты запускать, а не что компилировать: правка любого теста
компилирует программу заново. Каждый файл выводит заголовок, каждый тест —
строку (`ok`, или `FAIL` и `ERR` со строкой теста и сообщением), затем итоги, а между ними — то, что печатает сам тестируемый код
(например, строка вывода команды); код выхода — 1, если что-то упало.
На этом шаге в блоге двенадцать тестов.

> [!NOTE]
> Перед каждым тестом все таблицы очищаются, а фикстуры вставляются
> заново, поэтому тесты не зависят друг от друга. `gen/tests.rb` и
> `gen/test/` генерируются: коммитьте их вместе с остальным `gen/`.

<!-- step → #where-next -->
## Что дальше

Теперь у вас есть блог со статьями и комментариями, с валидациями и тестами,
который обслуживает `cybertrain server`. Продвинутый учебник продолжает с
этого места с тем же приложением.

<!-- list: next-list -->
- [**Продвинутый учебник**](advanced-tutorial.md) — Шаги 13–19: компонент и хелпер, живые комментарии через Turbo, фоновая задача, JSON, вход, обложка и сборка для развёртывания.
- [**Что нужно знать**](advanced-tutorial.md#things-to-know) — Ограничения и особенности, о которых стоит знать, пока они не застали врасплох.
- [**`examples/blog`**](../../examples/blog) — Приложение, в которое вырастают оба учебника, вместе с тестами.
- [**Руководства**](index.md) — По странице на тему: модели, запросы, шаблоны, реальное время, фоновая работа, тестирование.
- [**Модели и база данных**](models.md) — Миграции, запросы, ассоциации и все валидаторы.
- [**Тестирование**](testing.md) — Фикстуры, проверки и `cybertrain test` во всех подробностях.
- [**Справочник API**](site:api/index.html) — Все классы и методы, которые использует приложение, с примерами.
- [**CyberTrain на GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Исходный код, README и релизы.
- [**Главная CyberTrain**](site:index.html) — Обзор, возможности и как это работает.
