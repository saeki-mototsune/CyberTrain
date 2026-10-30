# syntax=docker/dockerfile:1
# The production image of the example blog, for `kamal deploy`
# (config/deploy.yml). An app made by `cybertrain new` gets a Dockerfile that
# installs the released gem and fetches the framework by its git tag; this
# one builds against the framework in this checkout instead, as spin.toml's
# `path = "../.."` does, so the build context is the repository root:
#
#   docker build -f examples/blog/Dockerfile -t blog .     # from the repository root
#   docker run --rm -p 127.0.0.1:3000:3000 -e CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) \
#     -v blog_storage:/app/storage blog
#
# Dockerfile.dockerignore, beside this file, decides what of the repository
# is sent.

ARG UBUNTU_VERSION=24.04

# ---- build: Spinel, then `cybertrain build` -> examples/blog/dist --------
FROM docker.io/library/ubuntu:$UBUNTU_VERSION AS build

# ruby-dev and the prism gem: Spinel's build runs a Ruby generator that
# requires prism, which 24.04's Ruby 3.2 does not bundle (1.9.0 is
# PRISM_VERSION in Spinel's Makefile at Cybertrain::SPINEL_TAG).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git curl ca-certificates \
      ruby ruby-dev libsqlite3-dev zlib1g-dev libjemalloc-dev && \
    rm -rf /var/lib/apt/lists/* && \
    gem install --no-document prism -v 1.9.0

# The CLI runs from the checkout (ruby -I/src exe/cybertrain), as CONTRIBUTING.md
# does. `cybertrain setup` builds the Spinel release the checkout pins (a few
# minutes); its layer is rebuilt whenever exe/ or cybertrain/ change.
WORKDIR /src
COPY cybertrain.gemspec cybertrain.rb spin.toml README.md /src/
COPY exe/ /src/exe/
COPY cybertrain/ /src/cybertrain/
RUN ruby -I/src exe/cybertrain setup

COPY examples/blog/ /src/examples/blog/
WORKDIR /src/examples/blog
RUN ruby -I/src /src/exe/cybertrain build

# ---- runtime: the binary, public/ and the libraries it links ------------
FROM docker.io/library/ubuntu:$UBUNTU_VERSION

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libsqlite3-0 zlib1g libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --system --create-home --shell /bin/bash app

WORKDIR /app
COPY --from=build --chown=app:app /src/examples/blog/dist/ /app/

# storage/ holds the SQLite database (storage/production.sqlite3); mount
# a volume there so it outlives the container.
USER app
# SPINEL_GC_FULL_INTERVAL=8: a full collection every eighth one. Left to
# adapt, Spinel's cadence falls to nearly every collection full under a
# server's request garbage; fixed at 8 it serves about 16% more requests
# a second on one CPU at the same memory (docs/spinel-feedback.md, 5).
ENV CYBERTRAIN_ENV=production \
    CYBERTRAIN_HOST=0.0.0.0 \
    PORT=3000 \
    SPINEL_GC_FULL_INTERVAL=8
EXPOSE 3000

# Apply pending migrations, then serve. exec hands SIGTERM to the server,
# which finishes the requests in flight before it exits.
CMD ["sh", "-c", "./blog migrate && exec ./blog"]
