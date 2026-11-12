---
source_sha256: fe2c05ecaf069531464f4c4acba55c5839ea809973a39f81eec7caf7f761d280
---
# Запросы

Что контроллер получает из запроса и что фреймворк проверяет, прежде чем он запустится: маршруты и их форматы, `respond_to`, concerns и `helper_method`, строгие параметры, отдача файлов и HTTP-кэширование, cookies и зашифрованная сессия, ограничение частоты запросов и адрес клиента за прокси, Content Security Policy, `force_ssl` и проверка хостов, параметризованные заголовки, а также то, как разбираются и ограничиваются строки запроса и тела запросов.

## Маршрутизация

`config/routes.rb` использует DSL маршрутизации Rails; `spin run gen` выполняет его и пишет `gen/routes.rb` (таблицу маршрутов, диспетчер и хелперы `*_path` / `*_url`). На верхнем уровне вызову не нужен получатель; вложенный блок называет получатель, который ему передан, потому что Spinel выполняет без получателя только верхний уровень `Routes.draw`:

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
end
```

`namespace :admin` добавляет к путям префикс `/admin`, а к хелперам — `admin_` (`admin_articles_path`, `admin_article_path(article)`); его контроллеры — `Admin::ArticlesController` в `app/controllers/admin/articles_controller.rb`, их представления — в `app/views/admin/articles/`. Пространства имён вкладываются друг в друга. Контроллер в пространстве имён можно записать вложением (`module Admin` / `class ArticlesController < ApplicationController`) или в краткой форме (`class Admin::ArticlesController`, когда `module Admin` уже есть); сканер читает обе. `jobs_page` внутри пространства имён получает его префикс.

`scope` меняет одну часть за раз, и три части сочетаются, как в Rails:

```ruby
scope "/dashboard" do |s|          # только префикс пути
  s.get "/stats", to: "stats#show"
end
scope module: "billing" do |s|     # только модуль контроллера: Billing::InvoicesController
  s.resources :invoices
end
scope "/v1", as: "v1" do |v|       # путь и префикс хелперов: v1_about_path
  v.get "/about", to: "pages#about"
end
```

`namespace` и `scope` используются вне блоков `resources` (внутри них gen их отклоняет).

### Одиночные ресурсы, `controller:` и `param:`

`resource` (в единственном числе) принимает блок и `controller:`, как `resources`. Блок добавляет маршруты элемента и вложенные ресурсы с путями и именами, как в Rails:

```ruby
resource :profile, controller: "pages", only: [:show] do |r|
  r.get :refresh, on: :member       # GET /profile/refresh, refresh_profile_path
end
resources :indicators, param: :key  # /indicators/:key, params[:key]
```

`on: :member` и `on: :collection` размещают собственный маршрут так же, как блоки `member` и `collection`; у одиночного ресурса нет коллекции. `param: :key` задаёт имя сегмента элемента (`params[:key]`), а вложенные ресурсы под ним используют `:indicator_key`; `indicator_path(ind)` по-прежнему читает `ind.to_param`, который модель переопределяет, чтобы вернуть ключ. Сегменты `:id` и `:x_id` собственного маршрута сохраняют прежние имена аргументов хелпера (`get "/users/:id"` даёт `user_path(user)`).

### Редиректы и строки запроса

`get "/old", to: redirect("/new")` отвечает 301 (`redirect("/new", status: 302)` для другого кода); `%{name}` в цели — значение сегмента, экранированное: `get "/old-posts/:id", to: redirect("/posts/%{id}")`. У маршрута-редиректа нет хелпера, если не указан `as:`. Блочная форма `redirect` не поддерживается; цель вычисляет действие контроллера.

Именованные аргументы хелпера пути уходят в строку запроса, в заданном порядке и экранированными: `article_path(a, page: 2)` — это `/articles/3?page=2`, значение nil опускает свой ключ, массив даёт `key[]=v` для каждого элемента, а значение-Hash вызывает `ArgumentError`. `format: :json` добавляет расширение (`/articles/3.json`), а `anchor: "c4"` — фрагмент (`#c4`, в конце). Именованные аргументы никогда не заполняют сегмент пути: сегменты — позиционные аргументы (`post_path(3)`, а не `post_path(id: 3)`). `url_for("/x", format: :csv)` добавляет те же опции к String.

