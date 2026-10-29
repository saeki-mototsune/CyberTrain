---
title: Guides
---
# Guides

Everything CyberTrain's documentation covers beyond the API reference: the tutorial that builds the blog step by step, then a guide for each area of the framework.

<!-- list: next-list -->
- [**Tutorial**](tutorial.md) — Build the blog step by step: scaffold, comments, authentication, uploads, deployment
- [**Installing**](install.md) — Requirements, the `cybertrain` command, how Spinel and the framework are installed
- [**How it works**](how-it-works.md) — Build-time code generation, interpreted views, the server, the development loop, and the full list of differences from Rails
- [**Models and the database**](models.md) — Migrations, queries beyond `where`, pagination
- [**Requests**](requests.md) — Rate limiting, the client address, parameterised headers
- [**Configuration**](configuration.md) — `config/app.rb`, environment variables, time zones
- [**Background work and operations**](background-and-operations.md) — Jobs, scheduled tasks, backups, the health check
- [**Outbound HTTP, WebSocket feeds and e-mail**](external-services.md) — `HttpClient`, `WebSocket.subscribe`, `Mailer`
- [**Testing**](testing.md) — Writing tests for an app, outbound calls, CI
- [**The template language**](template-language.md) — Helpers, the form builder and what a template may call in `app/views/**/*.html.erb`
