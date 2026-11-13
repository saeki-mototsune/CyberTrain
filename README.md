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

**Status:** pre-alpha. Routing (namespaces, scopes, formats and
`respond_to`), controllers with concerns, `helper_method`, strong
parameters, HTTP caching, cookies and an encrypted session, CSRF, a Content
Security Policy, `force_ssl` and host checks, ERB-style templates with
components, application helpers, the number, form and Turbo helpers and
per-controller layouts, digested assets with an import map, SQLite models
(decimal, json, date and datetime columns; declared associations with
`includes`; Rails' validators; model concerns; encrypted columns; bulk
inserts and typed aggregates), migrations, i18n (Rails' `t` and `l`,
dictionaries compiled in, English and Japanese bundled), and the
authentication generator (sign-in, sign-up or invite-only, password reset,
confirmation, lockout, remember me, an account page, admin users) and the
file-upload generator all work end to end. So do background jobs (job classes with retry
policies, cron schedules, a jobs page), a cache store, Turbo Streams over
Server-Sent Events or WebSocket, and the outbound clients: HTTP (streamed,
gzip and Server-Sent Events responses), SMTP (plain or HTML mail, sent now
or from a job) and WebSocket feeds, and the tests: Rails' test classes
(`ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`,
`ViewComponent::TestCase`) with `setup` / `teardown`, fixtures,
`travel_to`, `assert_select`, broadcast, mail and job assertions, all run
by `cybertrain test` as one compiled program, and the time helpers
(`5.minutes.ago`, `beginning_of_day`) in a configured time zone. [examples/blog](examples/blog) is the
Rails "Getting Started" blog built on it, in English and Japanese, with an
admin user guarding its `/admin` pages. Since 2026-11-05 porting an
existing Rails application is a goal, in five phases
([design record](docs/design.md), D1); a SQLite database that a Rails
application created can be taken over as it is. Not built: mailer
classes (a mailer is a module whose methods return a `MailMessage` to
`deliver_later`), mail attachments, HTTP/2
([what differs from Rails](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html#differences-from-rails)).

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
cybertrain server      # http://127.0.0.1:3000; a Ruby edit shows at once from a CRuby preview, then the compiled binary takes over
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
| [Installing](https://saeki-mototsune.github.io/CyberTrain/guide/install.html) | Requirements (Ruby with `fiddle` for the CRuby preview), the `cybertrain` command, how Spinel and the framework are installed |
| [How it works](https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html) | Build-time code generation, interpreted views, the server, the development loop (the CRuby preview and the compiled binary that takes over), and a table of the differences from Rails |
| [Models and the database](https://saeki-mototsune.github.io/CyberTrain/guide/models.html) | Migrations, column types, queries, associations, validations, encrypted columns, transactions, taking over a Rails database |
| [Requests](https://saeki-mototsune.github.io/CyberTrain/guide/requests.html) | Routing, formats and `respond_to`, concerns, strong parameters, HTTP caching, cookies and the session, rate limiting, CSP, `force_ssl` and hosts, headers, query strings and request bodies |
| [Authentication](https://saeki-mototsune.github.io/CyberTrain/guide/authentication.html) | `generate authentication`: sign-in, sign-up or invite-only, password reset, confirmation, lockout, remember me, the account page, admin users, upgrading from 0.4 |
| [Assets](https://saeki-mototsune.github.io/CyberTrain/guide/assets.html) | Digested stylesheets, images and JavaScript, CSS `url()`, the helpers, the import map, serving |
| [Internationalization](https://saeki-mototsune.github.io/CyberTrain/guide/i18n.html) | Dictionaries in `config/locales`, `t` and `l`, lazy lookup, plural forms, the locale per request, translated validation messages |
| [Configuration](https://saeki-mototsune.github.io/CyberTrain/guide/configuration.html) | `config/app.rb`, environment variables, time zones |
| [Background work and operations](https://saeki-mototsune.github.io/CyberTrain/guide/background-and-operations.html) | Job classes, retries and concurrency keys (delivered at least once, so make jobs idempotent), `every` and `cron` tasks, the jobs page, the `worker` and `feeds` process roles, the cache store, the console, backups, the health check |
| [Realtime](https://saeki-mototsune.github.io/CyberTrain/guide/realtime.html) | Turbo Streams over Server-Sent Events or WebSocket, broadcasts from actions, jobs and feeds, signed stream names, feed health |
| [Outbound HTTP, WebSocket feeds and e-mail](https://saeki-mototsune.github.io/CyberTrain/guide/external-services.html) | `HttpClient` (streaming, gzip, redirects, Server-Sent Events), `WebSocket.subscribe` (timers, restarts), `Mailer` (HTML mail, `deliver_later`) |
| [Testing](https://saeki-mototsune.github.io/CyberTrain/guide/testing.html) | Test classes, fixtures, `cybertrain test`, time travel, components and streams, mail, jobs, outbound calls, CI |
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
