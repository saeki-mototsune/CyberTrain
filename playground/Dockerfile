# syntax=docker/dockerfile:1
#
# The cybertrain playground image: Ubuntu 24.04, the cybertrain CLI and
# Spinel built from this checkout, a bare mirror of this repository for
# `cybertrain new`, and the tutorial blog prebuilt in /workspace/blog.
# .devcontainer/devcontainer.json (GitHub Codespaces) runs it; CI publishes
# it as ghcr.io/saeki-mototsune/cybertrain-playground. See playground/README.md.
#
#   docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .
#
# Always name the target: a later stage adds a browser editor.
# The context is the repository root and must hold the .git directory (a
# clone, not a git worktree, whose .git is a file): the mirror is made from
# it through a bind mount, so .git never lands in a layer.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Exactly the files cybertrain.gemspec packages, so that a change to the
# framework alone keeps the gem and Spinel layers cached. A file added to
# spec.files must be added here too (gem build fails otherwise).
FROM scratch AS cli-src
COPY cybertrain.gemspec README.md /src/
COPY exe/cybertrain /src/exe/
COPY cybertrain/version.rb cybertrain/cli.rb /src/cybertrain/
COPY cybertrain/cli/ /src/cybertrain/cli/
COPY cybertrain/generator/inflector.rb /src/cybertrain/generator/

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS toolchain

LABEL org.opencontainers.image.source="https://github.com/saeki-mototsune/cybertrain" \
      org.opencontainers.image.title="cybertrain-playground" \
      org.opencontainers.image.description="Try cybertrain without installing it: Spinel, the cybertrain CLI and the tutorial blog, prebuilt." \
      org.opencontainers.image.licenses="MIT"

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    CYBERTRAIN_HOME=/opt/cybertrain \
    XDG_CACHE_HOME=/opt/cybertrain-cache \
    PATH=/opt/cybertrain/bin:${PATH}

