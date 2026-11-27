---
source_sha256: 66999cb2e64c8060c3a4cd7100fab0efa7c77701391e63b73ae9b4f068b1db93
title: "进阶教程：把博客继续推进"
description: "用 CyberTrain 继续推进入门指南中的博客：组件和辅助方法、用 Turbo Streams 实时推送评论、后台作业、JSON、登录、上传的封面图片，以及用 cybertrain build 为部署而构建。"
og_title: "进阶教程：把 CyberTrain 博客继续推进"
og_description: "在 CyberTrain 入门指南的博客上加入 Turbo、后台作业、JSON、登录、上传和可部署的构建。"
og_image: tutorial.png
crumb: "进阶教程"
nav: tutorial
toc_title: "步骤 13–19"
meta:
  - term: "你需要"
    text: '[教程](tutorial.md#test)中做到第 12 步的博客'
  - term: "从这里开始"
    text: "带文章、评论和测试的 `blog/`"
  - term: "最终得到"
    text: "`dist/blog`"
---

# 进阶教程：把博客继续推进

[教程](tutorial.md)以一个包含文章和评论的博客结束。本页继续推进同一个应用：用组件渲染评论、用 Turbo 把新评论推送到每个打开的页面、把一个后台作业加入队列、返回 JSON、添加登录、附加一张上传的图片，并把应用构建到可部署的 `dist/` 目录中。这个应用最终会发展成 [`examples/blog`](../../examples/blog)，由 CI 在 Linux 和 macOS 上运行测试。

<!-- step 13 #component stage: 你编写 · `app/components/`, `app/helpers/` -->
## 组件与辅助方法

> [!WHY]
> 从下一步开始，评论会在两个地方渲染：在页面上，以及在背后没有任何请求的广播中。组件是一个旁边配有模板的类，在这两处渲染出的结果相同；辅助方法则是每个模板都能调用的方法。

```shell 终端 — blog/
cybertrain generate component comment comment   # 先是名称，然后是它的属性：只有一个，也叫 comment
cybertrain generate helper comments
```

第一条命令写出 `app/components/comment_component.rb`（每个属性对应一个关键字）及其模板；第二条写出一个空的 `CommentsHelper`。两者还各写出一个测试，本步骤的最后会回头处理它。这个类已经是博客所需要的样子：

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

把生成的模板换成评论的标记，并为辅助模块写上它唯一的方法：

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # 评论者的名字，放在 <strong> 中并经过转义：<%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

然后在页面原先渲染局部视图的地方渲染组件，并删除 `app/views/comments/_comment.html.erb`：

