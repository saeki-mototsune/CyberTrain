---
title: Guides
---
# Guides

Everything CyberTrain's documentation covers beyond the API reference: the tutorial that builds the blog step by step, then a guide for each area of the framework.

<!-- list: next-list -->
- [**Tutorial**](tutorial.md) — Build the blog step by step: scaffold, comments, live updates with Turbo, a background job, authentication, uploads, deployment
- [**Installing**](install.md) — Requirements, the `cybertrain` command, how Spinel and the framework are installed
- [**How it works**](how-it-works.md) — Build-time code generation, interpreted views, the server, the development loop, and a table of the differences from Rails
- [**Models and the database**](models.md) — Migrations, column types, queries, associations, validations, encrypted columns, transactions, taking over a Rails database
- [**Requests**](requests.md) — Routing, formats and `respond_to`, concerns, strong parameters, HTTP caching, cookies and the encrypted session, rate limiting, the Content Security Policy, `force_ssl` and host checks, headers, query strings and request bodies
- [**Assets**](assets.md) — Digested stylesheets, images and JavaScript, CSS `url()`, the helpers, the import map, serving and retention
- [**Configuration**](configuration.md) — `config/app.rb`, environment variables, time zones
- [**Background work and operations**](background-and-operations.md) — Job classes, retries, `every` and `cron` tasks, the jobs page, the `worker` and `feeds` process roles, the cache store, the console, backups, the health check
- [**Realtime**](realtime.md) — Turbo Streams over Server-Sent Events or WebSocket, broadcasts from actions, jobs and feeds, signed stream names, feed health
- [**Outbound HTTP, WebSocket feeds and e-mail**](external-services.md) — `HttpClient` with streaming, gzip and Server-Sent Events, `WebSocket.subscribe` with timers and restarts, `Mailer` with HTML mail and `deliver_later`
- [**Testing**](testing.md) — Writing tests for an app, outbound calls, jobs, CI
- [**The template language**](template-language.md) — Helpers, components, the form builder and what a template may call in `app/views/**/*.html.erb`