## Форматы и `respond_to`

Каждый маршрут допускает необязательное расширение в последнем сегменте: `/articles/3.json` даёт `params[:id] == "3"` и `request.format == :json`. В маршруте, который принимает формат, динамический сегмент никогда не захватывает `.` (умолчание Rails), поэтому `/articles/3.json.bak` — это 404. Маршрут, сегмент которого содержит точку по своей причине, указывает `format: false` (у `get` и других глаголов, `resources`, `resource` и `root`):

```ruby
get "/files/:name", to: "files#show", format: false   # у /files/report.v2 name равно "report.v2"
```

`request.format` — это Symbol: по расширению, из зарегистрированных в Rails типов (`:html`, `:json`, `:csv`, `:xml`, `:pdf`, `:turbo_stream`, ...; `jpg` — это `:jpeg`, `htm` — `:html`, `txt` — `:text`), и `:unknown` для любого другого расширения. Без расширения он берётся из `Accept`: `:turbo_stream`, если там есть `text/vnd.turbo-stream.html`, `:json`, если есть `application/json` и перед ним нет `text/html`, иначе `:html` (тип с `q=0` не учитывается).

```ruby
def show
  @article = Article.find(params[:id])
  respond_to do |format|
    format.html
    format.json { render json: @article.as_json }
    format.turbo_stream
  end
end
```

У сборщика (`Cybertrain::FormatCollector`) есть `html`, `json`, `turbo_stream`, `csv`, `xml`, `text` и `any`. Первое подходящее объявление сразу выполняет свой блок, так что блок видит переменные экземпляра действия; объявление без блока рендерит шаблон действия для этого формата (`show.html.erb` в лейауте, `show.turbo_stream.erb` без него). Если ничего не подошло, ответ — `406 Not Acceptable`. `any` подходит к любому формату, кроме `:unknown`. Turbo отправляет форму, запрашивая `text/vnd.turbo-stream.html, text/html`: формат такого запроса — `:turbo_stream`, и действие без `format.turbo_stream` отвечает через свой `format.html`, как в Rails (расширение `.turbo_stream` запрашивает только этот формат). Тот же откат действует для любого `Accept`, где рядом с не-html форматом перечислены `text/html` или `*/*`: клиент, отправивший `application/json, text/plain, */*` действию, у которого есть только html-шаблон, получит html, а не 406. Откат выполняет блок второй раз, для html, поэтому оператор в блоке, кроме строк `format.`, выполняется дважды: оставляйте в блоке только строки `format.`. Запись с `q=0` отказывается от своего типа: на `application/json, text/html;q=0` html не отдаётся, есть рядом `*/*` или нет.

Ответ, формат которого определён по `Accept` (без расширения, заголовок `Accept` отправлен), несёт `Vary: Accept`, объединённый с `Vary`, который поставило действие, так что браузер или кэш никогда не отдадут html одного URL запросу его JSON или Turbo Stream; у пути с расширением его нет.

Без `respond_to` действие рендерит `<action>.<format>.erb`, если он есть (`create.turbo_stream.erb`, без лейаута, с типом содержимого формата), и отвечает 406, если его нет; html — как раньше. У JSON нет шаблонов: действие отвечает JSON через `render json:`. Внутри блока `render :edit` рендерит шаблон формата, с которым совпал этот блок (`edit.turbo_stream.erb` в `format.turbo_stream`).

Контроллер собирает ответы Turbo Stream через `turbo_stream` (построитель turbo-rails: `replace`, `update`, `append`, `prepend`, `before`, `after` — каждый с целью и одним из `partial:` с `locals:` или `html:`, — и `remove`):

```ruby
render turbo_stream: [turbo_stream.remove(@comment), turbo_stream.update("count", html: @count.to_s)]
```

## Concerns и `helper_method`

Concern контроллера — это модуль в `app/controllers/concerns/`, как в Rails:

```ruby app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 20
  end
end
```

