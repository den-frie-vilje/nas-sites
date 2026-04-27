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

## Tight-coupling caveat: workflows merge in lockstep

`nas-sites` PR #7 deletes the old `build-and-notify.yml` reusable workflow
in the same PR that adds `build-and-sign.yml`. Once #7 lands on `main`,
any site repo that still references `build-and-notify.yml@main` will fail
on its next CI run with "workflow not found." This is deliberate — silent
deprecation lets stale callers keep POSTing to a webhook that may no
longer exist. Loud failure surfaces the lag.

The operational consequence: each site's migration PR must merge **within
minutes** of `nas-sites/main` getting the new pipeline. Coordinate the
merges; don't leave a multi-hour gap where the staging branch can
auto-deploy on a Sveltia content commit and break.

## Cutover plan

### Phase 1 — `nas-sites` first

1. Review and merge [`nas-sites` PR #7](https://github.com/den-frie-vilje/nas-sites/pull/7).
   On merge, `main` has `build-and-sign.yml` and no longer has
   `build-and-notify.yml`.
2. **Within minutes**, merge each site repo's matching migration PR (see
   Phase 2). Until those merge, every push to those sites will fail.

### Phase 2 — site repo migration PRs

For each site, open a PR that:

- changes `.github/workflows/deploy-staging.yml` (and `deploy-production.yml`)
  to call `den-frie-vilje/nas-sites/.github/workflows/build-and-sign.yml@main`;
- drops the `webhook-url`, `smoke-check-url`, and `WEBHOOK_SECRET` inputs;
- optionally adds `verify-url: https://<env-origin>/` so CI polls the new
  commit's SHA after sign;
- keeps `environment`, `dockerfile`, `image-name`, `build-args`,
  `platforms` unchanged.

For skovbyesexologi.com, this is [PR #16](https://github.com/den-frie-vilje/skovbyesexologi.com/pull/16).

### Phase 3 — NAS bootstrap (can happen in parallel with Phase 1/2)

Bring up the new agent on the NAS without yet pointing it at any site:

1. Clone nas-sites onto the NAS.
2. Run `tools/bootstrap-deploy-user.sh`, `tools/update-agent.sh`,
   `tools/install-boot-tasks.sh`.
3. Add the DSM Task Scheduler entry per
   [PULL-DEPLOY-MODEL.md §6](PULL-DEPLOY-MODEL.md#6-schedule-the-agent).
4. Verify: agent fires on schedule, finds no sites, logs
   "no site configs … nothing to do", exits clean.

### Phase 4 — wire the canary site

Once the site PR has merged AND the agent is running on the NAS:

1. Run `tools/bootstrap-site.sh` for the canary `(site, env)`. Suggest
   skovbyesexologi.com staging first.
2. Trigger a manual fire as a smoke test:
   ```sh
   sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh skovbyesexologi.com staging
   ```
3. Verify: cosign verify line passes, container redeploys, site stays up.
4. Wait for the next scheduled fire to confirm the no-op idempotent path.
5. Push a no-op commit (or `workflow_dispatch`) to the staging branch.
   CI's `verify-url` step should find the new commit SHA in the staging
   origin's response within ~6 min.

If the canary works, repeat for production. If not, see Rollback below.

### Phase 5 — decommission the old webhook stack on the NAS

Once every site is on the new pipeline and verified:

```sh
cd /volume1/docker/webhook && sudo docker compose down
sudo rm -rf /volume1/docker/webhook
```

Then in DSM Web Station, remove the per-site `/hooks/*` route handlers
from each per-site Caddyfile. In each site repo's GitHub Actions secrets,
delete `STAGING_WEBHOOK_SECRET` and `PRODUCTION_WEBHOOK_SECRET`.

## Rollback

The lockstep merge in Phase 1+2 means rollback is also lockstep:

- **During Phase 4** (site is on new pipeline, NAS is on new agent):
  remove the site's `sites.d/<...>.env` on the NAS; the agent stops
  touching it. The site's last successfully-deployed container keeps
  serving until you re-add the config or roll forward.
- **During Phase 1+2 merge window** (site PR merged but NAS not yet
  bootstrapped, OR vice versa): the deploy fails loudly and the site
  keeps serving its last good container. CI fails, no deploy lands.
  Investigate and either roll forward (finish bootstrap) or revert the
  site repo PR + revert nas-sites PR #7. Reverting nas-sites #7 restores
  `build-and-notify.yml` from git, and the site repo's revert puts back
  its old workflow caller — both work again.
- **After Phase 5** (old webhook stack removed): rollback means restoring
  the deleted files from git history and re-running the old webhook
  bootstrap from `docs/NAS-BOOTSTRAP.md` at the pre-deletion commit. By
  this point the new pipeline has been working for some time, so this
  scenario should be rare.

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
