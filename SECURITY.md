# Security policy

## Reporting a vulnerability

Please report vulnerabilities through GitHub's Private Vulnerability
Reporting (this repository's Security tab → "Report a vulnerability"), not
in a public issue.

In scope: the framework (`cybertrain/`), the `cybertrain` CLI, the
playground images (`playground/`) and the hosted playground
([playground/README.md](playground/README.md)). Reports we especially
welcome:

- escaping a session's container;
- reaching another visitor's session;
- reaching the host, the control plane or a cloud metadata service from
  inside a session;
- getting around the session limits;
- leaks of a session's address, which works like a password: anyone who has
  it can use the session, terminal included.

Out of scope: running code of your choice inside your own session (that is
what a session is for), load by sheer volume, and Cloudflare's own
behaviour.

We aim to answer within 7 days. Please give us time to ship a fix before
you publish the details.
