---
source_sha256: e0f7dae3450486201886a4688b71a1c63ca141e8116bfa1cb85f665869af0353
path: tutorial.html
title: "入门：博客"
description: "用 CyberTrain 构建 Rails 入门指南中的博客（带评论的文章）：生成脚手架、执行迁移、嵌套路由、用 Turbo 实时推送评论、把作业加入队列、用 Cybertrain::Test 测试，并用 cybertrain build 为部署而构建。"
og_title: "CyberTrain 入门：博客"
og_description: "对照 Rails 官方的入门指南：一个包含文章和评论的博客，在 Spinel 上用 CyberTrain 构建。"
og_image: tutorial.png
crumb: "教程"
nav: tutorial
toc_title: "步骤 00–19"
meta:
  - term: "你需要"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3、zlib 和 OpenSSL 头文件（Spinel 会自动为你安装）<a class="meta-link" href="#requirements">第 00 步</a>'
  - term: "从这里开始"
    text: "`gem install cybertrain`"
  - term: "最终得到"
    text: "`dist/blog`"
---

# 入门：博客

对照 Rails 官方的[入门指南](https://guides.rubyonrails.org/getting_started.html)：一个包含文章和评论的博客。你将为文章生成脚手架、添加验证、把评论嵌套在文章之下、用 Turbo 把新评论推送到每个打开的页面、把一个后台作业加入队列、返回 JSON、编写在进程内驱动应用的测试、添加登录、附加一张上传的图片，并把应用构建到可部署的 `dist/` 目录中。这个应用最终会发展成 [`examples/blog`](../../examples/blog)，由 CI 在 Linux 和 macOS 上运行测试。


<!-- step 00 #requirements stage: 准备 · Ruby、`cc`、SQLite -->
## 环境要求

> [!WHY]
> CyberTrain 通过 Spinel 编译为 C，所以需要 C 工具链和 SQLite 头文件；`cybertrain` 命令是一个 gem，所以需要 Ruby。

<!-- list: checklist -->
- Ruby 3.2+ 和 RubyGems，仅供 `cybertrain` 命令使用；应用本身从不在 CRuby 上运行。在 Ruby 3.2 上，还需要 `gem install prism`。
- Spinel，版本为 CyberTrain 锁定的版本（`cybertrain doctor` 会打印它），即 [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) 分支的一个版本，它先于上游收录了 CyberTrain 所需的修复；未在其他版本上测试。你无需手动安装：第一个需要它的命令会把该版本构建到 `~/.cybertrain` 中（需要几分钟，仅一次），除非 `PATH` 上已有该版本的 `spinel`。
- C 工具链（`cc`，或 `CC` 指定的编译器）和 `make`，以及 `git` 和 `curl`，用于构建 Spinel；Spinel 会把每个程序编译为 C。
- SQLite 3、zlib 和 OpenSSL 的头文件和库：Debian/Ubuntu 上为 `libsqlite3-dev`、`zlib1g-dev` 和 `libssl-dev`。在 macOS 上，SQLite 和 zlib 随 Xcode 命令行工具提供，OpenSSL 则来自 Homebrew（`brew install openssl@3`，再设置[环境要求](install.md#requirements)给出的两个路径）。

`cybertrain doctor` 会检查以上所有内容，并为缺少的部分打印安装命令。完整列表以及哪些是可选的：[环境要求](install.md#requirements)；Spinel 安装在哪里，以及如何使用另一份安装：[Spinel 是如何安装的](install.md#how-spinel-is-installed)。

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
<span class="ln cmd">cybertrain new blog          <span class="c"># 首次运行时安装 Spinel（需要几分钟）</span></span>
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

`cybertrain new` 会写出应用，其 `spin.toml` 指向与 CLI 相匹配的版本（X.Y.Z 即 `cybertrain version` 打印的版本）：

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }
```

然后它会确保 Spinel 已安装（第一次时，这意味着要把锁定版本的 Spinel 构建到 `~/.cybertrain` 中：需要几分钟，仅一次；参见[第 00 步](#requirements)），并运行 `spin lock`（spin 会把框架拉取到其缓存 `~/.cache/spin/packages/` 中，并在 `spin.lock` 中锁定提交）和 `SPIN_DEBUG=1 spin run gen`（以 spin 的调试模式构建 gen），就像 `rails new` 会运行 `bundle install` 一样，所以 `cybertrain server` 可以立即使用。最后它会打印接下来的步骤。框架的任何部分都不会被复制到应用中；请提交 `spin.toml` 和 `spin.lock`。

> [!NOTE]
> 如果 Spinel 或两个 `spin` 步骤之一失败，已写出的文件会保留，`new` 以状态码 1 退出，并打印排除原因后需要运行的命令（对于 Spinel：先运行 `cybertrain setup`，再在新目录中运行 `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen`）。`--skip-spin` 只写出文件；`--path DIR` 改为依赖本地检出的代码，`--git URL [--ref R]` 依赖位于 URL 的框架（分支或标签 R），`--version V` 则在 `cybertrain` 进入 `spin-index` 后依赖索引中的版本。

应用名使用小写字母、数字和 `_`，并以字母开头。生成的目录树：

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

`bin/blog.rb` 是应用唯一的入口，也就是 `spin build blog` 编译的程序：`./blog` 提供服务，`./blog migrate` 和 `./blog db status` 管理数据库。`bin/gen.rb` 运行生成器（`spin run gen`），`bin/db.rb` 在开发期间运行迁移器（`cybertrain db migrate` 会用到它，因为在第一次迁移生成 `gen/models/` 之前，`bin/blog.rb` 无法编译）。`gen/` 中已经有 `spin run gen` 写出的内容，其中包括 `views.rb`：已提交的、空的内嵌视图表。

布局用 `stylesheet_link_tag` 引入 `app/assets/stylesheets/application.css`，并用 `javascript_importmap_tags` 通过 `config/importmap.rb` 的 import map 加载 `app/javascript/application.js`；`spin run gen` 把两者加上摘要写入 `public/assets/`，该目录被 git 忽略（参见[资源](assets.md)）。`.env.example` 列出应用读取的变量，`.github/workflows/ci.yml` 在 GitHub 上运行测试（[持续集成](testing.md#continuous-integration)），目录树的最后一行则是[第 19 步](#ship)的 Kamal 配置。

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

它会写出一个迁移、一个模型、一个控制器和五个视图（`index`、`show`、`new`、`edit`、`_form`），并把 `resources :articles` 插入 `config/routes.rb`。字段类型有 `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime`、`references` 和 `attachment`（上传的文件，见[第 18 步](#attachments)）；默认为 `string`。快速上手中的 `cybertrain g scaffold` 是同一条命令。

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
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` 没有写超类：`Cybertrain::Model` 超类、列和查找方法都来自 `gen/models/article.rb`。保存失败时会报告诸如 “Title can't be blank”、“Title has already been taken” 和 “Body is too short (minimum is 10 characters)” 这样的消息。其他校验器（`format`、`inclusion`、`numericality` 等）见[校验](models.md#validations)。

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
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen（gen 和 db 为调试模式）
cybertrain server        # http://127.0.0.1:3000；修改 Ruby 后会重新构建，视图无需重新构建即可重新加载
```

`spin run gen` 读取 `db/schema.rb` 和 `config/routes.rb`，扫描 `app/` 并写入 `gen/`；`spin run db -- migrate` 执行 `db/migrate/*.rb` 并重写 `db/schema.rb`。顺序很重要：第一次 `spin run gen` 把新迁移放进 `gen/migrations.rb`（`bin/db.rb` 会 require 它），第二次则根据重写后的 `db/schema.rb` 构建模型。

`cybertrain server` 会打印它运行的每条 `spin` 命令，然后是应用的启动横幅。第一次启动需要编译应用，所以要花一些时间：

```text 输出 — cybertrain server
=> Booting cybertrain X.Y.Z
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- 修改 schema、路由，控制器或模型的回调和实例变量，辅助方法、组件或作业，或者某个资源之后，重新运行 `cybertrain spin run gen` 并提交 `gen/`。开发服务器会替你完成这一步，而 `cybertrain spin run gen -- --check` 只列出哪些内容已经过时，不写入任何东西。
- 用 `cybertrain server 4000`（或 `PORT=4000`）更改端口。
- `spin run db` 要求在参数前加上 `--`，`cybertrain db` 会替你加上；`cybertrain db status` 和其他数据库命令也是如此。

> [!RULE]
> ### 控制台不是 Ruby
>
> `rails console` 没有完全对应的功能：Spinel 没有 `eval`。`cybertrain spin run blog -- console`（构建之后为 `./blog console`）在模型上求值模板表达式，例如 `Article.where(title: "x").count`，而 `dbconsole` 打开 `sqlite3`（[控制台](background-and-operations.md#the-console)）。修改 Ruby 代码需要重新构建，开发时 `cybertrain server` 会替你完成（重新构建、停止、`execv`）。开发时视图在每次请求时从磁盘解析，所以修改视图无需重新构建；`cybertrain build` 会为生产环境把它们嵌入。

<!-- step 08 #scaffold-comment stage: 你编写 · `db/migrate/`, `app/` -->
## 生成评论脚手架

> [!WHY]
> `references` 类型会为你生成外键，关联正是由它推导出来的。

```shell 终端 — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # 脚手架已为 comments 表写好了迁移
```

`article:references` 会添加 `article_id` 列、索引和外键——这足以让 `Article`/`Comment` 获得关联：`spin run gen` 会从外键中读出 `Article#comments` 和 `Comment#article`。生成的 schema：

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

> [!NOTE]
> 如果 `cybertrain server` 一直开着，脚手架一写出文件它就会重新构建，而此时表还不存在，于是它会记录 `Build failed; still serving the previous build (see tmp/rebuild.log)`。等 `cybertrain db migrate` 重写了 `db/schema.rb`，它会再次重新构建。

> [!EXAMPLE] 删除带评论的文章
> ### 删除带评论的文章
>
> 外键会拒绝删除仍有评论的文章。像 Rails 一样声明关联，`destroy` 就会在它的事务中先删除这些评论：
>
> ```ruby app/models/article.rb（节选）
>   # each comment's own destroy runs, callbacks included
>   has_many :comments, dependent: :destroy
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

然后给评论模型添加验证：

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true

  belongs_to :article
end
```

声明的 `belongs_to` 还会让没有文章的评论在数据库拒绝之前就无效（“Article can't be blank”）。

> [!NOTE]
> `Article#comments` 是评论的 relation，所以 Rails 的 `@article.comments.find(params[:id])` 在 `destroy` 中可以原样使用，不属于该文章的评论会返回 404。

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

然后在文章页面的末尾渲染评论和表单，并替换脚手架生成的评论表单：

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

评论的局部视图：

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

### 表单和按钮指向哪里

`button_to ... [@article, comment]` 和 `form_with(model: [@article, comment])` 都通过同一条 `[parent, child]` 规则解析：新的子对象路由到嵌套集合（`article_comments_path`），已持久化的子对象路由到嵌套成员（`article_comment_path`），两者都由上面的嵌套 `resources` 块生成到 `gen/routes.rb` 中。表单以局部变量的形式接收它的评论，这样[第 13 步](#turbo)就能用一条新的评论再次渲染它。

> [!RULE] 视图是一套封闭的语法
> ### 视图是一套封闭的语法，而不是 Ruby
>
> Spinel 没有 `eval`，所以模板按照一套固定的语法来解释执行。`link_to` 没有 `method:` 选项；请使用 `button_to`。`each` 接受一个或两个块参数。像 `<%# locals: (comment:) %>` 这样的严格局部变量注释不能带默认值。局部视图会得到调用方环境的一份副本，所以在 `comments/_form` 中可以看到 `@article`。

> [!EXAMPLE] 带评论数和日期筛选的列表
> ### 带评论数和日期筛选的列表
>
> examples/blog 先列出最新的文章及其评论数（无论有多少文章都只需两次查询），并按日期筛选：
>
> ```ruby app/models/article.rb（节选） · app/controllers/articles_controller.rb（节选）
>   scope :recent, -> { order(created_at: :desc) }
>
>   def index
>     articles = Article.recent.includes(:comments)
>     from = Cybertrain::Cast.date_or_nil(params[:from])   # 不是 YYYY-MM-DD 时为 nil
>     unless from.nil?
>       articles = articles.where_between(:created_at, Time.utc(from.year, from.month, from.day), nil)
>     end
>     @articles = articles.to_a
>   end
> ```
>
> 在视图中，`article.comments.size` 直接从预加载的评论作答。Rails 的 `where(created_at: from..)` 在这里写作 `where_between`，因为 Spinel 无法构造 Time 的 Range（[条件与查找](models.md#conditions-and-finders)）。

<!-- step 12 #component stage: 你编写 · `app/components/`, `app/helpers/` -->
## 组件与辅助方法

> [!WHY]
> 从下一步开始，评论会在两个地方渲染：在页面上，以及在背后没有任何请求的广播中。组件是一个旁边配有模板的类，在这两处渲染出的结果相同；辅助方法则是每个模板都能调用的方法。

```shell 终端 — blog/
cybertrain generate component comment comment   # 先是名称，然后是它的属性：只有一个，也叫 comment
cybertrain generate helper comments
```

第一条命令写出 `app/components/comment_component.rb`（每个属性对应一个关键字）及其模板；第二条写出一个空的 `CommentsHelper`。两者还各写出一个测试，[第 16 步](#test)会回头处理它。这个类已经是博客所需要的样子：

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

<!-- step 13 #turbo stage: 运行时 · 基于 Server-Sent Events 的 Turbo Streams -->
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

<!-- step 14 #job stage: 你编写 · `app/jobs/` -->
## 后台作业

> [!WHY]
> 不应拖住响应的工作（例如发送通知）在响应之后运行。和 Solid Queue 上的 Active Job 一样，作业是 `app/jobs/` 中的一个类，加上应用自己数据库中的一行：不需要其他服务。

```shell 终端 — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

它会写出 `app/jobs/notify_comment_job.rb`，其中有该选项所要求的 `retry_on` 行和一个空的 `perform`，另外还有一个测试。把 `perform` 填上；这里它只写一条日志，真实的应用会在这里发送邮件：

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

发表一条评论，服务器的日志会显示作业在响应之后运行：

```text 输出 — cybertrain server
[INFO] Started POST "/articles/1/comments" for 127.0.0.1
[INFO] Completed 200 in 2ms
[INFO] new comment 1 on article 1
[INFO] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` 是传给 `perform_later` 的 Hash，以 JSON 形式保存，读回时键为 String：请传递 id，而不是记录，并用 `Cybertrain::Cast` 收窄其中的值。`perform_in(seconds, args)` 和 `perform_at(time, args)` 把它安排在之后运行。
- 作业是 `cybertrain_jobs` 中的行，由提供服务的进程的三个作业线程运行，或者由用 `./blog worker` 启动的单独进程的作业线程运行（[进程角色](background-and-operations.md#process-roles)）。
- `retry_on StandardError, wait: 30, attempts: 3` 会在 30 秒后把失败的运行重新入队，总共尝试三次；此后这一行变为 `failed` 并保留下来（[重试与丢弃](background-and-operations.md#retries-and-discards)）。
- 作业可能运行不止一次（进程在运行某个作业的中途死掉时，该作业会再运行一次），所以要把 `perform` 写成可以安全重复执行的。
- 失败的作业用 `./blog jobs` 列出、重试和丢弃，也可以在 `config/routes.rb` 中被注释掉的 `jobs_page` 那一行所挂载的页面上操作（[作业页面](background-and-operations.md#the-jobs-page-and-the-jobs-command)）。

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
> cron 表达式按 `CYBERTRAIN_SCHEDULER_TZ`（默认为 UTC）解读，并且同一时间只有一个进程运行这份时间表（[定时任务](background-and-operations.md#scheduled-tasks)）。

<!-- step 15 #json stage: 你编写 · `app/controllers/` -->
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

<!-- step 16 #test stage: 构建时 · `cybertrain spin test` -->
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

断言：`assert`、`refute`、`assert_equal`、`assert_nil`、`assert_includes`、`assert_raises("Class") { }`、`flunk`。客户端还提供 `assert_response` 和 `assert_redirected_to`。

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

### 作业、Turbo Stream 和组件

测试客户端不启动作业线程，所以入队的作业会一直留在队列中，直到测试运行它。`post` 的第三个参数设置请求头，这里是 Turbo 提交表单时发送的 `Accept`：

```ruby test/comments.rb（片段）
require_relative "support/blog_test"   # 同时加载 cybertrain/test/jobs

def post_comment(client, article, headers = {})
  client.get(BlogTest.article_path(article))
  client.post("#{BlogTest.article_path(article)}/comments",
              { "authenticity_token" => BlogTest.form_token(client),
                "comment[commenter]" => "Dave", "comment[body]" => "First!" }, headers)
end

test "a comment queues its notification" do
  BlogTest.reset
  post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article)
  assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
  assert_equal 1, perform_enqueued_jobs
  assert_no_enqueued_jobs
end

test "a form Turbo submits is answered with a Turbo Stream" do
  BlogTest.reset
  res = post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article,
                     { "accept" => "text/vnd.turbo-stream.html, text/html" })
  assert_response res, :ok
  assert_includes res.body, "<turbo-stream action=\"append\" target=\"comments\">"
end
```

[第 12 步](#component)写出了 `test/comment_component.rb`，它用一个 String 来渲染组件，而模板现在需要的是一条评论。替换它的内容：

```ruby test/comment_component.rb
require_relative "support/blog_test"
require "cybertrain/test/views"   # Cybertrain::Test.render_component

test "the comment component names its author" do
  BlogTest.reset
  comment = BlogTest.comment(BlogTest.article, "Alice", "Great post!")
  html = Cybertrain::Test.render_component(CommentComponent.new(comment: comment))
  assert_includes html, "<strong class=\"comment-author\">Alice</strong> wrote:"
end

Cybertrain::Test.run!
```

`render_component` 像广播那样渲染，不经过请求。其他辅助方法，以及如何在测试中读取流：[测试作业](testing.md#testing-jobs)和[测试流和组件](testing.md#testing-streams-and-components)。

> [!COMPILE] 片段中省略的内容
> ### 片段中省略的内容
>
> - `support/blog_test` 就是 [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb)：把它复制到你的应用的 `test/support/` 中，这里的文件会被 require，而不会被运行。它会迁移一个全新的 `storage/test.sqlite3`，以 `BLOG` 启动应用，加载 `Cybertrain::Test`、它的客户端和作业辅助方法，并提供 `BlogTest.form_token`（最近渲染的表单中的 CSRF 令牌）、`BlogTest.article_path`、`BlogTest.article` 和 `BlogTest.comment`（各返回一条已保存的记录）以及 `BlogTest.reset`（清空各表、缓存和作业队列）。
> - 在文件末尾调用 `Cybertrain::Test.run!`，它会运行测试，并打印快照所比对的各行输出。
> - 在 `config/app.rb` 中设置 `c.log_level = :none if c.test?`，让请求日志不进入被比对的输出。

### 运行测试

```shell 终端 — blog/
cybertrain spin test
```

`cybertrain spin test` 用锁定版本的 Spinel 运行 `spin test`；如果工具链已在 `PATH` 上（[第 00 步](#requirements)），直接运行 `spin test` 效果相同。它会把每个 `test/*.rb` 编译成独立的程序，并将其输出（stdout 和 stderr 合在一起）与已提交的快照 `test/<name>.rb.expected` 进行比对。`test/support/` 中的文件会被 require，而不会被运行。生成器在第 12 步和第 14 步写出的测试（`test/comments_helper.rb`、`test/notify_comment_job.rb`）会和其余测试一起运行。要写入快照：

```shell 终端 — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` 根据 CRuby 的输出写入快照。通过 FFI 访问 SQLite 的测试无法在 CRuby 下运行，所以它们的快照来自编译后的二进制文件（上面的第二行）。只要快照过时，`cybertrain spin test` 就会以非零状态退出，所以它后面跟的是 `;` 而不是 `&&`；`[ -x ]` 检查会在编译失败时跳过捕获，从而保留旧快照。无法在 CRuby 下运行的测试需要先有这个快照，`cybertrain spin test` 才能通过；其他没有快照的测试会与 CRuby 的输出进行比对。

<!-- step 17 #authentication stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加登录

> [!WHY]
> 到目前为止，任何人都能编辑或删除文章。和 Rails 8 的 `bin/rails generate authentication` 一样，一条命令就能加上用邮箱和密码登录的功能，而且写成归应用所有的代码，而不是作为引擎安装。

```shell 终端 — blog/
cybertrain generate authentication
cybertrain db migrate    # 创建 users 和 sessions 表
```

它写出 `users` 和 `sessions` 的迁移与模型、被它包含进 `ApplicationController` 的 `Authentication` 关注点、用于登录、注册、重置密码和账户页面的控制器与视图、一个邮件程序、`./blog user` 命令，以及测试。它还会添加路由、布局顶部的 `sessions/_nav` 局部模板，以及 `config/app.rb` 中的 `base_url` 设置，邮件中的链接以它开头。每个文件都列在 [认证](authentication.md#generating-it) 中。

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

> [!RULE] Spinel 规则：has_secure_password
> ### `has_secure_password` 被逐一写出
>
> Spinel 无法在运行时定义方法，所以 `User` 模型直接写出了 `has_secure_password` 本该定义的方法：`password=`、`authenticate` 和 `User.authenticate_by(email_address:, password:)`。密码由 `Cybertrain::Password` 做哈希：它是用 Ruby 实现的 PBKDF2-HMAC-SHA256，默认迭代 10 万次（编译后约 0.2 秒）；bcrypt 则需要让二进制链接一个 C 库。可以在 `config/app.rb` 里用 `Cybertrain::Password.iterations = 600_000` 提高成本，`User#authenticate` 会在每个用户登录时重新计算哈希。

### 更新测试

[步骤 16](#test) 中期望出现表单、提交表单，或访问 `index` 和 `show` 以外动作的测试，现在都会遇到登录页面。先用生成器写进 `test/support/app_test.rb` 的辅助方法让客户端登录：

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
> 像 [第 16 步](#test) 那样运行 `cybertrain spin test`；`test/authentication.rb`、生成器写出的其他测试以及这个测试都使用 SQLite，所以它们的快照来自编译后的二进制。登录尝试像 Rails 的生成器一样受到速率限制：每个客户端地址每三分钟十次，在应用的数据库中计数，所以每个进程共同计数；在反向代理之后，请配置 [可信代理](requests.md#rate-limiting-and-the-client-address)。`examples/blog` 用 `--invite-only` 完成这一步，并让它的 `/admin` 页面只对管理员开放。

<!-- step 18 #attachments stage: 你编写 · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## 添加封面图片

> [!WHY]
> 文章可以带一张图片。分工和登录一样：框架负责解析 `multipart/form-data` 并保存字节，其余部分由一条命令写成归应用所有的代码，以此取代 Active Storage 的 `has_one_attached`。

图片会显示在文章页面上，而从步骤 17 起访客就可以阅读这个页面，所以它的下载也必须对他们开放。在运行生成器之前，先把 `:cover` 加入步骤 17 写下的列表：

```ruby app/controllers/articles_controller.rb （节选）
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell 终端 — blog/
cybertrain generate attachment article cover   # 新模型则用：generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # 给 articles 添加 cover_* 列
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

下载和 `show` 一样通过 `set_article` 找到它的文章，所以 `set_article` 中用来限制用户能看到哪些文章的任何做法，同样会限制下载。生成器打印的各行中有一条警告，因为这个 `show` 里有它自己的代码：

```text 输出 — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

在这里，那段代码构建一条评论并选择格式；它不拒绝任何人，所以没有什么需要复制到 `cover` 中。

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
> 生成器会把 `show` 的访问规则复制到下载上，但只复制它能读懂的那些，也就是回调。如果除 `set_article` 之外还有一个 `before_action` 列出了 `:show` 却没有列出新动作，它会以 `cannot preserve show's authorization for :cover` 停止，什么也不写。`def show` 中的代码检查的是什么，它读不出来，所以才有那条警告。`show` 为空时，只要 `allow_unauthenticated_access` 列出了 `:show`，它就会自行把 `:cover` 加进去；`show` 中有代码时，它不改动这一行，而这一行里没有 `:cover` 的话，图片需要登录才能看到。

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
> 和[步骤 16](#test) 一样用 `cybertrain spin test` 运行；这个测试会用到 SQLite，所以它的快照来自编译后的二进制。`examples/blog` 也包含这一步，并且它的 JSON 不包含 `cover_*` 列（`Article#public_json`）。尚未实现：每个字段多个文件、S3 或其他远程存储、图片变体，以及把大请求体流式写入磁盘（整个请求体会读入内存，上限为 `max_body_bytes`）。

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
- 提供服务的进程同时运行第 13 步和第 14 步中的作业、定时任务和流轮询器：一个进程就是一套完整的部署。`./blog worker` 把作业移到它们自己的进程中（[进程角色](background-and-operations.md#process-roles)）。
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
- 关联来自外键或一行声明；不支持 `has_many :through`、嵌套的 `includes`、枚举、STI 或多态关联。
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
- [**认证**](authentication.md) — 密码重置、确认、锁定、保持登录、账户页面和管理员用户。
- [**国际化**](i18n.md) — 词典、`t` 和 `l`，以及每个请求的语言区域。
- [**指南**](index.md) — 每个主题一页：模型、请求、模板、实时、后台任务、测试。
- [**GitHub 上的 CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — 源代码、README 和发布版本。
- [**API 参考**](site:api/index.html) — 应用用到的每个类和方法，附带示例。
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — 技术验证（spike）及其发现的编译器约束。
- [**Spinel**](https://github.com/matz/spinel) — matz 开发的 Ruby AOT 编译器。
- [**CyberTrain 首页**](site:index.html) — 概览、特性和工作原理。
