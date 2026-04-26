# nas-sites

Reusable GitHub Actions workflows + shared NAS-side infrastructure for the
den-frie-vilje **docker-hosted-site pattern**: any repo that builds a
container image can deploy to the shared Synology NAS through a single
HMAC-signed webhook call, without touching platform-specific build
tooling in the reusable layer.

## What this repo provides

### Reusable workflows (in `.github/workflows/`)

- **`build-and-notify.yml`** — generic docker build + push + deploy. Takes
  an image name, Dockerfile path, and webhook URL; does the build, pushes
  to GHCR, scans for leaked secrets, POSTs an HMAC-signed trigger to the
  NAS, and smoke-checks the live URL. **Zero assumptions about
  language/framework** — your Dockerfile is the interface.
- **`rollback.yml`** — retag an older immutable tag as `<env>-latest` and
  POST the webhook so the NAS picks it up. Manifest-level retag only; no
  image data transferred.
- **`webhook-image.yml`** — builds the shared deploy-webhook image
  (`ghcr.io/den-frie-vilje/nas-webhook:latest`) that runs on every NAS
  using this pattern.

### Shared NAS-side artefacts (in `shared/webhook/`)

- **`Dockerfile`** — the webhook image source (adnanh/webhook +
  docker-cli + git + curl)
- **`hooks.yaml`** — HMAC-verified endpoint template; per-site entries
  get appended
- **`scripts/deploy.sh`** — deploy script invoked by each webhook fire.
  Self-updates from a NAS-side clone of this repo at
  `/volume1/docker/webhook/nas-sites/`, so commits to `shared/webhook/**`
  propagate on the next deploy fire without a manual `sudo cp`
- **`compose.yml`** — compose file for the webhook stack
- **`webhook.env.example`** — per-site HMAC + CF secrets shape

---

## Architecture

```
  ┌─────────────────┐     push         ┌──────────────┐
  │ your-site repo  │ ───────────────▶ │ GH Actions   │
  │  - Dockerfile   │                  │ - docker build│
  │  - deploy-*.yml │                  │ - docker push │
  │    (thin caller)│                  │ - POST webhook│
  └─────────────────┘                  └──────┬───────┘
                                              │
                                              ▼
  ┌───────────────────────────────────────────────────────┐
  │  NAS (Synology)                                       │
  │                                                       │
  │   DSM Web Station → Caddy (per site) → site container │
  │                       │                               │
  │                       └── /hooks/* → shared webhook   │
  │                                         │             │
  │                                         ▼             │
  │                                    /scripts/deploy.sh │
  │                                    (git pull + docker │
  │                                     compose pull+up)  │
  └───────────────────────────────────────────────────────┘
```

Per-site URLs follow the convention:
```
<DOMAIN_DASHED>.stage.denfrievilje.dk    (staging origin)
<DOMAIN_DASHED>.prod.denfrievilje.dk     (production origin)
<DOMAIN>                                 (client-facing, CNAME'd to .prod)
```

Where `<DOMAIN_DASHED>` = `<DOMAIN>` with dots replaced by dashes. This
keeps the whole origin inside a single DNS label so the wildcard LE cert
`*.{stage,prod}.denfrievilje.dk` covers every site with zero per-site
cert issuance.

---

## Using the reusable workflow from a site repo

Example thin caller in your site repo's `.github/workflows/deploy-staging.yml`:

```yaml
name: Deploy to staging
on:
  push:
    branches: [staging]
  workflow_dispatch:

jobs:
  deploy:
    uses: den-frie-vilje/nas-sites/.github/workflows/build-and-notify.yml@main
    with:
      environment: staging
      dockerfile: deploy/Dockerfile
      image-name: ghcr.io/den-frie-vilje/example-site
      webhook-url: https://example-com.stage.denfrievilje.dk/hooks/deploy/example.com/staging
      smoke-check-url: https://example-com.stage.denfrievilje.dk/
    secrets:
      WEBHOOK_SECRET: ${{ secrets.STAGING_WEBHOOK_SECRET }}
```

