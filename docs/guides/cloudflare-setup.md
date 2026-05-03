# Cloudflare Setup

Cloudflare provides HTTPS and caching for `apt.stridelabs.ai`. The bucket alone serves over `https://storage.googleapis.com/apt.stridelabs.ai/` (apt is happy with that URL), but the friendly hostname requires a proxy.

## DNS record

In the Cloudflare dashboard for `stridelabs.ai`:

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | `apt` |
| Target | `c.storage.googleapis.com` |
| Proxy status | **Proxied** (orange cloud) |
| TTL | Auto |

Proxy status must be Proxied. DNS-only would let the request hit GCS directly, where the TLS cert (`*.storage.googleapis.com`) doesn't match `apt.stridelabs.ai` and the browser/apt rejects it.

## SSL/TLS mode

For the `stridelabs.ai` zone (or scoped via Configuration Rule for `apt.stridelabs.ai`):

| Mode | Verdict |
|---|---|
| Off | No |
| Flexible | Works (HTTP origin), but unnecessarily lax |
| **Full** | **Pick this** |
| Full (Strict) | Fails — GCS cert hostname mismatch |

**Full** validates the origin's cert chain but not the hostname. That's acceptable here because the actual integrity boundary is GPG signing on the apt metadata; TLS is opportunistic privacy, not authenticity.

## Cache rules

Two rules under **Rules → Cache Rules**:

### Rule 1: bypass cache for apt metadata

| Field | Value |
|---|---|
| Rule name | apt-charliek dists bypass |
| Custom filter | `(http.host eq "apt.stridelabs.ai" and starts_with(http.request.uri.path, "/dists/"))` |
| Cache eligibility | Bypass cache |

Apt metadata changes on every publish. A stale `InRelease` cached at the edge for 4 hours is the most common Cloudflare-fronted-apt-repo failure mode — users get 404s on `apt install` because the cached metadata references debs that haven't propagated yet.

### Rule 2: long-cache the deb pool

| Field | Value |
|---|---|
| Rule name | apt-charliek pool cache |
| Custom filter | `(http.host eq "apt.stridelabs.ai" and starts_with(http.request.uri.path, "/pool/"))` |
| Cache eligibility | Eligible for cache |
| Edge TTL | 1 month |
| Browser TTL | 1 month |

Debs are content-addressed by version (`prox_1.4.0_amd64.deb` never changes its bytes). Long edge caching cuts GCS egress and improves install speed.

## Belt-and-suspenders

The publish script also stamps `Cache-Control: no-cache` on every `dists/**` object via `gcloud storage objects update`. So even if a Cloudflare rule drifts or gets deleted, the origin headers say "don't cache."

## Verification

After the rules are saved, run:

```bash
# dists/* should bypass
curl -I https://apt.stridelabs.ai/dists/noble/InRelease | grep -i cf-cache-status
# Expected: BYPASS or DYNAMIC

# pool/* should be cached after warmup
curl -fsSI https://apt.stridelabs.ai/pool/main/p/prox/prox_1.4.0_amd64.deb >/dev/null
curl -I    https://apt.stridelabs.ai/pool/main/p/prox/prox_1.4.0_amd64.deb | grep -i cf-cache-status
# Expected on second hit: HIT
```

(Adjust the path once a real prox version is published.)
