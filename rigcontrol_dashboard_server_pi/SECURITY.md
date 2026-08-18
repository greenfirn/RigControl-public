# Security Design — RigControl / Home Assistant Reverse Proxy

This document describes the network and application security model for the
Caddy-fronted Home Assistant + RigControl stack, including the reasoning
behind each layer and a known issue that was found and fixed.

## Generating the `basic_auth` password hash

Caddy's `basic_auth` directive expects a bcrypt hash, never a plaintext
password. Generate one using Caddy's own CLI (already present in the
`caddy:2` image, so no extra tooling needed):

```bash
docker exec -it caddy caddy hash-password
```

This prompts for a password interactively and prints a bcrypt hash like:

```
$2a$14$examplehashoutputgoeshereXXXXXXXXXXXXXXXXXXXXXXXX
```

Store that value as `CADDY_AUTH_HASH` in `.env` — **not** directly in the
Caddyfile. When placing it in `.env`, every `$` in the hash must be escaped
as `$$`, since docker-compose treats a single `$` as the start of its own
variable substitution and will silently truncate the value otherwise:

```env
CADDY_AUTH_HASH=$$2a$$14$$examplehashoutputgoeshereXXXXXXXXXXXXXXXXXXXXXXXX
```

The Caddyfile then references it via env substitution rather than a
hardcoded hash:

```caddyfile
basic_auth {
    {$CADDY_AUTH_USER} {$CADDY_AUTH_HASH}
}
```

After changing `.env`, the `caddy` container must be **recreated**, not
just reloaded, for the new value to take effect:

```bash
docker compose up -d caddy
docker exec caddy printenv | grep CADDY_AUTH_HASH   # confirm it's not truncated
```

## Overview

All public traffic terminates at a single **Caddy** reverse proxy running on
the host (`network_mode: host`), which fronts two internal services:

| Service        | Internal port | Exposed publicly?          |
|----------------|---------------|-----------------------------|
| Home Assistant | `8123`        | Yes, via Caddy (default route) |
| RigCloud       | `8765`        | Yes, via Caddy (`/dashboard/*`), and directly on the LAN |

Everything else in the stack (Mosquitto, Zigbee2MQTT, Node-RED, DuckDNS
updater) stays bound to the host/LAN and is never routed through the public
site block.

## Layer 1 — Network edge (router)

- Only two ports are forwarded from WAN to the Caddy host: **80** and
  **443** (TCP), both targeting the host's static LAN IP.
- No other service ports are exposed to the internet. MQTT, Zigbee2MQTT,
  Node-RED, and the RigCloud API port (`8765`) are only reachable from the
  LAN or through Caddy.

## Layer 2 — TLS (Let's Encrypt via Caddy)

- Caddy automatically provisions and renews a publicly-trusted certificate
  for the DuckDNS hostname using the ACME HTTP-01 challenge.
- `tls <email>` is used rather than on-demand TLS, since the hostname is
  known ahead of time. On-demand TLS was deliberately avoided here — it's
  designed for scenarios where hostnames aren't known at config time (e.g.
  multi-tenant SaaS), and without an `ask` allow-list it lets anyone who
  points DNS at the server's IP trigger certificate requests against it,
  which risks hitting Let's Encrypt's rate limits.
- `auto_https off` is **not** set globally, since that directive disables
  all automatic certificate management, including explicit `tls <email>`
  blocks — the two are mutually exclusive in practice.

## Layer 3 — Authentication (Caddy `basic_auth`)

- All routes under `/dashboard/*` — dashboard UI, REST API, and WebSocket
  — sit behind a single `basic_auth` block using a bcrypt-hashed password.
- **Design note:** an earlier revision of the config routed
  `/dashboard/ws*` to the backend through a *separate* `handle` block that
  bypassed `basic_auth` entirely, since the reasoning at the time was that
  browsers can't attach custom headers to a native WebSocket handshake.
  In practice, `basic_auth` is enforced during the HTTP upgrade request
  itself (before the connection becomes a WebSocket), so browsers *do*
  send the standard `Authorization` header on that initial request and
  the auth check works normally. The separate unauthenticated block was
  removed, and `/dashboard/ws` now falls under the same `handle
  /dashboard/*` block as the rest of the app, closing what had been an
  open, unauthenticated telemetry stream.
- The backend (`rigcloud_dashboard_server.py`) does not implement its own
  authentication on the `/ws` route — auth is enforced entirely at the
  proxy layer. This keeps auth centralized in one place (Caddy) rather
  than duplicated in application code, but it also means Caddy is a
  hard dependency for security here: the backend must never be exposed
  directly to an untrusted network without something in front of it.

