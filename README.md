# nas-sites

Reusable GitHub Actions workflow + a NAS-side deploy agent for the
den-frie-vilje **docker-hosted-site pattern**.

The CD model is **pull-only**: CI builds, pushes, and Sigstore-signs the
image; the NAS pulls, verifies the signature, and deploys on its own
schedule.

## What this repo provides

### Reusable CI workflow (`.github/workflows/`)

- **[`build-and-sign.yml`](.github/workflows/build-and-sign.yml)** — generic
  Docker build + push + Sigstore Cosign keyless signing. Site repos call
  this; it has no language or framework assumptions. CI does not call the
  NAS — the workflow ends at `cosign sign`.

### NAS-side deploy agent (`nas-agent/`)

- **[`deploy-agent.sh`](nas-agent/deploy-agent.sh)** — operator-installed
  bash agent. Runs every 5–15 min via DSM Task Scheduler. For each
  configured site it pulls the site repo, cosign-verifies every image
  referenced by the compose file (failing closed on signature error),
  then runs `docker compose pull && up -d --wait` if any image digest
  changed.
- **[`sites.env.example`](nas-agent/sites.env.example)** — template for a
  per-(site, env) config file under `/volume1/docker/nas-sites/sites.d/`.
- **[`systemd/`](nas-agent/systemd)** — secondary scheduling option for
  non-DSM hosts.

The agent is not auto-updated at runtime. Edits to `nas-agent/deploy-agent.sh`
in this repo only land on the NAS when an operator pulls and re-installs
them.

## Architecture

```
  ┌─────────────────┐     push          ┌──────────────────┐
  │ your-site repo  │ ────────────────▶ │ GH Actions       │
  │  - Dockerfile   │                   │ - docker build   │
  │  - deploy-*.yml │                   │ - docker push    │
  │  (thin caller)  │                   │ - cosign sign    │
  └─────────────────┘                   └──────────────────┘

                                                       │ image + signature in GHCR + Rekor
                                                       ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  NAS (Synology, DSM 7.2.2+)                                 │
  │                                                             │
  │   DSM Web Station → Caddy (per site) → site container       │
  │                                                             │
  │   DSM Task Scheduler (every ~5 min):                        │
  │     /volume1/docker/nas-sites/deploy-agent.sh               │
  │       for each /volume1/docker/nas-sites/sites.d/*.env:     │
  │         git fetch + reset                                   │
  │         cosign verify every image (fail closed)             │
  │         if digest changed:                                  │
  │           docker compose pull && up -d --wait               │
  │           optional: CF cache purge                          │
  └─────────────────────────────────────────────────────────────┘
```

Per-site URLs follow the convention:

```
<DOMAIN_DASHED>.stage.denfrievilje.dk    (staging origin)
<DOMAIN_DASHED>.prod.denfrievilje.dk     (production origin)
<DOMAIN>                                 (client-facing, CNAME'd to .prod)
```

`<DOMAIN_DASHED>` = `<DOMAIN>` with dots replaced by dashes. This keeps
the whole origin inside a single DNS label so the wildcard cert
`*.{stage,prod}.denfrievilje.dk` covers every site without per-site cert
issuance.

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
    uses: den-frie-vilje/nas-sites/.github/workflows/build-and-sign.yml@main
    with:
      environment: staging
      dockerfile: deploy/Dockerfile
      image-name: ghcr.io/den-frie-vilje/example-site
      build-args: |
        PUBLIC_GIT_SHA=${{ github.sha }}
      verify-url: https://example-com.stage.denfrievilje.dk/