Контроллер, в котором написано `include AdminGate`, получает то, что объявляет блок `included` (`before_action`, `skip_before_action`, `after_action`, `helper_method`, `rate_limit`, `rescue_from`, `layout`), на месте `include` и в порядке записи, а в его действиях работает `self.class.per_page`. Concerns могут включать concerns: gen разворачивает их в глубину, каждый один раз, и отклоняет цикл, называя его (`concern cycle: A includes B includes A`). `include A, B` включает B первым, как Ruby, поэтому блок `included` и колбэки B идут раньше, чем у A. `around_action` отклоняется (around-колбэков нет). Присваивания `@x =` в методах concern — переменные представления контроллера.

Spinel компилирует никогда не выполняемые блоки `included` и `class_methods`, поэтому gen разворачивает их сам: он записывает каждый concern в `gen/concerns/<путь под app/>`, опустошив эти два блока (файлы приложения загружают эти копии), а `gen/concerns.rb` заново открывает каждый включающий класс со вставленными объявлениями и переадресацией для каждого метода `class_methods`. Отсюда два правила. Метод `class_methods` не может называться так же, как метод экземпляра concern, включающего класса или его предков (Spinel определил бы оба как методы экземпляра, spikes/NOTES.md, правило 93); gen его отклоняет, называя оба места (`файл:строка` метода экземпляра). А `include` модуля, который не является concern (`include Comparable`, имя без файла под `app/*/concerns`), остаётся Ruby как есть, поэтому опечатка в имени concern — это `NameError` при загрузке приложения, а не сообщение gen. gen ищет имя так же, как Ruby, сначала в модулях самого класса, поэтому `include Gate` внутри `module Admin` подключает `Admin::Gate`. Имя, которое не приводит ни к одному concern, но оканчивается именем concern (`include Gate`, когда есть только `Admin::Gate`), останавливает gen: Ruby подключил бы другой модуль или выбросил бы исключение, и блок `included` этого concern потерялся бы.

Concerns моделей лежат в `app/models/concerns/` и работают так же: их блок `included` может содержать любые объявления уровня класса модели (`validates`, `validate`, `scope`, `belongs_to`, `has_many`, `has_one`, `encrypts`, колбэки, `normalizes`), которые считаются написанными в модели на месте `include`. Колбэки concern выполняются после собственных колбэков модели того же вида, а `include` внутри блока `included` concern модели подключает этот concern. Имя метода `class_methods` в concern модели не может совпадать со scope модели или с методом класса, который есть у каждой модели (`recent` рядом со `scope :recent`, `where`); gen его отклоняет.

`helper_method :current_user, :admin?` в контроллере или в блоке `included` concern делает эти методы контроллера вызываемыми из шаблонов этого контроллера, а также из компонентов и partial-шаблонов, которые они рендерят, с аргументами. gen отклоняет имя, которое является хелпером фреймворка, оканчивается на `_path` или `_url`, определено модулем в `app/helpers`, не имеет `def` в контроллере, его родителях или его concerns, или параметры которого шаблон передать не может (`*rest`, `**opts`, `...`).

## Параметры: `params.expect` и вложенный `permit`

```ruby
def article_params
  params.expect(article: [:title, :body, tags: [], meta: [:source]])
end
# => {"title" => "Hi", "body" => "...", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
```

`permit` принимает те же формы: ключ разрешает String, `key: []` — список String, а `key: [...]` — вложенный уровень. Фильтр, который не является Array (`permit(meta: :source)`, `expect(article: :title)`) или содержит Array (`[[:title]]`), вызывает `ArgumentError`: это ошибка в коде, а не плохой запрос, поэтому не 400. Значение неподходящего вида, неперечисленный ключ и загруженный файл отбрасываются. `expect` возвращает уровень под своим единственным ключом и вызывает `Params::ParameterMissing` (ответ 400), если этого ключа нет, он неподходящего вида или ничего не разрешает. `params.expect(:id)` читает одну String и отвечает `{"id" => "3"}`; `params.expect(tags: [])` так же отвечает непустым списком. Оба возвращают `Hash{String => Object}`: значения — String, массивы String или вложенные Hash, поэтому сужайте значение через `Cybertrain::Cast.str` (или `.to_s`), прежде чем вызывать на нём методы String.

