# View-Only Mode & Email Unlock

RigControl's dashboard drops into a read-only "view-only mode" for any client that isn't on the local network. Sending commands, changing settings, editing flightsheets/overclocks/wallets, and every other state-changing action is blocked. A locked-out remote user can request a one-time code by email and unlock full access for that browser.

This doc explains what actually controls that decision, and where the real security boundary is versus what's just UI polish. Everything below reflects the implementation in `rigcontrol_dashboard_server.py` and `app.js`/`index.html`.

## What decides "local" vs "remote"

The server looks at the request's source IP and checks it against the standard private/loopback ranges:

- `127.0.0.0/8`, `::1/128` — loopback
- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` — RFC1918 private
- `169.254.0.0/16`, `fe80::/10` — link-local
- `fc00::/7` — IPv6 unique local

This lives in `is_local_ip()` / `is_local_request()`. Anything outside those ranges is remote.

**Where the IP comes from matters.** By default the server uses `request.client.host` — the IP of whatever actually opened the TCP connection to it. If the dashboard sits behind a reverse proxy (Caddy, nginx, etc.), that's the *proxy's* IP, not the real client's — every request looks local, and view-only mode never engages for anyone. Setting `TRUST_PROXY_HEADERS=true` switches the server to reading the first address in `X-Forwarded-For` instead, which a proxy sets to the real client IP.

**This setting is a trust decision, not just a config toggle.** `X-Forwarded-For` is just an HTTP header — any client can send one, and a remote attacker could set `X-Forwarded-For: 127.0.0.1` themselves before their request ever reaches your proxy. Proxies (Caddy included) don't strip that — they *append* their own observed peer address, so the header ends up as `X-Forwarded-For: 127.0.0.1, <attacker's real IP>`. `_client_ip()` deliberately reads from the **right end** of that list, not the left, since entries near the end are the ones your own trusted proxies actually appended from real TCP connections — the part of the header a client can't fake. Anything a client sends just pads the front.

**How far in from the right depends on how many trusted hops are in front of you — this is now configurable, not hardcoded.** A single Caddy instance appends exactly one entry, so the real client IP is the *last* one. Add a tunnel or CDN in front of Caddy — Cloudflare, ngrok, another reverse proxy — and *that* hop appends its own entry too, pushing the real client IP to the *second-to-last* position, and so on for each additional trusted hop. Two env vars control this instead of requiring a code change:

