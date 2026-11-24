---
source_sha256: f3d5e388be9dc562f649c6e1dcf1afcea8d74ed13d2d2c8f461e12945ecee24b
title: "Продвинутый учебник: развиваем блог дальше"
description: "Продолжите блог из Getting Started на CyberTrain: компонент и хелпер, живые комментарии через Turbo Streams, фоновая задача, JSON, вход, загруженная обложка и сборка для развёртывания командой cybertrain build."
og_title: "Продвинутый учебник: развиваем блог на CyberTrain дальше"
og_description: "Turbo, фоновая задача, JSON, вход, загрузка файлов и сборка для развёртывания — в блоге из Getting Started CyberTrain."
og_image: tutorial.png
crumb: "Продвинутый учебник"
nav: tutorial
toc_title: "Шаги 13–19"
meta:
  - term: "Что нужно"
    text: 'Блог из [учебника](tutorial.md#test), до шага 12'
  - term: "Начало"
    text: "`blog/` со статьями, комментариями и тестами"
  - term: "Результат"
    text: "`dist/blog`"
---

# Продвинутый учебник: развиваем блог&nbsp;дальше

[Учебник](tutorial.md) заканчивается блогом со статьями и комментариями.
Эта страница развивает то же приложение: комментарии отрисовываются
компонентом, новые рассылаются на все открытые страницы через Turbo, фоновая
задача ставится в очередь, приложение отвечает в JSON, появляются вход и
загруженная картинка, а в конце приложение собирается в готовый к
развёртыванию каталог `dist/`. Приложение, в которое всё это вырастает, —
[`examples/blog`](../../examples/blog); оно проверяется в CI на Linux и macOS.

<!-- step 13 #component stage: Вы пишете · `app/components/`, `app/helpers/` -->
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
`CommentsHelper`. Каждая пишет ещё и тест, к которому мы вернёмся в конце
этого шага. Класс уже такой, какой нужен блогу:

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

### Тест компонента