## Отдача файлов, HTTP-кэширование и коды статуса

`send_data(bytes, filename: "report.csv", type: "text/csv", disposition: "attachment")` отвечает байтами и заголовком `Content-Disposition`, в котором имя файла записано и в кавычках, и в виде `filename*` из RFC 5987, поэтому диакритика и кавычки сохраняются; `disposition: "inline"` показывает файл в браузере. Байты отправляются с указанным `type`, так что это для данных, созданных приложением; файл, загруженный пользователем, отдаётся через `send_blob`, который никогда не даёт браузеру его выполнить.

```ruby
def show
  @post = Post.find(params[:id])
  fresh_when etag: @post, last_modified: @post.updated_at
end

def feed
  @posts = Post.order(created_at: :desc).limit(20).to_a
  return unless stale?(etag: @posts.first)
  expires_in 300, public: true
end
```

`fresh_when` ставит слабый `ETag` (из String или из таблицы, `to_param` и `updated_at` записи) и `Last-Modified` и отвечает `304 Not Modified`, когда `If-None-Match` запроса (а без него `If-Modified-Since`) показывает, что у клиента актуальная версия; `stale?` делает то же и возвращает, должно ли действие рендерить. 304 получают только GET и HEAD. `Cache-Control` равен `max-age=0, private, must-revalidate` (`public` при `public: true`), если только `expires_in seconds` не поставил раньше `max-age=<seconds>`. Автоматического ETag у других ответов нет. `If-None-Match: *` подходит к любому валидатору, который поставило действие: к `ETag` или только к `Last-Modified`.

ETag составляется из заданного вами ключа, формата запроса и отпечатка сборки (отпечатки ассетов и import map, а в бинарнике `cybertrain build` ещё и представления), поэтому html и JSON одного URL никогда не делят один ETag, а развёртывание, меняющее ассеты или представления, заставляет всех клиентов перепроверить. Два следствия. В разработке без `--embed-views` шаблоны читаются с диска и в отпечаток не входят: правка представления всё ещё может получить `304`, пока не изменится запись или страница не будет перезагружена без кэшированной копии. И ключ называет то, что показывает страница, а не того, кто её видит: содержимое, различающееся по пользователям, должно включать пользователя в ключ (`etag: "posts/#{@post.id}-#{@post.updated_at.to_i}-#{current_user.id}"`), иначе оно будет показано не тому человеку. Не делайте `public` страницу, несущую CSP-nonce (`content_security_policy` с nonce, `javascript_importmap_tags`): общий кэш отдаёт каждому посетителю одну и ту же страницу, а значит, и один nonce, который тогда ничего не защищает.

`status:` и `head` принимают все символы Rack (`:unauthorized`, `:payment_required`, `:unprocessable_content`, `:too_many_requests`, ..., со старыми `:unprocessable_entity` и `:payload_too_large` как синонимами), а фразы статусов — из RFC 9110 (413 "Content Too Large", 422 "Unprocessable Content").

## Cookies и сессия

```ruby
cookies[:theme] = "dark"
cookies[:theme] = { value: "dark", expires: Time.now + 86_400, same_site: "Strict" }
cookies.permanent[:locale] = "ja"
cookies.signed[:user_id] = "5"     # клиент может прочитать, но не изменить
cookies.encrypted[:card] = "4242"  # ни прочитать, ни изменить
cookies.signed[:user_id]           # => "5" или nil, если его изменили
cookies.delete(:theme)
```

Запись принимает String или Hash с `value:`, `expires:` (Time), `max_age:`, `path:`, `httponly:`, `secure:` и `same_site:`. Cookies записываются с `Path=/`, `HttpOnly` и `SameSite=Lax`, а также `Secure`, когда он есть у cookie сессии (в production или с `force_ssl`), если запись не указывает иного. `permanent` пишет `Max-Age` на 20 лет. Подписанное значение — это HMAC-SHA256 под ключом, выведенным из `secret_key_base`; зашифрованное — AES-256-GCM под другим ключом; каждое привязано к имени своей cookie, поэтому под другим именем оно не проверяется и не расшифровывается, а изменённое значение читается как nil. Значение, прочитанное после записи в том же запросе, — записанное.