# Ruby 3.2 for the CLI, a C toolchain, make, git, curl and the SQLite headers
# (what `cybertrain doctor` checks); gcc + libc6-dev rather than
# build-essential (no g++). procps: ps/pgrep for terminals and smoke.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git gcc make libc6-dev libsqlite3-dev procps ruby \
 && rm -rf /var/lib/apt/lists/*

# User dev, uid/gid 1000 (ubuntu:24.04 ships "ubuntu" with 1000: removed
# first). Nothing the prebuilt app needs lives in its home directory.
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi; \
    if getent group 1000 >/dev/null; then groupdel "$(getent group 1000 | cut -d: -f1)"; fi; \
    groupadd --gid 1000 dev; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev; \
    install -d -o dev -g dev /opt/cybertrain /opt/cybertrain-cache /opt/cybertrain-mirror /workspace

# `cybertrain new` writes git = "https://github.com/saeki-mototsune/cybertrain";
# these rules make git (and so spin) clone the mirror below instead.
RUN git config --system url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain" \
 && git config --system --add url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain.git"

# The CLI gem, built from this checkout's cybertrain.gemspec (not rubygems.org).
RUN --mount=type=bind,from=cli-src,source=/src,target=/tmp/cli-src \
    cd /tmp/cli-src \
 && gem build cybertrain.gemspec --output /tmp/cybertrain.gem \
 && gem install --local --no-document /tmp/cybertrain.gem \
 && rm /tmp/cybertrain.gem \
 && cybertrain version

USER dev
WORKDIR /home/dev

# Spinel (Cybertrain::SPINEL_TAG) into $CYBERTRAIN_HOME: the slow step
# (41.5 s on 10 CPUs in the spike).
RUN cybertrain setup && cybertrain doctor

# The framework mirror: this checkout's HEAD as a one-commit bare repository
# with the tag v<VERSION> forced onto it, so an image built from an untagged
# commit still resolves ref = "v<VERSION>". Owned by dev, the user who clones it.
# The bind-mounted .git belongs to root, not dev: git checks a repository's
# owner in the upload-pack the fetch starts, which a -c on the fetch does not
# reach, so safe.directory goes on upload-pack's own command line.
RUN --mount=type=bind,source=.git,target=/tmp/checkout.git \
    set -eu; \
    if [ ! -d /tmp/checkout.git/objects ]; then \
      echo "playground/Dockerfile: the build context needs this repository's .git directory (a clone, not a worktree)" >&2; \
      exit 1; \
    fi; \
    version="$(ruby -e 'require "cybertrain/version"; print Cybertrain::VERSION')"; \
    mirror=/opt/cybertrain-mirror/cybertrain.git; \
    git init -q --bare --initial-branch=main "$mirror"; \
    git -C "$mirror" fetch -q --depth 1 --no-tags --upload-pack "git -c safe.directory='*' upload-pack" /tmp/checkout.git "+HEAD:refs/heads/main"; \
    git -C "$mirror" tag -f "v$version" main; \
    git -C "$mirror" rev-parse --verify -q "refs/tags/v$version" >/dev/null

# ---------------------------------------------------------------------------
FROM toolchain AS playground

USER root
COPY playground/profile.sh /etc/profile.d/cybertrain-playground.sh
COPY --chmod=0755 playground/playground-server /usr/local/bin/playground-server
# Interactive non-login shells read /etc/bash.bashrc only.
RUN echo '[ -r /etc/profile.d/cybertrain-playground.sh ] && . /etc/profile.d/cybertrain-playground.sh' >> /etc/bash.bashrc

USER dev
WORKDIR /workspace
# Tutorial step 02 (spin lock clones the mirror, then spin run gen).
RUN cybertrain new blog
WORKDIR /workspace/blog
# Step 03.
RUN cybertrain generate scaffold article title:string body:text
# Step 04: the root route.
COPY --chown=dev:dev playground/routes.rb config/routes.rb
# Step 07, then one full build: gen/ is current and build/bin/{gen,db,blog}
# exist, so the first `cybertrain server` compiles nothing. spin's freshness
# test compares mtimes: never copy this tree with anything but `cp -a`.
RUN cybertrain db migrate
RUN cybertrain spin run gen && cybertrain spin build blog
COPY --chown=dev:dev playground/PLAYGROUND.md PLAYGROUND.md
# One commit, so the Source Control view shows the visitor's own changes.
RUN git init -q -b main \
 && git add -A \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q -m "Tutorial steps 02-04 and 07: new, scaffold article, root route, db migrate" \
 && test -z "$(git status --porcelain)"

EXPOSE 3000
CMD ["playground-server"]

# ---------------------------------------------------------------------------
# The hosted playground's session image (SP2): the playground stage plus
# code-server. Only the control plane runs it (playground/control): a
# read-only root file system, empty tmpfs mounts on /tmp, /home/dev,
# /workspace and /opt/cybertrain-cache, and no network but its own internal
# one. Nothing here changes the playground stage, which Codespaces runs.
#
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
FROM playground AS web

ARG TARGETARCH
ARG CODE_SERVER_VERSION=4.139.1
# sha256 of code-server-<version>-linux-<arch>.tar.gz on the GitHub release
# (the release API's "digest" of each asset).
ARG CODE_SERVER_SHA256_AMD64=53029be6c5781b7bca49b815fcc9a2a3fc111813ad8c9965b2c0f0d2985a0674
ARG CODE_SERVER_SHA256_ARM64=0edb4b60d9c4744b2dd14b0911e3c2e6dd8c6f3c13bd58bda23ae744e59e7df1

USER root
# The version check runs with a throwaway HOME: a first run writes a config
# file there and logs that before the version line (hence the grep).
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) sum="$CODE_SERVER_SHA256_AMD64" ;; \
      arm64) sum="$CODE_SERVER_SHA256_ARM64" ;; \
      *) echo "playground/Dockerfile: no code-server for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tarball="code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL -o "/tmp/$tarball" \
        "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/$tarball"; \
    echo "$sum  /tmp/$tarball" | sha256sum -c -; \
    mkdir /usr/lib/code-server; \
    tar -xzf "/tmp/$tarball" -C /usr/lib/code-server --strip-components 1 --no-same-owner; \
    rm "/tmp/$tarball"; \
    ln -s /usr/lib/code-server/bin/code-server /usr/local/bin/code-server; \
    test "$(HOME=/tmp/cs-home code-server --version | grep -m 1 '^[0-9]' | cut -d ' ' -f 1)" = "$CODE_SERVER_VERSION"; \
    rm -rf /tmp/cs-home

# code-server's user settings (the entrypoint copies them into the session's
# home) and the session's entrypoint.
COPY playground/web/settings.json /opt/cybertrain-web/settings.json
COPY --chmod=0755 playground/web/playground-web /usr/local/bin/playground-web
# The router reaches the dev server at the session's own address, so the app
# listens on every interface (only the router shares the session's network).
# An empty gallery: an install could not download anything here (no network),
# and the visitor's browser then contacts no extension marketplace.
ENV CYBERTRAIN_HOST=0.0.0.0 \
    EXTENSIONS_GALLERY={}

USER dev
WORKDIR /workspace/blog
# The folderOpen task that starts the server in a visible terminal. It is the
# playground's, not the visitor's, so Source Control does not show it. The
# directory is made first so that dev owns it.
RUN mkdir .vscode
COPY --chown=dev:dev playground/web/tasks.json .vscode/tasks.json
# This environment's guide replaces the Codespaces one inside the one commit.
COPY --chown=dev:dev playground/web/PLAYGROUND.md PLAYGROUND.md
RUN echo '/.vscode/' >> .git/info/exclude \
 && git add PLAYGROUND.md \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q --amend --no-edit \
 && test -z "$(git status --porcelain)" \
 && test "$(git rev-list --count HEAD)" = 1

# What the entrypoint copies into the empty tmpfs mounts. cp -a keeps file
# times, so the copy is as fresh as the build (spin compares mtimes).
USER root
RUN mkdir -p /opt/cybertrain-web/seed \
 && cp -a /workspace /opt/cybertrain-web/seed/workspace \
 && cp -a /opt/cybertrain-cache /opt/cybertrain-web/seed/cybertrain-cache

USER dev
# The mount point itself, never a directory below it: a WORKDIR inside the
# /workspace tmpfs would make runc create it there, root-owned and empty,
# before the entrypoint runs, and the seed copy would then be skipped.
WORKDIR /workspace
EXPOSE 8080 3000
ENTRYPOINT ["/usr/local/bin/playground-web"]
CMD []