```erb app/views/articles/show.html.erb（节选）
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- 模板把组件的实例变量看作局部变量（`comment`），并按名称看到它不带参数的公开方法。它只拿到评论，拿不到页面的 `@article`，所以按钮的路径由 `comment.article_id` 构建。
- 对于 id 为 7 的评论，`dom_id(comment)` 是 `comment_7`：下一步的广播瞄准的就是这个元素 id。
- 组件和局部视图一样按名称指定，用的是去掉 `_component` 的 snake_case 名称：模板不能指名常量。
- `Cybertrain::Html.tag` 会转义其内容并返回 `SafeString`，模板会原样输出它；辅助方法返回的普通 `String` 则会被转义。

> [!RULE] Spinel 规则：辅助方法和组件是生成的分派
> ### 辅助方法和组件是生成的分派
>
> 模板不能使用 `send`，所以 `spin run gen` 把 `app/helpers/` 和 `app/components/` 当作文本读取，并把分派代码写入 `gen/helpers.rb` 和 `gen/components.rb`。辅助方法的参数都是具名的（没有 `*rest`，没有 `**opts`），它的实参以模板中的值的形式传入，这就是 `comment_author` 用 `case ... when Comment` 收窄参数的原因。其余内容见[应用的辅助方法](template-language.md#application-helpers)和[组件](template-language.md#components)。

### 组件的测试

生成的测试在模板现在需要一条评论的地方传入一个 String 来渲染 `CommentComponent`。改为渲染夹具中的评论：

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` 像广播一样在没有请求的情况下渲染，`assert_select` 读取它渲染的结果（[测试流和组件](testing.md#testing-streams-and-components)）。辅助方法的测试按生成时的样子就能通过。和[第 12 步](tutorial.md#test)一样，用 `cybertrain test` 运行它们。

<!-- step 14 #turbo stage: 运行时 · 基于 Server-Sent Events 的 Turbo Streams -->
## 用 Turbo 实时推送评论

> [!WHY]
> 在一个浏览器中发表的评论，应该无需刷新就出现在所有打开着这篇文章的页面上。和 Rails 8 应用一样，这靠的是 Turbo Streams，而且除了服务器之外，没有任何东西需要安装或启动。

### 加载 Turbo

`cybertrain new` 把这两行都留成了注释；取消它们的注释：

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

布局中的 `javascript_importmap_tags` 会写出 import map 和 `import "application"`，所以现在每个页面都会运行 Turbo（[import map](assets.md#the-import-map)）。

Turbo Streams 的服务器端是一个子系统：在 `bin/blog.rb` 中核心那一行的下面添加它的那一行，并在 `bin/db.rb` 中添加同样的一行。没有它，`spin run gen` 会停在下面的 `turbo_stream_from` 处，并指出需要的那一行。

```ruby bin/blog.rb（节选）
require "cybertrain/core"
require "cybertrain/streams"
```

### 让页面订阅

给列表和表单各加一个 id，并让页面订阅这篇文章的流：

```erb app/views/articles/show.html.erb（节选）
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

### 广播并响应

`create` 先广播已保存的评论，再响应发表它的那个浏览器；`destroy` 则通知其他页面移除该元素：

```ruby app/controllers/comments_controller.rb（节选）
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # 每个用 turbo_stream_from @article 订阅的页面都会追加这条评论。
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    @new_comment = Comment.new   # create.turbo_stream.erb 放回的空表单
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
    target = Cybertrain::Html.dom_id(@comment)   # 在 destroy 清除 id 之前读取
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

在两个窗口中打开同一篇文章，并在其中一个窗口发表评论：评论会出现在两个窗口中，而提交它的表单会变回空白。

### 发生了什么

<!-- list: points -->
- `turbo_stream_from @article` 为流 `articles:<id>` 写出一个带签名令牌的 `<turbo-stream-source>` 元素。Turbo 把它作为 `EventSource` 连接到 `/cybertrain/stream`，这个端点服务器本来就提供。
- 一次广播就是 `cybertrain_messages` 中的一行，这张表由框架自己创建。每个服务器进程都轮询这张表，并把这一行交给它持有的页面，前后大约十分之一秒。
- Turbo 提交表单时会请求 Turbo Stream，所以 `format.turbo_stream` 渲染 `create.turbo_stream.erb`，不带布局。关闭 JavaScript 时的普通表单提交则走 `format.html`，像以前一样被重定向。
- 发表评论的窗口会收到这条评论两次，一次在响应中，一次在广播中，但只显示一次：Turbo 会替换 id 相同的元素。

更多内容，包括 WebSocket 以及供你自己的 JavaScript 使用的流：[实时](realtime.md#turbo-streams)。

> [!NOTE]
> 这里的 Turbo 是从 jsDelivr 获取的。要自己提供它，把 `turbo.es2017-esm.js` 复制到 `vendor/javascript/`，并用 `to: "turbo.es2017-esm.js"` 固定它。如果你启用了 `config/app.rb` 中被注释掉的 Content Security Policy，它的 `script_src` 必须允许提供 Turbo 的那个源（[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)）。

### 测试 Turbo Stream 响应

像 Turbo 提交表单时那样请求 Turbo Stream 的请求，会得到 Turbo Stream 响应。在[第 12 步](tutorial.md#test)的评论测试中加入一个测试：

```ruby test/controllers/comments_controller_test.rb（节选）
  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end
```

<!-- step 15 #job stage: 你编写 · `app/jobs/` -->
## 后台作业

> [!WHY]
> 不应拖住响应的工作（例如发送通知）独立于请求运行：它可能在响应写出之前开始，也可能在之后。和 Solid Queue 上的 Active Job 一样，作业是 `app/jobs/` 中的一个类，加上应用自己数据库中的一行：不需要其他服务。

```shell 终端 — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

它会写出 `app/jobs/notify_comment_job.rb`，其中有该选项所要求的 `retry_on` 行和一个空的 `perform`，另外还有一个测试，并向 `bin/blog.rb` 和 `bin/db.rb` 添加 `require "cybertrain/jobs"`，还会取消 `config/deploy.yml` 中 `worker` 角色的注释（[第 19 步](#ship)）。把 `perform` 填上；这里它只写一条日志，真实的应用会在这里发送邮件：

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

评论保存之后，在 `create` 中把它入队：

```ruby app/controllers/comments_controller.rb（节选）
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # 每个用 turbo_stream_from @article 订阅的页面都会追加这条评论。
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

发表一条评论，服务器的日志会显示作业的运行：这里它在响应之后运行，但作业线程也可能在响应写出之前取得这一行，所以各行的顺序可能不同；作业的行带有作业的标签和把它加入队列的请求的 ID：

```text 输出 — cybertrain server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started POST "/articles/1/comments" for 127.0.0.1
2026-11-14T09:30:00.122Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 2ms
2026-11-14T09:30:00.950Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] new comment 1 on article 1
2026-11-14T09:30:00.951Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` 是传给 `perform_later` 的 Hash，以 JSON 形式保存，读回时键为 String：请传递 id，而不是记录，并用 `Cybertrain::Cast` 收窄其中的值。`perform_in(seconds, args)` 和 `perform_at(time, args)` 把它安排在之后运行。
- 作业是 `cybertrain_jobs` 中的行，由提供服务的进程的三个作业线程运行，或者由用 `./blog worker` 启动的单独进程的作业线程运行（[进程角色](background-and-operations.md#process-roles)）。
- `retry_on StandardError, wait: 30, attempts: 3` 会在 30 秒后把失败的运行重新入队，总共尝试三次；此后这一行变为 `failed` 并保留下来（[重试与丢弃](background-and-operations.md#retries-and-discards)）。
- 作业可能运行不止一次（进程在运行某个作业的中途死掉时，该作业会再运行一次），所以要把 `perform` 写成可以安全重复执行的。
- 失败的作业用 `./blog jobs` 列出、重试和丢弃，也可以在 `/admin/jobs` 的作业页面上操作：`config/routes.rb` 中被注释掉的 `jobs_page` 那一行指定了 `require_admin`，这个方法由[第 17 步](#authentication)的生成器写出，页面也由那个生成器替你挂载（[作业页面](background-and-operations.md#the-jobs-page-and-the-jobs-command)）。

> [!RULE] Spinel 规则：作业策略作为文本读取
> ### 作业策略作为文本读取
>
> `spin run gen` 读取 `app/jobs/` 下的每个类，并把它的另一半写入 `gen/jobs.rb`：`perform_later`，以及把每个 `retry_on` 写成一个 `rescue` 分支。因此 `retry_on`、`discard_on` 和 `limits_concurrency` 各占一行，并使用字面值：写 `wait: 30`，而不是 `wait: 30.seconds` 或 lambda。

> [!EXAMPLE] 每晚删除已完成的作业
> ### 每晚删除已完成的作业
>
> 每条评论都会留下一个 `done` 行。`config/app.rb` 的末尾有一个被注释掉的定时任务，它会删除已有一周之久的这类行；取消它的注释：
>
> ```ruby config/app.rb（节选）
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> cron 表达式按 `CYBERTRAIN_SCHEDULER_TZ`（默认为应用的 `time_zone`，未设置时为 UTC）解读，并且同一时间只有一个进程运行这份时间表（[定时任务](background-and-operations.md#scheduled-tasks)）。

### 测试评论会把作业加入队列

生成器写出的作业测试原样就能通过。在评论测试中加入一个测试，检查 `create` 会把作业加入队列，并运行它：

```ruby test/controllers/comments_controller_test.rb（节选）
  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end
```

测试不运行作业线程，所以排队的作业会一直等到测试运行它（`perform_enqueued_jobs`）；其他作业断言见[测试作业](testing.md#testing-jobs)。

<!-- step 16 #json stage: 你编写 · `app/controllers/` -->
## 返回 JSON

> [!WHY]
> 同一个动作既能提供页面，也能提供 API：用 `respond_to`，和 Rails 一样。

```ruby app/controllers/articles_controller.rb（节选）
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

```console 终端 — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- 格式取自扩展名（`/articles.json`），没有扩展名时取自 `Accept` 请求头。动作没有列出的格式（例如 `/articles.xml`）会得到 `406 Not Acceptable`。
- 不带块的 `format.html` 像以前一样渲染动作的模板。
- `as_json` 给出记录的各列，时间为 ISO 8601 格式的 UTC。JSON 没有模板：动作用 `render json:` 返回它。
- 块里只写 `format.` 开头的那些行：请求回退到 html 时，这个块会再运行一次。

`/articles/1.json` 是单篇文章，来自 `show` 中同样的块。关于格式的全部内容：[格式与 `respond_to`](requests.md#formats-and-respond_to)。

<!-- step 17 #authentication stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加登录

> [!WHY]
> 到目前为止，任何人都能编辑或删除文章。和 Rails 8 的 `bin/rails generate authentication` 一样，一条命令就能加上用邮箱和密码登录的功能，而且写成归应用所有的代码，而不是作为引擎安装。

```shell 终端 — blog/
cybertrain generate authentication
cybertrain db migrate    # 创建 users 和 sessions 表
```

它写出 `users` 和 `sessions` 的迁移与模型、被它包含进 `ApplicationController` 的 `Authentication` 关注点、用于登录、注册、重置密码和账户页面的控制器与视图、一个邮件程序、`./blog user` 命令，以及测试。它还会添加路由（其中包括面向管理员的 `/admin/jobs` 作业页面）、布局顶部的 `sessions/_nav` 局部模板，以及 `config/app.rb` 中的 `base_url` 设置，邮件中的链接以它开头。最后，它会向 `bin/blog.rb` 和 `bin/db.rb` 添加其代码用到的子系统的行：`cybertrain/jobs`（作业页面和发送邮件的线程）、`cybertrain/mailer`、`cybertrain/mailer/later`（邮件通过 `deliver_later` 发送）和 `cybertrain/rate_limit`（登录尝试有速率限制，见下文）。每个文件都列在 [认证](authentication.md#generating-it) 中。

```ruby app/controllers/concerns/authentication.rb（节选）
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
```

从现在起，每个动作都需要已登录的用户，访客会被重定向到 `/session/new`。像 Rails 指南那样，把任何人都能阅读的页面重新开放：

```ruby app/controllers/articles_controller.rb（节选）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

这些页面上 `resume_session` 仍会运行，所以模板可以读取 `@current_user`。把访客用不了的东西隐藏起来：

```erb app/views/articles/show.html.erb（节选）
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

评论组件对所有人都保留 “Destroy comment” 按钮：广播只为所有观看者渲染一次，没有请求，也就没有当前用户。点击它的访客会被带到登录页面，因为 `CommentsController` 没有开放任何动作；新评论仍然会到达访客的页面，因为流不是控制器的动作。

启动服务器并打开 `http://127.0.0.1:3000/sign_up` 创建第一个用户。Rails 的生成器没有注册页面，第一个用户要在控制台中创建；CyberTrain 写出了 `RegistrationsController`，所以第一个用户在浏览器中注册。对于仅限邀请的应用，请改用 `--invite-only` 运行生成器：没有注册页面，第一个用户来自 `./blog user EMAIL`，或来自只有服务器本机才能打开的 `/setup` 页面（[开放注册，或仅限邀请](authentication.md#sign-up-or-invite-only)）。

登录页面还链接到通过邮件重置密码，nav 链接到账户页面；[认证](authentication.md) 指南介绍了它们，以及锁定、“保持登录”、`--confirmable` 和管理员用户。重置邮件需要 SMTP 设置，在生产环境中还需要 `BLOG_BASE_URL`（[邮件中的链接](authentication.md#links-in-mails)）。

> [!RULE] has_secure_password 被逐一写出
> ### `has_secure_password` 被逐一写出
>
> CyberTrain 没有 `has_secure_password` 宏。生成器把它本该定义的方法写进 `User` 模型，成为应用自己拥有的代码：`password=`、`authenticate` 和 `User.authenticate_by(email_address:, password:)`。密码由 `Cybertrain::Password` 做哈希：它是用 Ruby 实现的 PBKDF2-HMAC-SHA256，默认迭代 10 万次（编译后约 0.2 秒）；bcrypt 则需要让二进制链接一个 C 库。可以在 `config/app.rb` 里用 `Cybertrain::Password.iterations = 600_000` 提高成本，`User#authenticate` 会在每个用户登录时重新计算哈希。

### 更新测试

[步骤 12](tutorial.md#test) 中打开表单、提交表单或访问 `index` 和 `show` 以外动作的测试，现在会遇到登录页面。生成器写出了 `test/fixtures/users.yml`（`one` 和 `two`，密码是 `"password"`）和 `test/support/session_test_helper.rb`，`test/test_helper.rb` 现在把其中的 `sign_in_as` 给了每个集成测试，并且生成器已经在文章测试的 `setup` 中加上了登录（它会输出 `insert test/controllers/articles_controller_test.rb (sign_in_as users(:one))`），所以你会看到：

```ruby test/controllers/articles_controller_test.rb（节选）
  setup do
    sign_in_as users(:one)
    @article = articles(:one)
  end
```

评论测试没有可供生成器添加登录的 `setup`，而 `CommentsController` 的每个动作（create 和 destroy）现在都需要已登录的用户，所以它的四个测试也都需要；给它加上：

```ruby test/controllers/comments_controller_test.rb（节选）
class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end
```

从现在起生成的脚手架会自己登录。

> [!NOTE]
> 生成器自己的测试（`test/controllers/sessions_controller_test.rb`、`registrations_controller_test.rb`、`passwords_controller_test.rb`、`accounts_controller_test.rb`、`test/integration/remember_me_test.rb`、`lockout_test.rb`、`admin_test.rb`，见[测试](authentication.md#testing)）在 `cybertrain test` 中和其他测试一起运行，用 `travel_to` 拨动时钟来检查第 15 天和第 30 天。和 Rails 的生成器一样，登录尝试受到限流：每个客户端地址每三分钟十次，在应用的数据库中计数，所以所有进程一起计数；在反向代理之后，请配置[受信任的代理](requests.md#rate-limiting-and-the-client-address)。`examples/blog` 用 `--invite-only` 完成这一步，并让它的 `/admin` 页面只对管理员开放。

<!-- step 18 #attachments stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加封面图片

> [!WHY]
> 文章可以带一张图片。分工和登录一样：框架负责解析 `multipart/form-data` 并保存字节，其余部分由一条命令写成归应用所有的代码，以此取代 Active Storage 的 `has_one_attached`。

图片会显示在文章页面上，而从步骤 17 起访客就可以阅读这个页面，所以它的下载也必须对他们开放。在运行生成器之前，先把 `:cover` 加入步骤 17 写下的列表。下载也不会运行 `def show` 中的代码，而这个 `show` 有代码（为表单构建一条空评论并选择格式），所以除非用 `--show-checks-nothing` 表明这段代码不限制任何人，生成器会停止；这段代码确实不限制任何人：

```ruby app/controllers/articles_controller.rb （节选）
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell 终端 — blog/
cybertrain generate attachment article cover --show-checks-nothing   # 新模型则用：generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                                                # 给 articles 添加 cover_* 列
```

它会写出一个迁移，为 `articles` 添加五列（`cover_key`, `cover_filename`, `cover_content_type`, `cover_byte_size`, `cover_checksum`；文件本身不在 SQLite 中），并在 `Article` 中写出一个代码块，包含 `cover_file=`、`cover_attached?`、`cover_url`、一个验证，以及保存和销毁回调。在 `ArticlesController` 中，它添加一个由 `before_action :set_article` 保护的 `cover` 动作，并在 `create` 和 `update` 中各加一行：

```ruby app/controllers/articles_controller.rb （节选）
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

下载和 `show` 一样通过 `set_article` 找到它的文章，所以 `set_article` 中用来限制用户能看到哪些文章的任何做法，同样会限制下载。生成器打印的各行中仍有一条警告，因为这个 `show` 里有它自己的代码：

```text 输出 — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

在这里，那段代码构建一条评论并选择格式；它不拒绝任何人，所以没有什么需要复制到 `cover` 中。如果它会拒绝某些人（`head 404 if @article.draft?`），这项检查应放在同时列出 `:show` 和 `:cover` 的 `before_action` 中，生成器能读懂它。但移走这项检查并不会让这个 `show` 变空，它仍然构建评论并选择格式，所以生成器仍会停止：要么在 `show` 为空时运行，要么在确认 `show` 中剩下的代码不限制任何人之后，加上 `--show-checks-nothing` 运行。

生成器还会在 `config/routes.rb` 中添加 `get "/articles/:id/cover"`，在表单中添加 `multipart: true` 和一个位于提交按钮上方的文件输入框，并在显示页面中紧跟 `<h1>` 之后添加这张图片：

```erb app/views/articles/_form.html.erb （节选）
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb （节选）
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!NOTE]
> 生成器会把 `show` 的访问规则复制到下载上，但只复制它能读懂的那些，也就是回调。如果除 `set_article` 之外还有一个 `before_action` 列出了 `:show` 却没有列出新动作，它会以 `cannot preserve show's authorization for :cover` 停止，什么也不写。`def show` 中的代码检查的是什么，它读不出来，所以除非 `--show-checks-nothing` 为它担保，生成器同样会停止；有了担保，它会给出警告。`show` 为空时，只要 `allow_unauthenticated_access` 列出了 `:show`，它就会自行把 `:cover` 加进去；`show` 中有代码时，它不改动这一行，而这一行里没有 `:cover` 的话，图片需要登录才能看到。

> [!RULE] has_one_attached 被逐一写出
> ### `has_one_attached` 被逐一写出
>
> 没有 `has_one_attached`，也没有共享的附件表：允许的类型、大小以及谁可以下载，每个应用都不一样，所以生成器把这些方法逐一写出，以字段命名，放在 `Article` 中，并把元数据放进 `articles` 的五个列里。这些列都是 `NOT NULL`，用 `""` 和 `0` 表示“没有附件”：可为空的列会让 Spinel 失去类型推断。SQLite 只保存元数据（文本值遇到 NUL 字节就会截断）；字节保存在文件里。

### 文件如何提供

<!-- list: points -->
- **类型。** 默认只接受不超过 2 MB 的 PNG、JPEG、GIF 和 WebP（`COVER_TYPES` and `COVER_MAX_BYTES` 在模型中；`--any` 则接受任何类型）。类型由文件的前几个字节检测，绝不采用浏览器给出的值。
- **存储。** 字节保存到 `storage/uploads/<2 hex>/<32 hex key>`（`Cybertrain::BlobStore`，权限 0600）。替换文件会删除旧文件，销毁文章会删除它的文件。请把 `storage/uploads/` 和 SQLite 文件一起备份。
- **提供。** 文件通过控制器中的 `send_blob` 发出，绝不从 `public/` 提供。四种图片类型内联显示；其他类型一律作为下载（`application/octet-stream`）。每个响应都带有 `X-Content-Type-Options: nosniff` 和 `Content-Security-Policy: default-src 'none'; sandbox`。
- **参数。** `params.nested(:article).upload(:cover)` 是一个 `Cybertrain::UploadedFile`，没有选择文件时为 nil。`permit` 从不返回文件，所以文件只能通过那一行显式的代码进入。CSRF 令牌和普通表单一样，从 multipart 请求体中读取。损坏或过大的请求体会得到 400；限制由 `config/app.rb` 中的 `max_upload_bytes` 和 `max_multipart_parts` 设置，存放目录由 `upload_root` 设置。

启动服务器，编辑一篇文章并选择一张图片。生成器还写了 `test/integration/article_cover_attachment_test.rb` 和图片 `test/fixtures/files/cover.png`，它们测试整个流程，并且因为应用现在有了 `User`，会先登录。由于这里的 `:cover` 是公开的，它会检查访客能否下载封面；正文则填入 `"A article."`，长度补足到 [步骤 05](tutorial.md#validations) 要求的至少 10 个字符。

> [!NOTE]
> 和[步骤 12](tutorial.md#test) 一样用 `cybertrain test` 运行（2026-11-13 测得，教程的博客此时有 83 个测试、870 个断言）。`examples/blog` 也包含这一步，并且它的 JSON 不包含 `cover_*` 列（`Article#public_json`）。尚未实现：每个字段多个文件、S3 或其他远程存储、图片变体，以及把大请求体流式写入磁盘（整个请求体会读入内存，上限为 `max_body_bytes`）。

<!-- step 19 #ship stage: 运行时 · `dist/blog` -->
## 为部署而构建

> [!WHY]
> 一条命令就能把应用构建到可部署的 `dist/` 目录中，所有视图都已嵌入。

```shell 终端 — blog/
cybertrain build
```

这会写出 `dist/`：嵌入了所有视图的应用二进制文件，以及放在它旁边、供它使用的文件。它会运行 `SPIN_DEBUG=1 spin run gen -- --embed-views`、`spin build blog` 和 `SPIN_DEBUG=1 spin run gen`（最后这一步会恢复已提交的、空的 `gen/views.rb`，即使在失败或按下 Ctrl-C 之后也是如此），然后组装出：

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>编译后的框架、控制器、模型和模板解释器，并嵌入了所有视图</span></li>
  <li><code>dist/public/</code><span>静态资源和错误页面，也可以交给反向代理来提供</span></li>
  <li><code>dist/storage/</code><span>创建时为空；默认存放 SQLite 文件（重新构建永远不会清空它）</span></li>
  <li><code>dist/tmp/</code><span>创建时为空（重新构建永远不会清空它）</span></li>
</ul>

把 `dist/` 复制到操作系统和 CPU 都相同的机器上（该二进制文件链接系统的 SQLite），然后在那里运行。构建出的二进制文件默认使用生产环境（可用 `CYBERTRAIN_ENV` 覆盖）。设置 `CYBERTRAIN_SECRET_KEY_BASE`（`cybertrain secret` 也能打印一个）；示例如下：

```shell 终端 — 生产主机
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` 执行编译进二进制文件的迁移，`./blog db status` 显示它们的状态；`PORT` 设置端口。重启前后请保持密钥不变：更改它会使所有会话失效。`./blog help` 会列出二进制文件的其他命令，其中有 `worker`、`jobs`、`console` 和 `db backup`。

`Cybertrain::Config` 首先读取环境变量；`config/app.rb` 中的设置会覆盖它们。首次部署会遇到的变量如下（全部变量见[配置](configuration.md#configuration-and-environment-variables)）：

<div class="table-scroll" role="region" aria-label="环境变量" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">变量</th><th scope="col">属性</th><th scope="col">默认值</th></tr></thead>
  <tbody>
    <tr><td data-label="变量"><code>CYBERTRAIN_ENV</code></td><td data-label="属性"><code>env</code></td><td data-label="默认值"><code>"development"</code>；由 <code>cybertrain build</code> 构建的二进制文件中为 <code>"production"</code>（也可以是 <code>"test"</code>）</td></tr>
    <tr><td data-label="变量"><code>PORT</code></td><td data-label="属性"><code>port</code></td><td data-label="默认值"><code>3000</code></td></tr>
    <tr><td data-label="变量"><code>CYBERTRAIN_DATABASE</code></td><td data-label="属性"><code>database_path</code></td><td data-label="默认值"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="变量"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="属性"><code>secret_key_base</code></td><td data-label="默认值">生产环境中必需；开发/测试环境会自动生成一个并写入 <code>tmp/secret_key</code></td></tr>
    <tr><td data-label="变量"><code>SPINEL_WORKERS</code></td><td data-label="属性"><code>workers</code></td><td data-label="默认值"><code>1</code></td></tr>
    <tr><td data-label="变量"><code>CYBERTRAIN_HOST</code></td><td data-label="属性"><code>host</code></td><td data-label="默认值"><code>"127.0.0.1"</code>；<code>0.0.0.0</code> 监听所有网络接口（容器）</td></tr>
    <tr><td data-label="变量"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="属性"><code>session_same_site</code></td><td data-label="默认值"><code>"Lax"</code>；也可以是 <code>Strict</code> 或 <code>None</code>（<code>None</code> 总会加上 <code>Secure</code>）；其他任何值都会让服务器在启动时停止</td></tr>
    <tr><td data-label="变量"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="属性"><code>session_partitioned</code></td><td data-label="默认值"><code>false</code>；<code>1</code> 或 <code>true</code> 会加上 <code>Partitioned</code>（以及 <code>Secure</code>）</td></tr>
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
- 服务器使用纯 HTTP/1.1：如需 TLS 和 HTTP/2，请在前面放 nginx 或 Caddy。生产环境中会话 cookie 带有 `Secure`，所以要通过 HTTPS 提供服务（仅当生产环境确实使用纯 http 时，才在 `config/app.rb` 中设置 `c.session_secure = false`）。在这样的代理之后，`CYBERTRAIN_FORCE_SSL=1` 会把 http 重定向到 https，`CYBERTRAIN_HOSTS` 则指定应用响应哪些主机名（[主机与 `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)）。
- 提供服务的进程同时运行第 14 步和第 15 步中的作业、定时任务和流轮询器：一个进程就是一套完整的部署。`./blog worker` 把作业移到它们自己的进程中（[进程角色](background-and-operations.md#process-roles)）。
- 没有 `CYBERTRAIN_SECRET_KEY_BASE` 时，生产环境会拒绝启动。
- 在生产环境中，异常会返回 500；而裸错误响应（路由器的纯文本 404、`head :not_found`、`render plain:`）在 `public/<status>.html` 存在时会被该文件替换；`cybertrain new` 会写出 `404.html` 和 `500.html`。
- `SIGTERM` 会让服务器停止接受新连接，让正在处理的请求完成，并在它们完成后退出，或在服务器的 `drain_timeout`（10 秒）之后退出。
- 监视器、CRuby 预览和重新构建循环永远不会在生产环境中运行。正在运行的 `cybertrain server` 在 `cybertrain build` 持有 `tmp/cybertrain-build.lock` 期间不会重新生成，也不会重启任何东西。

`cybertrain new` 还会写出一套 [Kamal 2](https://kamal-deploy.org) 配置。`Dockerfile` 在 Ubuntu 构建阶段运行 `cybertrain setup` 和 `cybertrain build`，再把 `dist/` 复制到同一发行版的精简阶段；该镜像启动时先执行迁移，然后在 `0.0.0.0:3000` 上提供服务。此外还有 `.dockerignore`、`config/deploy.yml`（前端是带 Let&rsquo;s Encrypt 的 kamal-proxy，健康检查使用 `public/up.html`，SQLite 文件放在挂载于 `/app/storage` 的卷上，还有第 15 步取消了注释的 `worker` 角色：用同一个镜像运行 `./blog worker` 的第二个容器；除非 `CYBERTRAIN_WORKER` 为 0，web 角色也会运行作业），以及从环境变量读取 `KAMAL_REGISTRY_PASSWORD` 和 `CYBERTRAIN_SECRET_KEY_BASE` 的 `.kamal/secrets`。填好 `config/deploy.yml` 中标为 `CHANGE ME` 的值，提交，然后运行：

```shell 终端 — blog/
kamal setup    # 首次：在服务器上安装 Docker 和 kamal-proxy，构建、推送并启动
kamal deploy   # 之后的每次部署
```

二进制文件在镜像内编译，因此操作系统总与镜像一致；请把 `config/deploy.yml` 中的 `builder.arch` 设为服务器的 CPU 架构。只部署到一台服务器：数据库是该服务器卷上的一个 SQLite 文件。[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする)（日文；英文版见 [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)）第 8 部分完整介绍了这一流程，包括备份。

完成的应用 [`examples/blog`](../../examples/blog#deploying-with-kamal) 也带有这套配置，只有一处不同：它针对仓库中的框架构建（其 `spin.toml` 中的 `path = "../.."`），因此它的 `Dockerfile` 不安装 gem，而是从检出目录运行 `cybertrain setup` 和 `cybertrain build`，构建上下文是仓库根目录（`builder.context: ../..`，由 `Dockerfile.dockerignore` 只发送框架和应用）。CI（[`blog-image.yml`](../../.github/workflows/blog-image.yml)）在每次发布时构建该镜像，检查健康检查、通过表单创建文章、正常停止以及数据库保留在卷上，并用 Kamal 加载 `config/deploy.yml`。

> [!NOTE]
> 这些部分如何组合，以及 Kamal 与 Caddy 之后的服务器的比较，见[部署页面](site:deploy.html)。

<!-- step + #things-to-know -->
## 须知

> [!WHY]
> 值得提前了解的限制和特殊之处，免得到时措手不及。

<!-- list: points know -->
- 会话只能保存 String，存放在加密的 cookie 中。
- 仅支持 SQLite，通过 Spinel 的 FFI 访问。
- 没有回溯（backtrace）：错误只显示类、消息、请求行以及模板名/行号。
- 视图中拼错的属性会抛出异常（`undefined method 'titel' for Article`）；值为 `nil` 的列则渲染为空。
- 关联来自外键或一行声明；不支持 `has_many :through`、枚举、STI 或多态关联。
- 不支持 `constraints` 或 `mount`；JSON 用 `render json:` 返回（没有 JSON 模板）。
- 在脚手架生成的模型中，只有第一个字符串字段会获得默认的存在性验证。
- 生成器对 `app/controllers`、`app/models`、`app/helpers`、`app/components` 和 `app/jobs` 使用词法扫描（正则表达式），而不是解析器。
- 作业至少运行一次；广播只会到达发送时打开着的页面，或在一分钟内重新连接的页面。
- 视图在构建时嵌入：即使只修改了视图，也需要运行 `cybertrain build` 并重启，改动才能到达生产环境。
- 在与运行机器相同的操作系统和 CPU 上构建 `dist/`：该二进制文件链接系统的 SQLite。
- `SPINEL_WORKERS` 默认为 `1`。
- 只测试过锁定版本的 Spinel（`Cybertrain::SPINEL_TAG`）。
- 更多与 Rails 的差异，汇总在一张表里：[与 Rails 的差异](how-it-works.md#differences-from-rails)。

<!-- step → #where-next -->
## 下一步

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — 本教程最终发展成的应用及其测试。
- [**部署**](site:deploy.html) — 构建好的应用如何在生产环境中运行：Kamal，或在 Caddy 之后用 systemd。
- [**认证**](authentication.md) — 密码重置、确认、锁定、保持登录、账户页面和管理员用户。
- [**国际化**](i18n.md) — 词典、`t` 和 `l`，以及每个请求的语言区域。
- [**指南**](index.md) — 每个主题一页：模型、请求、模板、实时、后台任务、测试。
- [**GitHub 上的 CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — 源代码、README 和发布版本。
- [**API 参考**](site:api/index.html) — 应用用到的每个类和方法，附带示例。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — 技术验证（spike）及其发现的编译器约束。
- [**Spinel**](https://github.com/matz/spinel) — matz 开发的 Ruby AOT 编译器。
- [**CyberTrain 首页**](site:index.html) — 概览、特性和工作原理。
