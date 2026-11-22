# FUTURE: Public Access through Cloudflare Tunnel

Status: **tabled** (2026-11-21). No public application needs exposing yet. This records the options that were evaluated, the recommendation and a rough plan, so the work can be picked up later.

## Goal

Make selected apps on the demigods cluster reachable from the internet without:
- port-forwarding on the OpenWRT router, or
- publishing the home IP.

Admin and internal apps must stay unreachable from outside.

## Starting point

- Traefik (Helm route, chart 42.4.1) runs the `traefik-gateway` Gateway on MetalLB's `192.168.5.60`. That's a private address behind OpenWRT, so it can't be reached from the internet.
- cert-manager issues Let's Encrypt certificates through DNS-01 with Cloudflare (`letsencrypt-dns01`).
- **Done 2026-11-21:**
  - The Gateway now has apex and wildcard listeners (`faultycloud.app` and `*.faultycloud.app`, HTTP and HTTPS), and the `faultycloud-app-tls` certificate covers both names.
  - HTTPRoutes attach only from namespaces labeled `demigods/traefik-gateway=allowed` (see COMPONENTS.md).
  - Under the plan below, this Gateway becomes the **internal** one. It would move to `*.lan.faultycloud.app`, and its label selector would carry over to the internal Gateway.

## Options evaluated

### ExternalDNS: rejected
ExternalDNS publishes DNS records for routes, but the cluster's addresses are private. Public records pointing at `192.168.5.x` would only work on the LAN, would leak the internal layout, and OpenWRT's DNS rebind protection drops such answers by default. It also does nothing to carry traffic in. A tunnel creates its own DNS records, so ExternalDNS adds nothing.

### Cloudflare Tunnel
Cloudflare's edge terminates public HTTPS, and a connector, `cloudflared`, running in the cluster carries the traffic in over an outbound-only connection. No inbound ports are opened. Cloudflare does not replace Traefik: `cloudflared` is only the way in, and Traefik still routes inside the cluster.

### Third-party tunnel controllers
These were vetted for maintenance health on 2026-11-21:

| | STRRL/cloudflare-tunnel-ingress-controller | adyanth/cloudflare-operator |
|---|---|---|
| Latest release | v0.1.0, 2026-08-12 | v0.14.0, 2026-11-01 |
| Release pace (last 24 months) | About every 4–5 months (gaps of 266, 137, 122 and 23 days) | Four releases in Apr–Jun 2025, then a 17-month gap |
| Commits (last 6 months) | 78, but the maintainer's last was 2026-10-03; about a sixth are dependabot | 2; none between Oct 2025 and Aug 2026 |
| Maintainers | Effectively one | Effectively one; PRs open for 6–17 months |
| Stars / license | 1.2k / MIT | 695 / Apache-2.0; README says alpha |
| Gateway API | No; Ingress only. Draft PoC in PR #369, not merged. | No; issue #81 open since 2023 |
| Helm chart | Yes | No (kustomize only) |
| Notable problems | #375: the default connector image trusts compromised CAs, no maintainer reply after 25 days, and its image-sync job has failed daily since 2026-10-16. #377: rewrites every DNS record on each reconcile, about 3,300 API calls a day. | #70: changing a hostname leaves the old DNS record behind (open since 2022). Slow reviews. |

Neither supports Gateway API, so both would need Ingress objects alongside the HTTPRoutes. **Neither is recommended.**

Gateway-API-native controllers also exist. They were only surveyed, not vetted:

| Project | Stars | Recent releases |
|---|---|---|
| `lexfrei/cloudflare-tunnel-gateway-controller` | 48 | v5.0.0 (Oct 7), v4.0.0 (Oct 2), v3.5.0 (Sep 6). Active but changing fast. |
| `cfgate/cfgate` | 26 | Still alpha (`v0.2.0-alpha.11`, Oct 4). Also manages DNS and Access. |
| `matheuscscp/cloudflare-gateway-controller` | 19 | v0.16.0 (Sep 7), about every 2 months |

These would run as a **second Gateway implementation** with their own GatewayClass, alongside Traefik rather than in front of it. If per-app tunnel config as YAML becomes important, vet `lexfrei/cloudflare-tunnel-gateway-controller` properly first.

## Recommendation

Run the **official `cloudflared` connector as a plain Deployment**, with a single wildcard rule in the tunnel: `*.faultycloud.app` (plus the bare domain) → Traefik.

- It's Cloudflare's own image, so security fixes come straight from Cloudflare, not through a fork.
- No third-party controller sits between the cluster and Cloudflare's API.
- The route rules are set once in Cloudflare. After that, a new public app is just an HTTPRoute on the public Gateway.
- The cost is that the tunnel's route rules live in the Cloudflare dashboard or API, not in the repo. With the wildcard they rarely change.

## Keeping internal apps private

With a wildcard tunnel, any route reachable through it is public. Privacy should be built into the structure, so it doesn't depend on hostnames or on remembering a setting.

