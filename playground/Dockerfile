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
COPY cybertrain/version.rb cybertrain/app_name.rb cybertrain/ident.rb cybertrain/cli.rb /src/cybertrain/
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
