<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/assets/brand/lockup-stacked-dark.svg">
    <img alt="CyberTrain" src="site/assets/brand/lockup-stacked-light.svg" width="360">
  </picture>
</p>
<p align="center">
  <a href="https://saeki-mototsune.github.io/CyberTrain/">Homepage</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/tutorial.html">Tutorial</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/guide/">Guides</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/api/">API reference</a>
</p>


# cybertrain

A Rails-shaped web framework written natively for
[Spinel](https://github.com/matz/spinel), matz's ahead-of-time Ruby compiler.
`cybertrain build` compiles your controllers, models, views and the framework
into **one native binary**: no Rack, no gems at runtime, no Ruby interpreter
in production. The Rails vocabulary (`before_action`, `Article.where(...)`,
`resources :articles`) comes from plain Ruby generated at build time instead
of runtime metaprogramming.

**Status:** pre-alpha. Routing, controllers, sessions/CSRF, ERB-style
templates with components and application helpers, SQLite models
(decimal, json, date and datetime columns; declared associations with
`includes`; Rails' validators; encrypted columns; bulk inserts and typed
aggregates), migrations, and the authentication and file-upload generators
all work end to end. So do background jobs (job classes with retry
policies, cron schedules, a jobs page), a cache store, Turbo Streams over
Server-Sent Events or WebSocket, and the outbound clients: HTTP (streamed,
gzip and Server-Sent Events responses), SMTP (plain or HTML mail, sent now
or from a job) and WebSocket feeds. [examples/blog](examples/blog) is the
Rails "Getting Started" blog built on it. Since 2026-11-05 porting an
existing Rails application is a goal, in five phases
([design record](docs/design.md), D1); a SQLite database that a Rails
application created can be taken over as it is. Not built: an asset
pipeline, i18n, mailer classes (a mail is a method that calls
`Mailer.deliver` or `deliver_later`), mail attachments, HTTP/2
([what differs from Rails](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html#differences-from-rails)).

## Quick start

Needs Ruby 3.2+, a C toolchain, `make`, `git`, `curl` and the SQLite and zlib
headers ([details](https://saeki-mototsune.github.io/CyberTrain/guide/install.html#requirements); `cybertrain doctor`
checks them).

```sh
gem install cybertrain
cybertrain new blog    # also installs Spinel, the first time (a few minutes)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # production: one binary in dist/
```

The binary runs every role a deployment needs: `./blog server` for HTTP and
the realtime endpoint (`turbo_stream_from @article` on a page,
`Cybertrain::Stream.broadcast_append_to` from an action or a job),
`./blog worker` for jobs and scheduled tasks (several may share the
database; jobs are delivered at least once), `./blog feeds` for WebSocket
subscriptions, and `./blog console` for a prompt over the models.

Or try it with nothing installed:
[open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
([what the playground holds](https://saeki-mototsune.github.io/CyberTrain/playground.html)).

On one CPU core, with 16 connections, the blog serves 2.2 to 8.8 times the requests per second of
the same app in Rails 8.1, in about a tenth of the memory
([numbers](https://saeki-mototsune.github.io/CyberTrain/index.html#performance)).

## Documentation

| | |
| --- | --- |
| [Tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) | Build the blog step by step: scaffold, comments, authentication, uploads, deployment |
| [Installing](https://saeki-mototsune.github.io/CyberTrain/guide/install.html) | Requirements, the `cybertrain` command, how Spinel and the framework are installed |
| [How it works](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html) | Build-time code generation, interpreted views, the server, the development loop, and a table of the differences from Rails |
| [Models and the database](https://saeki-mototsune.github.io/CyberTrain/guide/models.html) | Migrations, column types, queries, associations, validations, encrypted columns, transactions, taking over a Rails database |
| [Requests](https://saeki-mototsune.github.io/CyberTrain/guide/requests.html) | Rate limiting, the client address, parameterised headers, query strings and request bodies |
| [Configuration](https://saeki-mototsune.github.io/CyberTrain/guide/configuration.html) | `config/app.rb`, environment variables, time zones |
| [Background work and operations](https://saeki-mototsune.github.io/CyberTrain/guide/background-and-operations.html) | Job classes, retries and concurrency keys (delivered at least once, so make jobs idempotent), `every` and `cron` tasks, the jobs page, the `worker` and `feeds` process roles, the cache store, the console, backups, the health check |
| [Realtime](https://saeki-mototsune.github.io/CyberTrain/guide/realtime.html) | Turbo Streams over Server-Sent Events or WebSocket, broadcasts from actions, jobs and feeds, signed stream names, feed health |
| [Outbound HTTP, WebSocket feeds and e-mail](https://saeki-mototsune.github.io/CyberTrain/guide/external-services.html) | `HttpClient` (streaming, gzip, redirects, Server-Sent Events), `WebSocket.subscribe` (timers, restarts), `Mailer` (HTML mail, `deliver_later`) |
| [Testing](https://saeki-mototsune.github.io/CyberTrain/guide/testing.html) | Writing tests for an app, outbound calls, jobs, CI |
| [Deploying](https://saeki-mototsune.github.io/CyberTrain/deploy.html) | To a server with systemd, or with Kamal |
| [API reference](https://saeki-mototsune.github.io/CyberTrain/api/) | Every class and method an application uses; also [the template language](https://saeki-mototsune.github.io/CyberTrain/guide/template-language.html) |
| [Design record](docs/design.md) · [benchmark](docs/benchmark.md) · [spikes](spikes/NOTES.md) | Why it is built this way, and the Spinel constraints behind it |

The guides' Markdown sources are in [docs/guide/](docs/guide/).

## Contributing

Bug reports, questions and pull requests are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md) (setup, tests, the commit gate, releasing).
Security issues go through [SECURITY.md](SECURITY.md).

## License

MIT; see [LICENSE](LICENSE).