- **`TRUSTED_PROXY_HOPS`** (default `1`) — the number of trusted reverse proxies between the client and this server. Caddy alone: leave at `1`. Add one more hop in front (Cloudflare, another proxy, a tunnel): set to `2`. `_client_ip()` walks in from the end of `X-Forwarded-For` by exactly this many positions. Get the count wrong and it either trusts a client-spoofable entry (too low) or misreads a real client as something else (too high) — set it to the actual number of hops, not a guess.
- **`TRUST_CLOUDFLARE`** (default `false`) — if the dashboard is *only* reachable through Cloudflare (origin firewalled to Cloudflare's IP ranges, or a Cloudflare Tunnel with no other ingress), turn this on instead of counting hops. Cloudflare's edge sets `CF-Connecting-IP` from its own view of the real client and unconditionally overwrites any client-supplied value with that name before it reaches your origin, so it's trustworthy on its own without needing `TRUSTED_PROXY_HOPS` to track Cloudflare's internal topology. This only holds if "Cloudflare is the only way in" is actually true for your setup — if the origin is still reachable directly (unfirewalled port, no-Cloudflare fallback DNS, etc.), an attacker can skip Cloudflare entirely and set `CF-Connecting-IP` themselves, and this protection is void.

If both are enabled, `CF-Connecting-IP` is checked first and used when present; `X-Forwarded-For` with hop-counting is the fallback. Only enable either when you know exactly what sits in front of this server — a wrong assumption here doesn't just misbehave, it silently disables the local/remote distinction that view-only mode depends on.

## What's actually enforced vs. what's just UI

This is the part worth being precise about: **the browser doesn't decide anything.** Every button greyed out, the banner, the disabled Send Command box — none of that is the security boundary. It's there so a locked-out user isn't confused by controls that would fail anyway.

The real enforcement is a FastAPI middleware, `view_only_gate`, that runs on every single HTTP request before it reaches any route handler. The rule is simple and fails closed:

- If the request method is `POST`, `PUT`, `DELETE`, or `PATCH`
- **and** the path isn't on a short exemption list (read-style POSTs like `/api/stats/request`, plus the two unlock endpoints themselves)
- **and** the client isn't local **and** doesn't have a valid unlock cookie

...it gets rejected with `403` before any of your data or MQTT topics are touched. This means even a remote client that bypasses the UI entirely — curling the API directly — gets the same rejection. The frontend greying out buttons is a courtesy; the middleware is the actual gate.

`GET` requests are never blocked, by design — viewing the dashboard remotely is the whole point of view-only mode, only *changing* things is restricted.

## The unlock flow

1. Clicking the view-only banner opens a small dialog with an email field and a "Send Unlock Code" button. The email field isn't optional decoration — the request is rejected without one.
2. Submitting calls `POST /api/view-only/request-code` with `{ email }`. The server checks the global cooldown first (see below), then requires the submitted email to case-insensitively match one of the address(es) configured under Settings → Email Recipients. **If it doesn't match, the request is rejected with `403 Email not recognized` and no code is generated or sent.** This means knowing (or guessing) a configured recipient address is now a precondition for getting a code at all, not just for reading it — someone who doesn't know that address can't cause a code to be issued in the first place.
3. On a match, the server generates a 16-character hex code (`secrets.token_hex(8)` — cryptographically random, not a predictable sequence), stores it in memory with a 10-minute expiry, and emails it to that same address through the same SMTP configuration used for offline/notification alerts. It deliberately ignores the "email notifications enabled" toggle — this is an authentication action, not a notification the user opted into.
4. Entering the code calls `POST /api/view-only/verify-code`. The server compares it using `secrets.compare_digest` (constant-time, avoids timing attacks) and checks it hasn't expired. The code is single-use — a correct match immediately invalidates it so it can't be replayed.
5. On success, the server sets an `httponly`, `SameSite=Lax` cookie good for 12 hours. From then on, `has_dashboard_access()` treats that browser as authorized the same as a LAN client, until the cookie expires.

**Logging out early.** A "⎋" button appears next to Settings, but only when the client is both remote and currently unlocked (`is_local` is `false` and `view_only` is `false` in `/api/config` — a LAN client never sees it, since there's no unlock to log out of). Clicking it calls `POST /api/view-only/logout`, which forgets the token server-side (`_unlock_tokens.pop(...)`, so the old cookie value can't be reused even if it leaked) and clears the cookie on the client. The browser immediately falls back to view-only without waiting for the 12-hour TTL to expire — useful on a shared/public machine where you don't want the unlock outliving the session.

**Wrong email guesses still cost the requester the cooldown window.** The 60-second rate limit is checked and stamped *before* the email is validated, so a wrong guess consumes the same cooldown a correct request would. This is intentional — without it, an attacker could hammer `request-code` with guessed addresses at full speed until one matched, using the lack of a code in their inbox as a signal of which guesses were wrong. Paying a 60-second penalty per guess, right or wrong, makes that kind of enumeration impractically slow.

## Honest limitations

A few things worth knowing rather than assuming away:

- **The unlock is only as strong as the email inbox it's sent to.** Anyone who can read that inbox can unlock the dashboard. This isn't multi-factor in the traditional sense — it's single-factor (email access) standing in for the missing second factor of "being on the LAN."
- **Knowing the email address is now required, but the code still isn't bound to whoever requested it.** Requiring a matching email raises the bar — a stranger with no idea which address is configured can no longer trigger a code at all — but it isn't requester binding. Anyone who knows (or correctly guesses) the configured address can request a code, and whoever enters that code first, from any browser, gets unlocked. There's still no session/requester token tying a specific code to the specific browser that asked for it.
- **The email check is a match against a known value, not proof of inbox access — until step 3.** Guessing the right address gets a code sent, but the code itself only ever reaches the real inbox. So the *code* remains the actual second factor; the email field mainly narrows who can cause a code to be sent, and doubles as the second thing an attacker has to get right (address *and* inbox access) rather than just inbox access alone.
- **The rate limit is global, not per-client** - by design, see above - **but there's now a second, per-IP layer on top of it.** In addition to the global 60-second cooldown, `UNLOCK_MAX_ATTEMPTS_PER_IP` (default 3) caps how many unlock attempts a single IP can make within `UNLOCK_ATTEMPTS_WINDOW_SECONDS` (default 24h), counting both `request-code` and `verify-code` calls, success or failure. This doesn't replace the global cooldown's protection (see the "why is the cooldown global" reasoning above) and has the identical honest limitation: it's keyed on IP, so an attacker rotating addresses via VPN is no more stopped by this than by a per-IP cooldown would be. What it does add is a cheap floor on a single-source attacker - one script hammering from one address - without weakening the global cooldown's defense against distributed attempts.
- **No CSRF token.** `SameSite=Lax` on the unlock cookie blocks it from being sent on cross-site `POST` requests from other sites, which covers the most common CSRF pattern, but there's no explicit CSRF token on top of that.
- **LAN access has no authentication at all beyond IP.** Any device on the private network ranges above gets full control with zero login. If your LAN isn't trusted (shared housing, guest Wi-Fi on the same subnet, etc.), the private-IP check alone isn't a real access control.
- **Unlock state doesn't sync across browsers/devices.** It's a cookie, not an account — unlocking on your phone doesn't unlock your laptop.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `TRUST_PROXY_HEADERS` | `false` | Trust `X-Forwarded-For` for client IP instead of the raw socket IP. Only enable behind a proxy you control. |
| `TRUSTED_PROXY_HOPS` | `1` | How many trusted reverse proxies sit in front (Caddy alone = 1; add a tunnel/CDN in front of Caddy = 2, etc). Only used when `TRUST_PROXY_HEADERS=true`. |
| `TRUST_CLOUDFLARE` | `false` | Prefer Cloudflare's `CF-Connecting-IP` over `X-Forwarded-For` hop-counting. Only enable if Cloudflare is the sole ingress path. |
| `UNLOCK_CODE_TTL_SECONDS` | `600` | How long a requested code stays valid before it expires. |
| `UNLOCK_CODE_COOLDOWN_SECONDS` | `60` | Minimum seconds between unlock code requests — global, not per-client, and applies to wrong-email guesses too. |
| `UNLOCK_TOKEN_TTL_SECONDS` | `43200` | How long a successful unlock lasts on that browser (12h) before it has to unlock again. |
| `UNLOCK_COOKIE_NAME` | `rigcloud_unlock` | Name of the cookie set on successful unlock. |
| `UNLOCK_MAX_ATTEMPTS_PER_IP` | `3` | Per-IP cap on unlock attempts (request-code + verify-code combined) within the window below. Complements, doesn't replace, the global cooldown. |
| `UNLOCK_ATTEMPTS_WINDOW_SECONDS` | `86400` | Window the per-IP cap above applies over (default 24h). |

The email address(es) a request must match to receive a code aren't a separate setting — they're whatever's already configured under `EMAIL_RECIPIENTS` / Settings → Email Recipients, the same list used for offline/notification alerts.
