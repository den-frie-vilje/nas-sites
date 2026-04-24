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
- **`scripts/deploy.sh`** — self-updating deploy script invoked by each
  webhook fire
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

## Related repos

- [den-frie-vilje/skovbyesexologi.com](https://github.com/den-frie-vilje/skovbyesexologi.com)
  — first consumer site; source for most of this repo's initial content
