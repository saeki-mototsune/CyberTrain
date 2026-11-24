---
source_sha256: c032393ee1441a62fcb16089fd5dd57ffbf4c06b5032ca07d5dd2f103da52cde
---
# 安装

在你的机器上运行 CyberTrain 需要什么、如何安装 `cybertrain` 命令、它有哪些命令，以及它如何替你安装 Spinel 和框架。

> [!NOTE]
> 想不安装任何东西就试用 CyberTrain，请打开[在线试用](site:playground.html)：GitHub Codespaces 会在你浏览器中的 VS Code 里打开教程中的博客、`cybertrain` 命令和锁定版本的 Spinel。同一个镜像也可以在 Docker 下本地运行。

## 环境要求

- Spinel，版本为 `Cybertrain::SPINEL_TAG` 所指的版本（[cybertrain/version.rb](../../cybertrain/version.rb)；`cybertrain doctor` 会打印它，与 [.github/workflows/ci.yml](../../.github/workflows/ci.yml) 中 CI 的 `SPINEL_TAG` 相同），即 [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)（`Cybertrain::SPINEL_REPOSITORY`）的一个版本；它是 matz/spinel 的分支，先于上游版本收录了 CyberTrain 所需的修复；未在其他版本上测试。你无需手动安装：`cybertrain` 命令在第一次需要它时会把该版本构建到 `~/.cybertrain` 中（`cybertrain setup` 可按需执行这一步），除非 `PATH` 上已有该版本的 `spinel`——参见 [Spinel 是如何安装的](#how-spinel-is-installed)。
- 构建它需要：C 工具链（`cc`，或 `CC` 指定的编译器）和 `make`——Spinel 会把每个程序编译为 C——以及 `git` 和 `curl`。
- SQLite 3 头文件和库（Debian/Ubuntu 上为 `libsqlite3-dev`；macOS 上随 Xcode 命令行工具提供）——模型直接使用 Spinel 的 FFI，而不是 gem。
- zlib 头文件和库（Debian/Ubuntu 上为 `zlib1g-dev`；macOS 上在 SDK 中）——gzip 压缩的请求体（`request.decoded_body`）通过系统的 zlib 解压，绑定方式相同。
- OpenSSL 头文件和库（Debian/Ubuntu 上为 `libssl-dev`）——每个应用都会链接它们：会话 cookie 和 `cookies.encrypted` 通过 Spinel 的 `openssl` 包使用 AES-256-GCM，而 Spinel 只有在头文件存在时才会构建这个包。在 macOS 上安装 Homebrew 的版本（`brew install openssl@3`），它是 keg-only 的，需要加入编译器的路径：`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`。
- Ruby 3.2+ 和 RubyGems，供 `cybertrain` 命令和开发服务器的 CRuby 预览使用；预览还需要 Ruby 的 `fiddle` 库（它需要 libffi），没有 `fiddle` 时 `cybertrain server` 只运行编译版的循环。部署后的应用从不在 CRuby 上运行。在 Ruby 3.2 上，构建 Spinel 还需要 `prism` gem（见下文）。

`cybertrain doctor` 会检查这些工具和头文件、`PATH` 上的 `ruby` 能否加载 `fiddle`，以及 Spinel 的安装情况；缺少必需项时，它还会打印适用于你的平台的安装命令（缺少 `fiddle` 不算在内：服务器仍会以编译版运行）。

<details><summary>更多软件包 — Ruby 3.2 上的 prism；jemalloc，可选</summary>

- 构建 Spinel 需要 Ruby 的 `prism` gem，Ruby 3.3 及以上已内置；Ruby 3.2 请运行 `gem install prism`（需要 Ruby 的开发头文件，Debian/Ubuntu 上为 `ruby-dev`）。`cybertrain doctor` 会检查它。
- 在安装 OpenSSL 头文件之前构建的 Spinel 没有 `openssl` 包，这时应用的构建会失败；装好头文件后运行 `cybertrain setup --force` 重新构建它。同一个包也用于 TLS（`require "cybertrain/net/tls"`）和加密列（`encrypts`）。
- jemalloc 的开发包（`libjemalloc-dev`；`brew install jemalloc`）是可选的：只有当应用的 `spin.toml` 写明 `allocator = "jemalloc"` 时才需要它，`cybertrain new` 会把这一行写成注释。在生产环境中依赖它之前，请先在自己的应用上测量：在 examples/blog 上，2026-10-09 的测量中动态页面的每秒请求数为 1.3 到 1.4 倍，最近一次测量中页面只相差百分之几（单核下 POST 多 18%）（[docs/benchmark.md](../benchmark.md)）。

</details>

## 安装 CLI

```shell 终端 — 任意目录
gem install cybertrain
cybertrain doctor
```

第一行从 RubyGems 安装这个命令，第二行检查[环境要求](#requirements)；[教程](tutorial.md#install)从这里接着往下讲，从 `cybertrain new` 一直讲到 `cybertrain build`。

## `cybertrain` 命令

`cybertrain help` 会打印这些命令：

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` 在 NAME 中创建应用，然后在其中运行 `spin lock` 和 `SPIN_DEBUG=1 spin run gen`，需要时会先安装 Spinel（CLI 以 spin 的调试模式构建 gen 和 `bin/db.rb`）。
- `cybertrain generate scaffold NAME field:type ... [parent:references] [--any]`（别名 `g scaffold`）为当前目录中的应用添加一个资源；`parent:references` 字段就是 `parent_id` 列，`--any` 用于附件字段（见下）。
- `cybertrain generate authentication [--invite-only] [--confirmable] [--force]` 为其添加用邮箱和密码登录的功能：users 和 sessions 表、`User` 和 `Session` 模型、`ApplicationController` 所 include 的 `Authentication` concern、登录、注册、密码重置和账户的控制器与视图、路由、由 `require_admin` 保护的作业页面、`bin/<app>.rb` 和 `bin/db.rb` 中它需要的子系统行，以及测试。`--invite-only` 不生成注册页面；`--confirmable` 让新账户在登录前先通过邮件确认地址；再次运行时，对会被改动的文件只打印差异，加上 `--force` 则直接覆盖（[认证](authentication.md)）。
- `cybertrain generate attachment MODEL FIELD [--any]` 为已生成脚手架的模型添加文件上传功能：五个元数据列、模型方法和回调、一个下载动作、路由、表单字段和一个测试（参见[添加封面图片](advanced-tutorial.md#attachments)）。脚手架字段 `cover:attachment` 的作用相同。
- `cybertrain generate helper NAME [--force]` 添加 `app/helpers/NAME_helper.rb` 和一个测试；运行 `spin run gen` 之后，这个模块的方法可以在任何模板中调用（[应用的辅助方法](template-language.md#application-helpers)）。
- `cybertrain generate component NAME [attr[:type] ...] [--force]` 添加一个视图组件：`app/components/NAME_component.rb`、它的模板和一个测试（[组件](template-language.md#components)）。
- `cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]` 添加 `app/jobs/NAME_job.rb` 和一个测试，并在 `bin/<app>.rb` 和 `bin/db.rb` 中加入 `require "cybertrain/jobs"`（[后台任务](background-and-operations.md#background-work)）。
- `cybertrain db migrate` 先生成代码，再执行待处理的迁移，然后再次生成（`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db -- migrate; SPIN_DEBUG=1 spin run gen`）；`cybertrain migration` 作为别名保留。
- `cybertrain db COMMAND...` 在 `SPIN_DEBUG=1 spin
  run gen` 之后运行其他任意数据库命令：`status`、`rollback [N]`（之后会再次生成）、`schema`（不做迁移，按数据库的现状写出 `db/schema.rb`）、`schema:dump`、`create`、`backup` 和 `vacuum`（[运维](background-and-operations.md#operations-backups-vacuum-health-check)）以及 `normalize`（[日期时间与 `db normalize`](models.md#datetimes-and-db-normalize)）。
- `cybertrain server [PORT] [--spinel]` 启动开发服务器（默认是应用的端口，即 `PORT` 或 `c.port`，都没有设置时为 3000）。改动之后应用立即在 CRuby 上运行，同时 Spinel 在后台构建它，构建成功后编译好的二进制文件接管端口；应用的响应带有 `X-Cybertrain-Runtime: cruby` 或 `spinel`（[开发循环](how-it-works.md#the-development-loop)）。`--spinel` 只运行编译版的循环，每次改动都要等它的构建（`SPIN_DEBUG=1 spin run gen`；若有 Ruby 文件比 `build/bin/NAME` 新，则 `spin build NAME -- --incremental`；`spin run NAME`，或 `spin run NAME -- PORT`）。
- `cybertrain build` 构建嵌入了 `app/views/` 的 NAME，并组装 `dist/`（二进制文件、`public/`、`storage/`、`tmp/`）。
- `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` 先生成，再把 `test/` 下的所有测试编译成一个程序（只在有改动时）并运行，只保留参数指定的测试（见[测试应用](testing.md#running-the-tests)）。
- `cybertrain spin ARGS...` 在任意目录下用锁定版本的 Spinel 运行 `spin`（`cybertrain spin test`、`cybertrain spin run gen -- --check`）。
- `cybertrain secret [--hex]` 打印一个用于 `CYBERTRAIN_SECRET_KEY_BASE` 的新随机密钥；加上 `--hex` 则打印一个用于 `CYBERTRAIN_ENCRYPTION_KEY` 的新密钥。两者都是 64 位十六进制数字。
- `cybertrain setup [--force]` 把锁定版本的 Spinel 安装到 `~/.cybertrain` 中，除非 `PATH` 上已有该版本的 `spinel`；`--force` 会重新构建 `~/.cybertrain` 下的副本。
- `cybertrain doctor` 检查[环境要求](#requirements)中的每一项：`git`、`make`、`curl`、C 编译器、SQLite、zlib 和 OpenSSL 的头文件、`prism` gem、Ruby 能否加载 `fiddle`（CRuby 预览需要它）以及 Spinel 的安装情况。
- `cybertrain version` 打印版本；`cybertrain help` 打印这份列表。

`generate`、`db`、`server`、`build` 和 `test` 需在应用目录内运行；NAME 是其 `spin.toml` 中的 `[package] name`。

## Spinel 是如何安装的

每个运行 `spin` 的命令（`new`、`db`、`server`、`build`、`test`、`spin`）都会先确保有 `Cybertrain::SPINEL_TAG` 所指版本的 Spinel 可用。如果 `PATH` 上有 `spinel`（以及 `spin`），且其 `spinel --version` 报告的正是该版本，就直接使用它；否则使用 `cybertrain` 保存在 `~/.cybertrain/spinel/<SPINEL_TAG>/` 下的副本；如果也没有，`cybertrain` 就从 `Cybertrain::SPINEL_REPOSITORY` 的发布标签构建这份副本（`git clone`、`make deps`、`make -j`、`make install PREFIX=...`），只需一次，耗时几分钟，并把日志写入 `~/.cybertrain/log/spinel-<SPINEL_TAG>-build.log`（某一步失败时会打印其最后几行）。

如果缺少构建所需的工具，`cybertrain` 会在开始前指出缺少哪个，并打印适用于你的平台的安装命令。`PATH` 上其他版本的 `spinel` 永远不会被使用或改动：`cybertrain` 会保留自己的副本（并在安装时说明这一点）。

`cybertrain setup` 会按需执行同样的操作，并且在正在使用的是它自己的副本时，打印把它加入 `PATH` 的那一行，方便你自己运行 `spin`：

```shell 终端 — 任意目录
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` 中存放指向当前所用版本的 `spinel` 和 `spin` 链接，所以版本升级后这一行仍然有效；`cybertrain spin ...` 则完全不需要 `PATH`。

<details><summary>环境变量 — `CYBERTRAIN_HOME` 替代 `~/.cybertrain`，`CYBERTRAIN_SPINEL_HOME` 使用已有的安装</summary>

有两个环境变量可以覆盖以上所有行为：

- `CYBERTRAIN_HOME` 替代 `~/.cybertrain`（路径中不能有空格、引号、`$` 或 `:`，Spinel 的 Makefile 和 `PATH` 无法处理它们）。
- `CYBERTRAIN_SPINEL_HOME=PREFIX` 强制使用已有的安装：此时 `cybertrain` 使用 `PREFIX/bin` 中的 `spinel` 和 `spin`（如果 `spinel` 直接位于 `PREFIX` 中，则使用 `PREFIX` 本身中的），如果它们不是该版本，就报错并停止。

第三个变量 `CYBERTRAIN_KEEP_SRC=1` 会保留构建时克隆的 Spinel 源码（`~/.cybertrain/src/spinel-<SPINEL_TAG>/`），而不是在构建后删除它。

</details>

## gem 与框架

`gem install cybertrain` 安装的是一个命令，而不是框架。这个 gem 就是 `cybertrain` 命令，它是纯 Ruby 编写的，在你的机器上运行于 CRuby（3.2 或更新版本）之下，并替你调用 Spinel 的 `spin` 工具；框架和 Spinel 都不在这个 gem 里。框架是一个 Spinel 包，你的应用在其 `spin.toml` 中依赖它：Spinel 把它和你的代码一起进行 AOT 编译，它是随应用交付的部分。`dist/` 中的二进制文件无需 Ruby、gem 或 Spinel 即可运行。只有在开发时，应用的代码（包括框架）才也在 CRuby 上运行：`cybertrain server` 会提供应用的 CRuby 预览，直到编译好的二进制文件接管。

### `cybertrain new` 写出什么

`cybertrain new` 会写出应用，其 `spin.toml` 指向与 CLI 相匹配的版本（`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }`，X.Y.Z 即 `cybertrain version` 打印的版本），确保 Spinel 已安装，然后运行 `spin lock`（spin 会把框架拉取到其缓存 `~/.cache/spin/packages/` 中，并在 `spin.lock` 中锁定提交）和 `SPIN_DEBUG=1 spin run gen`，就像 `rails new` 会运行 `bundle install` 一样，最后打印接下来的步骤。框架的任何部分都不会被复制到应用中；请提交 `spin.toml` 和 `spin.lock`。`bin/<app>.rb` 和 `bin/db.rb` require `cybertrain/core`，即不含可选子系统的框架；需要某个子系统的生成器会添加它的那一行（[子系统](how-it-works.md#subsystems)）。它还会写出 `AGENTS.md`，即给 AI 编程代理的说明（应用与 Rails 的不同之处，以及认定一项改动完成之前要运行的检查），以及为 Claude Code 导入它的 `CLAUDE.md`。

如果 Spinel 或两个 `spin` 步骤之一失败，已写出的文件会保留，`new` 以状态码 1 退出，并打印排除原因后需要运行的命令（对于 Spinel：先运行 `cybertrain setup`，再在新目录中运行 `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen`）。

有四个选项会改变它写出和运行的内容：

- `--skip-spin` 只写出文件：不安装 Spinel，不运行 `spin lock`，也不运行 `spin run gen`。
- `--path DIR` 改为依赖本地检出的代码
  （开发 CyberTrain 本身时，用 `--path ~/src/cybertrain`，检出代码在哪里就写哪里）。
- `--git URL [--ref R]` 依赖位于 URL 的框架（分支或标签 R）。
- `--version V` 在框架进入 `spin-index` 后依赖其中的发布版本 V（`cybertrain = "V"`）：参见[索引中的版本](#an-index-version)。

`--path`、`--version` 和 `--git` 只能给出其中一个；`--ref` 需要配合 `--git`。

### 索引中的版本

`spin-index` 是 spin 按名称查找包的列表。框架目前还不在其中：在此之前，在用 `--version` 创建的应用里运行 `spin lock` 会得到 `not in the index: cybertrain`，依赖某个发布版本的办法是 `new` 默认写入的标签。进入索引之后，`cybertrain new NAME --version X.Y.Z` 写入 `cybertrain = "X.Y.Z"`，spin 在索引中找到该版本的提交，`spin.lock` 固定的内容与使用标签时相同（版本、仓库和提交），因此每条命令以及 `new` 写出的 CI 工作流都和默认情况下一样运行。有三点与 `Gemfile` 给人的预期不同：

- **指定一个发布版本。** 在满足约束的发布版本中，spin 选择最低的，而不是最新的：`"~> X.Y"` 是索引中从 X.Y 起、到下一个主版本之前的最低版本（只有 `"~> X.Y.Z"` 才限定在 X.Y 之内），之后发布了更新的版本也仍然是它。所以请写确切的版本，也就是 `cybertrain version` 打印的那个；V 是其他写法时，`new` 会打印一条提示。
- **Spinel 仍然由 `cybertrain` 命令提供。** 索引条目不指定 Spinel 的发布版本。框架是针对其中一个版本编写并测试的，即 `cybertrain setup` 构建的那个，同一版本的 `cybertrain` 命令会安装它。在用其他 Spinel 构建的项目里只运行 `spin add cybertrain`，这种用法未经测试。
- **spin 读取的是它自己的索引副本。** 它只把索引克隆一次，放在 `~/.cache/spin/`，`spin lock` 不会更新这个副本；`spin search cybertrain` 会更新，并打印最新的发布版本。

### 把应用迁移到新版本

gem 和框架从同一个标签发布，因此版本一致：X.Y.Z 版的 gem 生成的应用依赖框架 `vX.Y.Z`。要把应用迁移到新版本，先更新 gem，把 `spin.toml` 指向新标签，然后在应用中运行：

```shell 终端 — 应用目录
rm spin.lock
cybertrain spin lock
cybertrain spin run gen
```

对于 git 依赖，无论 `spin.toml` 中的 `ref` 变成什么，`spin lock` 都会保留它已锁定的提交，所以要先删除锁文件。如果应用还有其他依赖，可以改为只从 `spin.lock` 中删除 `[lock.cybertrain]` 表和 `[lock.spinel-http]` 表（框架依赖的 HTTP 层），保留其他锁定。

依赖[索引中的版本](#an-index-version)的应用不需要 `rm`，因为此时 `spin lock` 会移动锁定：先运行 `cybertrain spin search cybertrain` 更新 spin 的索引副本，再把 `spin.toml` 中 `cybertrain =` 一行的版本改为新的发布版本，然后运行 `cybertrain spin lock` 和 `cybertrain spin run gen`。

两者是否一致由命令来检查。`server`、`build`、`db`、`test` 和 `generate` 在运行 spin 或写出文件之前，会把 spin 将要构建的框架版本，即应用的 `spin.lock` 中锁定的版本，与命令自己的版本（`cybertrain version`）进行比较：决定用哪个 Spinel 版本编译应用的是命令而不是应用，而且命令的模板和生成器是为同一版本的框架编写的。版本不同时，命令以状态码 1 停止：

```text 输出 — cybertrain build
error: this application's framework is cybertrain X.Y.Z (spin.lock), but this cybertrain command is A.B.C.
The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either
  gem install cybertrain -v X.Y.Z    # the command the application is on
or point the cybertrain dependency in spin.toml at A.B.C (ref = "vA.B.C"), then relock from nothing (spin lock keeps a locked git commit)
  rm spin.lock && cybertrain spin lock
```

两种做法任选其一。`cybertrain spin ...` 不做这项检查，因此 `cybertrain spin lock` 总能运行。对于索引中的版本，消息给出的是 `cybertrain = "A.B.C"` 和单独的 `cybertrain spin lock`；只有在 `spin.toml` 仍然允许时，spin 才构建锁定的版本，因此 `spin.toml` 指定的版本一旦与锁不同，就会用它来比较；如果某个范围（`"~> X.Y"`）不再允许锁定的版本，则在运行 `cybertrain spin lock` 之前命令会拒绝执行。依赖框架本地检出代码（`path = ...`）的应用不做检查。没有 `spin.lock` 的应用，则与其 `spin.toml` 指定的版本（`"X.Y.Z"` 或 `ref = "vX.Y.Z"`）比较；分支、提交或范围不指定任何版本，因此不做检查。

重新锁定只是升级的一个步骤。完整的流程，以及每个版本对应用的改变，见[升级](upgrading.md)。
