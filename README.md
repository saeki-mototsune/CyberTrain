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

## Status

Pre-alpha. What is listed here works end to end.
[examples/blog](examples/blog) is the Rails "Getting Started" blog built on
it, in English and Japanese, with an admin user guarding its `/admin` pages.

- **Requests** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/requests.html)):
  routing (namespaces, scopes, formats and `respond_to`), controllers with
  concerns and `helper_method`, strong parameters, HTTP caching, cookies and
  an encrypted session, CSRF, a Content Security Policy, `force_ssl` and
  host checks, rate limiting.
- **Views** ([template language](https://saeki-mototsune.github.io/CyberTrain/guide/template-language.html)):
  ERB-style templates with components, application helpers, the number,
  form and Turbo helpers, and per-controller layouts.
- **Assets** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/assets.html)):
  digested stylesheets, images and JavaScript, with an import map.
- **Internationalization** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/i18n.html)):
  Rails' `t` and `l`, dictionaries compiled in, English and Japanese
  bundled.
- **Models** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/models.html)):
  SQLite with migrations; decimal, json, date and datetime columns;
  declared associations with `includes`; Rails' validators; model concerns;
  encrypted columns; bulk inserts and typed aggregates.
- **Authentication** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/authentication.html)):
  `cybertrain generate authentication` writes sign-in, sign-up or
  invite-only, password reset, confirmation, lockout, remember me, an
  account page and admin users into the application.
- **Other generators**: scaffold, file upload
  ([tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html#attachments)),
  helper, component and job.
- **Background work** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/background-and-operations.html)):
  job classes with retry policies, cron schedules, a jobs page, a cache
  store.
- **Realtime** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/realtime.html)):
  Turbo Streams over Server-Sent Events or WebSocket.
- **Outbound clients** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/external-services.html)):
  HTTP (streamed, gzip and Server-Sent Events responses), SMTP (plain or
  HTML mail, sent now or from a job), WebSocket feeds.
- **Tests** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/testing.html)):
  Rails' test classes (`ActiveSupport::TestCase`,
  `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`) with
  `setup` / `teardown`, fixtures, `travel_to`, `assert_select`, and
  broadcast, mail and job assertions, all run by `cybertrain test` as one
  compiled program.
- **Time** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/configuration.html#time-zones)):
  the time helpers (`5.minutes.ago`, `beginning_of_day`) in a configured
  time zone.
