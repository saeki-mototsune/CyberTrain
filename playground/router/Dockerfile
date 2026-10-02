# playground/router/Dockerfile -- the hosted playground's router (SP2): stock
# Caddy with a static Caddyfile and three static pages. Kamal builds it
# (playground/deploy/router.yml); playground/dev/compose.yml runs it locally.
# Run it with --dns 127.0.0.1: it needs no outside name, and the ids of ended
# sessions must not reach the host's resolver.
FROM caddy:2.11.4-alpine
COPY playground/router/Caddyfile /etc/caddy/Caddyfile
COPY playground/router/pages/ /srv/pages/
# Defaults for validation and local runs; Kamal sets the real values.
ENV PLAY_DOMAIN=play.localhost \
    PLAY_PUBLIC_URL=http://play.localhost:8080 \
    PLAY_SUBNET_POOL=10.250.0.0/16
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