```

`verify-url` is optional but recommended — after sign, CI polls the live
URL until the new commit's SHA appears in the response, turning "CI
green" into "CI green and the NAS picked up the change." See
[PULL-DEPLOY-MODEL.md §Exposing the build SHA](docs/PULL-DEPLOY-MODEL.md#exposing-the-build-sha-for-ci-side-deploy-verification)
for the one-line site change required.

The site repo owns:

- `deploy/Dockerfile` — multi-stage build producing the runtime image
- Per-site compose files, Caddy configs, env files

The NAS owns:

- `deploy-agent.sh` (installed once by the operator)
- A per-site config file under `/volume1/docker/nas-sites/sites.d/`
- The cadence (DSM Task Scheduler, typically every 5 min)

## Network invariants

Two Docker networks are in play per NAS:

- **`nas-deploy`** (external, shared) — hosts each site's `caddy`
  container so per-site Caddys can address each other if needed and so
  DSM Web Station targets have a stable, named docker network.
- **`internal`** (external: false, per-compose-project) — hosts a site's
  `site` container and its `sveltia-auth` container. Each site's compose
  creates its own `internal` network so service names are scoped
  per-project and cannot collide across sites.

**Invariant for `nas-deploy`**: only per-site Caddys may join it. Adding
any other service — especially one with a common service name like
`site` — risks cross-site DNS collisions. Site-scoped services stay on
their project's `internal` network.

## Security model

The CD pipeline's privilege boundary is:

| Capability | Requires |
|---|---|
| Deploy code on NAS | An image cosign-signed by `build-and-sign.yml@refs/heads/(main\|staging)` of a `den-frie-vilje/*` repo, AND a commit on the watched branch of the corresponding site repo, AND the deploy agent's next fire to land |
| Modify what the NAS deploys (e.g. disable signature verification) | Operator action: pull `nas-sites/main`, re-install `deploy-agent.sh` on the NAS via sudo. A `nas-sites/main` push alone cannot do this. |
| Trigger an out-of-band deploy | NAS operator with shell access (`sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh`). |

For the full threat model, the run-as-`deploy` posture, and known
residual risks (notably: docker-socket access is functionally
root-equivalent), see
[PULL-DEPLOY-MODEL.md §Security model](docs/PULL-DEPLOY-MODEL.md#security-model).

## Documentation

- **[PULL-DEPLOY-MODEL.md](docs/PULL-DEPLOY-MODEL.md)** — operator manual:
  install the agent, schedule it, day-2 ops, troubleshooting, security
  model.
- **[NAS-BOOTSTRAP.md](docs/NAS-BOOTSTRAP.md)** — fresh-NAS provisioning
  (DNS, certs, networks, vhosts).
- **[MIGRATION-FROM-WEBHOOK.md](docs/MIGRATION-FROM-WEBHOOK.md)** —
  cutover guide for sites still using the prior webhook-based pipeline.
  Time-boxed: deletes itself once all sites are migrated.

## Roadmap

### Site templates

Scaffold `templates/` with ready-to-fork shapes for the common cases:

- [ ] `templates/sveltekit-static/` — SvelteKit + adapter-static
- [ ] `templates/astro-static/` — same shape, Astro instead
- [ ] `templates/hugo/` — Hugo, no Node in builder stage
- [ ] `templates/node-api/` — long-running Node/Deno backend
- [ ] `templates/static-with-api/` — multi-container (static frontend +
  Node backend + optional DB)

### Ansible-based NAS bootstrap

- [ ] `ansible/bootstrap-nas.yml` — one-shot NAS provisioning (docker,
  acme.sh wildcards via DNS-01, deploy-agent install, DSM Task Scheduler
  task creation via the WebAPI, DSM firewall rule for `:5000`/`:5001` LAN-only)
- [ ] `ansible/bootstrap-site.yml` — per-site NAS setup (dirs, env files,
  `sites.d/<...>.env` append, Web Station vhost creation via DSM WebAPI)
- [ ] Inventory file structure for per-NAS config
- [ ] Tested on a fresh DSM 7.2.2+ install

### Production digest pinning

- [ ] Decide policy: should `compose.production.yml` pin images to digests
  (`@sha256:…`) instead of using rolling `<env>-latest` tags? This closes
  the TOCTOU window between cosign verify and `docker compose pull`. Cost:
  an extra PR per production deploy.
- [ ] If yes: tooling to update the digest in PR comments / via a CLI.

### Branch protection and signed commits

Required to make the security-model assumptions hold:

- [ ] Branch protection on `nas-sites/main` requiring PR review
- [ ] Signed-commit enforcement on `nas-sites/main`
- [ ] Same on each consumer site repo's deploy branches (`main`, `staging`)

### Synotools hardening (optional)

Replace the `synology_dsm` acme.sh hook (which needs admin creds in an
env file) with a root-local `synowebapi` call. Removes the last
credential from disk on the NAS.
