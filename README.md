# nas-sites

Reusable GitHub Actions workflows + shared NAS-side infrastructure for the
den-frie-vilje **docker-hosted-site pattern**: any repo that builds a
container image can deploy to a Synology NAS through a single HMAC-signed
webhook call, without touching platform-specific build tooling in the
reusable layer.

## What this repo provides

### Reusable workflows (`.github/workflows/`)

- **`build-and-notify.yml`** — generic docker build + push + deploy. Takes
  an image name, Dockerfile path, and webhook URL; does the build, pushes
  to GHCR, scans the resulting image for leaked-secret shapes, POSTs an
  HMAC-signed trigger to the NAS webhook, and smoke-checks the live URL.
  Zero assumptions about language/framework — the consumer's Dockerfile
  is the interface.
  - **Smart retry** around the webhook POST: retries on curl exit
    non-zero (TCP/DNS) and HTTP 502/503/504 (upstream gateway), but
    NOT on HTTP 500 (real deploy failure from the webhook). 180s delay
    between attempts so any retry fires AFTER the original deploy.sh
    finishes — combined with the per-site flock in deploy.sh, the
    second attempt is idempotent and never races the first.
- **`rollback.yml`** — retag an older immutable tag as `<env>-latest` and
  POST the webhook so the NAS picks it up. Manifest-level retag only; no
  image data transferred.
- **`webhook-image.yml`** — builds the shared deploy-webhook image
  (`ghcr.io/den-frie-vilje/nas-webhook:latest`). Multi-arch
  (amd64 + arm64), updated whenever `shared/webhook/Dockerfile` changes.

### NAS-side artefacts (`shared/webhook/`)

These are the files the webhook container's mount points serve. The NAS
keeps a permanent shallow clone of this repo at
`/volume1/docker/webhook/nas-sites/`; `deploy.sh` git-pulls that clone on
every fire and propagates any changes. Commits here land on the next
deploy fire of any site, with no manual `sudo cp`.

- **`Dockerfile`** — webhook image source (adnanh/webhook + docker-cli +
  git + curl)
- **`hooks.yaml`** — HMAC-verified endpoint template + per-site entries.
  Per-site additions are committed here (auto-propagates).
- **`scripts/deploy.sh`** — the deploy script every webhook fire runs.
- **`compose.yml`** — webhook stack compose file
- **`webhook.env.example`** — per-site HMAC + Cloudflare secrets shape

### Operational properties of `deploy.sh`

These are non-obvious and have all bitten in production once — preserved
in code comments + here so future operators don't have to rediscover.

- **Self-update**: at the top of every fire, deploy.sh `git pull`s the
  NAS-side `nas-sites` clone, compares the on-disk `deploy.sh` and
  `/etc/webhook/hooks.yaml` against that clone's
  `shared/webhook/{scripts/deploy.sh,hooks.yaml}`, and propagates any
  diff. If `deploy.sh` itself changed, the script re-execs under the new
  code mid-fire. Loud warning when the NAS-side clone is missing instead
  of silently freezing self-update.