Cookie сессии шифруется и аутентифицируется AES-256-GCM, как cookie store в Rails, под собственным ключом, выведенным из `secret_key_base`: клиент не может ни прочитать, ни изменить её. Cookie, которая не расшифровывается (изменённая, чужая или старая подписанная), загружается как пустая сессия, как и cookie больше 4096 байт; сессия, cookie которой превысила бы 4096 байт, или cookie из jar, у которой `name=value` их превышает, при записи вызывает `Session::CookieOverflow`. Значения остаются String. Смена `secret_key_base`, как и раньше, разлогинивает всех.

## Ограничение частоты запросов и адрес клиента

`rate_limit` в контроллере ограничивает, как часто один клиент может вызывать
некоторые действия; подсчёт ведётся до выполнения действия:

```ruby
class SessionsController < ApplicationController
  # когда лимит исчерпан — 303 обратно к форме, с flash[:alert]
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
  rate_limit to: 5, within: 60, only: [:create], by: :account_key, with: :slow_down, name: "account"
end
```

Каждое объявление засчитывает не более `to` запросов за окно в `within` секунд для каждого клиента и контроллера, а затем отвечает 429 с заголовком `Retry-After` (сколько секунд осталось в окне) или делает редирект, если задан `redirect_to:`. Остальные опции называют методы контроллера: `by:` — ключ (по умолчанию `:client_ip`, `:remote_addr` для собеседника соединения или метод вроде `account_key`, чей nil или `""` вызывает исключение, а не считает всех клиентов вместе), `with:` — что ответить вместо этого (если он ничего не рендерит, следует 429), `if:` / `unless:` — когда лимит действует (пропущенный запрос не засчитывается). Контроллер с двумя лимитами даёт каждому свой `name:` (gen отклоняет второй лимит с тем же именем в одном контроллере, включая лимиты родителей, и имя с `:`). `within:` задаётся в секундах, `only:`/`except:` принимают массивы.

Счётчики живут в `Cybertrain::Cache`, в базе данных приложения, поэтому все процессы, обслуживающие приложение, считают вместе, а счётчики переживают перезапуск; окна фиксированные и выровнены по часам (`now / within`). `store: :memory` сохраняет прежний счётчик на процесс: каждый процесс считает сам по себе, в таблице не более чем на 10 000 ключей (когда она заполнена, место освобождают истёкшие окна, а затем самые старые), которая теряется при перезапуске, с окном, которое открывается с первым запросом ключа, и с блокировкой, которую берёт каждый запрос к ограниченному действию (называйте действия через `only:`). В тесте `Cybertrain::RateLimit.reset_all!` забывает все счётчики (таблицы в памяти и строки лимитов в кэше); `Cybertrain::Cache.clock = -> { n }` фиксирует часы хранилища в кэше, а `Cybertrain::RateLimit.current_time = n` — часы хранилища в памяти (`-1` их восстанавливает).

### Адрес клиента за прокси

Засчитываемый адрес — `request.client_ip` (`by: :remote_addr` вместо этого
считает собеседника соединения). Это `request.remote_addr`, если только не
включён `config.trusted_proxy` (`CYBERTRAIN_TRUSTED_PROXY=1`) **и** соединение
приходит с loopback, то есть от обратного прокси на том же хосте (nginx,
Caddy, kamal-proxy); тогда это последний адрес в `X-Forwarded-For` — тот,
который добавил прокси. Более ранние записи — это то, что прислал клиент, и они
никогда не используются, а пустая последняя запись, запись длиннее 45 байт или
не из печатных символов ASCII даёт `remote_addr`. Без этой настройки все
посетители за таким прокси делят его адрес, и десять неверных паролей
блокируют всех; с ней клиент, подключающийся напрямую откуда-то ещё, всё равно
не может выбрать собственный адрес. `request.loopback?` сообщает, приходит ли
соединение с этой машины (127.0.0.0/8, `::1`, `::ffff:127.x.x.x`), — для
страниц, к которым должен иметь доступ только оператор на сервере; за прокси
на том же хосте каждый запрос — loopback, поэтому там проверяйте также
`client_ip`. Проектное решение: [docs/design.md](../design.md) D26.