- **Operations** ([guide](https://saeki-mototsune.github.io/CyberTrain/guide/background-and-operations.html#logs)):
  log lines with the time, the level and tags, a request id on every
  request and in the jobs it queues, JSON lines for a log collector, error
  reporting (`Cybertrain.error`, subscribers, and Sentry or GlitchTip
  through `require "cybertrain/error_reporter/sentry"`), and a console
  over the models.

Not built: mailer classes (a mailer is a module whose methods return a
`MailMessage` to `deliver_later`), mail attachments, HTTP/2
([what differs from Rails](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html#differences-from-rails)).

Since 2026-11-05 porting an existing Rails application by hand is a goal
([design record](docs/design.md), D1). A port is a rewrite against
cybertrain's API, not Rails code run unchanged. The five phases planned for
it have shipped, and a SQLite database that a Rails application created can
be taken over as it is
([guide](https://saeki-mototsune.github.io/CyberTrain/guide/models.html#taking-over-a-database-rails-created)).

## Quick start

Needs Ruby 3.2+, a C toolchain, `make`, `git`, `curl` and the SQLite, zlib and
OpenSSL headers ([details](https://saeki-mototsune.github.io/CyberTrain/guide/install.html#requirements); `cybertrain doctor`
checks them).

```sh
gem install cybertrain
cybertrain new blog    # also installs Spinel, the first time (a few minutes)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000/articles; a Ruby edit shows at once from a CRuby preview, then the compiled binary takes over
cybertrain build       # production: one binary in dist/
```

The binary runs every role a deployment needs: `./blog server` for HTTP and
the realtime endpoint (`turbo_stream_from @article` on a page,
`Cybertrain::Stream.broadcast_append_to` from an action or a job),
`./blog worker` for jobs and scheduled tasks (several may share the
database; jobs are delivered at least once), `./blog feeds` for WebSocket
subscriptions, and `./blog console` for a prompt over the models. A new
app's `bin/blog.rb` requires only the core; jobs, Turbo Streams, feeds, the
mailer, the cache, rate limiting and sending error reports to Sentry are one `require` line each, so an app
compiles only what it uses
([subsystems](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html#subsystems)).

Or try it with nothing installed:
[open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
([what the playground holds](https://saeki-mototsune.github.io/CyberTrain/playground.html)).

On one CPU core, with 16 connections, the blog served 2.2 to 8.8 times the
requests per second of the same app in Rails 8.1, in about a tenth of the
memory, in the run of 2026-11-05
([numbers](https://saeki-mototsune.github.io/CyberTrain/index.html#performance));
the blog has grown since and the comparison has not been re-run
([what has changed](docs/benchmark.md#the-apps-today)).

## Documentation

| | |
| --- | --- |
| [Tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) | Build the blog step by step: scaffold, comments, authentication, uploads, deployment |
| [Installing](https://saeki-mototsune.github.io/CyberTrain/guide/install.html) | Requirements (Ruby with `fiddle` for the CRuby preview), the `cybertrain` command, how Spinel and the framework are installed |
| [How it works](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html) | Build-time code generation, interpreted views, the server, the development loop (the CRuby preview and the compiled binary that takes over), and a table of the differences from Rails |
| [Models and the database](https://saeki-mototsune.github.io/CyberTrain/guide/models.html) | Migrations, column types, queries, associations, validations, encrypted columns, transactions, taking over a Rails database |
| [Requests](https://saeki-mototsune.github.io/CyberTrain/guide/requests.html) | Routing, formats and `respond_to`, concerns, strong parameters, HTTP caching, cookies and the session, rate limiting, CSP, `force_ssl` and hosts, headers, query strings and request bodies |
| [Authentication](https://saeki-mototsune.github.io/CyberTrain/guide/authentication.html) | `generate authentication`: sign-in, sign-up or invite-only, password reset, confirmation, lockout, remember me, the account page, admin users |
| [Assets](https://saeki-mototsune.github.io/CyberTrain/guide/assets.html) | Digested stylesheets, images and JavaScript, CSS `url()`, the helpers, the import map, serving |
| [Internationalization](https://saeki-mototsune.github.io/CyberTrain/guide/i18n.html) | Dictionaries in `config/locales`, `t` and `l`, lazy lookup, plural forms, the locale per request, translated validation messages |
| [Configuration](https://saeki-mototsune.github.io/CyberTrain/guide/configuration.html) | `config/app.rb`, environment variables, time zones |
| [Background work and operations](https://saeki-mototsune.github.io/CyberTrain/guide/background-and-operations.html) | Job classes, retries and concurrency keys (delivered at least once, so make jobs idempotent), `every` and `cron` tasks, the jobs page, the `worker` and `feeds` process roles, the cache store, the console, backups, the health check, logs and request ids, error reporting to Sentry |
| [Realtime](https://saeki-mototsune.github.io/CyberTrain/guide/realtime.html) | Turbo Streams over Server-Sent Events or WebSocket, broadcasts from actions, jobs and feeds, signed stream names, feed health |
| [Outbound HTTP, WebSocket feeds and e-mail](https://saeki-mototsune.github.io/CyberTrain/guide/external-services.html) | `HttpClient` (streaming, gzip, redirects, Server-Sent Events), `WebSocket.subscribe` (timers, restarts), `Mailer` (HTML mail, `deliver_later`) |
| [Testing](https://saeki-mototsune.github.io/CyberTrain/guide/testing.html) | Test classes, fixtures, `cybertrain test`, time travel, components and streams, mail, jobs, outbound calls, logs and error reports, CI |
| [Upgrading](https://saeki-mototsune.github.io/CyberTrain/guide/upgrading.html) | Moving an application to a newer release: the procedure, step by step, and the notes of each release |
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
