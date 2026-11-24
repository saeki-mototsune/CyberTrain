---
source_sha256: 447d7230c2313f3f2c2544e19d67a25e08684ec740ae8e582774f589fce01f08
title: 指南
---
# 指南

CyberTrain 文档中 API 参考之外的全部内容：一步步构建博客的教程，把它继续推进的进阶教程，以及框架每个领域各自的指南。

<!-- list: next-list -->
- [**教程**](tutorial.md) — 一步步构建博客：安装、文章脚手架、校验、嵌套在文章下的评论、测试
- [**进阶教程**](advanced-tutorial.md) — 把博客继续推进：组件和辅助方法、用 Turbo 实时显示评论、后台作业、JSON、登录、上传图片、为部署构建
- [**安装**](install.md) — 环境要求、`cybertrain` 命令、Spinel 与框架的安装方式
- [**工作原理**](how-it-works.md) — 构建时代码生成、应用按需 require 的可选子系统、解释执行的视图、服务器、通过 FFI 使用的 SQLite、开发循环，以及与 Rails 的差异表
- [**模型与数据库**](models.md) — 迁移、列类型、查询、关联、校验、加密列、事务、接管 Rails 数据库
- [**请求**](requests.md) — 路由、格式与 `respond_to`、concern、强参数、HTTP 缓存、cookie 与加密的会话、限流、Content Security Policy、`force_ssl` 与主机检查、请求头、查询字符串与请求体
- [**认证**](authentication.md) — `generate authentication`：登录、开放注册或仅限邀请、密码重置、确认、锁定、保持登录、账户页面、管理员用户
- [**资源**](assets.md) — 带摘要的样式表、图片和 JavaScript、CSS 的 `url()`、辅助方法、import map、提供文件与保留
- [**国际化**](i18n.md) — `config/locales` 中的词典、`t` 和 `l`、惰性查找、复数形式、为每个请求选择语言区域、翻译后的验证消息、捆绑的英语和日语
- [**配置**](configuration.md) — `config/app.rb`、环境变量、时区
- [**后台任务与运维**](background-and-operations.md) — 作业类、重试、`every` 与 `cron` 任务、作业页面、`worker` 与 `feeds` 进程角色、缓存存储、控制台、备份、健康检查
- [**日志与错误报告**](logs-and-errors.md) — 日志行、级别与 JSON 行、请求 ID 与标签、`Cybertrain.error`、订阅者与过滤器、发送到 Sentry 或 GlitchTip
- [**实时**](realtime.md) — 基于 Server-Sent Events 或 WebSocket 的 Turbo Streams，来自动作、作业和数据订阅的广播，签名的流名称，数据订阅的健康状况
- [**出站 HTTP、WebSocket 订阅与电子邮件**](external-services.md) — 支持流式、gzip 和 Server-Sent Events 的 `HttpClient`，带定时器和重启的 `WebSocket.subscribe`，支持 HTML 邮件和 `deliver_later` 的 `Mailer`
- [**测试**](testing.md) — 为应用编写测试、出站调用、作业、日志与错误报告、CI
- [**升级**](upgrading.md) — 把应用迁移到更新的版本：带命令的分步流程，以及各版本的说明
- [**模板语言**](template-language.md) — 辅助方法、组件、表单构建器，以及模板在 `app/views/**/*.html.erb` 中可以调用的内容
