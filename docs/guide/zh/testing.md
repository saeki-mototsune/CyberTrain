---
source_sha256: 8708d189e270a6ea82cabcd3fcc2f574bb7b99b714678d9820d9a6b7bc315312
---
# 测试应用

应用的测试是 `test/` 下的 Rails 风格的类，`cybertrain test` 把它们全部作为一个编译后的程序运行。Minitest 和 RSpec 通过反射查找测试方法，提前（AOT）编译器做不到这一点，所以 `spin run gen` 把每个测试类改写成普通方法，并写出一张覆盖所有测试的分派表。

## 编写测试

`cybertrain new` 会写出 `test/test_helper.rb`；和 Rails 一样，每个测试文件开头都加载它：

```ruby test/test_helper.rb
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # 所有测试共用的辅助方法写在这里。
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

基类有三个，都是 Rails 自己的：`ActiveSupport::TestCase`（模型、作业、邮件程序，以及一切不涉及请求的东西）、`ActionDispatch::IntegrationTest`（请求，见[集成测试](#integration-tests)）和 `ViewComponent::TestCase`（`render_inline`，见[测试流和组件](#testing-streams-and-components)）。应用可以在 `test/test_helper.rb` 或 `test/support/` 中放一个自己的基类并继承它。辅助方法、常量和 `private` 像在 Rails 中一样写在类体里；每个测试都在一个新实例上运行，所以在 `setup` 中设置的实例变量属于这个测试。`fixtures :all` 和 `require "test_helper"` 会被接受，但本身不做任何事：每个测试都会加载所有夹具。

每个测试按以下顺序运行：

1. 清空所有表，包括框架的表（作业、缓存、Turbo 消息、计划、订阅、租约），id 从 1 重新开始；
2. 插入夹具（[夹具](#fixtures)）；
3. 重置 `Mailer.deliveries`、限流计数器和 `I18n.locale`，时区回到 `config/app.rb` 配置的时区；
4. `setup`（先运行父类的；多个 `setup do` 块按顺序运行）；
5. 测试主体，前面没有任何失败时才运行；
6. `teardown`，总会运行：在断言失败、异常或 setup 失败之后也会运行（多个 `teardown do` 块按相反顺序运行，然后是父类的）；
7. 时钟回到真实时间，测试启动的每个接收器都会被停止。

Rails 则是在一个事务中运行每个测试并回滚。这在这里行不通：在这个框架中 SQLite 没有保存点，所以测试自己的 `transaction` 会结束外层的事务；而作业线程使用别的连接，看不到测试写入的行。

## 运行测试

```sh
cybertrain test                                         # 所有测试
cybertrain test test/controllers                        # 某个目录下的文件
cybertrain test test/models/article_test.rb             # 一个文件
cybertrain test -n "creates an article"                 # 按名称选一个测试
cybertrain test -n test_creates_an_article              # 或按方法名
cybertrain test -n /article/                            # 名称包含 "article" 的测试
```

`cybertrain test` 运行 `SPIN_DEBUG=1 spin run gen`（和 CLI 的所有命令一样，gen 以 spin 的调试模式构建），它写出 `gen/tests.rb`（程序）以及 `gen/test/` 下每个测试类改写后的副本，两者都和 `gen/` 的其余部分一起提交；然后只要有输入比 `build/test/tests` 新，就把 `gen/tests.rb` 编译成它（发布构建），再运行它。所有 `test/**/*_test.rb`，以及除 `test/test_helper.rb` 之外的所有其他 `test/*.rb` 都在其中；`test/support/`（由辅助文件加载）和 `test/fixtures/` 中没有测试。程序在第一个测试之前删除 `storage/test.sqlite3`，迁移出一个新的数据库并在其上启动应用（不启动作业、调度器或订阅线程：作业由测试自己运行）。`CYBERTRAIN_TEST_DATABASE` 可以改为指定另一个文件。由于程序会删除它测试所用的文件，它会给自己创建的每个数据库加上标记（`PRAGMA application_id`，一个专用的值），只有当已有文件带着这个标记、就是本应用自己的 `storage/test.sqlite3`（无论路径怎么写）或是空文件时，才会删除或清空它。其他文件都会以退出状态 2 被拒绝，什么都不删除：`cybertrain test refuses to delete <path>: not a database cybertrain test created; delete it yourself or name another file`。名为 `development.sqlite3` 或 `production.sqlite3` 的文件（不区分大小写），或与 `storage/development.sqlite3`、`storage/production.sqlite3` 是同一个文件的，会以 `cybertrain test refuses to delete <path>: it is the development database`（或 `production`）被拒绝。名称必须是文件路径：`:memory:` 和 `file:` URI 会被拒绝（`cybertrain test refuses CYBERTRAIN_TEST_DATABASE ":memory:": name the test database by its file path (not :memory: or a file: URI)`）。升级之后，你以前在 `CYBERTRAIN_TEST_DATABASE` 中指定的文件没有标记，会被拒绝一次：删除它（连同 `-wal` 和 `-shm`），`cybertrain test` 就会创建一个带标记的；默认的 `storage/test.sqlite3` 什么都不需要做。在创建数据库期间变成符号链接的路径会以退出状态 2 被拒绝：`cybertrain test refuses <path>: it became a symlink while the test database was created (nothing was marked or migrated); remove it and run again`。每个测试之前的清空只涉及主数据库的表，从不涉及同名的 TEMP 表或附加数据库的表。已知限制：标记在 `cp` 测试数据库之后仍然存在，所以以测试数据库命名的副本（或测试连接的副本）会被清空；在创建文件和加标记之间被终止的运行会在你指定的路径上留下没有标记的文件，下次会被拒绝（请删除它）；`storage/test.sqlite3` 是目录时，程序删除它会抛出异常。

除非 `config/app.rb` 自己设置了同样的东西，程序会像 Rails 那样准备测试环境：关闭防伪造保护，请求日志不输出（级别 `:none`，仍会写出错误行），日志行为文本（不读取导出的 `CYBERTRAIN_LOG_FORMAT`），不向 Sentry 发送错误报告（导出的 `CYBERTRAIN_SENTRY_DSN` 会被清空），邮件保存在 `Mailer.deliveries` 中（`:test`），关闭 `force_ssl`（测试时不读取变量 `CYBERTRAIN_MAIL_DELIVERY_METHOD` 和 `CYBERTRAIN_FORCE_SSL`，即使它们的值无效），上传的文件写入 `tmp/test_uploads/`，每次运行时清空，并且不做主机检查（导出的 `CYBERTRAIN_HOSTS` 不会打开它）。`*_url` 辅助方法的主机 `www.example.com` 始终是允许的主机。

```text 输出 — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:14)
         Expected change of 1, got 0 (from 2 to 2)
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

每个文件一个标题，每个测试一行，最后是合计，不显示耗时。给出的行号是测试的 `test "..."` 所在的行：编译后的程序没有回溯，所以不知道失败的断言在哪一行。有测试失败时退出状态为 1，否则为 0，参数不被接受时为 2。被测代码自己输出的内容（比如某个命令的输出行）会出现在测试行之间。测试、setup、teardown 或钩子抛出 `NotImplementedError`、其他 `ScriptError` 或 `SystemStackError` 时，和其他异常一样记为 `ERR`，运行继续；只有 `Interrupt`、`SystemExit` 和 `NoMemoryError` 会结束运行。在 Spinel 下，真正的栈溢出仍会以段错误结束进程：只有代码自己抛出的 `SystemStackError` 才会到达运行器。

参数：`-n NAME` 保留名称或方法名为 NAME 的测试，`-n /TEXT/` 保留名称或方法名中以纯文本形式包含 TEXT 的测试（`.`、`?` 和 `()` 就是它们自己）。包含 `^ $ \ * + [ ] { } |` 之一的 TEXT 不是正则表达式，会以退出状态 2 被拒绝：`-n /^test_create/: the text between the slashes is a plain substring of the test name, not a regexp (^ would be looked for as itself); write the text to look for (-n /test_create/)`。文件或目录保留其中的测试；`FILE:LINE` 会被拒绝（`line filters are not supported; give the file, and -n for the name`）；`--` 结束选项。一个测试都没保留的筛选会在合计之前输出 `no test matched the filter`，并以 0 退出。在 `test/` 下添加或删除文件会重新编译程序。

**一次修改的代价。** 文件参数和 `-n` 选择运行哪些测试，而不是编译什么：程序总是包含所有测试，所以改变筛选会复用二进制文件；而修改任何一个测试（或构建程序所用的任何其他东西）都会先重新构建 `bin/gen`，再重新编译整个程序。以下是 2026-11-12 和 2026-11-13 在一台共享的 4 vCPU 云机器上测得的数字（你自己的机器会不同）：examples/blog 的 21 个文件、149 个测试第一次编译用了约 527 秒（第一次运行总共 656 秒，二进制文件 10.2 MB），之后不做改动运行 `cybertrain test test/controllers`，复用了二进制文件，约 1 秒就开始（博客自己的运行，2026-11-13）；博客的应用加上三个测试文件（八个测试）编译用了 162 到 233 秒，内存峰值约 2.2 GB，生成 8.1 MB 的二进制文件（2026-11-12）。先写好几个测试再一起运行；专注于某一个测试时，缩小的是运行范围，而不是构建。

当两个测试文件或支持文件定义了同一个顶层方法或常量时（在一个程序中它们会变成一个：把共享的辅助方法移到 `test/support/`，或移进类里），`gen/tests.rb` 会被拒绝，`cybertrain test` 不编译，给出原因并以 1 退出；[gen 在测试类中拒绝的写法](#what-gen-refuses-in-a-test-class)中的其他情况也一样。

## 夹具

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

`test/fixtures/<table>.yml` 是 Rails 的格式：标签，下面是列。gen 运行时用[词典](i18n.md#dictionaries)所用的 YAML 子集读取这些文件，并带着 `文件:行` 拒绝以下内容：不是 `db/schema.rb` 中某张表的文件；既不是列也不是模型的 `belongs_to` 的键；ERB（任何地方出现 `<%`：没有 `eval`；相对于现在的时间请在 `setup` 中或用 `travel_to` 设置）；不符合列类型的值（不存在的日期、超出 64 位的整数、布尔值写成 `yes`）；两个标签使用同一个 id；以及一个指不到父表文件中任何行的 `belongs_to` 标签。和 Rails 一样，`DEFAULTS` 不是一行。

- 没有 `id:` 的行会得到 Rails 为其标签计算的 id（`ActiveRecord::FixtureSet.identify`），所以一个标签的 id 和在 Rails 应用中相同。`author: alice` 会把 `author_id` 设为 alice 的 id。
- 日期时间是 UTC。行中省略的 `created_at` 和 `updated_at` 取每个测试之前插入该行时时钟的时间。
- `articles(:one)` 返回该行的 `Article.find`；未知的标签会抛出 `Cybertrain::Test::FixtureNotFound`。每次调用一个标签。
- 夹具在 gen 运行时检查，但它的错误只会让测试运行停止：`spin run gen`（因此还有 `cybertrain db migrate`，脚手架的夹具会先于它出现）会继续，而 `cybertrain test` 输出 `test/fixtures/<table>.yml:<行>: ...` 并以 1 退出。
- 和 Rails 一样，指向某个父行的夹具会让这个父行无法删除：一旦 `comments.yml` 中有 `article: one`，脚手架的 “should destroy article” 就会因外键而失败。请声明 `has_many :comments, dependent: :destroy`，或让子夹具指向另一行（`article: two`），或删除一个没有被引用的行。
- 不提供：`fixtures :articles`（每个文件都会加载）、`articles(:one, :two)`、多态标签（`commentable: one (Article)`；请写出 `_id` 和 `_type` 列）、`has_and_belongs_to_many` 的标签，以及锚点和别名。

## 集成测试

`ActionDispatch::IntegrationTest` 在进程内向已启动的应用发送请求，不使用套接字，每个测试都有一个新的 cookie 存储：

- `get`、`post`、`patch`、`put`、`delete`、`head`（路径、`params: {}`、`headers: {}`），写法与 Rails 相同。每个都返回 `Cybertrain::Response`（Rails 返回状态码），它也是 `response`（`response.body`、`response.status`、`response.header(name)`）。
- `params:` 接受嵌套的 Hash，按表单的方式发送（`article[title]=New`）；值可以是 String、Symbol、数字、`true` / `false`、nil、Date 或 Time（以列读回时的文本发送），所以脚手架测试可以原样发送记录的值。Array 会被拒绝。
- 在 `post`、`patch` 或 `put` 的 `params:` 中放入 `fixture_file_upload("cover.png", "image/png")` 会以 multipart 发送请求；文件从 `test/fixtures/files/` 读取。
- `headers:` 接受头的名称，或 Rails 的 `HTTP_ACCEPT` 形式。
- `config/routes.rb` 的路径辅助方法和在控制器中一样可用。`*_url` 辅助方法写出 `http://www.example.com/...`；这个主机上的 URL 按其路径请求，`assert_redirected_to` 可以比较任一种形式。其他主机上的 URL 会被拒绝。
- `cookies` 是测试的 cookie 存储，一个 `Cybertrain::Test::ClientCookies`：`cookies[:user]` 或 `cookies["user"]`（原始的、仍是百分号编码的值）、`[]=`、`key?`、`delete`、`keys`、`size`、`empty?` 和 `to_h`。`Max-Age` 或 `Expires` 在时钟上已过的 cookie 会消失，`travel_to` 越过它之后也是如此（`Max-Age` 优先于 `Expires`）；测试用 `[]=` 写入的 cookie 永不过期。无法读取的 `Max-Age`（`Max-Age=abc`）会被忽略，负数会让 cookie 过期。与 Rails 的不同，它没有 `each`、`length`、`include?`、`fetch` 或 `==`：移植过来的测试请改为读取 `cookies.to_h`。
- `follow_redirect!` 请求上一个响应的 `Location`（不带 `#fragment`）；如果上一个响应不是重定向，它会让测试失败：`follow_redirect!: the last response was 200, not a redirect (3xx with a Location)`。
- `assert_response(:success)`（或任何状态符号，或一个数字；`:error` 恰好表示 500，而 Rails 接受任何 5xx）、`assert_redirected_to(path)`、`assert_select`、`assert_turbo_stream`。
- 没有：`session`、`flash`、`assigns`、`request`、`host!` 和 `as:`。请改为检查页面（`assert_select`、`response.body`）。

**防伪造保护**在测试中是关闭的，除非 `config/app.rb` 设置了 `csrf`，这和 Rails 的测试环境一样，所以 `post` 不需要令牌。测试这项检查本身的测试可以为部分请求打开它：

```ruby
test "a form without the token is refused" do
  with_forgery_protection do
    post articles_path, params: { article: { title: "x" } }
    assert_response :forbidden
  end
end
```

在块中，表单需要测试请求过的某个页面中的 `authenticity_token`；块结束时一切都会恢复，即使块中的断言失败也是如此，而测试自己设置的东西（上传根目录、时区、语言区域、日志级别）会保留。

**登录。** `cybertrain generate authentication` 会写出 `test/support/session_test_helper.rb`，它被包含进每个集成测试：`sign_in_as users(:one)`（夹具用户的密码是 `"password"`；`remember: true` 会勾选“保持登录”）、`sign_out`、`authenticity_token_in(response.body)`（页面中第一个表单的令牌，用于 `with_forgery_protection` 中的请求），以及 `open_session`，即有自己 Cookie 的第二个浏览器（`phone = open_session`，然后 `phone.sign_in_as users(:two)` 和 `phone.get ...`）。每个请求都来自 `127.0.0.1`；需要另一个客户端地址的测试自己创建 `client = Cybertrain::Test::Client.new(Cybertrain::Test.app)` 并设置 `client.peer_address = "203.0.113.7"`（客户端自己的方法是 `client.get(path, headers)` 和 `client.post(path, fields, headers)`）。

## 断言

`assert`、`assert_not`（`refute`）、`assert_equal`、`assert_not_equal`、`assert_nil`、`assert_not_nil`、`assert_includes`、`assert_not_includes`、`assert_empty`、`assert_not_empty`、`assert_match` / `assert_no_match`（Regexp，或作为子串的 String）、`assert_in_delta(expected, actual, delta = 0.001)`、`assert_nothing_raised { }` 和 `flunk`，与 Minitest 相同。`assert_equal` 以 Minitest 的文本失败（两行的 `Expected: 1` 和 `  Actual: 0`），新增的断言也是如此；`assert_includes`、`assert_nil` 和 `flunk` 保留各自较短的文本。`assert` 和 `refute` 的第二个参数是消息。块形式接受一个按位置传入的 lambda：

```ruby
assert_difference -> { Article.count }, 1 do
  post articles_path, params: { article: { title: "New", body: "A body long enough" } }
end
assert_no_difference(-> { Article.count }) { post articles_path, params: { article: { title: "" } } }
assert_changes(-> { article.reload.title }, from: "Old", to: "New") { article.update(title: "New") }

message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
assert_includes message, "999"
```

- `assert_raises` 接受一个类（和 Minitest 一样，子类也匹配）、作为 String 的类名的一部分（`assert_raises("RecordNotFound")`），或什么都不传（任何 StandardError），并返回异常的**消息**，而不是异常：在 Rails 写 `error = assert_raises(X) { }` 再用 `error.message` 的地方，请直接使用它返回的 String。在 Spinel 下一个方法只返回一种类型，而测试读取的正是消息。
- 块断言返回 nil，而不是块的值。
- 不提供：`assert_predicate`（它需要计算出的 `send`：请写 `assert article.valid?`）、`assert_difference` 中的 String 表达式（需要 `eval`）、表达式的 Array 或 Hash，以及其他断言的消息参数。Minitest 的 `refute_*` 名字中只有 `refute`：请写 `assert_not_equal`、`assert_not_nil` 等 `assert_not_*` 形式；调用 `refute_equal` 会让测试程序的构建停止，因为没有任何地方定义它。

## 时间旅行

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

`travel_to(time)`、`travel(seconds)`、`freeze_time` 和 `travel_back` 是 Rails 的辅助方法：每一个都会冻结时钟并丢弃秒以下的部分；带块时，块结束时（即使抛出异常）会恢复之前的时间，不带块时，旅行一直持续到 `travel_back` 或测试结束。框架记录时间的一切都会跟随：`Time.current`、测试程序中的 `Time.now`、记录的时间戳、缓存的过期、限流、会话的寿命、作业的 `run_at`、令牌的过期、调度器。等待和超时（读取流、接收器）仍使用真实时间，所以冻结的时钟永远不会让它们卡住。在生产环境中 `Time.now` 是系统时钟：应当跟随时间旅行的代码请读取 `Time.current`，这也是 Rails 的建议。`Time.now` 像内置方法一样返回进程 `TZ` 中的本地时间，而 `Time.current` 是 UTC。`travel_to` 接受 Time，不接受 Date，也没有 `Time.zone.local`：请用 `Time.utc(...)` 写出这个瞬间。调度器在时间旅行前后保留它记住的东西（上一次恢复、下一次运行的时间）；在调度器或工作线程运行时进行时间旅行的测试不受支持。

时长是 Integer 秒数：`5.minutes` 是 `300`，`2.weeks.ago` 和 `3.days.from_now` 返回时钟上的 Time。没有 `1.month`（一个月没有以秒计的固定长度）：它在运行时会产生 `NoMethodError`。请使用 Time 上的日历方法：`Time.current.months_ago(1)`、`advance(months: 1)`、`beginning_of_day`、`end_of_month`、`yesterday`（[时间与时区](models.md#times-and-the-time-zone)）。`advance` 在日历部分之后把时、分、秒作为经过的时间加上，并且只接受 Integer；真实时钟保留微秒。

## 测试流和组件

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

`render_inline(component, content: "")` 和 `render_inline(partial:, locals: {})` 在任何请求之外渲染，返回 HTML（Rails 返回一个 Nokogiri 片段，并以块接收内容），并保留它供 `assert_select` 使用。需要请求的辅助方法会抛出 `Cybertrain::Views::OutsideRequest`。

`assert_select(selector, equality = nil, count:, minimum:, maximum:, text:)` 检查本测试中最后一次 `render_inline` 或最后一个响应（两者都没有时失败：“No response yet”），并返回匹配的元素：

- 选择器：标签、`.class`、`#id`、`[attr]`、`[attr="v"]`、它们的组合（`a.btn[href="/x"]`）、后代和子代（`>`）组合符，以及列表（`h1, h2`）。伪类、`+` 和 `~`、其他属性运算符、反斜杠（`assert_select: CSS escapes (\) are not supported`）以及嵌套块形式会以 `assert_select: <feature> is not supported` 失败。
- `text:` 是与每个元素的文本比较的 String，或对该文本进行匹配的 Regexp。文本中连续的空白会合并为一个空格，两端会被去掉（Rails 只去掉两端）。第二个参数可以是 Rails 的位置参数形式：文本（String 或 Regexp）、数量（Integer）或 `true` / `false`；数量也可以是 `2..3` 这样的 Range；在这里给出数量的同时又给出 `count:`、`minimum:` 或 `maximum:` 会被拒绝，负的、反向的或缺少两端的 Range 也会被拒绝（`assert_select: a Range count needs both ends (got 2..)`）。
- HTML 按书写的样子读取，不会像浏览器（以及 Rails 的 `assert_select` 背后的 Nokogiri）那样修复：`table > tr` 能匹配不写 `<tbody>` 的表格，`p > div` 能匹配 `<p><div>`，而省略的结束标签（`<li>a<li>b`、`<p>a<p>b`）或自闭合的 `<div/>` 会让断言失败并给出位置。框架自身的模板都能读取。

广播是 `cybertrain_messages` 中的一行，所以流的断言直接读取这张表，不需要轮询器或套接字：

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

`assert_broadcasts(stream, count) { }` 统计块运行期间（不带块时从测试开始起）向某个流（名称或记录）广播的内容，并返回这些负载；`assert_no_broadcasts(stream)` 要求没有任何广播。`assert_turbo_stream(action:, target:, count: 1)` 读取最后一个响应（必须是 `text/vnd.turbo-stream.html`）或最后一次 `render_inline`。要像浏览器那样读取实时流，`Cybertrain::Test::Client` 的 `client.get_stream(path, events: n)` 会在内存中运行一个流式响应（[实时](realtime.md)）。

## 测试邮件

在 `cybertrain test` 中，除非 `config/app.rb` 设置了它，`Cybertrain.config.mail_delivery_method` 是 `:test`：`deliver_now`、`Mailer.deliver` 和 `deliver_later` 的作业会检查消息，并把它保存在 `Cybertrain::Mailer.deliveries` 中而不是建立连接，这个列表在每个测试之前清空。当应用没有设置发件人时，测试程序会使用发件人 `from@example.com`。

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

`assert_emails(count) { }` 统计块发送的邮件；块中用 `deliver_later` 排队的邮件会先被发送，失败的邮件作业会让断言带着它的错误失败。`assert_no_emails { }` 要求一封都没有。消息的读取方法是 `mail_to`、`mail_from`、`mail_subject`、`mail_body` 和 `mail_html`。测试 SMTP 路径本身的测试会设置 `Cybertrain.config.mail_delivery_method = :smtp`，并在 `teardown` 中改回 `:test`（这个设置在测试之间不会重置），见[测试出站调用](#testing-outbound-calls)。在测试环境之外，`:test` 会带着警告启动，并且不发送任何邮件。

## 测试作业

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

- `assert_enqueued_jobs(count, kind = "")` 统计队列中的作业（指定种类时只统计该种类）；`assert_no_enqueued_jobs(kind = "")` 要求一个都没有。
- `assert_enqueued_with(kind, args)` 要求队列中有一个该种类的作业，其参数以相等的值包含每个给定的键（`"comment_id" => 7` 匹配 JSON 中的 `7`；`comment_id: 7` 也可以）。
- `perform_enqueued_jobs { }` 是 Rails 的内联形式：运行块，然后运行块中排队的每个作业以及它们再排队的作业，不管其 `run_at`，并返回运行了多少个。抛出异常的作业会让测试带着它的类和错误失败，并且不会重试；应用丢弃的作业（`discard_on`）算作已运行。
- 不带块的 `perform_enqueued_jobs(now = Time.current)` 逐个运行在 `now` 到期的作业，直到没有到期的为止。安排在以后的重试会留在队列中：用 `travel` 越过它，或传入更晚的 `now`。两种形式都会在 10,000 个作业之后让测试失败（一个不断把自己重新排队的作业）。
- `clear_enqueued_jobs` 删除队列中的作业；`WelcomeJob.perform_now(args)` 直接运行一个作业，异常会传到测试。
- 计划任务用 `Cybertrain::Scheduler.run_due(Time.current.to_i)` （纪元秒数） 一次运行一轮。

## 测试出站调用

当被测代码发送 Webhook（[出站 HTTP](external-services.md#outbound-http)）或通过 SMTP 发送邮件（[发送邮件](external-services.md#sending-e-mail)）时，测试在进程内接收它：`Cybertrain::Test::HttpReceiver` 和 `Cybertrain::Test::SmtpReceiver` 在 `127.0.0.1` 上监听，记录收到的内容并用预设的回复应答。在测试中启动的接收器会在该测试之后被停止，即使测试失败也是如此。

```ruby test/integration/signup_hook_test.rb
require "test_helper"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

class SignupHookTest < ActiveSupport::TestCase
  setup do
    Cybertrain.config.http_allow_private = true   # 否则 HttpClient 会拒绝回环地址
  end

  teardown do
    Cybertrain.config.http_allow_private = false
    Cybertrain.config.mail_delivery_method = :test
  end

  test "a sign-up posts a webhook" do
    hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    hook.start                                   # 绑定一个空闲端口并返回它
    SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # 应用的代码
    req = hook.received_request                  # 最多等待 5 秒；什么都没来则为 nil
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

`HttpReceiver.new` 接受预设的 `status:`、`headers:`、`body:` 和 `chunked:`（`respond_with` 可在请求之间修改它们）；请求以 `ReceivedRequest` 返回（`http_method`、`http_target`、`http_path`、名称为小写的 `http_headers`、`http_header(name)`、已解码 chunked 正文的 `http_body`）。`SmtpReceiver` 扮演 220、EHLO（除非 `eight_bit_mime: false` 否则带 8BITMIME，`auth: true` 时带 AUTH PLAIN）、MAIL、RCPT、DATA 和 QUIT；`reject:` 可以让 `:greeting`、`:ehlo`、`:mail`、`:rcpt`、`:data` 或 `:message` 中的任意一个以给定的回复失败。`ReceivedMessage` 有 `envelope_from`、`envelope_recipients`、`message_data`（已撤销点填充）、`message_header(name)`、`message_body` 和命令的 `transcript`；对 HTML 消息，`message_parts` 会把它解码为 `"subject"`、`"text"` 和 `"html"`。两者都只接受一个连接，除非 `max:` 指定更多（`received_requests` / `received_messages` 返回全部）。每次等待都有上限：接收器在 `accept_window:`（10 秒）内没有连接就放弃，沉默的客户端在 `read_timeout:`（5 秒）后被断开，`stop`（调用两次也安全）结束它的线程并关闭端口，所以接收器永远不会抢走后面测试的连接。在测试之外（文件顶部）启动的接收器不会被自动停止。

订阅也用同样的方式测试，使用 `Cybertrain::Test::WebSocketReceiver`，它是 `127.0.0.1` 上按脚本运行的 WebSocket 服务器：每个连接执行一组 `Cybertrain::Test::WsStep`（`"accept"`、`"send_text"`、`"expect"`、`"silent"`、`"close"`、`"drop"`、`"echo_until_close"` 等），客户端发送的帧去掉掩码后从 `ws_received` 返回。

```ruby test/integration/trades_feed_test.rb
require "test_helper"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # 常量：块看不到局部变量

# 块写在方法中，它们的参数在那里被使用。
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
    Cybertrain::WebSocket.start!               # 测试程序从不启动订阅
    # ... 最多轮询 TICKS 几秒 ...
    Cybertrain::WebSocket.stop!
    assert_equal ["tick"], TICKS
    assert_equal "subscribe", rx.ws_received[0].rec_data
  end
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` 让重试间隔变得精确。本仓库的 `test/websocket_integration.rb` 展示了一个完整的测试。

## 测试日志与错误报告

响应的 `X-Request-Id` 就是请求的 ID。要读取日志行，测试在它观察的工作期间把一个 `StringIO` 交给 `Cybertrain.logger`，之后再把日志器放回去，这在一个专门的方法中完成（在 Spinel 下，围绕 `yield` 的 `rescue` 或 `ensure` 要放在普通方法中）：

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

行首的时间每次运行都不同（要比较它，就用 `freeze_time` 冻结），所以比较它之后的部分：级别、标签和消息。应用的请求日志在测试中不输出（`log_level :none`），但失败作业的 `ERROR` 行即使这样也会写出；执行失败作业的测试要像上面那样捕获日志器，否则这一行会出现在测试的行之间。

错误报告送到 `Cybertrain::Test::SentryReceiver`，这是 `cybertrain/test_help` 加载的、位于 `127.0.0.1` 上的 Sentry。`cybertrain test` 忽略导出的 DSN，所以测试自己赋一个 DSN，并在之后恢复：

```ruby test/integration/error_reporting_test.rb
require "test_helper"

class ErrorReportingTest < ActionDispatch::IntegrationTest
  setup do
    @sentry = Cybertrain::Test::SentryReceiver.new
    @sentry.start
    @saved_dsn = Cybertrain.config.sentry_dsn
    Cybertrain.config.sentry_dsn = @sentry.dsn                # http://public@127.0.0.1:<port>/1
    Cybertrain.config.http_allow_private = true               # 否则 HttpClient 拒绝环回地址
  end

  teardown do
    Cybertrain.config.sentry_dsn = @saved_dsn
    Cybertrain.config.http_allow_private = false
  end

  test "a failing job is reported" do
    NotifyCommentJob.perform_later("comment_id" => 999_999, "article_id" => articles(:one).id)
    perform_enqueued_jobs                                       # 失败的尝试不会让测试失败
    event = @sentry.received_events(1)[0]                      # 最多等待 5 秒
    assert_equal "NotifyCommentJob", event.sentry_field("transaction")
    assert_equal "Cybertrain::RecordNotFound", event.sentry_field("exception.values.0.type")
  end
end
```

`SentryReceiver.new(status: 200, max: 50, accept_window: 10.0)` 像 Sentry 那样应答每个信封（另一个 `status:`，比如 429，扮演拒绝的 Sentry）；`dsn(project = "1", prefix = "")` 是发往它的 DSN，`received_events(count, wait = 5.0)` 返回已到达的内容。每一个都是 `Cybertrain::Test::SentryEnvelope`：`sentry_path`、`sentry_auth`（`X-Sentry-Auth`）、`sentry_content_type`、`sentry_body`（三行 JSON）、读取事件字段的 `sentry_field("a.b.0.c")`（不存在时为 `""`），以及读取信封头的 `sentry_header_field(name)`。`extra` 中含有点的键（`job.attempt`）无法用按点拆分的 `sentry_field` 读取：请从 `sentry_body` 中读取。在测试中启动的接收器会在测试之后停止，和其他接收器一样。

在测试中添加的订阅者会在下一个测试之前被移除（`config/app.rb` 添加的会保留），每个测试之前，报告器会投递仍在队列中的内容并忘记去重的时间窗口，所以两个测试中的同一个失败都会被报告。对于读取订阅者收到内容的测试，`Cybertrain.error.drain_reports` 会等待（最多 2 秒）队列中的报告：

```ruby
Cybertrain.error.subscribe(SeenReports.new)   # 测试自己的 Cybertrain::ErrorSubscriber
get "/articles/999999"
Cybertrain.error.drain_reports
assert_equal 0, REPORTS_SEEN.size             # 404 不会被报告
```

## gen 在测试类中拒绝的写法

gen 把测试类改写成方法：`test "shows it" do` 变成 `def test_shows_it`（`[A-Za-z0-9_]` 之外的 ASCII 字符变成 `_`，其他字符变成 `_u<hex>_`（小写的码点，以 `_` 结尾），所以 `"ログ"` 是 `test__u30ed__u30b0_`，`"café x"` 是 `test_caf_ue9__x`；`-n` 接受方法名，也接受写出的名称），`setup do` 和 `teardown do` 块变成调用 `super` 的 `setup` 和 `teardown` 方法。凡是改写不能原样搬过去的内容，都会让这个文件被拒绝，绝不会悄悄生成错误的副本或丢掉测试：

- 不是纯字符串字面量的测试名（插值），或带有 gen 不读取的转义的测试名（`\u`、`\x`、`\c`、`\C`、`\M` 或八进制：请直接写出字符本身；`\n`、`\t` 和 `\"` 会被读取）；
- 同一个类中方法名重合的两个测试，包括 `def test_x`；
- 同一个类中同时有 `setup do` 和 `def setup`（`teardown` 同理），以及父类是应用基类的类中不调用 `super` 的 `def setup` 或 `def teardown`（基类的 `setup do` 块就不会运行）；
- 带参数的 `def test_x`，或写在 `private` 或 `protected` 之后的 `def test_x`（Minitest 只运行公开的测试方法）；
- `setup { }` 和 `setup :name`（请写 `setup do ... end`），以及 `test`、`setup` 或 `teardown` 上的块参数；
- 测试、setup 或 teardown 主体中的 `next`、`break` 或 `redo`，包括在主体的 `if`、`unless`、`case` 或 `begin` 之中（请用 `return`），以及 `return <value>`（每个都返回 nil）；
- 嵌套在另一个类或模块中的测试类、打开了两次的测试类，以及重新打开的 `ActiveSupport::TestCase` 中的 `setup do`（请写一个带 `setup do` 的应用基类并继承它）；
- gen 无法放进类体的 `test`、`setup` 或 `teardown` 行（在条件、循环、字符串或 heredoc 中）、不以 `end` 结尾的单行形式、后面还有代码的 `end`，以及混用制表符和空格的缩进；
- 参数不是字符串字面量的 `require_relative`。

被拒绝的文件不会让 `spin run gen` 停止，所以开发服务器、`cybertrain db migrate` 和 `cybertrain build` 照常工作：gen 写出一个只输出原因的 `gen/tests.rb`，`cybertrain test` 不编译，输出 `<path>:<line>: <reason>` 并以 1 退出。请修正它指出的那一行。`test "name" do` 也可以写成 `test"name"` 或中间用制表符。写在 `private` 之后的 `test "x" do` 不会被拒绝，但它在副本中会成为私有方法，运行时失败（Rails 会运行它）：请把测试写在 `private` 之上。其他已知限制：包含文本 `_u3042_` 的名称与把它换成 `"あ"` 的名称方法名相同（同一个类中 gen 会拒绝这一对）；模块中的 `def setup` 不检查 `super`；应用基类之下两层的类，即使那个基类没有定义 `setup`，也会被要求调用 `super`；测试文件被拒绝期间，`spin run gen -- --check` 不比较 `gen/test/` 中过时的副本（CI 会在 `cybertrain test` 处失败）。

`cybertrain test` 还会以同样的方式拒绝：`test/test_helper.rb` 或 `test/support/` 中的顶层 `test`、`setup` 或 `teardown`（它们永远不会运行）、顶层的 `def render_inline`（它会替换框架的那个）、`assert_select ... do` 和 `render_inline ... do`，以及[运行测试](#running-the-tests)中所说的重复的顶层辅助方法。类形式的文件只能通过 `cybertrain test` 运行：在 `spin test` 下，它的类体会抛出 “class-form tests run with `cybertrain test FILE`”。

## 顶层形式

以前的形式，即写在文件顶层的 `test` 块，仍然可用，既可以在 `cybertrain test` 中（像这里一样，使用程序的应用和夹具），也可以在 `cybertrain spin test` 下：

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

顶层的 `setup do` 和 `teardown do` 在其文件的每个测试前后运行。`cybertrain spin test` 把每个 `test/*.rb` 编译成单独的程序，并把输出与 `test/<name>.rb.expected` 比较；在那里既不清空表也没有夹具（它们需要 gen 的表清单），由 `Cybertrain::Test.run!` 运行该文件的测试。在 `cybertrain test` 中，文件的测试在清空和加载夹具之后与其他测试一起运行，`run!` 什么也不做。在 `spin test` 下没有东西会为这个文件启动应用，所以这样的文件要像 0.4 的支持文件（`AppTest.boot`、`BlogTest.boot`）那样自己启动，并且不使用夹具。`Cybertrain::Test::Client` 带着 cookie 存储驱动应用，包括 CSRF（`client.get`、`client.post(path, fields, headers)`、`client.follow_redirect!`、`client.response`，以及两个参数的 `assert_response res, :ok` 和 `assert_redirected_to res, path`）。涉及 SQLite 的测试的快照来自编译后的二进制文件：在框架的检出中用 `script/regen-snapshot test/<name>.rb`，或者 `rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`。

## 从 0.4 升级

- 按上面的样子添加 `test/test_helper.rb`，并把支持文件在加载时做的事（`AppTest.boot`、`BlogTest.boot`、迁移数据库）移出来：测试程序会在第一个测试之前在新数据库上启动，第二次启动只会浪费时间。
- 把 CI 步骤从 `spin test` 改为 `cybertrain test`。
- 定义了同一个顶层辅助方法或常量的两个文件（像 0.4 的生成器写的那样，各有一个 `new_client`）会一起被拒绝：把辅助方法移到 `test/support/`，或给其中一个改名。
- 每个测试之前所有表都会被清空，所以后面的测试不能再依赖前面的测试创建的行：把这样的数据移到夹具或 `setup` 中。
- 时钟的注入点已移除：`Cybertrain::Cache.clock=`、`Cache.system_clock`、`RateLimit.current_time=`、`SessionStore#fixed_now=`、`Application.status_now=` 和 `Background.supervisor_clock=`。请使用 `travel_to`、`travel` 或 `freeze_time`，它们的块形式不需要你自己写 `ensure` 就会恢复时间。
- 测试中的邮件保存在 `Cybertrain::Mailer.deliveries` 中；在 `Test::SmtpReceiver` 上读取邮件的测试要先设置 `Cybertrain.config.mail_delivery_method = :smtp`。
- 0.4 的 `generate helper` 写出的辅助方法测试定义了顶层的 `render_inline(source)`，它与框架的冲突：在那个文件中把它（包括调用处）改名为 `render_helper_template`。
- `1.month.ago` 写作 `Time.current.months_ago(1)`。
- `assert_equal` 以 Minitest 的两行文本失败；通过的测试快照不变。
- 再次运行 `cybertrain generate authentication` 会写出类形式的测试，并指出它们替代的每个旧文件（`test/authentication.rb`、`test/support/app_test.rb` 等）；`--force` 会删除它们。
- 以前查找整行日志（以方括号中的级别开头）的测试，改为分别查找级别和消息（`" ERROR "` 和 `"password reset mail not sent: "`）：现在一行以时间开头，可能带有请求的 ID（[日志](background-and-operations.md#logs)）。
- 导出的 `CYBERTRAIN_LOG_FORMAT` 或 `CYBERTRAIN_SENTRY_DSN` 不再影响测试；要用它们测试，请在 `config/app.rb` 中设置，或在测试中给 DSN 赋值。

## 持续集成

`cybertrain new` 会为应用写出 `.github/workflows/ci.yml`。它调用本仓库的 `setup-cybertrain` 动作（[.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)），并固定在 CLI 的发布标签上；该动作安装 SQLite、zlib 和 OpenSSL 的头文件以及 Ruby，从 `spin.lock` 中读取应用锁定的框架提交，取得该提交的框架并运行它的 `cybertrain doctor` 和 `cybertrain setup`（`~/.cybertrain/spinel` 按 Spinel 版本和 runner 镜像缓存）。然后工作流检查 `spin.lock` 是最新的（`spin lock && git diff --exit-code spin.lock`）、`gen/` 是新鲜的（`SPIN_DEBUG=1 spin run gen -- --check`），并运行 `cybertrain test`。工具链的步骤变化时，变化的是这个动作，而不是每个应用的副本。提交是从 `spin.lock` 读取的，所以工作流假定使用默认的 git 依赖；用 `--path` 创建的应用把框架的检出作为 `framework-path` 传给动作。
