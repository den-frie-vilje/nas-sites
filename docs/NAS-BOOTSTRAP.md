# NAS bootstrap — the first site on a fresh Synology

Condensed from [skovbyesexologi.com's DEPLOY.md](https://github.com/den-frie-vilje/skovbyesexologi.com/blob/main/DEPLOY.md),
which remains the authoritative step-by-step walkthrough for
the first consumer site. This doc will grow into a fully
site-agnostic bootstrap when the site-template extraction (Stage 3)
is done — for now it points back to that one.

## Prerequisite: a DSM 7.2.2+ NAS with Container Manager installed

That's it for prerequisites. No Tailscale, no SSH from CI, no
inbound services beyond :443.

## Bootstrap order

1. **DNS wildcards**: `*.stage.denfrievilje.dk` + `*.prod.denfrievilje.dk`
   → NAS public IP. (DEPLOY.md §1)
2. **acme.sh wildcard certs** installed on the NAS, imported
   into DSM's cert store via the `synology_dsm` deploy hook.
   (DEPLOY.md §2 — includes the ZeroSSL-default workaround,
   DSM non-default-port flags, the cert-slot-overwrite gotcha
   (SYNO_Certificate + SYNO_Create=1), and the Task Scheduler
   setup.)
3. **deploy user + docker paths + shared docker network**:
   ```sh
   sudo mkdir -p /volume1/docker/webhook
   sudo chown -R deploy:users /volume1/docker
   sudo docker network create nas-deploy
   ```
4. **Shared webhook container**:

   The NAS keeps a permanent shallow clone of `nas-sites` at
   `/volume1/docker/webhook/nas-sites/`. `deploy.sh` git-pulls
   this clone on every fire and propagates any changes to the
   webhook's mounted `hooks.yaml` + `scripts/deploy.sh` (see
   the `NAS_SITES` self-update block in `deploy.sh`). So bootstrap
   does TWO things: (1) the persistent clone for self-update,
   (2) the initial copy of the webhook artefacts into the
   webhook stack's mount paths.

   ```sh
   # 1) Persistent clone for ongoing self-update.
   sudo git clone --depth 1 \
     https://github.com/den-frie-vilje/nas-sites.git \
     /volume1/docker/webhook/nas-sites
   sudo chown -R deploy:users /volume1/docker/webhook/nas-sites

   # 2) Initial copy into the webhook stack's mount paths. After
   #    this, edits to nas-sites' shared/webhook/{hooks.yaml,
   #    scripts/deploy.sh} propagate via deploy.sh's self-update
   #    block — no manual cp per change.
   SRC=/volume1/docker/webhook/nas-sites/shared/webhook
   sudo cp "$SRC/compose.yml" /volume1/docker/webhook/compose.yml
   sudo mkdir -p /volume1/docker/webhook/webhook/scripts
   sudo cp "$SRC/hooks.yaml" /volume1/docker/webhook/webhook/hooks.yaml
   sudo cp "$SRC/scripts/deploy.sh" /volume1/docker/webhook/webhook/scripts/deploy.sh
   sudo chmod +x /volume1/docker/webhook/webhook/scripts/deploy.sh
   sudo cp "$SRC/webhook.env.example" /volume1/docker/webhook/webhook.env
   sudo chmod 600 /volume1/docker/webhook/webhook.env
   # Edit webhook.env with HMAC secrets per site (see webhook.env.example
   # in this repo for the naming convention).

   cd /volume1/docker/webhook
   sudo docker compose up -d
   ```
5. **Per-site dirs + staging.env/production.env** — follow the
   first consumer site's repo (skovbyesexologi.com/DEPLOY.md §4)
   until the site-template extraction formalises this step.
6. **DSM Web Station vhost per (site, env)** — hostname
   `<DOMAIN_DASHED>.<env>.denfrievilje.dk`, proxy_pass to the
   Caddy-container loopback port, bind the `*.stage.*` or
   `*.prod.*` wildcard cert. Staging vhost adds
   `X-Robots-Tag: noindex, nofollow`.

## Per-site onboarding after the first

- Append two hook entries to `shared/webhook/hooks.yaml` IN THIS
  REPO (not on the NAS). Commit + push. The NEXT deploy fire on
  ANY existing site git-pulls the nas-sites clone and propagates
  the new entries to the webhook's hooks.yaml. Webhook
  `-hotreload` picks them up within a second — no restart needed.
- Append two HMAC secrets (+ optional CF vars) to
  `/volume1/docker/webhook/webhook.env` ON THE NAS (these are
  per-NAS secrets, NOT committed) under the site's
  `<DOMAIN_SAFE>_…` prefix. Then on the NAS:
  ```sh
  cd /volume1/docker/webhook && sudo docker compose down && sudo docker compose up -d
  ```
  (env files are baked at container creation, so a `restart`
  doesn't pick up new secrets — needs full down + up).
- Create `/volume1/docker/<DOMAIN>/{repo,staging,production}/`
  directories
- Clone the site repo into `/volume1/docker/<DOMAIN>/repo`
- Copy staging.env.example → staging.env, populate OAuth creds
  + CADDY_PORT (pick next-free pair)
- Create the staging + production DSM vhosts
- Push any commit to the site's `staging` branch — deploy fires

The shared webhook is hot-reloading, and the site's first
`docker compose up` is triggered by the first CI deploy fire +
the chicken-and-egg manual bring-up covered in the first site's
DEPLOY.md §8.

## Gotchas

### `sudo git` on the nas-sites clone fails with "dubious ownership"

The bootstrap above clones `nas-sites` to
`/volume1/docker/webhook/nas-sites` and chowns the result to
`deploy:users`. When you later run a `sudo git ...` command
against that clone from the host shell, Git 2.35+ refuses with
`fatal: detected dubious ownership in repository at '...'`
because `sudo`-as-root is operating on a clone owned by a
different user. Two workarounds:

```sh
# Option A: trust this clone for root's git globally (one-time).
sudo git config --global --add safe.directory \
  /volume1/docker/webhook/nas-sites

# Option B: run as the clone owner instead of sudo.
sudo -u deploy git -C /volume1/docker/webhook/nas-sites status
```

Either works. The webhook container itself is unaffected: its
`deploy.sh` does `git config --global --add safe.directory '*'`
at startup and runs every git command from inside the
container, so its self-update path is never blocked by this.

### Pre-extraction layouts (existing NASes bootstrapped before
2026-04)

A NAS bootstrapped before the `nas-sites` extraction (PR #4 in
[skovbyesexologi.com](https://github.com/den-frie-vilje/skovbyesexologi.com/pull/4))
has a slightly different layout: `compose.yml` lives inside
`/volume1/docker/webhook/webhook/` (not at the top level
`/volume1/docker/webhook/compose.yml` shown above), and the
self-update used to read from each consumer site's repo
(broken since extraction; fixed by the deploy.sh self-update
update in
[`ba1d97a`](https://github.com/den-frie-vilje/nas-sites/commit/ba1d97a)).

Existing NASes don't need to migrate — both layouts function
identically for ongoing operations. The new layout above is
the target for fresh bootstraps and for future site templates.
If you want to align an existing NAS, the migration is roughly:
move `compose.yml` to the top level, remove the leftover
`Dockerfile` from `/volume1/docker/webhook/webhook/` (it was
used pre-extraction when the image built locally; the runtime
now pulls from GHCR), then `docker compose down && up -d`.
