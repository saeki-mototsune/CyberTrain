---
source_sha256: f91f3179b1b8012bb304301973b9de2d6e153abc889799c6d946d2c35f104605
---
# 认证

`cybertrain generate authentication` 像 Rails 8 的生成器那样，把电子邮件加密码的登录写成应用自己拥有的代码，并一起写出 Devise 所增加的内容：通过邮件重置密码、可选的地址确认、锁定、“保持登录”、账户页面和管理员用户。

## 生成

```shell 终端 — blog/
cybertrain generate authentication                  # 公开的注册页面
cybertrain generate authentication --invite-only    # 不开放注册：用户来自命令行或 /setup
cybertrain generate authentication --confirmable    # （两种模式都可以）新地址通过邮件确认
cybertrain db migrate
```

它在应用中写出：

| 文件 | 内容 |
| --- | --- |
| `db/migrate/*_create_users.rb`、`*_create_sessions.rb` | `users`（`email_address`、`password_digest`、`admin`、`failed_attempts`、`locked_until`；使用 `--confirmable` 时还有 `confirmed_at`、`unconfirmed_email`）和 `sessions`（每个已登录的浏览器一行，带 `remember` 和 `last_active_at`） |
| `app/models/user.rb`、`session.rb` | `password=`、`authenticate`、`User.authenticate_by`、令牌、锁定 |
| `app/controllers/concerns/authentication.rb` | `Authentication` 关注点，被包含进 `ApplicationController` |
| `sessions_controller.rb`、`registrations_controller.rb`（或 `setup_controller.rb`）、`passwords_controller.rb`、`accounts_controller.rb`、`confirmations_controller.rb` | 登录、注册（或第一个用户的页面）、密码重置、账户页面、确认 |
| `app/mailers/passwords_mailer.rb`、`confirmations_mailer.rb` | 邮件 |
| `app/commands/user_command.rb` | `./<app> user ...`，由 `bin/<app>.rb` require |
| `app/views/...` | 各个页面（每段文本都经过 `t()`）以及 `sessions/_nav` 局部模板 |
| `test/fixtures/users.yml`、`test/support/session_test_helper.rb`、`test/models/`、`test/controllers/`、`test/integration/` | 夹具用户、`sign_in_as`，以及每个部分的测试（[测试](#testing)） |

以及各进行一次的修改：在 `ApplicationController` 中加入 `include Authentication`、路由、作业页面那一行（[管理员用户](#admin-users-and-the-jobs-page)）、布局中的 nav 局部模板、`bin/<app>.rb` 中的用户命令、`config/app.rb` 中的 `base_url` 设置（[邮件中的链接](#links-in-mails)），以及在 `bin/<app>.rb` 和 `bin/db.rb` 中加入代码用到的子系统的行，除非 `require "cybertrain"` 已经加载了全部：`cybertrain/jobs`、`cybertrain/mailer`、`cybertrain/mailer/later` 和 `cybertrain/rate_limit`（[子系统](how-it-works.md#subsystems)）。用相同的选项再次运行不会改变任何东西：已经做过的修改会被找到并跳过，已经与它要写的内容相同的文件保持不变。它会写得不同的文件（你编辑过的，或者旧版生成器或其他选项写的）在没有 `--force` 时绝不会被覆盖，而是打印出它的差异（[从 0.4 升级](#upgrading-from-04)、[之后再开启确认](#turning-on-confirmation-later)）。

生成的页面上的文本在框架的英语和日语词典中，使用各自的惰性查找键（`sessions.new.title`、`passwords.create.sent`）；应用可以在 `config/locales/` 中覆盖它们或添加一种语言（[国际化](i18n.md#the-bundled-dictionaries)）。

## 登录与退出

```ruby app/controllers/concerns/authentication.rb（节选）
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session
    before_action :require_authentication
    helper_method :authenticated?
  end
```

从此每个动作都需要已登录的用户，访客会被送到 `/session/new`（303；如果是本站路径，GET 请求会被记住，登录后返回那里）。控制器像在 Rails 中一样向访客开放动作：

```ruby app/controllers/articles_controller.rb（节选）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
```

`allow_unauthenticated_access(only:, except:)` 是 `Cybertrain::Controller` 的方法，即 `skip_before_action :require_authentication`。开放的页面上 `resume_session` 仍会运行，所以模板可以读取 `@current_user`（和 `@current_session`），或调用 `authenticated?`。没有 `Current` 对象。

<!-- list: points -->
- `SessionsController`（`resource :session`）：`GET /session/new`、`POST /session`、`DELETE /session`。登录尝试按客户端地址限制为每三分钟十次，在缓存中计数，所以所有进程共同计数；在代理之后，请设置 [可信代理](requests.md#rate-limiting-and-the-client-address)。
- 错误的密码、未知的地址和已锁定的账户，在同样的密码校验之后（没有账户时针对一个虚拟摘要）得到同样的消息。
- 当密码此后被修改、超过有效期、或在 `auth_idle_timeout` 内没有请求时，`resume_session` 结束这次登录（并删除其 Session 行）（[保持登录](#remember-me-and-session-limits)）。
- 退出会删除 Session 行并清空 cookie 会话。

## 开放注册，或仅限邀请

默认情况下，生成器写出 `RegistrationsController`（`/sign_up`），它创建用户并让其登录。Rails 的生成器没有注册页面，把第一个用户留给控制台；CyberTrain 没有 Ruby 控制台，所以写出了这个页面。注册和登录一样，按客户端地址限制为每三分钟十次：每次注册都要计算一次密码哈希，可能发送一封带链接的邮件，而它的 "has already been taken" 会说出某个地址是否已注册。

生成的代码保存的每个地址，无论来自注册页面、`/setup`、账户页面还是用户命令，都必须是一个地址：`User.email_address_format?` 要求恰好一个两边都有文字的 `@`，并且没有逗号、空白、尖括号或控制字符。邮件发送器把 `ann@example.com,eve@evil.example` 读作两个收件人，所以没有这项检查，一个账户就可能拥有两个邮箱，重置链接会发给两者，而在 `--confirmable` 下任一邮箱都能完成确认。地址还必须通过邮件发送器自己的检查（`Cybertrain::Mailer.address_problem`）：只能是 ASCII（因此也不能有 Unicode 空白或控制字符），不含 `( ) [ ] ; : \ "` 中的任何一个，本地部分最多 64 字节，整体最多 254 字节。邮件发送器拒绝的地址即使保存下来也永远收不到邮件，所以在输入时就被拒绝。邮件标准允许的一些地址也会被拒绝（带空格或逗号的加引号本地部分、含非 ASCII 字符的地址）；这个方法由应用自行修改。检查出现之前保存的地址不会再次检查，所以该账户仍然可以重置密码和登录。

`--invite-only` 不写注册页面，这对内部工具才是正确的默认值，否则最先到达服务器的人就会得到账户。第一个用户来自用户命令，或来自 `SetupController`（`GET` 和 `POST /setup`），它创建用户并让其登录：

<!-- list: points -->
- 它只在还没有用户时、只在带有一次性令牌时、并且只对套接字对端是回环地址且不带 `X-Forwarded-For` 头的连接作出响应（同一主机上的代理会让每个请求都来自回环地址，并添加该头）。其他所有人都得到 404。
- 令牌是程序启动时生成的 32 个随机十六进制字符（`SetupController.setup_token`），以常数时间比较。在地址检查无效的场合，例如在不添加 `X-Forwarded-For` 的代理之后，它让页面保持关闭。请求日志中显示为 `[FILTERED]`。
- 在没有用户期间，服务器在启动前记录 `[WARN] no user exists yet: run ./<app> user EMAIL, or open /setup?token=<token> from this machine`；只有这一行会打印令牌。
- `<APP>_SETUP_OPEN=1`（`config/app.rb` 中的 `setup_open` 设置）为在另一台主机上的代理之后首次运行而取消地址检查，但从不取消令牌检查。用户创建后请取消它。

## 用户命令

两种模式都会写出 `./<app> user`：

```shell 终端 — 生产主机
./blog user ann@example.com                       # 创建，或设置密码；密码从标准输入读取
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user admin ann@example.com                 # 设为管理员
./blog user unadmin ann@example.com
```

没有密码参数时，它从标准输入读取一行（在终端上会显示提示；输入会回显），这样密码不会出现在 `ps` 和 shell 历史中。设置密码会让该用户的浏览器退出登录，并解除锁定。使用 `--confirmable` 时，它创建的用户是已确认的。它打印 `created`、`updated`、`admin` 或 `unadmin` 及地址并以 0 退出，或打印用法或错误并以 1 退出。

## 保持登录与会话期限

登录表单有一个 “Keep me signed in” 复选框（`check_box_tag :remember_me`）。一次登录的持续时间：

| | 勾选 | 不勾选 |
| --- | --- | --- |
| Session 行和 cookie 结束于 | `auth_remember_for`（30 天）之后 | `session_absolute_max_age`（两周）之后 |
| cookie | 剩余时间的 `Max-Age` | 没有 `Max-Age` 也没有 `Expires`：随浏览器结束 |
| 在 `auth_idle_timeout`（7 天；`0` 关闭）内未被使用 | 结束 | 结束 |

`last_active_at` 最多每分钟写一次。生成的 `start_new_session_for(user, remember:)` 依次调用 `session.restart_lifetime!` 和 `session.stamp_lifetime!(seconds, persistent)`，顺序如此：重新开始会清除印记。它写入的期限从不为 0：`session_absolute_max_age = 0` 时，不勾选的登录持续 `session_max_age`，或两周。这些设置见 [配置](configuration.md#authentication-settings)。

## 锁定

密码错误 `auth_lockout_attempts`（10）次，账户就会被锁定 `auth_lockout_period`（一小时）。被锁定的账户无论密码是什么，都回答密码错误的消息。登录成功、密码重置和 `./<app> user EMAIL` 会清除计数；`auth_lockout_attempts = 0` 关闭锁定，并不再执行之前的锁定。计数是一条按行当前值读取的 `UPDATE`（`Relation#update_all_sql`），所以同一时刻的登录都会被计入。按客户端地址的速率限制仍然保留。

## 密码重置

登录页面链接到 `/passwords/new`。地址表单总是回答 "If that address is registered, a link to reset the password was sent to it."，对未知地址也做同样的工作，只是不发送。邮件（`PasswordsMailer.reset(user, url).deliver_later`，使用请求的语言）带有 `/passwords/<token>/edit`；令牌有效 15 分钟，并且只在密码和地址保持不变时有效，所以只能用一次。设置新密码会解除锁定，并结束该用户的所有会话；使用 `--confirmable` 时还会撤回等待中的新地址（[确认地址](#confirming-addresses)）。

<!-- list: points -->
- 邮件由作业线程使用 `CYBERTRAIN_SMTP_*` 设置发送（[发送电子邮件](external-services.md#sending-e-mail)）：需要一个运行作业的进程和数据库。
- 链接所在页面返回 `Referrer-Policy: no-referrer`，框架的请求日志把令牌写成 `[FILTERED]`。
- 每个客户端地址每三分钟十次请求。

### 邮件中的链接

链接以生成器在 `config/app.rb` 中声明的 `base_url` 设置开头，取自 `<APP>_BASE_URL`（`BLOG_BASE_URL=https://blog.example.com`）。在提供应用的每个地方都用 https 设置它。未设置时，只有在 `Host` 头受到检查（开发环境，或设置了 `CYBERTRAIN_HOSTS`）或在测试中时，链接才使用请求到达的地址；其他情况下不发送邮件，日志写出 `[ERROR] password reset mail not sent: set <APP>_BASE_URL (or CYBERTRAIN_HOSTS)`，页面照常回答。伪造的 `Host` 永远不会进入链接。

## 确认地址

使用 `--confirmable` 时，注册会向该地址发送链接邮件，不让任何人登录。对尚未确认的地址输入正确的密码会以专门的消息拒绝（错误的密码得到通常的消息），登录页面链接到一个重新发送链接的表单。打开链接（`/confirmations/<token>`，有效三天，只能用一次）即确认地址；之后用户再登录。无论哪个控制器调用，关注点的 `start_new_session_for` 也会拒绝未确认的用户，并记录 `[WARN] no session started: user <id> has not confirmed its address`。这项检查位于生成器在 `--confirmable` 下写出的关注点中：新应用里是这样，在 0.4 升级中也是，因为那里的关注点是新文件。已经有关注点的应用会以差异的形式收到这项检查（[之后再开启确认](#turning-on-confirmation-later)）。

账户页面上的新地址在 `unconfirmed_email` 中等待，打开发往它的链接后才取代旧地址；页面可以撤回它（`DELETE /account/pending_email`），该链接随之失效。用户命令和 `/setup` 创建的用户是已确认的。密码重置会确认从未确认过的账户（链接证明了邮箱），但从不确认等待中的新地址：它会撤回该地址，其链接随之失效，因为请求它的人可能正是所有者要从其手中收回账户的人。所有者之后再重新请求即可。在账户页面上设置新密码则保留等待中的地址（用户就在那里，看得到它）。

## 账户页面

`/account/edit`（nav 中的 "Account"）只在给出当前密码时修改地址或密码，只在给出密码时删除账户（连同其会话，在一个事务中）。新密码会结束该用户的所有会话，并让这个浏览器按原来的“保持登录”状态重新登录。账户的修改和删除（因而也包括当前密码的错误）按客户端地址和按用户分别限制为每三分钟十次，当前密码的错误不计入锁定。

## 管理员用户与作业页面

`users.admin`（false）用 `./<app> user admin EMAIL` 设置。除非已登录的用户是管理员，关注点的 `require_admin` 都回答 404：

```ruby app/controllers/concerns/admin_gate.rb（节选，examples/blog）
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
  end
end
```

生成器把作业页面画在它的后面，替换 `cybertrain new` 写的那行注释：

```ruby config/routes.rb（节选）
jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
```

<!-- list: points -->
- 在作业页面上只运行 `require_admin`，所以访客得到 404，就像没有这个页面一样。在自己声明 `before_action :require_admin` 的控制器中，`require_authentication` 先运行（Rails 的顺序），所以访客被送去登录（303），已登录的非管理员得到 404。
- gen 拒绝没有 `before_action:` 的 `skip_before_action:`，也拒绝指向 `before_action:` 本身的那种：两者都会把页面向所有人开放。
- 应用自己写的 `jobs_page` 行保持不变。已经带有 `skip_before_action: :require_authentication` 的行视为已绘制；对其他行，生成器会提示加上它。要得到 404，请把这一行写成 `jobs_page "...", before_action: :require_admin, skip_before_action: :require_authentication`（gen 会拒绝没有 `before_action:` 的跳过）。
- 当 `ApplicationController` 自己定义了 `require_admin` 时，这个方法会在每个控制器中取代关注点的方法。生成器在插入 `include Authentication` 时会这样提示（`warn  app/controllers/application_controller.rb defines require_admin itself: ...`），并且不带跳过地绘制作业页面（`jobs_page "/admin/jobs", before_action: :require_admin`），这样那里也先运行 `require_authentication`。要使用关注点的方法，请删除它。
- 失败或被丢弃的邮件作业会在其行中保留邮件，而作业页面会显示行的参数：管理员可以在链接有效期间在那里读到重置或确认链接。这个页面只对管理员开放，而管理员本来就可以操作任何账户。
- `/setup` 和用户命令创建的是普通用户；用 `./<app> user admin EMAIL` 把第一个用户设为管理员。

## 留给应用的部分

以下是生成的代码所做的选择，以及各自的理由：

<!-- list: points -->
- 对存在且未锁定的账户输入错误的密码，会写一次该行（计数）；未知地址和已锁定的账户不会。这一次写入是一个时间差，和 Devise 的 lockable 一样被接受：为未知地址做同样的写入，会为一个速率限制已经约束的信号增加负载。密码重置表单也有同类的差异：已知地址会把邮件放入队列，多写一行。
- 注册、重置和确认邮件只按客户端地址限制，而不是按收件地址：有人可以按这个频率让某个地址收到邮件。登录按客户端地址限制为每三分钟十次，等于锁定阈值，所以一个客户端可以让一个已知账户一直处于锁定状态。按地址的限制（`rate_limit ... by:`）和更长的时间窗口由应用自行添加。
- 地址变更不会通知旧地址，等待中的新地址永不过期（其链接会过期，密码重置也会撤回它），从未确认的账户也永远不会被删除。
- 账户页面的 "has already been taken" 会告诉已登录、并给出了当前密码的用户某个地址已注册（与 Devise 相同），受该页面的速率限制约束。

## 框架提供的部件

生成的代码由框架 API 构成，这些 API 也可以单独使用：

| API | 作用 |
| --- | --- |
| `Cybertrain::Password` | PBKDF2-HMAC-SHA256 摘要：`hash`、`verify?`、`verify_serialized`、`dummy_digest`、`needs_rehash?`、`session_key`、`session_key_matches?`（[docs/design.md](../design.md) D25） |
| `Cybertrain::Token` | `issue(purpose, id, expires_in, bound_to)` 返回 `"<id>--<expires>--<hmac>"`；`id_from(token)`；`valid?(token, purpose, bound_to)` |
| `Cybertrain::MailMessage` | 邮件方法返回的对象：`deliver_later`（作业）或 `deliver_now` |
| `Session#restart_lifetime!`、`stamp_lifetime!(seconds, persistent)` | 一次登录自己的有效期，以及浏览器会话 cookie |
| `Relation#update_all_sql(sql, binds)` | 对匹配的行执行 `UPDATE ... SET <sql>` |
| `Controller.allow_unauthenticated_access`、`skip_before_action` | 向访客开放动作 |
| `Controller#safe_redirect_path(text, fallback)` | 来自请求的本站路径，或回退值 |
| `ParameterFilter.filter_path(path)` | 把形似令牌的路径段写成 `[FILTERED]` 的路径 |
| `check_box_tag(name, value = "1", checked = false)` | 没有隐藏字段的复选框 |

手写的登录像生成的 `User` 那样使用 `Password`：`Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)` 在每个进程中一次只校验一个密码（一次校验约占 0.2 秒 CPU），对未知地址也耗时相同；登录时写入 `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`，并在每个请求中用 `session_key_matches?` 检查，密码改变后浏览器就会退出登录。

`Token.valid?` 针对传入的 `bound_to` 校验令牌，所以要先用 `Token.id_from` 找到记录，再针对该记录自己的值校验，`User.find_by_password_reset_token` 就是这样做的。

## 测试

生成器写出 Rails 风格的测试类，由 `cybertrain test` 运行（[测试应用](testing.md)）：

| 文件 | 测试的内容 |
| --- | --- |
| `test/fixtures/users.yml` | `one`（管理员）和 `two`，密码是 `"password"`（使用 `--confirmable` 时两者都已确认） |
| `test/support/session_test_helper.rb` | `sign_in_as(user, remember: false)`、`sign_out`、`open_session`（第二个浏览器）和 `authenticity_token_in(body)`（页面第一个表单的令牌，用于 `with_forgery_protection` 中的请求），由 `test/test_helper.rb` 包含进每个集成测试 |
| `test/models/user_test.rb` | 地址格式 |
| `test/controllers/sessions_controller_test.rb` | 登录和退出 |
| `test/controllers/registrations_controller_test.rb` | 注册（不使用 `--invite-only` 时） |
| `test/integration/first_run_test.rb` | `/setup` 和 user 命令（使用 `--invite-only` 时） |
| `test/controllers/passwords_controller_test.rb` | 重置、它的邮件和链接 |
| `test/controllers/accounts_controller_test.rb` | 账户页面 |
| `test/controllers/confirmations_controller_test.rb` | 确认（使用 `--confirmable` 时） |
| `test/integration/remember_me_test.rb` | 第 15 天和第 30 天、空闲上限 |
| `test/integration/lockout_test.rb` | 锁定和它的一小时 |
| `test/integration/admin_test.rb` | `require_admin`、`user admin` |

时间用 `travel_to` 和 `travel` 推进（不会把任何行往回改时间），邮件用 `assert_emails` 和 `perform_enqueued_jobs` 从 `Cybertrain::Mailer.deliveries` 中读取。在认证之后生成的脚手架会在其控制器测试开头登录 `users(:one)`；在认证之前生成的不会，请在它的 `setup` 中加上 `sign_in_as users(:one)`。在一个由早先的生成器写过测试的应用中再次运行（`test/authentication.rb`、`admin.rb`、`remember_me.rb`、`lockout.rb`、`passwords.rb`、`accounts.rb`、`confirmations.rb`、`test/support/app_test.rb`、`test/support/authentication_helpers.rb`），生成器会指出每个文件以及替代它的文件；`--force` 会删除它们。

本仓库的 `script/auth-e2e signup invite confirmable upgrade04` 用生成器构建应用，并端到端地驱动它们。

## 从 0.4 升级

在 0.4 生成的应用中再次运行生成器。它写出缺少的文件、一个补充现有迁移所缺列的迁移，以及各项修改；对于它本应整体写出、但已存在且内容不同的文件，它不做改动，而是打印差异：

```text 输出 — cybertrain generate authentication（节选）
exist db/migrate/20260925120000_create_users.rb
create db/migrate/20260925120002_add_authentication_columns.rb
manual  app/models/user.rb (diff below)
create app/controllers/concerns/authentication.rb
manual  app/controllers/sessions_controller.rb (diff below)
create app/controllers/passwords_controller.rb
...
manual  app/controllers/application_controller.rb (diff below)
...
manual  app/controllers/application_controller.rb: apply this diff by hand, or re-run with --force to overwrite the file
--- a/app/controllers/application_controller.rb
+++ b/app/controllers/application_controller.rb
@@ -1,95 +1,5 @@
 class ApplicationController < Cybertrain::Controller
-  # ---- Authentication (cybertrain generate authentication) -------------
-  # Every action needs a signed-in user unless its controller opens it:
...
-  # ---- end of authentication ------------------------------------------
+  include Authentication
```

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) 是针对 0.4 生成的开放注册应用的完整输出。

<!-- list: points -->
- 保存输出，在应用目录中用 `patch -p1` 应用（patch 会跳过不属于差异的行），或者在你修改过文件的地方手工应用每个差异。在应用这些差异之前，应用可能无法构建：新文件会调用差异所添加的内容。
- `--force` 则用新文件覆盖旧文件，适用于你从未编辑过的文件；`ApplicationController` 中 0.4 的代码块只有在与 0.4 所写完全相同时才会被替换。
- 新迁移只添加缺少的列；运行 `cybertrain db migrate`。使用 `--confirmable` 时，它还把已有用户视为（自创建起）已确认，否则他们都无法登录。
- 使用 `--confirmable` 时，sessions 和 registrations 控制器的差异带有一行 `IMPORTANT:`：在应用它们之前，未确认的账户不会被告知为何无法登录，注册也不会收到链接邮件。在 0.4 的应用中关注点是新文件，连同确认检查一起写出，所以即使这些差异从未应用，它仍然不会为未确认的账户开始会话（并记录 `[WARN] no session started: user <id> has not confirmed its address`）。
- 升级时每个会话都会结束一次（cookie 现在是加密的），[升级 0.4 的应用](requests.md#upgrading-an-application-from-04) 的其余部分也同样适用。

### 之后再开启确认

在没有确认功能时生成的应用中运行 `cybertrain generate authentication --confirmable`（如果应用使用 `--invite-only`，也加上它）。它写出确认相关的文件和一个添加列的迁移（把已有的用户视为已确认），并为它以前写过的每个文件打印差异。这里关注点已经存在，所以确认检查作为这些差异之一到来，输出把它标为 `IMPORTANT:`：在应用关注点的差异之前，无论其他差异如何，未确认的账户都能登录。部署之前请应用它和 sessions 控制器的差异。使用 `--invite-only` 时，setup 控制器的差异也会被标出：在应用它之前，`/setup` 创建的第一个用户未被确认，无法登录（密码重置会确认它）。
