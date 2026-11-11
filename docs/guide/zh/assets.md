---
source_sha256: f33d41101fb56e6a4ccb2fd65374062a590ba781adb2baf79d57aef2a6aefb2c
---
# 资源

采用 Rails 8 目录布局的样式表、图片和 JavaScript：`spin run gen` 把它们加上摘要写入 `public/assets/`，改写 CSS 中的 `url()` 引用，并把清单和 import map 编译进二进制；标签辅助方法写出带摘要的路径，服务器让它们缓存一年。

## 源文件与逻辑路径

```text app/
app/assets/stylesheets/application.css    application.css
app/assets/images/logo.svg                logo.svg
app/javascript/application.js             application.js
app/javascript/controllers/hello.js       controllers/hello.js
vendor/javascript/chart.js                chart.js
```

`app/assets/` 下的每个直接子目录都是一个根，`app/javascript/` 和 `vendor/javascript/` 也是：文件的逻辑路径是它在根之下的路径（上面右侧一列），也就是辅助方法接受的名称。同一个逻辑路径出现在两个根之下时，`spin run gen` 会停止并指出两个文件。根之下的点文件（`.keep`）和符号链接目录会被跳过，但本身是符号链接的根（`app/assets`、`app/javascript`、`vendor/javascript`）会让 gen 停止并指出它；符号链接文件如果仍在它所在的目录树内就会被读取，指向树外或不存在目标的链接会让 gen 停止。含有空格或控制字符的路径会被拒绝。单独的 CSS 构建（Sass、Tailwind）可以写入 `app/assets/builds/`，它和其他根一样。

## 摘要与保留

`spin run gen` 把每个文件写成 `public/assets/<名称>-<摘要>.<扩展名>`，摘要是内容 SHA-256 的前 8 个十六进制字符（Propshaft 的短摘要）：`application.css` 变成 `application-1a2b3c4d.css`。`gen/assets.rb` 以生成的 `case` 形式保存从逻辑路径到带摘要路径的表，以及 import map 和它的预加载项，并被编译进二进制，所以程序旁边只需要 `public/assets/`。修改过的文件会得到新名称；旧文件从不被改写。

旧的摘要会被保留，这样部署前加载的页面，或滚动部署期间仍在运行的旧进程，都能找到其 HTML 所引用的文件：对每个逻辑路径，gen 保留当前摘要和之前的两个，删除更旧的文件，就像 Propshaft 的 `assets:clean` 保留三个版本一样。历史记录在 `public/assets/.manifest` 中（每个逻辑路径一行：路径，然后最多三个摘要），所以 `gen/assets.rb` 仍然只由源文件决定，`spin run gen -- --check` 也只比较它。`public/assets/` 是构建产物：`cybertrain new` 写出的 `.gitignore` 中列有 `/public/assets/`，`cybertrain build` 和镜像构建会运行 gen。

开发循环会监视 `app/assets/**`、`app/javascript/**` 和 `vendor/javascript/**`，所以保存样式表会重新运行 gen，下一个页面就会加载新的摘要。

## CSS 的 `url()`

样式表中指向某个资源的 `url()` 会被改写为带摘要的路径，与 Propshaft 的编译器一样；样式表在它所引用的文件之后才计算摘要，所以当它用到的图片变化时，它自己的摘要也会变化：

```css
.brand { background: url("logo.svg") no-repeat; }
/* in public/assets/application-1a2b3c4d.css: */
.brand { background: url("/assets/logo-8177afd7.svg") no-repeat; }
```

路径相对于样式表的**逻辑**目录解析（以 `/` 开头时从根开始）：从 `application.css` 出发，`logo.svg` 是逻辑路径 `logo.svg`，而 `../images/logo.svg` 会越过根，不是资源。`?query` 或 `#fragment` 会保留在带摘要的路径之后。`data:`、`http:`、`https:`、`//`、`#` 和 `%23` 目标保持不变；其他不是资源的目标按原样保留，gen 会给出警告。互相引用形成循环的样式表会让 gen 停止（`CSS url() cycle: a.css -> b.css -> a.css`）。

## 辅助方法

