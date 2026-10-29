---
source_sha256: 921f35c9cb87db6ad7dffa5eeabb53f95a5a5d262cbb98ad67ad0ba1542ddfaa
---
# 安装 cybertrain

## 在浏览器中试用

[在 GitHub Codespaces 中打开在线试用环境](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)，无需安装任何东西即可试用 cybertrain：VS Code 会在你的浏览器中打开，其中已备好 Spinel 2026.10.27.7020、`cybertrain` CLI，以及[教程](tutorial.md)中的博客（`cybertrain new blog`、文章脚手架、根路由和第一次迁移，均已构建过一次，所以服务器启动时无需编译）；它的开发服务器在一个终端中运行，应用则在新的浏览器标签页中显示文章列表。应用是一个只有一次提交的 git 仓库，所以“源代码管理”会显示你改动了什么。应用中的 `PLAYGROUND.md` 列出了可以尝试的内容，从编辑视图到从第 08 步（评论）继续学习教程。修改视图后，下次重新加载即可看到；修改 Ruby 代码则需要完整重新构建，约一分钟，之后服务器会自行重启；应用的标签页不会自行重新加载。在那里，`cybertrain new` 无需网络即可运行。

- 需要一个 GitHub 账号，codespace 使用你自己的 Codespaces 配额：GitHub 免费计划每月包含 120 核心小时和 15 GB-月的存储，在在线试用所用的默认 2 核机器上约为 60 小时。默认情况下，GitHub 会在 codespace 空闲 30 分钟后将其停止；在你删除它之前，它的存储一直计入配额。
- 如果 VS Code 询问你是否信任此文件夹中文件的作者，请选择 “Trust Folder & Continue”：只有这样，服务器的终端才会启动。
- 如果应用的标签页没有打开（弹出窗口拦截器，或者 codespace 被停止后又重新启动），请在 VS Code 关于端口 3000 的通知或“端口”视图中点击 “Open in Browser”，或者在 `server` 终端中按住 Ctrl 点击应用的 URL。`PLAYGROUND.md` 说明了它们各自的位置。
- 同一个镜像也可以在本地运行（它以 linux/amd64 发布；在 arm64 上，请从检出的代码构建）：

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  然后打开 http://localhost:3000。[playground/README.md](../../playground/README.md) 介绍了这个镜像、如何构建它以及 Codespaces 的设置。

## 环境要求

