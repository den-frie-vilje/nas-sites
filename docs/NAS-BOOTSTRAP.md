# NAS bootstrap — the parts that aren't about the deploy pipeline

This doc covers the one-time NAS provisioning that the deploy agent
*assumes is already in place* — DNS, certs, networks, vhosts. The deploy
agent itself, the per-site setup, and day-2 ops live in
[PULL-DEPLOY-MODEL.md](PULL-DEPLOY-MODEL.md), which drives everything
through interactive scripts under [`tools/`](../tools/).

## Prerequisite: a DSM 7.2.2+ NAS with Container Manager installed

That's it for prerequisites.

## Bootstrap order

1. **DNS wildcards**: `*.stage.denfrievilje.dk` + `*.prod.denfrievilje.dk`
   → NAS public IP.
2. **acme.sh wildcard certs** installed on the NAS, imported into DSM's
   cert store. The recommended import hook is the local-`synowebapi` one
   in [`tools/syno-acme-local-hook/`](../tools/syno-acme-local-hook/) —
   removes the on-disk DSM admin credential the upstream `synology_dsm`
   hook needs. Install with:
   ```sh
   sudo /volume1/docker/nas-sites/repo/tools/syno-acme-local-hook/install.sh
   ```
   See [SYNOTOOLS-HARDENING.md](SYNOTOOLS-HARDENING.md) for the full
   setup including the migration steps for an existing acme.sh install.
3. **Shared docker network**:
   ```sh
   sudo docker network create nas-deploy
   ```
4. **Pull-only deploy agent** — see
   [PULL-DEPLOY-MODEL.md §One-time bootstrap](PULL-DEPLOY-MODEL.md#one-time-bootstrap).
   Five interactive scripts walk through deploy user, docker group, agent
   install, boot-up task, and DSM Task Scheduler entry.
5. **DSM Web Station vhost per (site, env)** — hostname
   `<DOMAIN_DASHED>.<env>.denfrievilje.dk`, proxy_pass to the
   Caddy-container loopback port, bind the `*.stage.*` or `*.prod.*`
   wildcard cert. Staging vhost adds `X-Robots-Tag: noindex, nofollow`.
   This step is GUI-only — Web Station's APIs are too unstable across
   DSM versions to script (see SYNOTOOLS-HARDENING.md §Web Station).

## Per-site onboarding

```sh
sudo /volume1/docker/nas-sites/repo/tools/bootstrap-site.sh
```

Prompts for domain, environment, repo, branch, compose file path. Then
creates the per-site directory tree (`/volume1/docker/<DOMAIN>/{repo,<env>}/`),
clones the site repo, drops the per-stack env file, copies the agent
config from `nas-agent/sites.env.example`, opens `$EDITOR` on each, and
offers to run a one-off agent fire as a smoke test.

Run twice per site (once for staging, once for production). The DSM Web
Station vhost still has to be added by hand per step 5 above.

## Gotchas

### Custom systemd units do not survive DSM updates

Per Synology's developer documentation, `/etc/systemd/system/` is not
preserved across DSM minor-version updates. The deploy agent's
recommended scheduler is therefore DSM Task Scheduler, not systemd. The
repo includes systemd unit templates ([`nas-agent/systemd/`](../nas-agent/systemd))
for non-DSM hosts and for operators who explicitly accept the
maintenance burden.

### DSM Task Scheduler "every N minutes" stops after one hour

The `Last run time` field defaults to one hour after `First run time`.
For a continuously-firing agent, set it to `23:59` explicitly. See
[PULL-DEPLOY-MODEL.md §6](PULL-DEPLOY-MODEL.md#6-schedule-the-agent).

### `/etc/crontab` edits are overwritten by Task Scheduler

DSM's Task Scheduler is the writer of `/etc/crontab`. Hand edits are
wiped on reboot or after any Task Scheduler change. Use the GUI as the
source of truth.

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

The deploy agent applies workaround A internally on every fire, so its
own git operations are never blocked by this.

### `synogroup --member` REPLACES the member list

Not append. If you `synogroup --member docker deploy` on a docker group
that already had members, you'll silently drop them. The
`tools/bootstrap-deploy-user.sh` script reads `getent group docker` first
and re-applies the full member list.

### `install` is not on stock DSM

DSM ships BusyBox utilities for most of `/bin` and `/usr/bin`, and
BusyBox has no `install` applet. Use `cp + chmod + chown` instead. The
`tools/lib/common.sh` `install_file` helper does this; the operator
scripts use it consistently.
