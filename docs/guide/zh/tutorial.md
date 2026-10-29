---
source_sha256: d691894e4f45f3ee5fb2e51331b94c5dffa04f59d9509ebc3a0aab1fc31b4053
path: tutorial.html
title: "入门：博客"
description: "用 CyberTrain 构建 Rails 入门指南中的博客（带评论的文章）：生成脚手架、执行迁移、嵌套路由、用 Cybertrain::Test 测试，并用 cybertrain build 为部署而构建。"
og_title: "CyberTrain 入门：博客"
og_description: "对照 Rails 官方的入门指南：一个包含文章和评论的博客，在 Spinel 上用 CyberTrain 构建。"
og_image: tutorial.png
crumb: "教程"
nav: tutorial
toc_title: "步骤 00–15"
meta:
  - term: "你需要"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3 头文件（Spinel `2026.10.27.7020` 会自动为你安装）<a class="meta-link" href="#requirements">第 00 步</a>'
  - term: "从这里开始"
    text: "`gem install cybertrain`"
  - term: "最终得到"
    text: "`dist/blog`"
---

# 入门：博客

对照 Rails 官方的[入门指南](https://guides.rubyonrails.org/getting_started.html)：一个包含文章和评论的博客。你将为文章生成脚手架、添加验证、把评论嵌套在文章之下、编写一个在进程内驱动应用的测试、添加登录、附加一张上传的图片，并把应用构建到可部署的 `dist/` 目录中。完成后的应用就是 [`examples/blog`](../../examples/blog)，由 CI 在 Linux 和 macOS 上运行测试。


<!-- step 00 #requirements stage: 准备 · Ruby、`cc`、SQLite -->
## 环境要求

> [!WHY]
> CyberTrain 通过 Spinel 编译为 C，所以需要 C 工具链和 SQLite 头文件；`cybertrain` 命令是一个 gem，所以需要 Ruby。

<!-- list: checklist -->
- Ruby 3.2+ 和 RubyGems，仅供 `cybertrain` 命令使用；应用本身从不在 CRuby 上运行。在 Ruby 3.2 上，还需要 `gem install prism`。
- Spinel `2026.10.27.7020`，即 [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) 分支的一个版本，它先于上游收录了 CyberTrain 所需的修复；未在其他版本上测试。你无需手动安装：第一个需要它的命令会把该版本构建到 `~/.cybertrain` 中（需要几分钟，仅一次），除非 `PATH` 上已有该版本的 `spinel`。
- C 工具链（`cc`，或 `CC` 指定的编译器）和 `make`，以及 `git` 和 `curl`，用于构建 Spinel；Spinel 会把每个程序编译为 C。
- SQLite 3 和 zlib 头文件和库：Debian/Ubuntu 上为 `libsqlite3-dev` 和 `zlib1g-dev`；macOS 上随 Xcode 命令行工具提供。

`cybertrain doctor` 会检查以上所有内容。完整列表以及哪些是可选的：[环境要求](install.md#requirements)；Spinel 安装在哪里，以及如何使用另一份安装：[Spinel 是如何安装的](install.md#how-spinel-is-installed)。

> [!NOTE]
> 没有可以安装的机器？[在线试用](site:playground.html)会在 GitHub Codespace 中打开这个博客，第 02、03、04 和 07 步都已完成。

<!-- step 01 #install stage: 准备 · `cybertrain` CLI -->
## 安装 CLI

> [!WHY]
> `cybertrain` 命令用来创建应用、生成资源脚手架、执行迁移、启动服务和构建。

第一行从 RubyGems 安装它。其余几行是整个教程的概览；下面的步骤会逐条命令讲解。

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">终端 &mdash; 任意目录，之后在&nbsp;blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="代码：终端 &mdash; 任意目录，之后在 blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># 首次运行时安装 Spinel 2026.10.27.7020（需要几分钟）</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># 生产环境：dist/blog、dist/public/、dist/storage/、dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

[每条命令](install.md#the-cybertrain-command)及其选项，都列在安装指南中。

<!-- step 02 #new-app stage: 你编写 · `blog/` -->
## 创建应用

> [!WHY]
> 你会得到 Rails 的目录约定，外加三个 `bin/` 程序：`bin/blog.rb`（应用）、`bin/gen.rb`（生成器）和 `bin/db.rb`（开发时的迁移）。

```shell 终端 — 任意目录
cybertrain new blog
cd blog
```

`cybertrain new` 会写出应用，其 `spin.toml` 指向与 CLI 相匹配的版本：

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

然后它会确保 Spinel 已安装（第一次时，这意味着要把 Spinel `2026.10.27.7020` 构建到 `~/.cybertrain` 中：需要几分钟，仅一次；参见[第 00 步](#requirements)），并运行 `spin lock`（spin 会把框架拉取到其缓存 `~/.cache/spin/packages/` 中，并在 `spin.lock` 中锁定提交）和 `spin run gen`，就像 `rails new` 会运行 `bundle install` 一样，所以 `cybertrain server` 可以立即使用。最后它会打印接下来的步骤。框架的任何部分都不会被复制到应用中；请提交 `spin.toml` 和 `spin.lock`。

> [!NOTE]
> 如果 Spinel 或两个 `spin` 步骤之一失败，已写出的文件会保留，`new` 以状态码 1 退出，并打印排除原因后需要运行的命令（对于 Spinel：先运行 `cybertrain setup`，再在新目录中运行 `cybertrain spin lock && cybertrain spin run gen`）。`--skip-spin` 只写出文件；`--path DIR` 改为依赖本地检出的代码，`--git URL [--ref R]` 依赖位于 URL 的框架（分支或标签 R），`--version V` 则在 `cybertrain` 进入 `spin-index` 后依赖索引中的版本。

应用名使用小写字母、数字和 `_`，并以字母开头。生成的目录树：

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` 是应用唯一的入口，也就是 `spin build blog` 编译的程序：`./blog` 提供服务，`./blog migrate` 和 `./blog db status` 管理数据库。`bin/gen.rb` 运行生成器（`spin run gen`），`bin/db.rb` 在开发期间运行迁移器（`cybertrain db migrate` 会用到它，因为在第一次迁移生成 `gen/models/` 之前，`bin/blog.rb` 无法编译）。`gen/` 中已经有 `views.rb`，即已提交的、空的内嵌视图表。

`ApplicationController` 一开始是这样的，因此找不到记录时会通过 `rescue_from` 映射为 404：

```ruby app/controllers/application_controller.rb
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

<!-- step 03 #scaffold-article stage: 你编写 · `app/`, `db/migrate/` -->
## 生成文章脚手架

> [!WHY]
> 一条命令写出整套 CRUD，Rails 风格。

```shell 终端 — blog/
cybertrain generate scaffold article title:string body:text
```

它会写出一个迁移、一个模型、一个控制器和五个视图（`index`、`show`、`new`、`edit`、`_form`），并把 `resources :articles` 插入 `config/routes.rb`。字段类型有 `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime` 和 `references`；默认为 `string`。快速上手中的 `cybertrain g scaffold` 是同一条命令。

> [!NOTE]
> 已有文件永远不会被覆盖：每个文件都会报告为 `create`、`identical` 或 `exist`。

<!-- step 04 #root-route stage: 你编写 · `config/routes.rb` -->
## 设置根路由

> [!WHY]
> `/` 应当显示文章列表。

```ruby config/routes.rb
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

> [!NOTE]
> 路由在构建时读取：`spin run gen` 会把它们转换为 `gen/routes.rb`。`cybertrain server`、`cybertrain db migrate` 和 `cybertrain build` 会替你运行它。

<!-- step 05 #validations stage: 你编写 · `app/models/` -->
## 添加模型验证

> [!WHY]
> 与 Rails 指南一样，手动添加一个长度验证。

```ruby app/models/article.rb
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` 没有写超类：`Cybertrain::Model` 超类、列和查找方法都来自 `gen/models/article.rb`。保存失败时会报告诸如 “Title can't be blank” 和 “Body is too short (minimum is 10 characters)” 这样的消息。

<!-- step 06 #articles-controller stage: 你编写 · `app/controllers/` -->
## ArticlesController

> [!WHY]
> 完整的 CRUD，连强参数和“先 flash 再重定向”都是 Rails 风格的，只有两处是 Spinel 处处强制要求的。

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

> [!RULE] Spinel 规则：new_action
> ### `new_action`，而不是 `new`
>
> 名字恰好叫 `new` 的方法会遮蔽 `ArticlesController.new(ctx)`，而框架要用它来构造控制器。路由 `GET /articles/new` 仍然映射到这个方法；你只需重命名方法。视图仍然是 `new.html.erb`，`render :new` 也保持不变。

> [!RULE] Spinel 规则：回调
> ### 回调显式接收控制器
>
> 无法对存储的块使用 `instance_exec`，所以块形式的回调会以参数形式接收控制器（或记录）：写 `before_action { |c| c.do_thing }`，而不是 `before_action { do_thing }`。动作和回调都按字面名称调用，从不使用 `send`。

脚手架写出的完整控制器还包含 `index`、`show`、`edit`、`update` 和 `destroy`；上面的节选省略了它们。在 `index` 中写的是 `@articles = Article.all.to_a`：其中的 `.to_a` 是必需的。

> [!NOTE]
> 实例变量是通过对 `@ivar =` 的词法扫描找到的，所以新增实例变量后要重新运行 `cybertrain spin run gen`；开发服务器会替你完成这一步。

<!-- step 07 #run stage: 先构建时，后运行时 · `gen/` &rarr; `build/bin/blog` -->
## 生成、迁移、运行

> [!WHY]
> 把 schema 和路由转换成 `gen/`，创建 SQLite 数据库，启动服务器。

```shell 终端 — blog/
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000；修改 Ruby 后会重新构建，视图无需重新构建即可重新加载
```

`spin run gen` 读取 `db/schema.rb` 和 `config/routes.rb`，扫描 `app/` 并写入 `gen/`；`spin run db -- migrate` 执行 `db/migrate/*.rb` 并重写 `db/schema.rb`。顺序很重要：第一次 `spin run gen` 把新迁移放进 `gen/migrations.rb`（`bin/db.rb` 会 require 它），第二次则根据重写后的 `db/schema.rb` 构建模型。

`cybertrain server` 会打印它运行的每条 `spin` 命令，然后是应用的启动横幅。第一次启动需要编译应用，所以要花一些时间：

```text 输出 — cybertrain server
=> Booting cybertrain 0.3.1
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- 修改 schema、路由，或者控制器、模型的回调和实例变量之后，重新运行 `cybertrain spin run gen` 并提交 `gen/`。开发服务器会替你完成这一步。
- 用 `cybertrain server 4000`（或 `PORT=4000`）更改端口。
- `spin run db` 要求在参数前加上 `--`，`cybertrain db` 会替你加上；`cybertrain db status` 和其他数据库命令也是如此。

> [!RULE]
> ### 没有控制台
>
> `rails console` 没有对应的功能：Spinel 没有 `eval`。修改 Ruby 代码需要重新构建，开发时 `cybertrain server` 会替你完成（重新构建、停止、`execv`）。开发时视图在每次请求时从磁盘解析，所以修改视图无需重新构建；`cybertrain build` 会为生产环境把它们嵌入。

<!-- step 08 #scaffold-comment stage: 你编写 · `db/migrate/`, `app/` -->
## 生成评论脚手架

> [!WHY]
> `references` 类型会为你生成外键，关联正是由它推导出来的。

```shell 终端 — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # 脚手架已为 comments 表写好了迁移
```

`article:references` 会添加 `article_id` 列、索引和外键——这足以让 `Article`/`Comment` 获得关联；不需要写 `has_many`/`belongs_to`，`spin run gen` 会从外键中读出关联。生成的 schema：

```ruby db/schema.rb（节选）
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

脚手架会插入一行独立的 `resources :comments`，下一步会替换它。

> [!EXAMPLE] 删除带评论的文章
> ### 删除带评论的文章
>
> 关联只来自外键，并且 `dependent:` 尚未实现。示例添加了一个显式接收记录的 `before_destroy` 回调：
>
> ```ruby app/models/article.rb（节选）
>   # Rails' `has_many :comments, dependent: :destroy`: the foreign key
>   # would refuse to delete an article that still has comments.
>   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
> ```

<!-- step 09 #nested-routes stage: 你编写 · `config/routes.rb` -->
## 嵌套路由

> [!WHY]
> Rails 指南把评论嵌套在文章之下。

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

> [!RULE] Spinel 规则：显式接收 mapper
> ### 嵌套块显式接收 mapper
>
> 要写 `resources :articles do |articles|` 和 `articles.resources :comments`，而不是直接写 `resources :comments`。Spinel 的 `instance_eval` 蹦床（trampoline）只会为最外层的块重新绑定 `self`。

<!-- step 10 #comments-controller stage: 你编写 · `app/controllers/` -->
## CommentsController

> [!WHY]
> 只有两个动作可以访问，而父文章取自 URL（`params[:article_id]`），而不是 `:id`。

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

然后给评论模型添加验证：

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true
end
```

> [!NOTE]
> 这里的 `Article#comments` 是一个 Array，所以 Rails 的 `@article.comments.find(params[:id])` 要写成 `Comment.where(article_id: @article.id).find(params[:id])`。不属于该文章的评论会返回 404。

<!-- step 11 #views stage: 运行时 · `app/views/`，开发时从磁盘读取，由 `cybertrain build` 嵌入 -->
## 视图与局部视图

> [!WHY]
> 文章页面列出它的评论，并在末尾放一个绑定到 `[@article, @comment]` 的表单。

首先，删除现在已无法访问的评论视图 `index`、`show`、`new` 和 `edit`，并在 `ArticlesController#show` 中提供一个空白的 `@comment`：

```ruby app/controllers/articles_controller.rb（节选）
  def show
    @comment = Comment.new
  end
```

然后在文章页面上渲染评论和表单：

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

评论的局部视图，与示例中的一致：

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

`button_to ... [@article, comment]` 和 `form_with(model: [@article, @comment])` 都通过同一条 `[parent, child]` 规则解析：新的子对象路由到嵌套集合（`article_comments_path`），已持久化的子对象路由到嵌套成员（`article_comment_path`）——这些路由都由上面的嵌套 `resources` 块生成到 `gen/routes.rb` 中。

> [!RULE] 视图是一套封闭的语法
> ### 视图是一套封闭的语法，而不是 Ruby
>
> Spinel 没有 `eval`，所以模板按照一套固定的语法来解释执行。`link_to` 没有 `method:` 选项；请使用 `button_to`。`each` 接受一个或两个块参数。像 `<%# locals: (comment:) %>` 这样的严格局部变量注释不能带默认值。局部视图会得到调用方环境的一份副本，所以在 `comments/_form` 中可以看到 `@article`。

<!-- step 12 #test stage: 构建时 · `cybertrain spin test` -->
## 测试

> [!WHY]
> minitest 和 RSpec 通过反射查找测试，而 AOT 编译器做不到这一点，因此 CyberTrain 提供了 `Cybertrain::Test`。

### 模型测试

```ruby test/articles.rb（片段）
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

断言：`assert`、`refute`、`assert_equal`、`assert_nil`、`assert_includes`、`assert_raises("Class") { }`、`flunk`。示例中还用到了 `assert_response` 和 `assert_redirected_to`。

### 完整的 HTTP 流程

```ruby test/articles.rb（片段）
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

`Cybertrain::Test::Client` 在进程内（不经过 socket）驱动应用，并带有 cookie jar，所以会话和 CSRF 的行为与在浏览器中一致。不带令牌的请求会得到 403。

> [!COMPILE] 片段中省略的内容
> ### 片段中省略的内容
>
> - `support/blog_test` 就是 [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb)：把它复制到你的应用的 `test/support/` 中，这里的文件会被 require，而不会被运行。它会迁移一个全新的 `storage/test.sqlite3`，以 `BLOG` 启动应用，加载 `Cybertrain::Test` 及其客户端，并提供 `BlogTest.form_token`（最近渲染的表单中的 CSRF 令牌）和 `BlogTest.article_path`。
> - 在文件末尾调用 `Cybertrain::Test.run!`，它会运行测试，并打印快照所比对的各行输出。
> - 在 `config/app.rb` 中设置 `c.log_level = :none if c.test?`，让请求日志不进入被比对的输出。

### 运行测试

```shell 终端 — blog/
cybertrain spin test
```

`cybertrain spin test` 用锁定版本的 Spinel 运行 `spin test`；如果工具链已在 `PATH` 上（[第 00 步](#requirements)），直接运行 `spin test` 效果相同。它会把每个 `test/*.rb` 编译成独立的程序，并将其输出（stdout 和 stderr 合在一起）与已提交的快照 `test/<name>.rb.expected` 进行比对。`test/support/` 中的文件会被 require，而不会被运行。要写入快照：

```shell 终端 — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` 根据 CRuby 的输出写入快照。通过 FFI 访问 SQLite 的测试无法在 CRuby 下运行，所以它们的快照来自编译后的二进制文件（上面的第二行）。只要快照过时，`cybertrain spin test` 就会以非零状态退出，所以它后面跟的是 `;` 而不是 `&&`；`[ -x ]` 检查会在编译失败时跳过捕获，从而保留旧快照。无法在 CRuby 下运行的测试需要先有这个快照，`cybertrain spin test` 才能通过；其他没有快照的测试会与 CRuby 的输出进行比对。

<!-- step 13 #authentication stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加登录

> [!WHY]
> 到目前为止，任何人都能编辑或删除文章。和 Rails 8 的 `bin/rails generate authentication` 一样，一条命令就能加上用邮箱和密码登录的功能，而且写成归应用所有的代码，而不是作为引擎安装。

```shell 终端 — blog/
cybertrain generate authentication
cybertrain db migrate    # 创建 users 和 sessions 表
```

它会写出 `users`（`email_address`、`password_digest`、唯一索引）和 `sessions`（每个已登录的浏览器一行）的迁移，`User` 和 `Session` 模型，`SessionsController`（`/session/new`、`POST /session`、`DELETE /session`）和 `RegistrationsController`（`/sign_up`）及其视图，在布局顶部渲染的 `sessions/_nav` 局部模板，以及 `test/authentication.rb` 和 `test/support/app_test.rb`。它还会插入路由，并在 `ApplicationController` 的类定义行之后插入下面这段代码：

```ruby app/controllers/application_controller.rb（节选）
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
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
  <%= render "comments/form" %>
<% end %>
```

启动服务器并打开 `http://127.0.0.1:3000/sign_up`，创建第一个用户。Rails 的生成器没有注册页面，第一个用户要在控制台里创建；CyberTrain 没有控制台，所以会写出 `RegistrationsController`。如果应用只接受邀请，请删除它及其路由。

<details><summary>只接受邀请的应用：`--invite-only` — 没有注册页面；第一个用户来自命令行，或来自只有服务器所在机器才能打开的页面</summary>

注册页面让任何能访问到服务器的人都能注册，这对内部工具来说是错误的默认设置：谁比管理员先到，谁就有了账号。`--invite-only` 不会写出 `RegistrationsController`，也没有注册链接；第一个用户来自命令行，或来自只有服务器自己的机器才能打开的页面，页面的链接由服务器在启动时打印出来：

```shell 终端 — blog/
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # 然后在同一台机器上打开它打印的 http://127.0.0.1:3000/setup?token=... 链接
```

在生产环境中，在二进制运行的目录里：

```shell 终端 — 生产主机
./blog user ann@example.com                        # 从标准输入读取密码（一行）
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user ann@example.com 's3cr3t-s3cr3t'        # 或者作为参数传入（在 ps 中可见）
```

<!-- list: points -->
- `app/commands/user_command.rb` 用 `Cybertrain::Main.command` 注册 `user` 命令（所以 `./blog help` 会列出它），并由 `bin/blog.rb` require。`EMAIL [PASSWORD]` 会创建用户，或者为使用该地址的用户设置密码（和任何密码修改一样，这会让该用户的浏览器退出登录）；它会打印 `created ADDRESS` 或 `updated ADDRESS` 并以 0 退出。不带 `PASSWORD` 时，它从标准输入读取一行（标准输入是终端时会给出提示；输入的内容会回显），并去掉末尾的换行符，这样密码就不会出现在 `ps` 和 shell 历史中。空密码、无法通过验证的记录（不足 8 个字符的密码）或错误的参数，会打印错误或用法说明并以 1 退出。
- `SetupController`（`GET`/`POST /setup`、`app/views/setup/new.html.erb`）创建第一个用户并让其登录。它只在还没有任何用户时、只在带有一次性令牌（见下文）时、并且只对套接字对端是环回地址（`request.loopback?`：`127.0.0.0/8` 或 `::1`）且不带 `X-Forwarded-For` 请求头的连接作出响应（同一主机上的代理会让每个请求都成为来自环回地址的请求，而代理会加上这个请求头）。请求头只能关闭这个页面，永远不能打开它。其他所有人，以及缺少令牌或令牌错误的请求，都会得到 404。
- 令牌：`SetupController::SETUP_TOKEN`，32 个随机十六进制字符（`Cybertrain::Crypto.random_token(16)`），在程序启动时生成并一直保留到程序退出，所以重启后会换成新的。`GET /setup` 通过 `?token=` 接收它，表单在隐藏字段里把它带回来，两者都以恒定时间比较（`Cybertrain::Crypto.secure_compare`）。地址检查失效时，正是它让页面保持关闭：同一主机上不添加 `X-Forwarded-For` 的代理（没有 `proxy_set_header X-Forwarded-For ...` 的 nginx）会让每个客户端看起来都来自环回地址，而只有能读取服务器日志的人才拿得到令牌。请求日志不会重复它：`token` 属于默认的 `filter_parameters`，所以这一行写作 `Started GET "/setup?token=[FILTERED]"`（除非 `config.filter_parameters` 或 `CYBERTRAIN_FILTER_PARAMETERS` 去掉了 `token`）。一旦用户已存在，令牌就打不开任何东西。
- 如果首次运行时位于另一台主机上的代理之后，`BLOG_SETUP_OPEN=1`（在 `config/app.rb` 中用 `c.setting_bool :setup_open` 声明）会取消地址检查，但仍然只在还没有用户时、仍然只在带有令牌时有效。用户创建之后请取消这个设置。
- 还没有任何用户时，服务器会在启动前记录 `[WARN] no user exists yet: run ./blog user EMAIL, or open /setup?token=<token> from this machine`（`UserCommand.warn_if_no_user`，在 `Cybertrain::Main.server?(ARGV)` 时由 `bin/blog.rb` 调用；它只为这一次查询连接数据库，users 表尚未迁移时什么也不输出）。这一行是唯一打印令牌的地方。

生成的 `test/authentication.rb` 对这两者都做了测试：带令牌、不带令牌（`SetupController.setup_token`）或带错误令牌访问 `/setup`，从另一个地址（`client.peer_address = "203.0.113.7"`）、经过代理、在用户已存在时以及打开开关时访问，以及通过 `Cybertrain::Main.run` 在进程内运行 `user` 命令。这些全部是应用代码，可以随意修改（docs/design.md D29）；框架只提供 `request.loopback?`、`Main.command`、`Main.server?`、`Crypto.random_token` / `Crypto.secure_compare` 以及测试客户端的 `peer_address`。

</details>

> [!RULE] Spinel 规则：has_secure_password
> ### `has_secure_password` 被逐一写出
>
> Spinel 无法在运行时定义方法，所以 `User` 模型直接写出了 `has_secure_password` 本该定义的方法：`password=`、`authenticate` 和 `User.authenticate_by(email_address:, password:)`。密码由 `Cybertrain::Password` 做哈希：它是用 Ruby 实现的 PBKDF2-HMAC-SHA256，默认迭代 10 万次（编译后约 0.2 秒）；bcrypt 则需要让二进制链接一个 C 库。可以在 `config/app.rb` 里用 `Cybertrain::Password.iterations = 600_000` 提高成本，`User#authenticate` 会在每个用户登录时重新计算哈希。

<details><summary>认证：框架提供了什么 — 生成器所用的各个部件，不用生成器也能使用</summary>

上面的生成器写出了整个流程；它所用的部件是框架 API，不用生成器也能使用（用于 API 令牌、管理员密码、手写的登录）：

<!-- list: points -->
- **`Cybertrain::Password`**：`hash(plain)` 生成加盐的 PBKDF2-HMAC-SHA256 摘要，摘要中记录了自身的参数（`$pbkdf2-sha256$i=100000$salt$key`）；`verify?(plain, digest)` 以恒定时间校验，遇到格式错误的摘要也不会抛出异常；`needs_rehash?(digest)` 判断摘要是否落后于当前的 `Password.iterations`。用于登录动作的有：
  - `verify_serialized(plain, digest)` 是每个进程一次只执行一个的 `verify?`（一个 Mutex）。一次哈希大约耗费 0.2 秒 CPU；一批同时到来的尝试会占住所有 worker，而通过这个方法它们会排队，其他 worker 继续提供页面。
  - `dummy_digest` 是一个随机密码的摘要，每个进程按当前成本生成一次。地址不存在时就用它来校验，这样响应时间就不会暴露哪些地址有账号：`Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)`。
  - `session_key(digest)` 是密码摘要在 `secret_key_base` 下的 HMAC；登录时把它存进会话，并在每个请求中用 `session_key_matches?(session[:password_key], user.password_digest)` 检查。修改密码会生成新的摘要，所以在此之前开始的所有会话都会退出登录。
  - 当 `Cybertrain.config.test?` 时，`iterations` 为 `Password::TEST_ITERATIONS`（1,000），这样测试套件不必为每个用户付出生产环境的成本；摘要记录了各自的迭代次数，所以其他一切都不变。
- **会话**（`session[:key]`，一个签名 cookie）：`clear` 在退出登录时清空会话（包括 CSRF 令牌）；`config.session_absolute_max_age`（两周；`0` 表示关闭）限制会话的整个生命期，无论使用得多频繁：cookie 记录了它首次写入的时间，比这更旧的 cookie 会被加载为空会话，因此复制来的 cookie 无法被永远重放。`session.restart_lifetime!` 会重新开始计时（在登录时）。
- **`Controller#local_path?(text)` 和 `safe_redirect_path(text, fallback)`**：来自请求的路径（`return_to` 参数、记住的页面）只有在以 `/` 开头但不以 `//` 或 `/\` 开头、只包含可打印的 ASCII 字符且不超过 2,048 字节时，才会被重定向过去：`redirect_to safe_redirect_path(params[:return_to], "/"), status: :see_other`。
- 控制器类上的 **`skip_before_action(name, only:, except:)`** 会为部分动作去掉继承来的 `before_action`；生成的 `allow_unauthenticated_access` 就是对它的一行封装。
- **`cybertrain generate authentication`** 以归应用所有的代码写出：`users` 和 `sessions` 的迁移与模型、`SessionsController`、`RegistrationsController`、它们的视图和导航局部模板、`ApplicationController` 中的代码块（`resume_session`、`require_authentication`、`start_new_session_for`、`terminate_session`、`after_authentication_url`）以及 `test/authentication.rb`。这些代码用到了本列表中的全部内容：`User.authenticate_by` 用 `verify_serialized` 和虚拟摘要来校验，`start_new_session_for` 存储密码密钥并重新开始生命期，`resume_session` 会结束密钥不再匹配或比 `session_absolute_max_age` 更旧的 Session 行，`after_authentication_url` 就是 `safe_redirect_path`。若要让修改了密码的那个浏览器保持登录，在保存之后存入新的密钥：`session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`。设计说明：[docs/design.md](../design.md) D25。

</details>

### 更新测试

[步骤 12](#test) 中期望出现表单、提交表单，或访问 `index` 和 `show` 以外动作的测试，现在都会遇到登录页面。先用生成器写进 `test/support/app_test.rb` 的辅助方法让客户端登录：

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
> 和[步骤 12](#test) 一样用 `cybertrain spin test` 运行。`test/authentication.rb` 和这个测试会用到 SQLite，所以它们的快照来自编译后的二进制。`examples/blog` 止步于这一步之前。登录尝试会像 Rails 的生成器那样受到速率限制：`SessionsController` 声明了 `rate_limit to: 10, within: 3 * 60, only: [:create]`，每个客户端地址每三分钟最多 10 次，超过后会带着 "Try again later." 回到表单，直到时间窗口结束。在反向代理后面，除非配置了[受信任的代理](requests.md#rate-limiting-and-the-client-address)，否则每位访客都按代理的地址计数。不会生成的部分：密码重置，它的邮件需要应用自己的 SMTP 设置（`Cybertrain::Mailer`，[发送电子邮件](external-services.md#sending-e-mail)），而生成器无从得知这些设置。

<!-- step 14 #attachments stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加封面图片

> [!WHY]
> 文章可以带一张图片。分工和登录一样：框架负责解析 `multipart/form-data` 并保存字节，其余部分由一条命令写成归应用所有的代码，以此取代 Active Storage 的 `has_one_attached`。

```shell 终端 — blog/
cybertrain generate attachment article cover   # 新模型则用：generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # 给 articles 添加 cover_* 列
```

它会写出一个迁移，为 `articles` 添加五列（`cover_key`, `cover_filename`, `cover_content_type`, `cover_byte_size`, `cover_checksum`；文件本身不在 SQLite 中），并在 `Article` 中写出一个代码块，包含 `cover_file=`、`cover_attached?`、`cover_url`、一个验证，以及保存和销毁回调。在 `ArticlesController` 中，它添加一个由 `before_action :set_article` 保护的 `cover` 动作，并在 `create` 和 `update` 中各加一行：

```ruby app/controllers/articles_controller.rb （节选）
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

步骤 13 让每个页面都变成私有的，而公开文章页面上的图片是从 `/articles/1/cover` 获取的。生成器让下载与文章页面完全同样公开：由于 `allow_unauthenticated_access` 列出了 `:show`，它会像上面第一行那样把 `:cover` 加到这个列表中，这样可以阅读文章的访客也能看到图片。如果文章页面需要登录，下载也同样需要。`set_article` 中用来限制用户能看到哪些文章的任何做法，同样会限制下载。

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

> [!RULE] Spinel 规则：has_one_attached
> ### `has_one_attached` 被逐一写出
>
> Spinel 无法在运行时定义方法（没有 `define_method`），所以没有 `has_one_attached`，也没有共享的附件表。生成器把它本会定义的东西逐一写出，成为以字段命名的方法，放在 `Article` 中，并把元数据放进 `articles` 的五个列里。这些列都是 `NOT NULL`，用 `""` 和 `0` 表示“没有附件”：可为空的列会让 Spinel 失去类型推断。SQLite 只保存元数据（文本值遇到 NUL 字节就会截断）；字节保存在文件里。

### 文件如何提供

<!-- list: points -->
- **类型。** 默认只接受不超过 2 MB 的 PNG、JPEG、GIF 和 WebP（`COVER_TYPES` and `COVER_MAX_BYTES` 在模型中；`--any` 则接受任何类型）。类型由文件的前几个字节检测，绝不采用浏览器给出的值。
- **存储。** 字节保存到 `storage/uploads/<2 hex>/<32 hex key>`（`Cybertrain::BlobStore`，权限 0600）。替换文件会删除旧文件，销毁文章会删除它的文件。请把 `storage/uploads/` 和 SQLite 文件一起备份。
- **提供。** 文件通过控制器中的 `send_blob` 发出，绝不从 `public/` 提供。四种图片类型内联显示；其他类型一律作为下载（`application/octet-stream`）。每个响应都带有 `X-Content-Type-Options: nosniff` 和 `Content-Security-Policy: default-src 'none'; sandbox`。
- **参数。** `params.nested(:article).upload(:cover)` 是一个 `Cybertrain::UploadedFile`，没有选择文件时为 nil。`permit` 从不返回文件，所以文件只能通过那一行显式的代码进入。CSRF 令牌和普通表单一样，从 multipart 请求体中读取。损坏或过大的请求体会得到 400；限制由 `config/app.rb` 中的 `max_upload_bytes` 和 `max_multipart_parts` 设置，存放目录由 `upload_root` 设置。

启动服务器，编辑一篇文章并选择一张图片。生成器还写了 `test/attachment_article_cover.rb`，它测试整个流程，并且因为应用现在有了 `User`，会先登录。由于这里的 `:cover` 是公开的，它会检查访客能否下载封面；正文则填入 `"A article."`，长度补足到 [步骤 05](#validations) 要求的至少 10 个字符。

> [!NOTE]
> 和[步骤 12](#test) 一样用 `cybertrain spin test` 运行；这个测试会用到 SQLite，所以它的快照来自编译后的二进制。`examples/blog` 止步于这一步之前。尚未实现：每个字段多个文件、S3 或其他远程存储、图片变体，以及把大请求体流式写入磁盘（整个请求体会读入内存，上限为 `max_body_bytes`）。

<!-- step 15 #ship stage: 运行时 · `dist/blog` -->
## 为部署而构建

> [!WHY]
> 一条命令就能把应用构建到可部署的 `dist/` 目录中，所有视图都已嵌入。

```shell 终端 — blog/
cybertrain build
```

这会写出 `dist/`：嵌入了所有视图的应用二进制文件，以及放在它旁边、供它使用的文件。它会运行 `spin run gen -- --embed-views`、`spin build blog` 和 `spin run gen`（最后这一步会恢复已提交的、空的 `gen/views.rb`，即使在失败或按下 Ctrl-C 之后也是如此），然后组装出：

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>编译后的框架、控制器、模型和模板解释器，并嵌入了所有视图</span></li>
  <li><code>dist/public/</code><span>静态资源和错误页面，也可以交给反向代理来提供</span></li>
  <li><code>dist/storage/</code><span>创建时为空；默认存放 SQLite 文件（重新构建永远不会清空它）</span></li>
  <li><code>dist/tmp/</code><span>创建时为空（重新构建永远不会清空它）</span></li>
</ul>

把 `dist/` 复制到操作系统和 CPU 都相同的机器上（该二进制文件链接系统的 SQLite），然后在那里运行。构建出的二进制文件默认使用生产环境（可用 `CYBERTRAIN_ENV` 覆盖）。设置 `CYBERTRAIN_SECRET_KEY_BASE`；示例如下：

```shell 终端 — 生产主机
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` 执行编译进二进制文件的迁移，`./blog db status` 显示它们的状态；`PORT` 设置端口。重启前后请保持密钥不变：更改它会使所有会话失效。

`Cybertrain::Config` 首先读取环境变量；`config/app.rb` 中的设置会覆盖它们：

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
- 服务器使用纯 HTTP/1.1：如需 TLS 和 HTTP/2，请在前面放 nginx 或 Caddy。生产环境中会话 cookie 带有 `Secure`，所以要通过 HTTPS 提供服务（仅当生产环境确实使用纯 http 时，才在 `config/app.rb` 中设置 `c.session_secure = false`）。
- 没有 `CYBERTRAIN_SECRET_KEY_BASE` 时，生产环境会拒绝启动。
- 在生产环境中，异常会返回 500；而裸错误响应（路由器的纯文本 404、`head :not_found`、`render plain:`）在 `public/<status>.html` 存在时会被该文件替换；`cybertrain new` 会写出 `404.html` 和 `500.html`。
- `SIGTERM` 会让服务器停止接受新连接，让正在处理的请求完成，并在它们完成后退出，或在服务器的 `drain_timeout`（10 秒）之后退出。
- 监视器和重新构建循环永远不会在生产环境中运行。正在运行的 `cybertrain server` 会在 `cybertrain build` 持有 `tmp/cybertrain-build.lock` 期间跳过重新构建。

`cybertrain new` 还会写出一套 [Kamal 2](https://kamal-deploy.org) 配置。`Dockerfile` 在 Ubuntu 构建阶段运行 `cybertrain setup` 和 `cybertrain build`，再把 `dist/` 复制到同一发行版的精简阶段；该镜像启动时先执行迁移，然后在 `0.0.0.0:3000` 上提供服务。此外还有 `.dockerignore`、`config/deploy.yml`（前端是带 Let&rsquo;s Encrypt 的 kamal-proxy，健康检查使用 `public/up.html`，SQLite 文件放在挂载于 `/app/storage` 的卷上），以及从环境变量读取 `KAMAL_REGISTRY_PASSWORD` 和 `CYBERTRAIN_SECRET_KEY_BASE` 的 `.kamal/secrets`。填好 `config/deploy.yml` 中标为 `CHANGE ME` 的值，提交，然后运行：

```shell 终端 — blog/
kamal setup    # 首次：在服务器上安装 Docker 和 kamal-proxy，构建、推送并启动
kamal deploy   # 之后的每次部署
```

二进制文件在镜像内编译，因此操作系统总与镜像一致；请把 `config/deploy.yml` 中的 `builder.arch` 设为服务器的 CPU 架构。只部署到一台服务器：数据库是该服务器卷上的一个 SQLite 文件。[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする)（日文；英文版见 [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)）第 8 部分完整介绍了这一流程，包括备份。

完成的应用 [`examples/blog`](../../examples/blog#deploying-with-kamal) 也带有这套配置，只有一处不同：它针对仓库中的框架构建（其 `spin.toml` 中的 `path = "../.."`），因此它的 `Dockerfile` 不安装 gem，而是从检出目录运行 `cybertrain setup` 和 `cybertrain build`，构建上下文是仓库根目录（`builder.context: ../..`，由 `Dockerfile.dockerignore` 只发送框架和应用）。CI（[`blog-image.yml`](../../.github/workflows/blog-image.yml)）在每次变更时构建该镜像，检查健康检查、通过表单创建文章、正常停止以及数据库保留在卷上，并用 Kamal 加载 `config/deploy.yml`。

> [!NOTE]
> 这些部分如何组合，以及 Kamal 与 Caddy 之后的服务器的比较，见[部署页面](site:deploy.html)。

<!-- step + #things-to-know -->
## 须知

> [!WHY]
> 值得提前了解的限制和特殊之处，免得到时措手不及。

<!-- list: points know -->
- 会话只能保存 String，存放在 HMAC 签名的 cookie 中。
- 仅支持 SQLite，通过 Spinel 的 FFI 访问。
- 没有回溯（backtrace）：错误只显示类、消息、请求行以及模板名/行号。
- 视图中拼错的属性会渲染为空白，而不会抛出异常；这是一个已知的不足。
- 关联只来自 schema 中的外键；不支持 `has_many :through`、`includes`、`pluck`、`dependent:`、枚举、STI 或多态关联。
- 不支持 `namespace`、`respond_to`/格式、`constraints` 或 `mount`；`render json:` 只有最基本的功能。
- 在脚手架生成的模型中，只有第一个字符串字段会获得默认的存在性验证。
- 生成器对 `app/controllers` 和 `app/models` 使用词法扫描（正则表达式），而不是解析器。
- 视图在构建时嵌入：即使只修改了视图，也需要运行 `cybertrain build` 并重启，改动才能到达生产环境。
- 在与运行机器相同的操作系统和 CPU 上构建 `dist/`：该二进制文件链接系统的 SQLite。
- `SPINEL_WORKERS` 默认为 `1`。
- 只测试过 Spinel `2026.10.27.7020`。
- 更多与 Rails 的差异，汇总在一张表里：[与 Rails 的差异](how-it-works.md#differences-from-rails)。

<!-- step → #where-next -->
## 下一步

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — 完成后的应用及其测试。
- [**GitHub 上的 CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — 源代码、README 和发布版本。
- [**API 参考**](site:api/index.html) — 应用用到的每个类和方法，附带示例。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — 技术验证（spike）及其发现的编译器约束。
- [**Spinel**](https://github.com/matz/spinel) — matz 开发的 Ruby AOT 编译器。
- [**CyberTrain 首页**](site:index.html) — 概览、特性和工作原理。