- Spinel `2026.10.27.7020`（`Cybertrain::SPINEL_TAG`，与 [.github/workflows/ci.yml](../../.github/workflows/ci.yml) 中 `SPINEL_TAG` 的版本相同），即 [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)（`Cybertrain::SPINEL_REPOSITORY`）的一个版本；它是 matz/spinel 的分支，先于上游版本收录了 cybertrain 所需的修复；未在其他版本上测试。你无需手动安装：`cybertrain` 命令在第一次需要它时会把该版本构建到 `~/.cybertrain` 中（`cybertrain setup` 可按需执行这一步），除非 `PATH` 上已有该版本的 `spinel`——参见[安装 CLI](#installing-the-cli)。
- 构建它需要：C 工具链（`cc`，或 `CC` 指定的编译器）和 `make`——Spinel 会把每个程序编译为 C——以及 `git` 和 `curl`。
- SQLite 3 头文件和库（Debian/Ubuntu 上为 `libsqlite3-dev`；macOS 上随 Xcode 命令行工具提供）——模型直接使用 Spinel 的 FFI，而不是 gem。
- zlib 头文件和库（Debian/Ubuntu 上为 `zlib1g-dev`；macOS 上在 SDK 中）——gzip 压缩的请求体（`request.decoded_body`）通过系统的 zlib 解压，绑定方式相同。
- Ruby 3.2+ 和 RubyGems，仅供 `cybertrain` 命令使用（应用从不在 CRuby 上运行）。构建 Spinel 还需要 Ruby 的 `prism` gem，Ruby 3.3 及以上已内置；Ruby 3.2 请运行 `gem install prism`（需要 Ruby 的开发头文件，Debian/Ubuntu 上为 `ruby-dev`）。`cybertrain doctor` 会检查它。
- OpenSSL 头文件（`libssl-dev`）是可选的：没有它们时，Spinel 构建时会不带其 `openssl` 包，而 cybertrain 并不使用这个包。在 macOS 上，require `openssl` 的应用需要让编译器的路径包含 Homebrew 的（keg-only）OpenSSL：`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`。
- jemalloc 的开发包（`libjemalloc-dev`；`brew install jemalloc`）是可选的：只有当应用的 `spin.toml` 写明 `allocator = "jemalloc"` 时才需要它，`cybertrain new` 会把这一行写成注释。在生产环境中值得开启：在 examples/blog 上每秒请求数可达 1.1 到 1.4 倍（[docs/benchmark.md](../benchmark.md)）。

`cybertrain doctor` 会检查这些工具和头文件以及 Spinel 的安装情况；缺少必需项时，它还会打印适用于你的平台的安装命令。

框架没有单独的测试运行器；它自己测试自己。`spin` 随 Spinel 提供，`cybertrain spin` 会运行 `cybertrain` 安装的那份副本，而不改动 `PATH`（也可以用 `cybertrain setup` 打印的 `export
PATH=...` 那一行把该副本加入 `PATH`，然后直接调用 `spin`）：

```sh
cybertrain spin test
```

会编译并运行 `test/` 下的每个程序，并把其输出与已提交的 `test/<name>.rb.expected` 快照进行比较——minitest/RSpec 无法在 Spinel 下运行，因为它们通过反射查找测试方法，而提前编译器在运行时没有任何可供反射的东西。`cybertrain spin test
--regen test/<name>.rb` 会根据 CRuby 的输出重写快照；少数通过 FFI 访问 SQLite 的测试则改从编译后的二进制文件获取快照（[spikes/NOTES.md](../../spikes/NOTES.md)，规则 23）；`script/regen-snapshot
test/<name>.rb` 会替你完成先构建再捕获这一步，并打印差异统计。

## 安装 CLI

```sh
gem install cybertrain
cybertrain new blog    # 首次运行时还会安装 Spinel（需要几分钟）
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # 生产环境：dist/
```

`cybertrain` 命令是纯 Ruby 编写的，gem 在 CRuby（3.2 或更新版本）下运行它；框架和 Spinel 都不在这个 gem 里。它的命令如下（`cybertrain help` 会把它们打印出来）：

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` 在 NAME 中创建应用，然后在其中运行 `spin lock` 和 `spin run gen`，需要时会先安装 Spinel。
- `cybertrain generate scaffold NAME field:type ...`（别名 `g scaffold`）为当前目录中的应用添加一个资源。
- `cybertrain generate authentication` 为其添加用邮箱和密码登录的功能：users 和 sessions 表、`User` 和 `Session` 模型、登录和注册的控制器与视图、路由、`ApplicationController` 中的一个 `before_action`，以及一个测试（参见[添加登录](tutorial.md#authentication)）。使用 `--invite-only` 时没有注册页面：用户通过 `./NAME user EMAIL` 创建；在还没有任何用户时，第一个用户也可以在 `/setup` 页面创建，该页面只响应服务器所在的机器，并需要服务器启动警告中打印的一次性令牌。
- `cybertrain generate attachment MODEL FIELD [--any]` 为已生成脚手架的模型添加文件上传功能：五个元数据列、模型方法和回调、一个下载动作、路由、表单字段和一个测试（参见[添加文件上传](tutorial.md#attachments)）。脚手架字段 `cover:attachment` 的作用相同。
- `cybertrain db migrate` 先生成代码，再执行待处理的迁移，然后再次生成（`spin run gen; spin run db -- migrate; spin run gen`）；`cybertrain migration` 作为别名保留。
- `cybertrain db COMMAND...` 在 `spin
  run gen` 之后运行其他任意数据库命令：`status`、`rollback [N]`（之后会再次生成）、`schema:dump`、`create`。
- `cybertrain server [PORT]` 先生成代码，然后启动开发服务器（`spin run gen; spin run NAME`，或 `spin run NAME -- PORT`；默认端口 3000）。
- `cybertrain build` 构建嵌入了 `app/views/` 的 NAME，并组装 `dist/`（二进制文件、`public/`、`storage/`、`tmp/`）。
- `cybertrain spin ARGS...` 在任意目录下用锁定版本的 Spinel 运行 `spin`（`cybertrain spin test`、`cybertrain spin run gen -- --check`）。
- `cybertrain setup [--force]` 把 Spinel `2026.10.27.7020` 安装到 `~/.cybertrain` 中，除非 `PATH` 上已有该版本的 `spinel`；`--force` 会重新构建 `~/.cybertrain` 下的副本。
- `cybertrain doctor` 检查 C 工具链、SQLite 头文件和 Spinel 的安装情况。
- `cybertrain version` 打印版本。

`db`、`server` 和 `build` 需在应用目录内运行；NAME 是其 `spin.toml` 中的 `[package] name`。

每个运行 `spin` 的命令（`new`、`db`、`server`、`build`、`spin`）都会先确保有 `Cybertrain::SPINEL_TAG` 所指版本的 Spinel 可用。如果 `PATH` 上有 `spinel`（以及 `spin`），且其 `spinel --version` 报告的正是该版本，就直接使用它；否则使用 `cybertrain` 保存在 `~/.cybertrain/spinel/2026.10.27.7020/` 下的副本；如果也没有，`cybertrain` 就从 `Cybertrain::SPINEL_REPOSITORY` 的发布标签构建这份副本（`git clone`、`make deps`、`make -j`、`make install PREFIX=...`），只需一次，耗时几分钟。构建日志位于 `~/.cybertrain/log/spinel-2026.10.27.7020-build.log`（某一步失败时会打印其最后几行）；如果缺少构建所需的工具，`cybertrain` 会在开始前指出缺少哪个，并打印适用于你的平台的安装命令。`PATH` 上其他版本的 `spinel` 永远不会被使用或改动：`cybertrain` 会保留自己的副本（并在安装时说明这一点）。

`cybertrain setup` 会按需执行同样的操作，并且在正在使用的是它自己的副本时，打印把它加入 `PATH` 的那一行，方便你自己运行 `spin`（`~/.cybertrain/bin` 中存放指向当前所用版本的 `spinel` 和 `spin` 链接，所以版本升级后这一行仍然有效；`cybertrain spin ...` 则完全不需要 `PATH`）：

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

有两个环境变量可以覆盖以上所有行为：`CYBERTRAIN_HOME` 替代 `~/.cybertrain`（路径中不能有空格、引号、`$` 或 `:`，Spinel 的 Makefile 和 `PATH` 无法处理它们），`CYBERTRAIN_SPINEL_HOME=PREFIX` 则强制使用已有的安装——此时 `cybertrain` 使用 `PREFIX/bin` 中的 `spinel` 和 `spin`（如果 `spinel` 直接位于 `PREFIX` 中，则使用 `PREFIX` 本身中的），如果它们不是该版本，就报错并停止。

`cybertrain new` 会写出应用，其 `spin.toml` 指向与 CLI 相匹配的版本（`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`），确保 Spinel 已安装，然后运行 `spin lock`（spin 会把框架拉取到其缓存 `~/.cache/spin/packages/` 中，并在 `spin.lock` 中锁定提交）和 `spin run gen`，就像 `rails new` 会运行 `bundle install` 一样，最后打印接下来的步骤。框架的任何部分都不会被复制到应用中；请提交 `spin.toml` 和 `spin.lock`。如果 Spinel 或两个 `spin` 步骤之一失败，已写出的文件会保留，`new` 以状态码 1 退出，并打印排除原因后需要运行的命令（对于 Spinel：先运行 `cybertrain setup`，再在新目录中运行 `cybertrain spin
lock && cybertrain spin run gen`）。

`--skip-spin` 只写出文件：不安装 Spinel，不运行 `spin lock`，也不运行 `spin run gen`。`--path DIR` 改为依赖本地检出的代码，`--git URL [--ref R]` 依赖位于 URL 的框架（分支或标签 R），`--version V` 则在 cybertrain 进入 `spin-index` 后依赖索引中的版本。`--path`、`--version` 和 `--git` 只能给出其中一个；`--ref` 需要配合 `--git`。

开发 cybertrain 本身时，请从检出的代码运行 CLI（`spin install` 会把 `bin/cybertrain.rb` 构建到 `~/.local/bin/cybertrain`；`ruby -I.
bin/cybertrain.rb` 也可以），并用 `cybertrain
new NAME --path ~/src/cybertrain`（检出代码所在的任意位置）创建依赖它的应用。