```
internet ─► Cloudflare ─► cloudflared ─► traefik "public" entrypoint (ClusterIP only)
                                              └─► Gateway: public    ← public apps attach here
LAN      ─► 192.168.5.60 (MetalLB) ─────► traefik web/websecure entrypoints
                                              └─► Gateway: internal  ← admin apps attach here
```

1. **Two Gateways, and the tunnel can only reach one of them.**
   - `cloudflared` targets a separate Traefik entrypoint that is exposed only as ClusterIP, never on the LoadBalancer. Requests arriving there can only match routes attached to the public Gateway.
   - Admin apps attach only to the internal Gateway, so even a leaked hostname can't be reached through the tunnel.
2. **Deliberate opt-in.** The public Gateway accepts routes only from namespaces labeled, for example, `demigods/exposure: public`. Exposing an app takes two deliberate steps: label its namespace and set `parentRefs` to the public Gateway.
3. **Separate hostnames, for clarity.**
   - Public apps: `*.faultycloud.app`.
   - Internal apps: `*.lan.faultycloud.app`. These are never put in public DNS. One OpenWRT dnsmasq line resolves them all on the LAN: `address=/lan.faultycloud.app/192.168.5.60`.
   - cert-manager can still issue a real `*.lan.faultycloud.app` certificate through DNS-01.
4. **Cloudflare Access**, for an admin app that occasionally has to be reachable from outside.
   - Route it through the public side with an Access policy in front, such as email one-time code or Google login. Cloudflare blocks unauthenticated requests at its edge. It's free for small teams.
   - For defense in depth, validate the `Cf-Access-Jwt-Assertion` header at the origin.
5. **Full remote access to private apps**, if it's needed later: Cloudflare WARP (private network routing through the same tunnel) or Tailscale. This is out of scope for the first pass.

## Implementation plan

Rough effort: **about half a day**.

| # | Step | Who | Effort |
|---|---|---|---|
| 1 | In the Cloudflare Zero Trust dashboard: create a remotely-managed tunnel, copy its token, and add public hostnames `faultycloud.app` and `*.faultycloud.app` → `http(s)://traefik-public.traefik.svc:<port>`. The wildcard DNS CNAME to `<tunnel-id>.cfargotunnel.com` may need adding by hand. | owner | 15–20 min |
| 2 | Traefik:<br>• add a `public` entrypoint (port), not exposed on the LoadBalancer<br>• turn the existing chart-managed Gateway into the internal one, with listeners `*.lan.faultycloud.app` (and the bare domain if it's wanted on the LAN)<br>• trust forwarded headers from the pod CIDR `10.253.0.0/23`, so apps see the real visitor IP from `CF-Connecting-IP` / `X-Forwarded-For`<br>Changes go in `traefik/helm/postCertManager.yaml`. | Claude | ~1 hr |
| 3 | Add a `public` Gateway as a plain manifest (the chart's `gateway:` block only creates one) on the public entrypoint, with `*.faultycloud.app` listeners. Restrict its `allowedRoutes` to namespaces labeled `demigods/exposure: public`. | Claude | ~1 hr |
| 4 | Certificates: `*.faultycloud.app` already exists (`faultycloud-app-tls`). Add `*.lan.faultycloud.app` for the internal Gateway through `letsencrypt-dns01`. | Claude | included above |
| 5 | New `cloudflared/` component, installed after traefik and certificateManager:<br>• `cloudflare/cloudflared` Deployment, pinned version, arm64 confirmed<br>• 2 replicas with anti-affinity across workers<br>• `/ready` health checks and metrics<br>• token Secret generated from a git-ignored `cloudflared/base/cloudflared.env`<br>• `install` / `demigods` / `uninstall` targets, README, root `Makefile` and `COMPONENTS.md` updates | Claude | ~1 hr |
| 6 | OpenWRT: add the `lan.faultycloud.app` dnsmasq entry. | owner | 5 min |
| 7 | Test:<br>• a `whoami` app on the public Gateway is reachable from outside through the tunnel, with the real client IP in its headers<br>• an app on the internal Gateway is reachable on the LAN and **not** through the tunnel, even when requested with a public hostname<br>• the LAN wildcard name resolves and serves a valid certificate | both | ~30 min |

Decide or confirm before building:
- **The `cloudflared` → Traefik hop.** Use plain HTTP inside the cluster, or HTTPS to the public entrypoint with `originServerName` set to match the wildcard certificate.
- **The bare `faultycloud.app`.** Decide whether it's public, internal or both.
- **Chart settings.** Check chart 42.4.1's options for an extra entrypoint that isn't exposed on the LoadBalancer Service, and for forwarded-header trust.
- **The tunnel token.** Decide whether to keep it git-ignored like `certificateManager/base/cloudflare.env`. That file holds the separate DNS-01 token, and the two tokens should stay separate.
- **Pinning.** Pin the current `cloudflared` release at build time.

## What does not change

- MetalLB, the `192.168.5.60` LoadBalancer IP and direct LAN access.
- cert-manager and DNS-01. It still issues the certificates for LAN access and for the internal HTTPS hop.
- Postgres and other non-HTTP services. They are not exposed through the tunnel: raw TCP would need `cloudflared` or WARP on every client.