Сгенерированный тест рендерит `CommentComponent` со String там, где шаблон
теперь ожидает комментарий. Отрендерите вместо этого комментарий из фикстуры:

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
`assert_select` читает то, что он отрендерил
([Тестирование потоков и компонентов](testing.md#testing-streams-and-components)).
Тест хелпера проходит в том виде, в каком его сгенерировали. Запускайте их,
как в [шаге 12](tutorial.md#test): `cybertrain test`.

<!-- step 14 #turbo stage: Запуск · Turbo Streams поверх Server-Sent Events -->
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

### Тест ответа Turbo Stream

Запрос, который просит Turbo Stream, как это делает отправка формы через
Turbo, получает его в ответ. Добавьте такой тест в тест комментариев из
[шага 12](tutorial.md#test):

```ruby test/controllers/comments_controller_test.rb (фрагмент)
  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end
```

<!-- step 15 #job stage: Вы пишете · `app/jobs/` -->
## Фоновая задача

> [!WHY]
> Работа, которая не должна задерживать ответ, например уведомление,
> выполняется отдельно от запроса: она может начаться до того, как ответ
> записан, или после. Как и в Active Job на Solid Queue, задача — это
> класс в `app/jobs/` и строка в собственной базе данных приложения: никаких
> других сервисов.

```shell терминал — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

Она пишет `app/jobs/notify_comment_job.rb` — со строкой `retry_on`, которую
запросила опция, и пустым `perform` — и тест, а в `bin/blog.rb` и `bin/db.rb`
добавляет `require "cybertrain/jobs"`, а в `config/deploy.yml` раскомментирует
роль `worker` ([шаг 19](#ship)). Заполните `perform`; здесь он
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

Отправьте комментарий — и в логе сервера будет видно, как выполняется задача,
здесь после ответа (поток задач может взять строку и до того, как ответ
записан, так что порядок строк может быть другим); её строки помечены задачей и идентификатором запроса,
который её поставил в очередь:

```text вывод — cybertrain server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started POST "/articles/1/comments" for 127.0.0.1
2026-11-14T09:30:00.122Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 2ms
2026-11-14T09:30:00.950Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] new comment 1 on article 1
2026-11-14T09:30:00.951Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 1 (NotifyCommentJob) done
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
  `./blog jobs` или на странице задач по адресу `/admin/jobs`:
  закомментированная строка `jobs_page` в `config/routes.rb` называет
  `require_admin`, метод, который пишет генератор [шага 17](#authentication),
  и страницу подключает тот же генератор
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

### Тест: комментарий ставит задачу в очередь

Тест задачи, записанный генератором, проходит как есть. Добавьте в тест
комментариев тест, который проверяет, что `create` ставит задачу в очередь,
и выполняет её:

```ruby test/controllers/comments_controller_test.rb (фрагмент)
  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end
```

Тест не запускает потоков задач, поэтому задача в очереди ждёт, пока её не
выполнит тест (`perform_enqueued_jobs`); остальные проверки для задач — в
[Тестирование задач](testing.md#testing-jobs).

<!-- step 16 #json stage: Вы пишете · `app/controllers/` -->
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

Генератор пишет миграции и модели `users` и `sessions`, concern `Authentication`, который он включает в `ApplicationController`, контроллеры и представления для входа, регистрации, сброса пароля и страницы учётной записи, почтовик, команду `./blog user` и тесты. Ещё он добавляет маршруты (среди них страница заданий по адресу `/admin/jobs`, для администраторов), partial `sessions/_nav` в начало макета и настройку `base_url` в `config/app.rb`, с которой начинаются ссылки в письмах. Наконец, он добавляет в `bin/blog.rb` и `bin/db.rb` строки подсистем, которые использует его код: `cybertrain/jobs` (страница заданий и поток, отправляющий письма), `cybertrain/mailer`, `cybertrain/mailer/later` (письма уходят через `deliver_later`) и `cybertrain/rate_limit` (попытки входа ограничены по частоте, см. ниже). Все файлы перечислены в разделе [Аутентификация](authentication.md#generating-it).

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

> [!RULE] has_secure_password расписан явно
> ### `has_secure_password` расписан явно
>
> Макроса `has_secure_password` в CyberTrain нет. То, что он определил бы,
> генератор записывает в модель `User` как код, которым владеет приложение:
> `password=`, `authenticate` и
> `User.authenticate_by(email_address:, password:)`. Пароли
> хеширует `Cybertrain::Password` — PBKDF2-HMAC-SHA256 на Ruby, по умолчанию 100
> 000 итераций (около 0,2 с в скомпилированном виде): для bcrypt бинарнику
> пришлось бы линковать C-библиотеку. Стоимость повышается строкой
> `Cybertrain::Password.iterations = 600_000` в `config/app.rb`;
> `User#authenticate` заново хеширует пароль каждого пользователя при его входе.

### Обновление тестов

Тесты из [шага 12](tutorial.md#test), которые открывают форму, отправляют её или
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

> [!RULE] has_one_attached расписан явно
> ### `has_one_attached` расписан явно
>
> Нет ни `has_one_attached`, ни общей таблицы вложений: допустимые типы,
> размеры и то, кому можно скачивать, в каждом приложении свои, поэтому
> генератор расписывает методы с именем по полю в `Article`,
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
минимума в 10 символов из [шага 05](tutorial.md#validations).

> [!NOTE]
> Запускайте `cybertrain test`, как в [шаге 12](tutorial.md#test) (по измерению
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
  опросчик потоков из шагов 14 и 15: один процесс — это всё развёртывание.
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
- Слежение за файлами, CRuby-превью и цикл пересборки никогда не работают в
  production. Запущенный `cybertrain server` ничего не перегенерирует и не
  перезапускает, пока `cybertrain build` удерживает
  `tmp/cybertrain-build.lock`.

`cybertrain new` также создаёт конфигурацию для
[Kamal 2](https://kamal-deploy.org). `Dockerfile` выполняет `cybertrain setup`
и `cybertrain build` на этапе сборки в Ubuntu и копирует `dist/` в облегчённый
этап того же выпуска; при запуске образ применяет миграции, а затем слушает
`0.0.0.0:3000`. Рядом лежат `.dockerignore`, `config/deploy.yml` (kamal-proxy
с Let&rsquo;s Encrypt перед приложением, проверка работоспособности по
`public/up.html`, файл SQLite на томе в `/app/storage` и роль `worker`, которую раскомментировал
шаг 15: второй контейнер того же образа, выполняющий `./blog worker`; роль web
тоже выполняет задачи, если `CYBERTRAIN_WORKER` не равен 0) и `.kamal/secrets`,
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
- [**Деплой**](site:deploy.html) — Как собранное приложение работает в продакшене: Kamal или systemd за Caddy.
- [**Аутентификация**](authentication.md) — Сброс пароля, подтверждение, блокировка, «оставаться в системе», страница учётной записи и администраторы.
- [**Интернационализация**](i18n.md) — Словари, `t` и `l` и локаль для каждого запроса.
- [**Руководства**](index.md) — По странице на тему: модели, запросы, шаблоны, реальное время, фоновая работа, тестирование.
- [**CyberTrain на GitHub**](https://github.com/saeki-mototsune/CyberTrain) — Исходный код, README и релизы.
- [**Справочник API**](site:api/index.html) — Все классы и методы, которые использует приложение, с примерами.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Спайки и обнаруженные ими ограничения компилятора.
- [**Spinel**](https://github.com/matz/spinel) — AOT-компилятор Ruby от matz.
- [**Главная CyberTrain**](site:index.html) — Обзор, возможности и как это работает.
