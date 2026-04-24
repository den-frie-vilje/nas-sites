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
   ```sh
   REPO=/tmp/nas-sites
   git clone --depth 1 https://github.com/den-frie-vilje/nas-sites.git "$REPO"
   sudo cp "$REPO/shared/webhook/compose.yml" /volume1/docker/webhook/compose.yml
   sudo mkdir -p /volume1/docker/webhook/webhook/scripts
   sudo cp "$REPO/shared/webhook/hooks.yaml" /volume1/docker/webhook/webhook/hooks.yaml
   sudo cp "$REPO/shared/webhook/scripts/deploy.sh" /volume1/docker/webhook/webhook/scripts/deploy.sh
   sudo chmod +x /volume1/docker/webhook/webhook/scripts/deploy.sh
   sudo cp "$REPO/shared/webhook/webhook.env.example" /volume1/docker/webhook/webhook.env
   sudo chmod 600 /volume1/docker/webhook/webhook.env
   # Edit webhook.env with HMAC secrets per site (see webhook.env.example
   # in this repo for the naming convention).
   rm -rf "$REPO"
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

- Append two hook entries to `/volume1/docker/webhook/webhook/hooks.yaml`
  (template in this repo's `shared/webhook/hooks.yaml`)
- Append two HMAC secrets (+ optional CF vars) to
  `/volume1/docker/webhook/webhook.env` under the site's
  `<DOMAIN_SAFE>_…` prefix
- Create `/volume1/docker/<DOMAIN>/{repo,staging,production}/`
  directories
- Clone the site repo into `/volume1/docker/<DOMAIN>/repo`
- Copy staging.env.example → staging.env, populate OAuth creds
  + CADDY_PORT (pick next-free pair)
- Create the staging + production DSM vhosts
- Push any commit to the site's `staging` branch — deploy fires

No NAS restart needed for new sites. The shared webhook is
hot-reloading, and the site's first `docker compose up` is
triggered by the first CI deploy fire + the chicken-and-egg
manual bring-up covered in the first site's DEPLOY.md §8.