## Layer 4 — Network segmentation (local access)

- A second Caddy site block listens on `:8081`, plain HTTP, restricted by
  a `remote_ip` matcher to the LAN's private subnets.
- This block intentionally has **no authentication** — it's meant for
  trusted local access only (e.g. dashboards on a home network) and is
  not reachable from outside the LAN, since it isn't included in the
  router's port-forwarding rules.
- Anything outside the matched subnets gets an explicit `403 Forbidden`
  rather than falling through silently.

## Layer 5 — Security headers

The public site block sets standard hardening headers on all responses:

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
```

## Layer 6 — DDoS / abuse mitigation (recommended, not yet implemented)

This stack runs on a residential connection behind a home ISP, which means
no amount of Caddy or application-layer configuration can absorb a genuine
volumetric DDoS — a flood large enough saturates the home uplink before it
reaches Caddy or even the router. Real protection requires keeping that
traffic off the origin IP entirely.

**Recommended: put Cloudflare in front of the domain (free tier).**

- Proxying `some-domain.duckdns.org` through Cloudflare ("orange cloud" DNS
  mode) absorbs L3/L4 volumetric attacks upstream, before they ever reach
  the Pi.
- It also hides the origin IP from public DNS resolution, which removes
  the most common way a home-hosted service gets discovered and targeted
  in the first place — right now, resolving the DuckDNS hostname reveals
  the real IP directly.
- Free tier includes basic rate limiting and WAF rules, covering most
  application-layer (L7) abuse without any cost.
- Existing Let's Encrypt/Caddy TLS setup keeps working unmodified under
  Cloudflare's "Full" SSL mode. Optionally, a Cloudflare Origin Certificate
  can later replace the public Let's Encrypt cert, since Origin Certs are
  only trusted by Cloudflare itself — this would prevent anyone who
  bypasses Cloudflare and hits the origin IP directly from getting a
  valid TLS handshake at all.
- Setup: add the DuckDNS hostname as a CNAME in Cloudflare DNS (or migrate
  the domain to Cloudflare DNS outright for tighter control), proxied.

**Application-layer safeguards, independent of Cloudflare:**

- `fail2ban` watching Caddy's access log for repeated `401` responses on
  `basic_auth`, banning offending IPs at the firewall after N failed
  attempts. Caddy does not rate-limit `basic_auth` natively, so this is
  currently the main gap against credential brute-forcing.
- `caddy-ratelimit` (third-party module, requires a custom `xcaddy` build
  — not present in the stock `caddy:2` image used here) for native per-IP
  request caps in Caddy itself.
- `ufw limit` on 80/tcp and 443/tcp as an OS-level stopgap against naive
  connection floods:
  ```bash
  sudo ufw limit 443/tcp
  sudo ufw limit 80/tcp
  ```
- Router-level SYN-flood/DoS protection, if exposed by the ER7206's
  firmware — worth enabling regardless of the above.

**Already in place, worth noting:**

- `MAX_WS_CONNECTIONS` in the RigCloud backend caps concurrent WebSocket
  connections, providing some existing protection against connection
  exhaustion on that endpoint.
- Only ports 80/443 are forwarded from the router, keeping the attack
  surface minimal regardless of the above.

## Secrets handling

- The `basic_auth` password is stored as a bcrypt hash directly in the
  Caddyfile, not in plaintext.
- **If this repository is public**, the Caddyfile should not be committed
  with real values in place — the bcrypt hash, DuckDNS hostname, and ACME
  account email should be templated out (e.g. via environment variables
  substituted at deploy time, or a `.gitignore`'d local override file)
  before pushing.
- Application secrets (SMTP credentials, Twilio tokens, MQTT credentials,
  AWS IoT certs) are injected via environment variables from a `.env`
  file that is excluded from version control, per the `docker-compose.yml`
  `environment:` blocks.

## Known limitations / possible future work

- `basic_auth` provides a single shared credential with no per-user
  accounts, no rate limiting on login attempts, and no MFA. This is an
  acceptable tradeoff for a single-operator homelab, but would not scale
  to multiple users or a higher-value target.
- The RigCloud backend trusts Caddy completely for authentication on all
  routes, including the WebSocket. If the backend is ever exposed on a
  port other than through Caddy (e.g. for local debugging), it should be
  firewalled off from anything but localhost.