Прокси, который обращается к приложению по сети, а не через loopback,
указывается по адресу: `config.trusted_proxies` из `CYBERTRAIN_TRUSTED_PROXIES`
принимает разделённые запятыми адреса IPv4 или IPv6 либо CIDR
(`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8` или один
`172.18.0.2`). Соединение изнутри одного из них обрабатывается так же, как
соединение с loopback выше: последний адрес `X-Forwarded-For`, проверенный тем
же способом. Запись IPv4 также совпадает с IPv4-mapped формой своих адресов
(`::ffff:172.18.0.2`), а `%zone` собеседника игнорируется. Запись, которая не
является адресом или CIDR либо имеет префикс больше `/32` (IPv4) или `/128`
(IPv6), останавливает сервер при запуске. `CYBERTRAIN_TRUSTED_PROXY=1` —
сокращение для `127.0.0.0/8,::1`, и обе настройки складываются.

Это случай Kamal: kamal-proxy работает в собственном контейнере Docker и подключается со своего адреса в сети Docker, поэтому `config/deploy.yml`, который пишет
`cybertrain new`, задаёт `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` (диапазон
Docker по умолчанию; измените его, если ваши сети используют другой,
`docker network inspect kamal`). Оставьте `proxy.forward_headers` Kamal
незаданным: с `ssl: true` kamal-proxy сам задаёт `X-Forwarded-For`, а не
передаёт заголовок клиента. Указывайте только сети, из которых не могут
подключаться клиенты: любой внутри указанной сети может выбрать адрес, который
засчитывает ограничение частоты.

## Content Security Policy, `force_ssl` и хосты

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

