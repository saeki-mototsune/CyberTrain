# cybertrain

A Rails-like web application framework written natively for
[Spinel](https://github.com/matz/spinel), matz's ahead-of-time Ruby compiler.
Applications compile with `spin build` into a single native binary.

Status: pre-alpha, under construction. The architecture and every settled
decision live in [docs/design.md](docs/design.md) (Japanese).

## Requirements

- Spinel `2026.09.12` (`spinel` and `spin` on PATH)
- A C toolchain and the SQLite headers/library

## Development

```sh
spin test          # run the framework's own tests
```
