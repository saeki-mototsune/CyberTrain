#!/bin/sh
# playground/router/entrypoint.sh -- the router image's entrypoint (SP2): Caddy
# listens only on this container's IPv4 address on the network that carries
# its default route (Kamal's network in production, the compose network
# locally). Session networks are --internal with inhibit_ipv4: no gateway, so
# never the default route, also after a `docker restart` that reattaches them.
# A session's connection to the router's address on its own network then gets
# a reset from the kernel instead of a connection Caddy accepts and holds
# until its request is aborted. The address is found at every start; when
# there is none, one warning line, and Caddy listens on every address as
# before (the Caddyfile's remote_ip rule still turns sessions away).
iface=$(awk '$2 == "00000000" && $8 == "00000000" { print $1; exit }' /proc/net/route 2> /dev/null)
addr=
if [ -n "$iface" ]; then
  addr=$(ip -4 -o addr show dev "$iface" 2> /dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
fi
if printf '%s\n' "$addr" | grep -Eqx '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
  export ROUTER_BIND="$addr"
else
  echo "router: warning: no IPv4 address on the default route's interface (${iface:-none}); listening on every address, session networks included" >&2
  unset ROUTER_BIND
fi
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