- **Per-site flock serialization**: `flock` (`-n` polling loop because
  Alpine BusyBox doesn't ship `-w`) prevents two simultaneous deploy.sh
  runs for the same site from racing over `docker compose` state.
  Released by the kernel on any process exit including SIGKILL — no
  stale-lock recovery needed.
- **`cat >` not `cp` for hooks.yaml writes**: `/etc/webhook/hooks.yaml`
  is a SINGLE-FILE bind mount. BusyBox `cp` fails against single-file
  binds with EEXIST because its create-and-truncate path conflicts with
  the kernel-level bind. `cat src > dst` writes through the existing
  inode without trying to recreate it.
- **Webhook response redaction**: `include-command-output-in-response-on-error`
  is `false` in `hooks.yaml`. On a deploy failure CI sees a generic
  91-byte error response instead of the script's full stdout/stderr —
  failure detail lives in `docker compose logs webhook` on the NAS.

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
  │                                    (self-update,      │
  │                                     git pull site,    │
  │                                     docker compose    │
  │                                     pull + up + wait) │
  └───────────────────────────────────────────────────────┘
```

Per-site URLs follow the convention:
```
<DOMAIN_DASHED>.stage.denfrievilje.dk    (staging origin)
<DOMAIN_DASHED>.prod.denfrievilje.dk     (production origin)
<DOMAIN>                                 (client-facing, CNAME'd to .prod)
```

`<DOMAIN_DASHED>` = `<DOMAIN>` with dots replaced by dashes. This keeps
the whole origin inside a single DNS label so the wildcard LE cert
`*.{stage,prod}.denfrievilje.dk` covers every site with zero per-site
cert issuance.

## Using the reusable workflow from a site repo

Example thin caller in a site repo's `.github/workflows/deploy-staging.yml`:

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
- Optional path-scoped Phase 3 signature verification gate in the
  caller's `deploy-production.yml` (recommended for any site that
  accepts content commits from non-developer sources — e.g. CMS API
  saves — alongside the deploy-gate environment for reviewer
  approval).

## Network invariants

Two Docker networks are in play per NAS:

- **`nas-deploy`** (external, shared) — hosts the singleton `webhook`
  container and each site's `caddy` container. The ONLY DNS resolution
  that happens over this network is each Caddy looking up `webhook:9000`.
  Nothing else.
- **`internal`** (external: false, per-compose-project) — hosts a site's
  `site` container and its `sveltia-auth` container (or whatever else is
  site-scoped). Each site's compose creates its own `internal` network,
  so service names (`site`, `sveltia-auth`) are scoped per-project and
  can't collide across sites.

**Invariant for `nas-deploy`**: only the shared webhook and per-site
Caddys may join it. Adding any other service to `nas-deploy` —
especially one with a common service name like `site` — risks cross-site
DNS collisions. Site-scoped services stay on their project's `internal`
network. (This was a real bug once — staging Caddy resolving `site:80`
to a different site's container — fixed by splitting the networks.)

## Roadmap

### Site templates

Scaffold `templates/` with ready-to-fork shapes for the common cases:

- [ ] `templates/sveltekit-static/` — SvelteKit + adapter-static
- [ ] `templates/astro-static/` — same shape, Astro instead
- [ ] `templates/hugo/` — Hugo, no Node in builder stage
- [ ] `templates/node-api/` — long-running Node/Deno backend, no Caddy
  static-serving (Caddy still used for TLS + routing)
- [ ] `templates/static-with-api/` — multi-container (static frontend +
  Node backend + optional DB)

Each template includes its own Dockerfile, compose files, Caddyfiles,
nginx.conf (if static), and `.github/workflows/deploy-*.yml` stubs.

**Per-site repo bootstrap checklist** (codify in the template README so
new sites don't forget):

- [ ] `staging` branch created + protected (no force-push, no deletion,
  same shape as `main` — staging is tied to the staging deploy
  environment, deleting it accidentally would orphan the deploy gate)
- [ ] `dependabot.yml` with `target-branch: staging` so dependency
  updates inherit the staging-soak before the production gate
- [ ] `production` GitHub environment exists (holds
  `PRODUCTION_WEBHOOK_SECRET`, no reviewer rule)
- [ ] `production-gate` GitHub environment exists with the maintainer
  as required reviewer, no secrets — Phase 1 / M1 pattern
- [ ] `deploy-production.yml` includes `verify-signatures` job with
  per-commit path filtering — Phase 3 / C2 + H4 pattern (commits
  that touch anything outside `src/content/**` + `static/img/**`
  must be GitHub-verified-signed)
- [ ] OAuth app registered on GitHub for any in-repo CMS that needs it,
  with redirect URL pointing at the staging hostname's `/auth/callback`

### Ansible-based NAS bootstrap

- [ ] `ansible/bootstrap-nas.yml` — one-shot NAS provisioning (docker,
  acme.sh wildcards via DNS-01, shared webhook container bring-up, DSM
  firewall rule for :5000/:5001 LAN-only)
- [ ] `ansible/bootstrap-site.yml` — per-site NAS setup (dirs, env
  files, webhook.env append, Web Station vhost creation via DSM WebAPI)
- [ ] Inventory file structure for per-NAS config
- [ ] Tested on a fresh DSM 7.2.2+ install

### Synotools hardening (optional)

Replace the `synology_dsm` acme.sh hook (which needs admin creds in an
env file) with a root-local `synowebapi` call. Removes the last
credential from disk on the NAS.

- [ ] Audit current `synowebapi` cert-import parameter names on latest DSM
- [ ] Write custom acme.sh deploy hook wrapping `synowebapi`
- [ ] Validate renewal path on one cert before cutover
- [ ] Document the tradeoff (undocumented API surface, needs sudo or
  root install) in NAS bootstrap docs

### Webhook on dedicated hostname

Move the deploy webhook off each site's per-site Caddy and onto a single
shared hostname `hooks.server.denfrievilje.dk`, routed directly from DSM
Web Station to the webhook container on the `nas-deploy` network.

**Why**: today the webhook URL is per-site
(`<domain-dashed>.{stage,prod}.denfrievilje.dk/hooks/deploy/<domain>/<env>`),
which routes through that site's Caddy container. compose v2
cascade-recreates per-site Caddy when the site's image digest changes,
which drops the in-flight CI→webhook curl connection — DSM returns 502
to curl, the build-and-notify smart retry waits 180s and tries again,
and the deploy ends up taking ~5 min instead of ~1 min via a redundant
second deploy.sh run. Moving the webhook off the per-site Caddy path
eliminates this entirely.

- [ ] Add A record `hooks.server.denfrievilje.dk` → NAS public IP
- [ ] Add to acme.sh cert renewal (single-host or wildcard
  `*.server.denfrievilje.dk` if other server-scoped services follow)
- [ ] Create DSM Web Station vhost for `hooks.server.denfrievilje.dk`
  proxying to `webhook:9000` on the `nas-deploy` network
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

This is a targeted subset of the Traefik replacement below — does the
connectivity-isolation win for the webhook without committing to
replace the entire DSM-Web-Station + per-site-Caddy pattern.

### Traefik front-door alternative (only when needed)

If a NAS ever becomes docker-host-only (no DSM Web Station tenancy to
respect), collapse the per-site DSM vhost + Caddy pair into a single
Traefik container that handles TLS + host-based routing via docker
labels. Removes `synowebapi` entirely (Traefik does ACME itself) and
removes per-site DSM vhost clicks.

- [ ] Write traefik-based variants of the site template compose files
- [ ] Write NAS migration playbook (takes :443 from DSM, moves DSM admin
  UI to a non-standard port)
- [ ] Do NOT attempt with existing client services still on Web Station
