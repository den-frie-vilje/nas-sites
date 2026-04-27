# NAS bootstrap — the first site on a fresh Synology

Condensed from [skovbyesexologi.com's DEPLOY.md](https://github.com/den-frie-vilje/skovbyesexologi.com/blob/main/DEPLOY.md),
which remains the authoritative step-by-step walkthrough for the first
consumer site. This doc covers the parts that are NOT about the deploy
pipeline itself — DNS, certs, networks, vhosts. For the deploy agent
(scheduling, signature verification, day-2 ops), see
[PULL-DEPLOY-MODEL.md](PULL-DEPLOY-MODEL.md).

## Prerequisite: a DSM 7.2.2+ NAS with Container Manager installed

That's it for prerequisites. No Tailscale, no SSH from CI, no inbound
services beyond `:443`.

## Bootstrap order

1. **DNS wildcards**: `*.stage.denfrievilje.dk` + `*.prod.denfrievilje.dk`
   → NAS public IP. (DEPLOY.md §1)
2. **acme.sh wildcard certs** installed on the NAS, imported into DSM's
   cert store via the `synology_dsm` deploy hook. (DEPLOY.md §2 — includes
   the ZeroSSL-default workaround, DSM non-default-port flags, the
   cert-slot-overwrite gotcha (`SYNO_Certificate` + `SYNO_Create=1`), and
   the Task Scheduler setup.)
3. **Shared docker network**:
   ```sh
   sudo docker network create nas-deploy
   ```
4. **Pull-only deploy agent** — see
   [PULL-DEPLOY-MODEL.md §One-time bootstrap](PULL-DEPLOY-MODEL.md#one-time-bootstrap).
   Walks through cloning nas-sites, installing `deploy-agent.sh`, dropping
   per-site config under `/volume1/docker/nas-sites/sites.d/`, and
   scheduling via DSM Task Scheduler.
5. **Per-site dirs + staging.env/production.env** — follow the first
   consumer site's repo (skovbyesexologi.com/DEPLOY.md §4) until the
   site-template extraction formalises this step.
6. **DSM Web Station vhost per (site, env)** — hostname
   `<DOMAIN_DASHED>.<env>.denfrievilje.dk`, proxy_pass to the
   Caddy-container loopback port, bind the `*.stage.*` or `*.prod.*`
   wildcard cert. Staging vhost adds `X-Robots-Tag: noindex, nofollow`.

## Per-site onboarding after the first

- Create `/volume1/docker/<DOMAIN>/{repo,staging,production}/` directories.
- Clone the site repo into `/volume1/docker/<DOMAIN>/repo`.
- Copy `staging.env.example` → `staging.env`, populate OAuth creds +
  `CADDY_PORT` (pick next-free pair).
- Drop a per-(site, env) config under
  `/volume1/docker/nas-sites/sites.d/<DOMAIN>.<ENV>.env` (see
  [`nas-agent/sites.env.example`](../nas-agent/sites.env.example)).
- Create the staging + production DSM vhosts.
- Push any commit to the site's `staging` branch — CI builds, signs, and
  pushes to GHCR. The agent's next fire (within ~5 min) verifies the
  signature and deploys.

The first deploy is also the chicken-and-egg manual bring-up covered in
the first site's DEPLOY.md §8 — once a stack dir exists with its env file,
the agent picks up from there.

## Gotchas

### Custom systemd units do not survive DSM updates

Per Synology's developer documentation, `/etc/systemd/system/` is not
preserved across DSM minor-version updates. The deploy agent's recommended
scheduler is therefore DSM Task Scheduler, not systemd. The repo includes
systemd unit templates ([`nas-agent/systemd/`](../nas-agent/systemd)) for
non-DSM hosts and for operators who explicitly accept the maintenance
burden.

### DSM Task Scheduler "every N minutes" stops after one hour

The `Last run time` field defaults to one hour after `First run time`.
For a continuously-firing agent, set it to `23:59` explicitly. See
[PULL-DEPLOY-MODEL.md §5.A](PULL-DEPLOY-MODEL.md#option-a-dsm-task-scheduler-recommended-on-dsm).

### `/etc/crontab` edits are overwritten by Task Scheduler

DSM's Task Scheduler is the writer of `/etc/crontab`. Hand edits are wiped
on reboot or after any Task Scheduler change. Use the GUI as the source of
truth, never `crontab -e` on DSM.

### `sudo git` on a clone owned by another user fails with "dubious ownership"

If you `sudo git clone ...` then later run a `git ...` command as another
user (or vice versa), Git 2.35+ refuses with `fatal: detected dubious
ownership`. Two workarounds:

```sh
# A: trust this clone for root's git globally (one-time).
sudo git config --global --add safe.directory /volume1/docker/<path>

# B: run as the clone owner.
sudo -u <owner> git -C /volume1/docker/<path> status
```

The deploy agent applies workaround A internally on every fire so its own
git operations are never blocked by this.