The site repo owns:
- `deploy/Dockerfile` — multi-stage build producing the runtime image
- Per-site compose files, Caddy configs
- Per-site environment env files

---

## Roadmap

### ✅ Stage 1 — Workflow extraction (current)

- Move reusable GH Actions workflows (build-and-notify, rollback,
  webhook-image) from the skovbyesexologi.com repo to nas-sites
- Rename the webhook image from `skovbyesexologi-webhook` to the
  client-neutral `nas-webhook`
- Move shared webhook artefacts (Dockerfile, hooks.yaml, deploy.sh,
  compose.yml) here
- Consumer sites (starting with skovbyesexologi.com) reference the
  reusable workflow via `uses:`

### 🔧 Stage 2 — Multi-stage Dockerfile + rootless runtime (part of Stage 1)

- Site Dockerfiles become multi-stage: `node:XX-alpine` builder →
  `nginxinc/nginx-unprivileged:alpine` runtime
- All build tooling (pnpm, vite, typecheck) moves INTO the Dockerfile
- CI only runs docker + webhook commands, zero language assumptions
- Multi-arch (amd64 + arm64) so M-series macs can run the built images
  locally for debugging

### 📦 Stage 3 — Site templates (TODO)

Scaffold `templates/` with ready-to-fork shapes for the common cases:

- [ ] `templates/sveltekit-static/` — the skovbyesexologi.com pattern
- [ ] `templates/astro-static/` — same shape, Astro instead of SvelteKit
- [ ] `templates/hugo/` — Hugo site, no Node in builder stage
- [ ] `templates/node-api/` — Node/Deno backend, long-running, no Caddy
  (or Caddy for TLS termination but no static serving)
- [ ] `templates/static-with-api/` — multi-container (static frontend +
  Node backend + optional DB)

Each template includes its own Dockerfile, compose files, Caddyfiles,
nginx.conf (if static), and `.github/workflows/deploy-*.yml` stubs.

### 🏗️ Stage 4 — Ansible-based NAS bootstrap (TODO)

- [ ] `ansible/bootstrap-nas.yml` — one-shot NAS provisioning (docker,
  acme.sh wildcards via DNS-01, shared webhook container bring-up, DSM
  firewall rule for :5000/:5001 LAN-only)
- [ ] `ansible/bootstrap-site.yml` — per-site NAS setup (dirs, env
  files, webhook.env append, Web Station vhost creation via DSM WebAPI)
- [ ] Inventory file structure for per-NAS config
- [ ] Tested on a fresh DSM 7.2.2+ install

### 🛡️ Stage 5 — synotools hardening (TODO, optional)

Replace the `synology_dsm` acme.sh hook (which needs admin creds in an
env file) with a root-local `synowebapi` call. Removes the last
credential from disk on the NAS.

- [ ] Audit current synowebapi cert-import parameter names on latest DSM
- [ ] Write custom acme.sh deploy hook wrapping synowebapi
- [ ] Validate renewal path on one cert before cutover
- [ ] Document the tradeoff (undocumented API surface, needs sudo or
  root install) in NAS bootstrap docs

### 🚀 Stage 5b — Webhook on dedicated hostname (TODO)

Move the deploy webhook off each site's per-site Caddy and onto a single
shared hostname `hooks.server.denfrievilje.dk`, routed directly from DSM
Web Station to the webhook container on the `nas-deploy` network.

**Why**: today the webhook URL is per-site
(`<domain-dashed>.{stage,prod}.denfrievilje.dk/hooks/deploy/<domain>/<env>`),
which routes traffic through that site's Caddy container. compose v2
cascade-recreates per-site Caddy when the site's image digest changes,
which drops the in-flight CI→webhook curl connection — DSM returns 502
to curl, the build-and-notify smart retry waits 180s and tries again,
and the deploy ends up taking ~5 min instead of ~1 min via a redundant
second deploy.sh run. Moving the webhook off the per-site Caddy path
eliminates this entirely.

