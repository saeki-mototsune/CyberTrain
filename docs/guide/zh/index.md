---
source_sha256: 02b6af743ad823cd90594a88e40d3594e25244a063e7be2d82f628582e136fc7
title: 指南
---
# 指南

CyberTrain 文档中 API 参考之外的全部内容：一步步构建博客的教程，以及框架每个领域各自的指南。

<!-- list: next-list -->
- [**教程**](tutorial.md) — 一步步构建博客：脚手架、评论、登录、上传、部署
- [**安装**](install.md) — 环境要求、`cybertrain` 命令、Spinel 与框架的安装方式
- [**工作原理**](how-it-works.md) — 构建时代码生成、解释执行的视图、服务器、开发循环，以及与 Rails 的差异表
- [**模型与数据库**](models.md) — 迁移、`where` 之外的查询、分页、事务、列名、排序
- [**请求**](requests.md) — 限流、客户端地址、参数化的请求头、查询字符串与请求体
- [**配置**](configuration.md) — `config/app.rb`、环境变量、时区
- [**后台任务与运维**](background-and-operations.md) — 多线程运行的作业、定时任务、`worker` 与 `feeds` 进程角色、控制台、备份、健康检查
- [**实时**](realtime.md) — 基于 Server-Sent Events 或 WebSocket 的 Turbo Streams，来自动作、作业和数据订阅的广播，签名的流名称
- [**出站 HTTP、WebSocket 订阅与电子邮件**](external-services.md) — `HttpClient`、`WebSocket.subscribe`、`Mailer`
- [**测试**](testing.md) — 为应用编写测试、出站调用、CI
- [**模板语言**](template-language.md) — 辅助方法、组件、表单构建器，以及模板在 `app/views/**/*.html.erb` 中可以调用的内容
