# storybook-heroku-buildpack

This is a [Heroku buildpack](http://devcenter.heroku.com/articles/buildpacks) for [Storybook](https://storybook.js.org/).

## VPN IP gate (FLOW-1713)

Storybook is reachable only from the Oyster VPN (Perimeter 81) egress IPs. HTTP Basic auth stays on as a second layer.

### How the client IP is determined

`storybook.oysterhr.com` is a DNS-only CNAME to Heroku, so there is exactly one proxy hop: the Heroku router. The router **appends** the IP it saw as the **rightmost** `X-Forwarded-For` entry. Everything to its left was sent by the client and can be forged. That is why filters that read the leftmost XFF entry (most off-the-shelf "IP allowlist" buildpacks and middleware) are decorative: anyone can send `X-Forwarded-For: <an allowlisted IP>`.

The config uses nginx's realip module:

```
set_real_ip_from 10.0.0.0/8;     # the router's connection source (UNVERIFIED, see below)
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

nginx trusts XFF only when the TCP peer is inside `set_real_ip_from`, then walks the list right to left past trusted addresses. The result is `$remote_addr` = the router-appended client IP. A forged leftmost entry is ignored.

### Verify the router range before production (required)

Heroku does not document the router's source range. `10.0.0.0/8` is an assumption. If the router connects from outside it, nginx ignores XFF and `$remote_addr` becomes the router's IP, so **everyone gets 403** (fails closed, but it is an outage). On the staging app:

1. Deploy with the gate on and make a few requests.
2. `heroku logs -a oyster-storybook-staging | grep router_peer=`
3. Every `router_peer=` value must be inside `10.0.0.0/8`, and `client_ip=` must match your real egress IP (`curl ifconfig.me`).
4. If not, change `set_real_ip_from` to the observed range (as narrow as the evidence supports) before any production rollout.

### `VPN_ALLOWED_CIDRS`

Comma-separated IPv4 addresses or CIDRs. It is read when the dyno boots (`bin/start-nginx-solo` renders the ERB), so a config var change applies on restart with no rebuild.

- **Unset or empty:** no gate (previous behaviour). The first deploy is safe before the var exists.
- **Set:** `allow` for each valid entry, then `deny all`. Denied clients get `/vpn-403.html`.
- **Invalid entries** (bad octet, prefix shorter than /8, junk) are skipped and shown as `# SKIPPED` comments in the rendered config. A typo can never produce an nginx config that fails to load and sends the dyno into a crash loop.
- **Set, but every entry invalid:** fails closed (`deny all`).
- **IPv4 only.** An IPv6 entry is skipped — including in break-glass. From an IPv6-only connection, use an IPv4 hotspot or add a colleague's/office IPv4 egress instead.

The source of truth is `vpn/p81-ips.md` (13 Perimeter 81 gateway IPs):

```
95.179.220.118/32,209.35.224.184/32,131.226.43.208/32,172.235.251.116/32,185.14.187.105/32,64.226.129.141/32,64.226.128.64/32,216.238.98.228/32,139.180.190.134/32,212.59.68.116/32,5.22.218.185/32,5.22.223.158/32,149.28.246.199/32
```

### Break-glass (Perimeter 81 outage, or new gateway)

> 🔴 **WARNING: THIS RESTARTS ALL oyster-storybook DYNOS.** Any `config:set` restarts the app.

Append the emergency CIDR (for example a trusted admin's current egress from `curl ifconfig.me`, as `/32`) to the existing value, never replacing it:

```
heroku config:get VPN_ALLOWED_CIDRS -a oyster-storybook     # copy the current value
heroku config:set VPN_ALLOWED_CIDRS="<current>,203.0.113.7/32" -a oyster-storybook
```

Remove the entry when the incident is over (🔴 that restarts the dynos again). Emergency kill switch: `heroku config:unset VPN_ALLOWED_CIDRS` turns the gate off (🔴 restart; Basic auth still applies).

### Logs

The access log line carries `client_ip=` (after realip), `router_peer=` (the TCP peer before realip), `status=`, `uri=` and the raw `xff=`. To find denials: `heroku logs -a oyster-storybook | grep 'status=403'`.

### Rollout

Staging first, on a standalone app (see `docs/staging-rollout.md`): verify the router range, run `scripts/test-matrix.sh`, then cut production over to a pinned ref.
