# tools/

Operator scripts for the NAS. Every script in here is **interactive** — it
prints what it's about to do and asks for explicit confirmation at every
mutating step. Run them by hand from a root shell on the NAS; do not call
them from cron, GitHub Actions, or anything non-interactive.

These scripts live inside the nas-sites repo so they can be code-reviewed
and signed-commit-protected. They reach the NAS by way of the
operator-cloned `repo/` tree at `/volume1/docker/nas-sites/repo/`. Run from
there:

```sh
sudo /volume1/docker/nas-sites/repo/tools/<script>.sh
```

## What's here

| Script | When to run |
|---|---|
| [`update-agent.sh`](update-agent.sh) | After any `nas-sites/main` merge that touches `nas-agent/deploy-agent.sh`. Pulls the repo and re-installs the agent. The single most important script — running it is the explicit operator action that keeps "push to nas-sites/main" from being equivalent to "code execution on the NAS." |
| [`bootstrap-deploy-user.sh`](bootstrap-deploy-user.sh) | Once per fresh NAS. Creates the `deploy` user, the `docker` group, and applies socket ownership. |
| [`install-boot-tasks.sh`](install-boot-tasks.sh) | Once per fresh NAS, after the deploy-user bootstrap. Walks through the DSM Task Scheduler GUI clicks needed to persist `docker.sock` group ownership across reboots. |
| [`bootstrap-site.sh`](bootstrap-site.sh) | Once per `(site, environment)`. Prompts for domain, repo, branch, etc.; creates dirs, clones the site repo, drops the per-site agent config, opens `$EDITOR` on the secrets files. |
| [`syno-acme-local-hook/install.sh`](syno-acme-local-hook/install.sh) | Once per NAS, optional. Installs an acme.sh deploy hook that imports renewed certs into DSM via local `synowebapi`, removing the on-disk DSM admin credential the upstream hook needs. See [docs/SYNOTOOLS-HARDENING.md](../docs/SYNOTOOLS-HARDENING.md). |

## Conventions

- Every script sources `tools/lib/common.sh` for the shared interactive
  helpers (`heading`, `plan`, `confirm`, `ask`, `run`, `install_file`,
  `create_empty_file`).
- Every mutating step echoes the literal command before running it (`run`),
  so the operator always sees what landed.
- Scripts refuse to run unless invoked as root and on DSM (override with
  `ALLOW_NON_DSM=1` for testing).
- `install_file` and `create_empty_file` are used instead of GNU `install`
  because DSM ships BusyBox utilities, and BusyBox has no `install` applet.

## Why interactive

Every script in here mutates state on a production NAS. The interactive
prompts are deliberate friction: the operator must read what's about to
happen and type `y` to consent, every time. Scripts that pretend to be
helpful by being silent end up running on autopilot and producing
surprises. The opposite property is what we want here.