Политика выключена, пока `config/app.rb` её не объявит, как в Rails. После этого каждый ответ несёт `Content-Security-Policy` (`Content-Security-Policy-Report-Only` при `c.content_security_policy_report_only = true`) со свежим nonce на каждый запрос в директивах с nonce; у 304 политики нет, поэтому закэшированная страница сохраняет nonce, с которым были написаны её скрипты. `csp_meta_tag`, `javascript_tag(nonce: true)`, `javascript_importmap_tags` и `stylesheet_link_tag(nonce: true)` пишут этот nonce ([Язык шаблонов](template-language.md#helpers-and-the-form-builder)). Символы — это ключевые слова и схемы (`:self` — это `'self'`, `:data` — `data:`); источник-String с пробелом, `;`, `,` или управляющим символом отклоняется при объявлении. Контроллер настраивает копию для своих действий, и её наследуют подклассы:

```ruby
class EmbedController < ApplicationController
  content_security_policy do |p|
    p.frame_ancestors "https://partner.example"
  end
end
```

Каждый ответ также несёт `Permissions-Policy: camera=(), microphone=(), geolocation=()`, если не задаёт свой; `c.permissions_policy` заменяет значение, `""` не отправляет ничего.

`CYBERTRAIN_FORCE_SSL=1` (`config.force_ssl`) перенаправляет http на https, 301 для GET и HEAD и 307 для остального, и добавляет `Strict-Transport-Security: max-age=63072000; includeSubDomains` к ответам по https. За прокси, завершающим TLS, запрос считается https, когда в нём есть `X-Forwarded-Proto: https`; этот заголовок читается независимо от `trusted_proxy` (клиент, который его подделает, пропустит лишь собственный редирект). `request.base_url` верит ему только от доверенного прокси, поэтому задайте также `CYBERTRAIN_TRUSTED_PROXY` или `CYBERTRAIN_TRUSTED_PROXIES`, иначе URL, которые строит приложение, останутся http. Редирект берёт хост из корректного `Host` (некорректный даёт 400), а http-запрос GET или HEAD к пути проверки здоровья никогда не перенаправляется. С `force_ssl` сессия и cookie jar пишут cookies с `Secure`.

Проверка хостов расширяет защиту разработки: `CYBERTRAIN_HOSTS` (имена хостов через запятую, без схемы, порта и подстановочных знаков) добавляется к `allowed_hosts` после имён loopback во всех окружениях. Разработка проверяет как раньше; production и test проверяют, только если задан `CYBERTRAIN_HOSTS`. Отклонённый `Host` получает 403 `Blocked host` и записывается в лог; GET или HEAD пути проверки здоровья проходит при любом Host, поэтому балансировщик, опрашивающий по адресу, по-прежнему достигает проверки здоровья.

## Параметризованные заголовки

API-клиенты часто отправляют заголовки вида `Scheme k1=v1, k2="v2"`
(`Authorization: Digest ...`, вендорский `X-Example-Auth`) или списки
`k1=v1;k2=v2, k3` (`Forwarded`, `Prefer`). `request.header_params(name)`
разбирает такой заголовок в `Hash`, отображающий имена в нижнем регистре на
значения, чтобы API-контроллер не разбивал его вручную:

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

И `,`, и `;` разделяют параметры, и побеждает первое вхождение имени; значение
в кавычках освобождается от них (`\"` и `\\` раскрываются), у значения без
кавычек обрезаются окружающие пробелы, а имя без `=` отображается на `""`.
Начальное слово схемы (`Digest`, `Bearer`) параметром не является:
его возвращает `request.header_scheme(name)` (`""`, если схемы нет). Заголовок,
который отсутствует или длиннее 8 КиБ, даёт `{}`. Значения — это байты в том
виде, в каком они отправлены, никогда не percent-декодированные и, возможно,
не являющиеся допустимым UTF-8. Учётные данные `Bearer <token>` или
`Basic <base64>` параметром не являются: проверьте схему, а затем прочитайте
учётные данные из `request.header("authorization")`. Проектное решение:
[docs/design.md](../design.md) D31.

## Строки запроса и тела

`Query.parse`, `Query.value_of`, `Query.decode` и `request.form_value` /
`query_value` возбуждают `Cybertrain::QueryMalformed` (`StandardError` в
`Cybertrain::QueryInvalid`, а не `ArgumentError`), на что отвечается 400, при:

- некорректной percent-последовательности, в обеих средах выполнения;
- недопустимой последовательности байтов UTF-8 — сырой (каким бы ни был тег String) или percent-кодированной (Rails тоже отвечает 400 на недопустимую кодировку параметра);
- сыром байте, который дополнила бы только escape-последовательность (`a=\xC3%A9`).

`Cookies.parse` вместо этого сохраняет такое значение сырым. Путь с недопустимой
последовательностью (сырой или percent-декодированной в сегменте) — тоже 400
(`request.path_segments`); некорректная escape-последовательность в пути остаётся
буквальной — 404 из-за несовпадения. Параметры запроса вкладываются не более чем
на 32 уровня и 4096 пар, сверх этого — 400. Примечание к обновлению: код
приложения, который перехватывал `ArgumentError` вокруг этих вызовов, должен
вместо этого перехватывать `Cybertrain::QueryInvalid`.

Запрос не хранит собственного дерева параметров (Router строит `params`,
middleware читает один ключ); приложение, которому нужно всё дерево, разбирает
его само, `Query.parse(request.utf8_query_string)`, и владеет результатом.

Rack оставляет тело запроса в gzip как есть. Здесь тело, отправленное с
`Content-Encoding: gzip` (SDK или API-клиент, когда тело больше нескольких
килобайт), — это `request.decoded_body`, распакованное один раз через системную
zlib с ограничением размера результата: по умолчанию 10 МиБ, а эндпоинт,
ожидающий больше, передаёт своё, `request.decoded_body(limit)`. Повреждённое
тело или кодировка, отличная от gzip/identity, — это
`Cybertrain::BodyUndecodable`, тело, которое распаковалось бы сверх лимита, —
`Cybertrain::BodyTooLarge`; оба — `QueryInvalid`, на которые отвечается 400.
`request.body` остаётся байтами в том виде, в каком они отправлены.

## Обновление приложения с 0.4

Что меняется для приложения, написанного для 0.4 (полный список — раздел 14 [проекта](../superpowers/specs/2026-11-10-phase4-web-layer-design.md)):

- Каждая сессия один раз завершается: зашифрованная cookie не читает старую подписанную, поэтому пользователи входят заново. Код, который вызывает `Session.load` или `Session.dump`, передаёт выведенный ключ, `Crypto.derive_key(secret, SessionStore::SESSION_KEY_LABEL)`; сырой секрет вызывает `Encryptor::Error`.
- Каждое приложение линкуется с OpenSSL ([Установка](install.md#requirements)); Dockerfile, ранее записанному `cybertrain new`, нужен `libssl-dev` на этапе сборки и `libssl3t64` на этапе выполнения.
- Динамический сегмент больше не захватывает `.` в маршруте, который принимает формат: id с точками требует `format: false` у своего маршрута.
- Написанная вручную лямбда `url_resolver` принимает три аргумента, `->(name, args, options)`; приложению, которое передаёт `Gen::Routes.url_resolver`, нужен только `spin run gen`.
- `params.permit` возвращает `Hash{String => Object}`: вызывайте `Cast.str` или `.to_s` на значении, прежде чем использовать его как String.
- `rate_limit` считает в кэше: `store: :memory` сохраняет прежний счётчик на процесс, двум лимитам в одном контроллере нужны свои `name:`, метод `by:`, отвечающий nil или `""`, вызывает исключение, а за методом `with:`, который ничего не рендерит, следует 429.
- Числовые хелперы вызывают исключение для значения, которое не является числом (nil в шаблоне даёт `""`, как и раньше), и для точности вне диапазона от 0 до 100.
- `include A, B` в контроллере или модели включает B первым, как Ruby; `include` модуля, который не является concern, остаётся Ruby.
- Все ETag меняются один раз (теперь в них входят формат запроса и отпечаток сборки), ответ, выбранный по `Accept`, отправляет `Vary: Accept`, а html-откат действует для любого `Accept`, где перечислены `text/html` или `*/*`. У запроса, который может получить html-откат (`application/json, text/html`), свой ETag, отличный от ETag запроса только этого формата; `text/html;q=0` в `Accept` не получает html-отката (406, если у действия есть только html), в том числе рядом с `*/*`; а `If-None-Match: *` получает 304 и от ответа, проверяемого только по `last_modified:`.
- `permit` и `expect` вызывают `ArgumentError` для фильтра, который не является Array; `layout`, называющий отсутствующий лейаут, вызывает `MissingTemplate` (лейаут `application` по умолчанию остаётся необязательным); cookie из jar больше 4096 байт вызывает `Session::CookieOverflow`.
- `public/style.css` продолжает работать; перенос в `app/assets/stylesheets/` необязателен ([Ассеты](assets.md#moving-publicstylecss)).
- Сообщения валидации берутся из встроенного словаря ([Интернационализация](i18n.md#models-and-validation-messages)) с тем же английским текстом, кроме трёх случаев: сообщение на `:base` больше не начинается с "Base", атрибут, оканчивающийся на `_id`, называется без "id" ("Article can't be blank", а не "Article id can't be blank"), а предел длины 1 читается как "1 character". Тесты, сравнивающие эти сообщения, меняются.
- `time_tag` без `format:` или с именем формата форматирует через `I18n.l` (на английской странице — тот же английский текст, что и раньше).
- gen пишет `gen/locales.rb` (пустой без `config/locales/`) и загружает `app/mailers/**/*.rb`; `cybertrain new` пишет `config/locales/en.yml`, который старое приложение может добавить.
- `allow_unauthenticated_access` теперь метод фреймворка; тот, что генератор 0.4 записал в `ApplicationController`, продолжает работать и имеет приоритет. Повторный запуск `cybertrain generate authentication` добавляет сброс пароля, блокировку, «оставаться в системе», страницу учётной записи и администраторов и печатает diff-ы для файлов, записанных 0.4 ([Обновление с 0.4](authentication.md#upgrading-from-04)).
