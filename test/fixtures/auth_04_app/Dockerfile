# syntax=docker/dockerfile:1
# The production image `kamal deploy` builds and runs (config/deploy.yml).
# To try it by hand:
#   docker build -t shop .
#   docker run --rm -p 127.0.0.1:3000:3000 -e CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) \
#     -v shop_storage:/app/storage shop
# then open http://localhost:3000 (the session cookie is Secure in
# production; Chrome and Firefox accept it from localhost over http).
#
# The framework is fetched by spin from what spin.toml names (a git tag
# by default); an app created with --path needs a git or version
# dependency before it can be built here.

ARG UBUNTU_VERSION=24.04

# ---- build: Spinel, then `cybertrain build` -> /src/dist ----------------
FROM docker.io/library/ubuntu:$UBUNTU_VERSION AS build

# ruby-dev and the prism gem: Spinel's build runs a Ruby generator that
# requires prism, which 24.04's Ruby 3.2 does not bundle.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git curl ca-certificates \
      ruby ruby-dev libsqlite3-dev zlib1g-dev libjemalloc-dev && \
    rm -rf /var/lib/apt/lists/* && \
    gem install --no-document prism -v 1.9.0

# The cybertrain command, then the Spinel release it pins: a few minutes,
# cached as a layer until the version changes.
RUN gem install cybertrain -v 0.4.1 --no-document && cybertrain setup

WORKDIR /src
COPY . .
RUN cybertrain build

# ---- runtime: the binary, public/ and the libraries it links ----------
FROM docker.io/library/ubuntu:$UBUNTU_VERSION

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libsqlite3-0 zlib1g libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --system --create-home --shell /bin/bash app

WORKDIR /app
COPY --from=build --chown=app:app /src/dist/ /app/

# storage/ holds the SQLite database (storage/production.sqlite3); mount
# a volume there so it outlives the container.
USER app
# SPINEL_GC_FULL_INTERVAL=8: a full collection every eighth one. Left to
# adapt, Spinel's cadence falls to nearly every collection full under a
# server's request garbage; fixed at 8 it serves about 16% more requests
# a second on one CPU at the same memory (cybertrain's
# docs/spinel-feedback.md, item 5).
ENV CYBERTRAIN_ENV=production \
    CYBERTRAIN_HOST=0.0.0.0 \
    PORT=3000 \
    SPINEL_GC_FULL_INTERVAL=8
EXPOSE 3000

# Apply pending migrations, then serve. exec hands SIGTERM to the server,
# which finishes the requests in flight before it exits.
CMD ["sh", "-c", "./shop migrate && exec ./shop"]
