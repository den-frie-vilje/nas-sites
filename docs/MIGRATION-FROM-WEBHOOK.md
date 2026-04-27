# Migration: webhook + deploy.sh → pull-only deploy agent

The old model is documented in this file mainly so the cutover steps make
sense; the operator manual for the new model is
[PULL-DEPLOY-MODEL.md](PULL-DEPLOY-MODEL.md).

## Why we're migrating

A security review found that the previous design composed two choices into
a path where push access to `nas-sites/main` was equivalent to root on the
NAS:

1. The webhook container had `/var/run/docker.sock` mounted (root on host).
2. Its `deploy.sh` self-updated from a `git pull` of `nas-sites/main` on
   every fire.

Together, a malicious commit to `nas-sites/main` would land on the next
fire of any site and execute as root. The fix the review asked for: drop
the inbound webhook entirely and run an operator-installed pull agent on
the NAS that verifies image signatures before deploying.

## What changes

| | Old | New |
|---|---|---|
| Trigger | GitHub Actions POSTs HMAC-signed webhook to NAS per push | NAS runs an agent every 5–15 min on its own schedule |
| NAS-side code source | Self-updated from `nas-sites/main` mid-fire | Operator-installed; no auto-update |
| Per-site secrets | One HMAC secret per site, in CI + on NAS | None — no inbound endpoint to authenticate |
| Image trust | Implicit (whatever GHCR returns at pull time) | Sigstore Cosign signature verified per-image, fail-closed |
| Inbound port on NAS | Per-site Caddy `/hooks/*` | None |
| Latency CI → live | < 1 min | 0–15 min (agent poll interval) |

## Cutover plan (per site, then per-NAS)

Migration is **per-site, not per-NAS**. The old webhook stack and the new
agent can run in parallel during the cutover window — they don't share
state.

### Phase 1 — get the new pipeline running on at least one site (canary)

1. **In `nas-sites`** (this repo, `refactor/pull-only-deploy` branch):
   merge to `main`. This makes `build-and-sign.yml` available and
   deprecates `build-and-notify.yml`.
2. **On the NAS**: complete the [PULL-DEPLOY-MODEL.md bootstrap](PULL-DEPLOY-MODEL.md#one-time-bootstrap)
   sections 1–5 (clone repo, install agent, schedule via DSM Task
   Scheduler) — but do NOT yet add any site config to `sites.d/`. The
   agent will run, find no sites, log "no site configs", and exit clean.
3. **Pick a canary site** (suggest staging-only first, e.g.
   `skovbyesexologi.com`).
4. **In the canary site repo**: open a PR that:
   - changes `.github/workflows/deploy-staging.yml` to call
     `den-frie-vilje/nas-sites/.github/workflows/build-and-sign.yml@main`
     instead of `build-and-notify.yml`
   - drops the `webhook-url`, `smoke-check-url`, and `WEBHOOK_SECRET`
     inputs (build-and-sign doesn't take them)
   - keeps `environment`, `dockerfile`, `image-name`, `build-args`,
     `platforms` unchanged
5. Merge the PR, push to the staging branch, watch CI build + sign + push.
   No webhook POST happens — the site repo's deploy workflow now only
   calls `build-and-sign.yml`, which doesn't talk to the NAS. The old
   webhook stack is still installed and still listening, but nothing is
   calling it for this site anymore.
6. **On the NAS**: add the canary site's staging config to
   `sites.d/skovbyesexologi.com.staging.env` (per
   PULL-DEPLOY-MODEL.md §3). Trigger the agent manually:
   `sudo /volume1/docker/nas-sites/deploy-agent.sh skovbyesexologi.com staging`
7. Verify: cosign verify line passes, container redeploys, site stays up.
8. Wait for the next scheduled fire to confirm the no-op idempotent path.

If the canary works, proceed. If not, revert the site repo PR and
investigate; the old webhook stack is still running and will resume serving
the next deploy.

### Phase 2 — migrate the rest of the sites

For each remaining site (do production AFTER the site's staging is on the
new pipeline and proven):

1. **Site repo PR**: identical to the canary PR above, for
   `deploy-staging.yml` and `deploy-production.yml`.
2. **NAS**: add `sites.d/<domain>.<env>.env` for both environments.
3. **Site repo settings**: delete the now-unused `WEBHOOK_SECRET` from
   GitHub Actions secrets.

### Phase 3 — decommission the old webhook stack

Once every site repo has been migrated (no callers of `build-and-notify.yml`
remain — verify with a search across the org's repos):

1. **On the NAS**:
   ```sh
   cd /volume1/docker/webhook && sudo docker compose down
   sudo rm -rf /volume1/docker/webhook
   ```
2. **DSM Web Station**: remove the per-site `/hooks/*` route handlers from
   each per-site Caddyfile.
3. **In `nas-sites`**: open a PR that deletes
   `.github/workflows/build-and-notify.yml`. Once merged, the migration is
   complete.

## Rollback

At any point during phases 1 or 2:

- **Per site**: revert the site repo's CI workflow PR. The site's CI goes
  back to calling the old webhook. Remove the site's `sites.d/<...>.env`
  on the NAS so the agent stops touching it.
- **All sites**: don't decommission the old webhook stack until phase 3.
  As long as `/volume1/docker/webhook` is still up and the per-site Caddy
  `/hooks/*` routes are still in place, any site repo can revert its PR
  and immediately use the old path.

After phase 3, rollback means restoring the deleted files from git history
and re-running the old webhook bootstrap from the previous
`docs/NAS-BOOTSTRAP.md` (preserved in git history for this purpose).

## Things this migration does NOT change

- Per-site repo layout (`deploy/Dockerfile`, `deploy/compose.<env>.yml`).
- Per-site stack directory layout on the NAS
  (`/volume1/docker/<domain>/{repo,staging,production}/`).
- DSM Web Station vhosts per (site, env).
- The `<DOMAIN_DASHED>.{stage,prod}.denfrievilje.dk` URL convention.
- The `*.{stage,prod}.denfrievilje.dk` wildcard cert setup.
- The two-network split (`nas-deploy` shared, `internal` per-project).

If your site uses any of these, the migration is purely a CD pipeline
change — nothing about how the site itself is built or served changes.
