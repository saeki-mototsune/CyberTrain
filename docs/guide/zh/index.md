---
source_sha256: dd0210788bb4d555f4969d357b102d23620f552a33d2a0ef7869ccee0a0bfce0
title: 指南
---
# 指南

CyberTrain 文档中 API 参考之外的全部内容：一步步构建博客的教程，以及框架每个领域各自的指南。

<!-- list: next-list -->
- [**教程**](tutorial.md) — 一步步构建博客：脚手架、评论、登录、上传、部署
- [**安装**](install.md) — 环境要求、`cybertrain` 命令、Spinel 与框架的安装方式
- [**工作原理**](how-it-works.md) — 构建时代码生成、解释执行的视图、服务器、开发循环，以及与 Rails 差异的完整列表
- [**模型与数据库**](models.md) — 迁移、`where` 之外的查询、分页
- [**请求**](requests.md) — 限流、客户端地址、参数化的请求头、查询字符串与请求体
- [**配置**](configuration.md) — `config/app.rb`、环境变量、时区
- [**后台任务与运维**](background-and-operations.md) — 作业、定时任务、备份、健康检查
- [**出站 HTTP、WebSocket 订阅与电子邮件**](external-services.md) — `HttpClient`、`WebSocket.subscribe`、`Mailer`
- [**测试**](testing.md) — 为应用编写测试、出站调用、CI
- [**模板语言**](template-language.md) — 辅助方法、表单构建器，以及模板在 `app/views/**/*.html.erb` 中可以调用的内容
