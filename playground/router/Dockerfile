# playground/router/Dockerfile -- the hosted playground's router (SP2): stock
# Caddy with a static Caddyfile and three static pages. Kamal builds it
# (playground/deploy/router.yml); playground/dev/compose.yml runs it locally.
# Run it with --dns 127.0.0.1: it needs no outside name, and the ids of ended
# sessions must not reach the host's resolver. entrypoint.sh starts Caddy
# listening only on the router's address on the network of its default route.
FROM caddy:2.11.4-alpine
COPY playground/router/Caddyfile /etc/caddy/Caddyfile
COPY playground/router/pages/ /srv/pages/
COPY playground/router/entrypoint.sh /usr/local/bin/router-entrypoint
# Defaults for validation and local runs; Kamal sets the real values.
ENV PLAY_DOMAIN=play.localhost \
    PLAY_PUBLIC_URL=http://play.localhost:8080 \
    PLAY_SUBNET_POOL=10.250.0.0/16
# The bind as entrypoint.sh relies on it: ROUTER_BIND's address alone, and
# without it every address (an empty bind must not mean no listener).
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
 && caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile | grep -q '"listen":\[":80"\]' \
 && ROUTER_BIND=192.0.2.1 caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile | grep -q '"listen":\["192.0.2.1:80"\]'
ENTRYPOINT ["/usr/local/bin/router-entrypoint"]