```erb
<%= stylesheet_link_tag "application" %>        <%# <link rel="stylesheet" href="/assets/application-1a2b3c4d.css"> %>
<%= javascript_include_tag "legacy" %>          <%# <script src="/assets/legacy-5e6f7a8b.js"></script> %>
<%= image_tag "logo.svg", alt: "CyberTrain", size: "32x32" %>
<%= asset_path "logo.svg" %>                    <%# /assets/logo-8177afd7.svg %>
```

名称缺少扩展名时，`stylesheet_link_tag` 加上 `.css`，`javascript_include_tag` 加上 `.js`；两者都接受 `nonce: true`，`stylesheet_link_tag` 还接受 `media:`。带协议的 URL（或 `//`、`data:`）按原样写出，以 `/` 开头的路径也一样。未知的逻辑名称在开发和测试环境中抛出 `Cybertrain::Assets::UnknownAsset`（`asset "logo.png" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)`）；生产环境只记录一次日志并写出 `/assets/<名称>`。完整签名见[模板语言](template-language.md#helpers-and-the-form-builder)。

## Import map

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin "chart", to: "chart.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
```

gen 把这个文件当作文本读取，从不执行它：`pin name, to:, preload:` 和 `pin_all_from dir, under:, preload:`、注释和空行；其他任何行都会让 gen 停止。不带协议的 `to:` 是资源的逻辑路径，没有 `to:` 的 pin 指向 `<name>.js`；`pin_all_from` 把目录下的每个 `.js` 文件以 `<under>/<去掉 .js 的路径>` 固定，`index.js` 则固定为 `under` 本身。`preload:` 默认为 true（importmap-rails 2）。在布局中，

```erb
<%= javascript_importmap_tags %>
```

会写出 `<script type="importmap">`、每个预加载 pin 的 `<link rel="modulepreload">` 以及 `<script type="module">import "application"</script>`，当 [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) 生效时，每个都带有请求的 nonce。没有 `bin/importmap pin`：把库复制到 `vendor/javascript/` 再固定它，或者固定一个 URL。不内置 Turbo。

## 提供文件

静态文件中间件对 `/assets/` 下名称带有 gen 所写摘要的文件（当前的摘要来自 `gen/assets.rb`，保留的摘要来自启动时读取的 `public/assets/.manifest`）使用 `Cache-Control: public, max-age=31536000, immutable` 提供；不需要 ETag，因为文件永远不会改变。`public/` 中的其他所有内容，包括应用放在 `public/assets/` 下的不带摘要的文件，仍然使用 `max-age=3600`。`/assets` 下的点文件（`.manifest`、中途失败的 gen 运行留下的临时文件）不会被提供；`public/` 其他位置的点文件（`/.well-known/...`）会被提供。真实路径离开 `public/` 的文件不会被提供：把 `public/assets` 做成指向 `public/` 之外目录的符号链接的部署方式（Capistrano 的共享目录），应改为在那里挂载或绑定挂载。自己提供 `public/` 的反向代理会发送它自己的响应头；请在那里给 `/assets/` 同样设置一年的 immutable 缓存。

## 迁移 `public/style.css`

在有资源功能之前创建的应用把 `public/style.css` 作为普通文件提供，并且继续可用。要迁移它：

```shell 终端 — 应用目录
mkdir -p app/assets/stylesheets app/javascript
git mv public/style.css app/assets/stylesheets/application.css
echo '/public/assets/' >> .gitignore
```

在 `app/views/layouts/application.html.erb` 中，把 `<link rel="stylesheet" href="/style.css">` 这一行换成 `<%= stylesheet_link_tag "application" %>`（有了 `config/importmap.rb` 之后，再加上 `<%= csp_meta_tag %>` 和 `<%= javascript_importmap_tags %>`），把样式表引用的图片移到 `app/assets/images/` 并改用 `url("logo.svg")` 这样的引用，然后运行 `spin run gen`。

## Kamal 的 `asset_path`

构建全新镜像的部署（Kamal、Docker）只带有当前的摘要。`cybertrain new` 写出的 `config/deploy.yml` 中有

```yaml
asset_path: /app/public/assets
```

所以在切换期间，Kamal 会把上一个版本的文件衔接到新容器中：部署前加载的页面仍能找到其 HTML 引用的 CSS 和 JavaScript。请在较旧的 `config/deploy.yml` 中加上这一行。
