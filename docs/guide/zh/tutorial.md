---
source_sha256: 6089daf50cee57c1a9721c18dbb9a850c8b9b6fdc50d6498999b523a0bb023a4
path: tutorial.html
title: "入门：博客"
description: "用 CyberTrain 构建 Rails 入门指南中的博客（带评论的文章）：安装、生成脚手架、添加验证、执行迁移、把评论嵌套在文章之下，并用 cybertrain test 测试应用。"
og_title: "CyberTrain 入门：博客"
og_description: "对照 Rails 官方的入门指南：一个包含文章和评论的博客，在 Spinel 上用 CyberTrain 构建。"
og_image: tutorial.png
crumb: "教程"
nav: tutorial
toc_title: "步骤 00–12"
meta:
  - term: "你需要"
    text: 'Ruby 3.2+、`cc`、`make`、`git`、`curl`、SQLite 3、zlib 和 OpenSSL 头文件（Spinel 会自动为你安装）<a class="meta-link" href="#requirements">第 00 步</a>'
  - term: "从这里开始"
    text: "`gem install cybertrain`"
  - term: "最终得到"
    text: "一个带文章、评论和测试的博客"
---

# 入门：博客

对照 Rails 官方的[入门指南](https://guides.rubyonrails.org/getting_started.html)：一个包含文章和评论的博客。你将安装 CLI、为文章生成脚手架、添加验证、把评论嵌套在文章之下并运行测试，最终在自己的机器上得到一个能运行的博客。随后，[进阶教程](advanced-tutorial.md)会把同一个博客继续推进：用 Turbo 实时推送评论、后台作业、JSON、登录、上传的图片，以及可部署的构建。


<!-- step 00 #requirements stage: 准备 · Ruby、`cc`、SQLite -->
## 环境要求

> [!WHY]
> CyberTrain 通过 Spinel 编译为 C，所以需要 C 工具链和 SQLite 头文件；`cybertrain` 命令是一个 gem，所以需要 Ruby。

<!-- list: checklist -->
- Ruby 3.2+ 和 RubyGems，供 `cybertrain` 命令和开发服务器的 CRuby 预览（需要 Ruby 的 `fiddle`）使用；部署后的应用从不在 CRuby 上运行。在 Ruby 3.2 上，还需要 `gem install prism`。
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

第一行从 RubyGems 安装它。其余几行是整个流程的概览：下面的步骤逐条命令讲解，一直到 `cybertrain server`；以 `cybertrain build` 结束的是[进阶教程](advanced-tutorial.md#ship)。

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

`bin/blog.rb` 和 `bin/db.rb` 都以 `require "cybertrain/core"` 开头：这是不含可选子系统（作业、Turbo Streams、邮件发送器、缓存等）的框架，能让每次构建都更短。进阶教程中用到某个子系统的步骤会添加它的那一行（[子系统](how-it-works.md#subsystems)）。

布局用 `stylesheet_link_tag` 引入 `app/assets/stylesheets/application.css`，并用 `javascript_importmap_tags` 通过 `config/importmap.rb` 的 import map 加载 `app/javascript/application.js`；`spin run gen` 把两者加上摘要写入 `public/assets/`，该目录被 git 忽略（参见[资源](assets.md)）。`.env.example` 列出应用读取的变量，`.github/workflows/ci.yml` 在 GitHub 上运行测试（[持续集成](testing.md#continuous-integration)），目录树的最后一行则是[第 19 步](advanced-tutorial.md#ship)的 Kamal 配置。

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

它会写出一个迁移、一个模型、一个控制器、五个视图（`index`、`show`、`new`、`edit`、`_form`）、一个夹具文件和测试（[步骤 12](#test)），并把 `resources :articles` 插入 `config/routes.rb`。字段类型有 `string`、`text`、`integer`、`float`、`boolean`、`date`、`datetime`、`references` 和 `attachment`（上传的文件，见[第 18 步](advanced-tutorial.md#attachments)）；默认为 `string`。快速上手中的 `cybertrain g scaffold` 是同一条命令。

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
  # jobs_page "/admin/jobs", before_action: :require_admin
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
> ### `new_action`，而不是 `new`
>
> `new` 动作写作 `new_action`：生成的路由就是用这个名字调用它的。改名发生在 Spinel 被记录为无法编译与 `ArticlesController.new(ctx)` 并存的、名为 `new` 的实例方法的时候；同样形状的精简程序在固定的发行版上可以编译，而这个名字作为 API 保留了下来。路由 `GET /articles/new` 仍然映射到这个方法；你只需重命名方法。视图仍然是 `new.html.erb`，`render :new` 也保持不变。

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
cybertrain server        # http://127.0.0.1:3000；修改 Ruby 后立即由 CRuby 反映，随后换成编译版；视图两者都不需要
```

`spin run gen` 读取 `db/schema.rb` 和 `config/routes.rb`，扫描 `app/` 并写入 `gen/`；`spin run db -- migrate` 执行 `db/migrate/*.rb` 并重写 `db/schema.rb`。顺序很重要：第一次 `spin run gen` 把新迁移放进 `gen/migrations.rb`（`bin/db.rb` 会 require 它），第二次则根据重写后的 `db/schema.rb` 构建模型。

`cybertrain server` 在一秒内就从 CRuby 提供应用，并在后台用 Spinel 构建它。第一次构建要编译整个应用，需要几分钟；在它完成之前由 CRuby 预览响应，每个页面的右下角都会说明这一点：

```text 输出 — cybertrain server
=> Booting cybertrain X.Y.Z
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> preview: CRuby (0.5s)
```

构建完成后，服务器会打印 `=> spinel: ready in …s; serving the compiled binary`，此后由编译好的二进制文件响应。修改 Ruby 后，它会打印 `Changed` 和文件名，立即重新由 CRuby 响应，并再次构建（[开发循环](how-it-works.md#the-development-loop)）。按 Ctrl-C 停止。

<!-- list: points -->
- 修改 schema、路由，控制器或模型的回调和实例变量，辅助方法、组件或作业，或者某个资源之后，重新运行 `cybertrain spin run gen` 并提交 `gen/`。开发服务器会替你完成这一步，而 `cybertrain spin run gen -- --check` 只列出哪些内容已经过时，不写入任何东西。
- 用 `cybertrain server 4000`（或 `PORT=4000`）更改端口。
- `spin run db` 要求在参数前加上 `--`，`cybertrain db` 会替你加上；`cybertrain db status` 和其他数据库命令也是如此。

> [!RULE]
> ### 控制台不是 Ruby
>
> `rails console` 没有完全对应的功能：Spinel 没有 `eval`。`cybertrain spin run blog -- console`（构建之后为 `./blog console`）在模型上求值模板表达式，例如 `Article.where(title: "x").count`，而 `dbconsole` 打开 `sqlite3`（[控制台](background-and-operations.md#the-console)）。修改 Ruby 代码需要重新构建：开发时 `cybertrain server` 会立即通过 CRuby 预览响应这些修改，并在构建完成后把端口交给编译好的二进制文件。开发时视图在每次请求时从磁盘解析，所以修改视图无需重新构建；`cybertrain build` 会为生产环境把它们嵌入。

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
> 如果 `cybertrain server` 一直开着，脚手架一写出文件它就会立刻接手，而此时表还不存在。新的 `Comment` 模型的列来自 `gen/models/comment.rb`，而 gen 要等表出现在 `db/schema.rb` 中才会写出这个文件，所以 CRuby 预览无法加载这个模型（`NoMethodError`）：服务器会用它自己的、写明错误的 503 页面响应，Spinel 的构建也会失败。等 `cybertrain db migrate` 重写了 `db/schema.rb`，服务器就会恢复响应。

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

  # A nested block takes the mapper as its argument: `articles.resources`,
  # not Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] 显式接收 mapper
> ### 嵌套块显式接收 mapper
>
> 要写 `resources :articles do |articles|` 和 `articles.resources :comments`，而不是直接写 `resources :comments`。这种写法是在 Spinel 被记录为无法编译嵌套在 `instance_eval` 内的块中不带接收者的调用时引入的；同样形状的精简程序在固定的发行版上可以编译，而显式的 mapper 仍是文档规定的写法，生成器和测试写的都是它。

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

脚手架写出的评论模型已经有 `belongs_to :article`，以及对它的第一个字符串字段 `commenter` 的存在性检查；再给正文加一条：

```ruby app/models/comment.rb
class Comment
  belongs_to :article
  validates :commenter, presence: true
  validates :body, presence: true
end
```

脚手架声明的 `belongs_to` 还会让没有文章的评论在数据库拒绝之前就无效（“Article can't be blank”）。

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

`button_to ... [@article, comment]` 和 `form_with(model: [@article, comment])` 都通过同一条 `[parent, child]` 规则解析：新的子对象路由到嵌套集合（`article_comments_path`），已持久化的子对象路由到嵌套成员（`article_comment_path`），两者都由上面的嵌套 `resources` 块生成到 `gen/routes.rb` 中。表单以局部变量的形式接收它的评论，这样[第 14 步](advanced-tutorial.md#turbo)就能用一条新的评论再次渲染它。

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

<!-- step 12 #test stage: 构建时 · `cybertrain test` -->
## 测试

> [!WHY]
> minitest 和 RSpec 通过反射查找测试，提前（AOT）编译器做不到这一点。不过测试仍然是 Rails 的类：`spin run gen` 把它们改写成一个程序，由 `cybertrain test` 编译并运行。

### 生成器写了什么

步骤 03 和 08 的脚手架写出了 Rails 的脚手架测试：`test/fixtures/articles.yml` 和 `comments.yml`（每个测试开始时就有的 `one` 和 `two` 两行）、`test/models/article_test.rb` 和 `comment_test.rb`（“the fixture is valid”），以及 `test/controllers/articles_controller_test.rb` 和 `comments_controller_test.rb`（每个动作一个请求）。`cybertrain new` 写出了每个文件都会加载的 `test/test_helper.rb`，以及请求 `/up` 的 `test/integration/health_test.rb`。其中三个需要跟上博客此后的变化：文章的 fixture 和两个控制器测试。

### 通过验证的夹具

脚手架的示例值（`MyString`、`MyText`）通不过[步骤 05](#validations) 的检查：两篇文章标题相同，正文也不到十个字符。给文章真正的值：

```yaml test/fixtures/articles.yml
one:
  title: Hello Rails
  body: I am on Rails! This is my first article.

two:
  title: Second article
  body: Another article, with no comments.
```

创建测试提交的是夹具自己的标题，而它现在已被占用；给它一个新标题：

```ruby test/controllers/articles_controller_test.rb（节选）
  test "should create article" do
    assert_difference(-> { Article.count }, 1) do
      post articles_url, params: { article: { body: @article.body, title: "A new title" } }
    end

    assert_redirected_to article_url(Article.last)
  end
```

`comments.yml` 的行属于 `article: one`。和 Rails 一样，指向某篇文章的夹具会让这篇文章无法删除，所以除非 `Article` 声明了 `has_many :comments, dependent: :destroy`（[步骤 08](#scaffold-comment) 末尾的方框），“should destroy article” 会因外键而失败。如果还没有，像 examples/blog 一样把它加到 `app/models/article.rb` 中：

```ruby app/models/article.rb（节选）
  has_many :comments, dependent: :destroy
```

### 文章下的评论

脚手架的评论测试请求的是[步骤 09](#nested-routes) 嵌套到文章下的路由，它们的辅助方法现在是 `article_comments_path` 和 `article_comment_path`。把它替换掉：

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

和 Rails 一样，测试中的防伪造保护是关闭的，所以 `post` 不需要令牌。其他断言见[测试应用](testing.md#assertions)。

### 运行测试

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

第一次运行会把所有测试编译成一个程序，需要几分钟（examples/blog 的测试在 2026-11-13 测量时有 149 个，在一台 4 vCPU 的云机器上用了大约九分钟）；没有改动时再次运行不会重新编译测试程序：它可能会重新构建一次 gen（`build gen`，几秒钟），之后不到一秒就开始。文件或 `-n` 选择运行哪些测试，而不是编译什么：修改任何测试都会重新编译程序。每个文件输出一个标题，每个测试一行（`ok`，或带着测试的行号和消息的 `FAIL` 和 `ERR`），最后是合计，其间还夹着被测代码自己输出的内容（例如某个命令的输出行）；有测试失败时退出状态为 1。在这一步，博客共有十二个测试。

> [!NOTE]
> 每个测试之前所有表都会被清空并重新插入夹具，所以测试之间互不依赖。`gen/tests.rb` 和 `gen/test/` 是生成的：和 `gen/` 的其余部分一起提交。

<!-- step → #where-next -->
## 下一步

现在你有了一个带文章和评论、经过验证和测试、由 `cybertrain server` 提供服务的博客。进阶教程会用同一个应用从这里继续。

<!-- list: next-list -->
- [**进阶教程**](advanced-tutorial.md) — 第 13–19 步：组件和辅助方法、用 Turbo 实时推送评论、后台作业、JSON、登录、封面图片，以及为部署而构建。
- [**须知**](advanced-tutorial.md#things-to-know) — 值得在它们让你意外之前了解的限制和怪癖。
- [**`examples/blog`**](../../examples/blog) — 两篇教程最终发展成的应用，附带测试。
- [**指南**](index.md) — 每个主题一页：模型、请求、模板、实时、后台任务、测试。
- [**模型与数据库**](models.md) — 迁移、查询、关联和全部验证器。
- [**测试**](testing.md) — 夹具、断言和 `cybertrain test` 的完整说明。
- [**API 参考**](site:api/index.html) — 应用用到的每个类和方法，附带示例。
- [**GitHub 上的 CyberTrain**](https://github.com/saeki-mototsune/CyberTrain) — 源代码、README 和发布版本。
- [**CyberTrain 首页**](site:index.html) — 概览、特性和工作原理。
