# Requests: rate limiting and headers

## Rate limiting and the client address

`rate_limit` in a controller caps how often one client may call some
actions, counted before the action runs:

```ruby
class SessionsController < ApplicationController
  # a 303 back to the form, with flash[:alert], once exhausted
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
end
```

Each declaration counts at most `to` requests per `within` seconds for each
client address and controller (a fixed window that opens with the first
request), then answers 429 with a `Retry-After` header, or redirects when
given `redirect_to:`. `within:` is in seconds, `only:`/`except:` take
Arrays, and there is no `with:` block. The counts live in the process, in a
table of at most 10,000 addresses (when it is full, expired windows and
then the oldest ones make room), so they are lost on restart and each
process counts on its own. Every request to a limited action takes one lock:
name the actions with `only:`. In a test, `Cybertrain::RateLimit.reset_all!`
forgets every count and `Cybertrain::RateLimit.current_time = n` fixes the
clock (`-1` restores it).

The address counted is `request.client_ip` (`by: :remote_addr` counts the
connection's peer instead). It is `request.remote_addr` unless
`config.trusted_proxy` is on (`CYBERTRAIN_TRUSTED_PROXY=1`) **and** the
connection comes from loopback, that is, from a reverse proxy on the same
host (nginx, Caddy, kamal-proxy); then it is the last address in
`X-Forwarded-For`, the one the proxy appended. Earlier entries are whatever
the client sent and are never used, and a last entry that is empty, longer
than 45 bytes or not printable ASCII gives `remote_addr`. Without the
setting, every visitor behind such a proxy shares its address, and ten bad
passwords lock everyone out; with it, a client connecting directly from
elsewhere still cannot choose its own address. `request.loopback?` tells
whether the connection comes from this machine (127.0.0.0/8, `::1`,
`::ffff:127.x.x.x`), for pages only an operator on the server should
reach; behind a proxy on the same host every request is loopback, so check
`client_ip` too there. Design: [docs/design.md](../design.md) D26.

A proxy that reaches the app over a network, not loopback, is listed by
address instead: `config.trusted_proxies`, from `CYBERTRAIN_TRUSTED_PROXIES`,
takes comma-separated IPv4 or IPv6 addresses or CIDRs
(`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`, or a single
`172.18.0.2`). A connection from inside one of them gets the same treatment
as a loopback one above: the last `X-Forwarded-For` address, validated the
same way. An IPv4 entry also matches the IPv4-mapped form of its addresses
(`::ffff:172.18.0.2`), and a peer's `%zone` is ignored. An entry that is not
an address or CIDR, or has a prefix past `/32` (IPv4) or `/128` (IPv6),
stops the server at boot. `CYBERTRAIN_TRUSTED_PROXY=1` is the shorthand for
`127.0.0.0/8,::1`, and the two add up. This is the Kamal case: kamal-proxy
runs in its own Docker container and connects from its address on the Docker
network, so the `config/deploy.yml` that `cybertrain new` writes sets
`CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` (Docker's default range; change
it if your networks use another, `docker network inspect kamal`). Leave
Kamal's `proxy.forward_headers` unset: with `ssl: true`, kamal-proxy sets
`X-Forwarded-For` itself rather than passing on the client's. List only
networks that clients cannot connect from: anyone inside a listed network
can choose the address a rate limit counts.

## Parameterised headers

API clients often send `Scheme k1=v1, k2="v2"` headers (`Authorization:
Digest ...`, a vendor `X-Example-Auth`) or `k1=v1;k2=v2, k3` lists
(`Forwarded`, `Prefer`). `request.header_params(name)` parses one into a
`Hash` of lowercase names to values, so an API controller does not split it
by hand:

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

`,` and `;` both separate parameters and the first occurrence of a name
wins; a quoted value is unquoted (`\"` and `\\` undone), an unquoted one
has the spaces around it trimmed, and a name without `=` maps to `""`. A
leading scheme word (`Digest`, `Bearer`) is not a parameter:
`request.header_scheme(name)` returns it (`""` when there is none). A header
that is missing or longer than 8 KiB gives `{}`. Values are the bytes as sent,
never percent-decoded and possibly not valid UTF-8. A `Bearer <token>` or
`Basic <base64>` credential is not a parameter: check the scheme, then read
the credential from `request.header("authorization")`. Design:
[docs/design.md](../design.md) D31.