- [ ] Add A record `hooks.server.denfrievilje.dk` → NAS public IP
- [ ] Add to acme.sh cert renewal (single-host cert or wildcard
  `*.server.denfrievilje.dk` if other server-scoped services follow)
- [ ] Create DSM Web Station vhost for `hooks.server.denfrievilje.dk`
  proxying to the `webhook:9000` container on the `nas-deploy`
  shared docker network
- [ ] Update consumer sites' `deploy-{staging,production}.yml` to use
  `https://hooks.server.denfrievilje.dk/hooks/deploy/<domain>/<env>`
  as the `webhook-url:` input
- [ ] Drop the `/hooks/*` route from each site's
  `Caddyfile.{staging,production}` (no longer needed there)
- [ ] Verify: a staging deploy completes single-shot in <2 min with no
  smart-retry firing
- [ ] Once verified across all sites: remove the 502/503/504 retry
  branch from `build-and-notify.yml`'s smart retry loop (keep the
  connection-error retry as general resilience)

**Wins** over the current smart-retry-only approach:

- Single-shot deploys (~1 min) replace today's typical two-shot (~5 min)
- Per-site Caddy recreates during deploys don't affect the webhook path
- One less moving part for new-site onboarding (per-site Caddyfile
  doesn't need a `/hooks/*` block)
- Cleaner separation of concerns — webhook is shared infrastructure,
  not per-site

This is a targeted subset of Stage 6 (full Traefik replacement) — does
the connectivity-isolation win for the webhook without committing to
replace the entire DSM-Web-Station + per-site-Caddy pattern.

### 🌉 Stage 6 — Traefik front-door alternative (TODO, only when needed)

If a NAS ever becomes docker-host-only (no DSM Web Station tenancy to
respect), collapse the per-site DSM vhost + Caddy pair into a single
Traefik container that handles TLS + host-based routing via docker
labels. Removes `synowebapi` entirely (Traefik does ACME itself) and
removes per-site DSM vhost clicks.

- [ ] Write traefik-based variants of the site template compose files
- [ ] Write NAS migration playbook (takes :443 from DSM, moves DSM admin
  UI to a non-standard port)
- [ ] Do NOT attempt with existing client services still on Web Station

---

## Site-template naming migration

Identifiers inherited from the first site that accidentally have its
name baked in. All change during Stage 1:

| Old (site-scoped) | New (neutral) |
| --- | --- |
| `ghcr.io/den-frie-vilje/skovbyesexologi-webhook` | `ghcr.io/den-frie-vilje/nas-webhook` |
| compose project `skovbyesexologi-webhook` | `nas-webhook` |
| docker network `skovbye-deploy` | `nas-deploy` |

HMAC secret prefixes (`SKOVBYESEXOLOGI_COM_*`) stay site-scoped — that's
correct per-site isolation, not a naming artefact.

---

## Network invariants

Two Docker networks are in play per NAS:

- **`nas-deploy`** (external, shared) — hosts the singleton
  `webhook` container and each site's `caddy` container. The
  ONLY DNS resolution that happens over this network is each
  Caddy looking up `webhook:9000`. Nothing else.
- **`internal`** (external: false, per-compose-project) —
  hosts a site's `site` container and its `sveltia-auth`
  container. Each site's compose creates its own `internal`
  network, so service names (`site`, `sveltia-auth`) are
  scoped per-project and can't collide across sites.

**Invariant for `nas-deploy`**: only the shared webhook and
per-site Caddys may join it. Adding any other service to
`nas-deploy` — especially one with a common service name —
risks cross-site DNS collisions. Site-scoped services stay on
their project's `internal` network.

## Related repos

- [den-frie-vilje/skovbyesexologi.com](https://github.com/den-frie-vilje/skovbyesexologi.com)
  — first consumer site; source for most of this repo's initial content
