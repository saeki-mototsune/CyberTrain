<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/assets/brand/lockup-stacked-dark.svg">
    <img alt="CyberTrain" src="site/assets/brand/lockup-stacked-light.svg" width="360">
  </picture>
</p>
<p align="center">
  <a href="https://saeki-mototsune.github.io/CyberTrain/">Homepage</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/tutorial.html">Tutorial</a> ·
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
templates, SQLite models with validations and associations, migrations,
authentication and file-upload generators, background jobs, outbound HTTP,
SMTP and WebSocket clients all work end to end;
[examples/blog](examples/blog) is the Rails "Getting Started" blog built on
it. Not built: a WebSocket server, an asset pipeline, i18n, mailer classes
([what differs from Rails](https://saeki-mototsune.github.io/CyberTrain/api/file.how-it-works.html#differences-from-rails)).

## Quick start

Needs Ruby 3.2+, a C toolchain, `make`, `git`, `curl` and the SQLite and zlib
headers ([details](https://saeki-mototsune.github.io/CyberTrain/api/file.install.html#requirements); `cybertrain doctor`
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

Or try it with nothing installed:
[open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
([what the playground holds](https://saeki-mototsune.github.io/CyberTrain/api/file.install.html#try-it-in-the-browser)).

On one CPU core the blog serves 2.6 to 12.2 times the requests per second of
the same app in Rails 8.1, in about a tenth of the memory
([numbers](https://saeki-mototsune.github.io/CyberTrain/api/file.how-it-works.html#performance)).

## Documentation

| | |
| --- | --- |
| [Tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) · [walkthrough](https://saeki-mototsune.github.io/CyberTrain/api/file.walkthrough.html) | Build the blog step by step: scaffold, comments, authentication, uploads, deployment |
| [Installing](https://saeki-mototsune.github.io/CyberTrain/api/file.install.html) | Requirements, the playground, every `cybertrain` command, how Spinel is installed |
| [How it works](https://saeki-mototsune.github.io/CyberTrain/api/file.how-it-works.html) | Build-time code generation, differences from Rails, performance |
| [Models and the database](https://saeki-mototsune.github.io/CyberTrain/api/file.models.html) | Migrations, queries beyond `where`, pagination |
| [Requests](https://saeki-mototsune.github.io/CyberTrain/api/file.requests.html) | Rate limiting, the client address, parameterised headers |
| [Configuration](https://saeki-mototsune.github.io/CyberTrain/api/file.configuration.html) | `config/app.rb`, environment variables, time zones |
| [Background work and operations](https://saeki-mototsune.github.io/CyberTrain/api/file.background-and-operations.html) | Jobs, scheduled tasks, backups, the health check |
| [Outbound HTTP, WebSocket feeds and e-mail](https://saeki-mototsune.github.io/CyberTrain/api/file.external-services.html) | `HttpClient`, `WebSocket.subscribe`, `Mailer` |
| [Testing](https://saeki-mototsune.github.io/CyberTrain/api/file.testing.html) | Writing tests for an app, outbound calls, CI |
| [Deploying](https://saeki-mototsune.github.io/CyberTrain/deploy.html) | To a server with systemd, or with Kamal |
| [API reference](https://saeki-mototsune.github.io/CyberTrain/api/) | Every class and method an application uses; also [the template language](https://saeki-mototsune.github.io/CyberTrain/api/file.template-language.html) |
| [Design record](docs/design.md) · [benchmark](docs/benchmark.md) · [spikes](spikes/NOTES.md) | Why it is built this way, and the Spinel constraints behind it |

The guides' Markdown sources are in [docs/guide/](docs/guide/).

## Contributing

Bug reports, questions and pull requests are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md) (setup, tests, the commit gate, releasing).
Security issues go through [SECURITY.md](SECURITY.md).

## License

MIT; see [LICENSE](LICENSE).
