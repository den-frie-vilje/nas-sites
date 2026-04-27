# Pull-only deploy model — operator manual

A small bash agent runs on the NAS every 5–15 minutes, pulls each site
repo, verifies the Sigstore Cosign signature on every image referenced
by that site's compose file, and runs `docker compose pull && up -d --wait`
only if something has actually changed.

This document is the operator manual for the agent. The security model
section at the bottom describes what the design defends against and the
known residual risks.

## Layout

Everything the agent reads or writes lives under `/volume1/docker/nas-sites/`.
This is intentional:

- It's covered by the same offsite backup as the rest of the docker stack.
- It survives DSM updates (the rootfs is regenerated on update; `/volume1`
  is not).
- It's easy to audit: one tree, one operator-readable home.

```
/volume1/docker/nas-sites/
├── deploy-agent.sh              # agent, operator-installed
├── sites.d/                     # per-(site, env) config
│   ├── example.com.staging.env
│   └── example.com.production.env
├── state/                       # agent-managed state (run logs, future state files)
├── repo/                        # operator-clone of nas-sites (reference + cp source)
└── systemd/                     # only if you opt out of DSM Task Scheduler
    ├── nas-sites-deploy.service
    └── nas-sites-deploy.timer
```

The only path the agent uses outside this tree is `/tmp/nas-sites-deploy/`
for per-site flock files. Lock files MUST live on tmpfs so they clear on
reboot (a stale lock on persistent storage would block deploys after an
unclean shutdown), and `/tmp` is universally writable across DSM versions
where `/run/lock` may be root-only.

### File ownership matrix

| Path | Owner:Group | Mode | Why |
|---|---|---|---|
| `deploy-agent.sh` | `root:root` | `0755` | `deploy` can execute, cannot tamper. Updates require operator sudo. |
| `sites.d/*.env` | `root:docker` | `0640` | Contains CF tokens + OAuth secrets. `deploy` reads, cannot rewrite. |
| `state/`, `state/runs/` | `deploy:users` | `0750` | Agent writes run logs here. |
| `repo/` (the nas-sites clone) | `deploy:users` | `0755` | Operator pulls; reference only — agent doesn't read at runtime. |
| `/volume1/docker/<domain>/repo/` | `deploy:users` | `0755` | Site repo clone. Agent does `git fetch + reset` here. |
| `/volume1/docker/<domain>/<env>/<env>.env` | `root:docker` | `0640` | Compose-time secrets. Same model as `sites.d/`. |
| `/tmp/nas-sites-deploy/` | `deploy:users` | `0750` | Lock files. Agent creates on first run. |

## One-time bootstrap

These steps run **once per NAS**, by a human operator with `sudo`. They
cannot be automated from CI by design — the operator is the source of
trust for what the NAS runs.

The mutating steps are encapsulated in interactive scripts under
[`tools/`](../tools/) — each prints what it's about to do and asks for
explicit confirmation before each change. Run them by hand from a root
shell on the NAS.

### 1. Clone nas-sites onto the NAS

```sh
sudo mkdir -p /volume1/docker/nas-sites
sudo git clone --depth 1 \
    https://github.com/den-frie-vilje/nas-sites.git \
    /volume1/docker/nas-sites/repo
```

This clone is for the operator: source of truth for the tools and the
agent script. **The agent itself does not read from this clone at
runtime** — that separation is what keeps `nas-sites/main` push access
from being equivalent to root on the NAS. Updates land on the NAS only
when an operator runs `tools/update-agent.sh`.

### 2. Deploy user + docker group + socket permissions

```sh
sudo /volume1/docker/nas-sites/repo/tools/bootstrap-deploy-user.sh
```

This walks through:

- creating the `deploy` user with locked password;
- creating the `docker` group (if absent);
- adding `deploy` to `docker` (correctly preserving any existing members
  — `synogroup --member` REPLACES the member list rather than appending,
  so the script reads the current members first);
- `chown root:docker /var/run/docker.sock && chmod 660`;
- a verification that `sudo -u deploy docker info` works.

**Important caveat**: docker-socket access is functionally root-equivalent
— any UID with read+write to the socket can launch a privileged container
that mounts `/`. Running as `deploy` is defense in depth, not blast-radius
reduction. See the §Security model section.

### 3. Install the agent

```sh
sudo /volume1/docker/nas-sites/repo/tools/update-agent.sh
```

Same script you'll run after every upstream agent update. First time
through it does the initial install; subsequent runs show the diff and
ask for confirmation before applying.

The installed file is owned `root:root 0755` — `deploy` can execute it,
cannot rewrite it. The only way to change what runs is operator sudo.

### 4. Persist the docker.sock ownership across reboots

```sh
sudo /volume1/docker/nas-sites/repo/tools/install-boot-tasks.sh
```

Walks the operator through the DSM Task Scheduler GUI clicks needed for a
"Triggered Task" on event Boot-up that re-applies the socket chown.
Container Manager resets the socket to `root:root 660` on every reboot
and on every package restart; without this task, the agent fails closed
on every boot until you re-apply ownership by hand.

(The script doesn't drive Task Scheduler over `synowebapi` — the
EventScheduler create payload is undocumented and brittle. The GUI path is
boring, well-supported, and the entry persists across DSM updates.)

### 5. Bootstrap the first site

```sh
sudo /volume1/docker/nas-sites/repo/tools/bootstrap-site.sh
```

Prompts for domain, environment (`staging` or `production`), repo,
branch, compose file path. Then:

- creates `/volume1/docker/<domain>/{repo,<env>}/` owned `deploy:users`;
- `git clone`s the site repo at the chosen branch (skips if already
  cloned);
- creates the per-stack `<env>.env` (root:docker 0640) and opens
  `$EDITOR` for compose-time secrets (`CADDY_PORT`, OAuth IDs, etc.);
- copies `nas-agent/sites.env.example` into
  `/volume1/docker/nas-sites/sites.d/<domain>.<env>.env` (root:docker
  0640), pre-fills the values you typed, opens `$EDITOR` for `CF_API_TOKEN`
  / `CF_ZONE_ID`;
- offers to run a one-off agent fire as a smoke test.

Run twice per new site (once for staging, once for production).

### 6. Schedule the agent

Two options. Pick one. **DSM Task Scheduler is recommended on Synology.**

#### Option A: DSM Task Scheduler (recommended on DSM)

1. Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script
2. **General** tab:
   - Task: `nas-sites-deploy`
   - User: `deploy`
   - Enabled: yes
3. **Schedule** tab:
   - Run on the following days: Daily
   - First run time: `00:00`
   - **Last run time: `23:59`**  ⚠ defaults to "+1 hour" — the agent will
     stop firing after the first hour if you leave the default. Set it to
     `23:59`.
   - Frequency: `Every 5 minute(s)` (or 10/15/30 — pick per latency tolerance)
4. **Task Settings** tab:
   - Run command: `/bin/bash /volume1/docker/nas-sites/deploy-agent.sh`
   - (Why explicit `/bin/bash`: DSM Task Scheduler invokes scripts via
     `/bin/sh` (ash) by default, which doesn't grok bash arrays. The
     shebang would handle this if exec'd, but routing through `bash`
     explicitly is more robust to operator copy-paste.)
   - Send run details by email: **on**, send only when the script
     terminates abnormally — quiet on success, loud on failure
   - Output result to a folder: `/volume1/docker/nas-sites/state/runs/`
     (creates `<task>/<timestamp>/` per fire — handy for forensics)
5. Save.

To trigger immediately for a smoke-test: select the task → Run.

#### Option B: systemd timer (non-DSM hosts, or operators who accept the brittleness)

Edit the `User=` field in `nas-agent/systemd/nas-sites-deploy.service`
from the default `root` to `deploy` before installing if you've completed
step 1's docker-group setup. Then:

```sh
sudo cp /volume1/docker/nas-sites/systemd/nas-sites-deploy.service \
        /volume1/docker/nas-sites/systemd/nas-sites-deploy.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nas-sites-deploy.timer
```

On DSM, units in `/etc/systemd/system/` are not reliably preserved across
DSM minor-version updates per Synology's developer documentation, and they
sit outside the `/volume1/docker/` backup tree. Use this only if you accept
re-installing after each DSM update.

### 7. Make GHCR signature artifacts public (per-image, one-time)

When CI signs an image with `cosign sign`, the signature lands in GHCR
as a *separate* OCI artifact (tagged `sha256-<digest>.sig` against the
same image repository). [GitHub Packages](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
defaults every newly-published package to **private**, even when the
parent image is public. The agent on the NAS pulls signatures
anonymously, so a private signature artifact returns HTTP 401 and the
agent reports `signature verification FAILED: no signatures found`.

Make the package public **once** per image (not per-deploy):

> GitHub → org `den-frie-vilje` → Packages → `<image-name>` → Package
> settings → Danger Zone → Change visibility → **Public** → confirm

This step cannot be scripted. The GitHub REST API exposes only
`list/get/delete/restore` for packages — no `PATCH visibility`
endpoint — and `gh` CLI has no `package` subcommand for this
([cli/cli#6820](https://github.com/cli/cli/issues/6820), open since
2022). Settings GUI is the only path.

After flipping visibility, anonymous `cosign verify` succeeds and the
agent can deploy. Re-run the agent manually to confirm:

```sh
sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh <domain> <env>
```

### 8. Smoke-test

```sh
# As the operator (sudo to run as deploy):
sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh
sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh example.com staging
```

Watch for the `agent: all sites ok` line. A `signature verification FAILED`
line means cosign couldn't validate the image — see Troubleshooting.

## Day-2 operations

### Updating the agent script

When `nas-agent/deploy-agent.sh` in this repo changes, it does not
propagate to the NAS automatically. The operator's job:

```sh
cd /volume1/docker/nas-sites/repo && sudo git pull
sudo install -m 0755 -o root -g root \
    /volume1/docker/nas-sites/repo/nas-agent/deploy-agent.sh \
    /volume1/docker/nas-sites/deploy-agent.sh
```

This is the security boundary the new model preserves. An attacker with
push access to `nas-sites/main` can change `deploy-agent.sh`, but the
change does not run until a human pulls and re-installs it.

### Adding a new site

1. Operator clones the new site's repo into
   `/volume1/docker/<domain>/repo`, creates `staging` and `production`
   stack dirs with their `.env` files, and creates the DSM Web Station
   vhost(s) per the bootstrap steps above.
2. Operator drops a `sites.d/<domain>.<env>.env` file per environment.
3. Next agent fire (within 5–15 min) verifies + deploys.

No CI-side change is required as long as the site repo's deploy workflow
already calls `build-and-sign.yml`.

### Rolling back

Pull-only rollback is `git revert` on the site repo:

```sh
# On a developer machine:
cd <site-repo>
git revert <bad-commit>
git push origin <branch>
```

The site's CI rebuilds + signs the reverted code. The NAS picks up the
new (older) image on its next fire. No "rollback workflow" exists in
nas-sites because there's nothing to coordinate from CI side anymore.

For an in-anger fast rollback (e.g. site is down, can't wait for CI), pin
the compose file to a previous immutable image tag manually, push, agent
deploys.

### Rotating Cloudflare / OAuth secrets

```sh
sudo $EDITOR /volume1/docker/nas-sites/sites.d/<domain>.<env>.env
# (no agent restart needed — re-read every fire)
```

For stack-level secrets (anything the compose file's `${VAR}` interpolates
from `<env>.env`):

```sh
sudo $EDITOR /volume1/docker/<domain>/<env>/<env>.env
# Force a redeploy on the next fire — the agent only redeploys on image
# digest change. To pick up env-file changes, do one of:
sudo /volume1/docker/nas-sites/deploy-agent.sh <domain> <env>   # manual fire
# (which still won't redeploy if the digest hasn't moved — you may need
# `docker compose -p <project> -f <compose> up -d --force-recreate`
# manually for an env-only change. Document this if it bites in practice.)
```

### Disabling the agent (maintenance windows)

DSM Task Scheduler: select the task → Disable.
systemd: `sudo systemctl stop nas-sites-deploy.timer`.

### Pausing one site without disabling all

Move (or rename) the site's config out of `sites.d/`:

```sh
sudo mv /volume1/docker/nas-sites/sites.d/example.com.staging.env \
        /volume1/docker/nas-sites/sites.d/example.com.staging.env.disabled
```

The agent globs `*.env` only.

## Exposing the build SHA for CI-side deploy verification

The pull-only model's main UX downside is that "CI green" no longer means
"deploy live" — there's a 0–N min latency window between `cosign sign`
and the agent's next fire. To close that gap, `build-and-sign.yml` has an
optional `verify-url` step that polls the live URL after build/sign and
fails CI if the new build doesn't appear within the timeout.

For this to work, the site needs to **expose its build identity in its
HTTP response** somewhere CI can grep for. Three common patterns, pick
whichever fits the site's stack:

### Pattern A: meta tag in the HTML head (static sites)

Bake `PUBLIC_GIT_SHA` into a meta tag at build time. SvelteKit/Astro/Hugo
all support this trivially. Example for a static SvelteKit site's
`src/app.html`:

```html
<head>
  <meta name="git-sha" content="%sveltekit.env.PUBLIC_GIT_SHA%" />
  ...
</head>
```

CI side: caller workflow passes `build-args: PUBLIC_GIT_SHA=${{ github.sha }}`
so the bundler can substitute it at build time. The default
`verify-pattern` is the first 8 chars of the commit SHA, which a `grep -F`
will find inside the meta tag's content attribute.

### Pattern B: dedicated `/_meta.json` endpoint

If the site is dynamic or you don't want SHAs in HTML, serve a small
JSON file:

```json
{"git_sha": "abc12345...", "built_at": "2026-04-27T13:24:51Z"}
```

Caller workflow:

```yaml
verify-url: https://example-com.stage.denfrievilje.dk/_meta.json
```

### Pattern C: Caddy response header

If you don't want any change to the application code, have Caddy stamp a
header from an env var (which the compose file passes from the build arg):

```caddyfile
header X-Build-SHA {$PUBLIC_GIT_SHA}
```

Caller workflow:

```yaml
verify-url: https://example-com.stage.denfrievilje.dk/
verify-pattern: ${{ github.sha }}   # full SHA — grep'd against -i headers
```

(Caveat: `curl` doesn't include response headers in the body by default.
Use `curl -i` patterns or switch to one of the body-based options above.
Pattern A or B is recommended for simplicity.)

### Failure mode

If the verify step times out (default 20 min), the workflow fails with a
clear error pointing at the likely causes. Common reasons:

- **Agent isn't running** — check DSM Task Scheduler.
- **Cosign verification failed** — check NAS logs with
  `sudo tail -f /var/log/messages | grep nas-sites-deploy`.
- **Agent ran but didn't redeploy** — confirm the image tag actually
  changed (check `docker compose -p <project> images`). The agent
  intentionally no-ops on unchanged digests.
- **Site doesn't expose `verify-pattern`** — grep the live response by
  hand to confirm.

## Image references in compose files: tag vs. digest

The agent accepts both forms. The choice is per-(site, env) and lives in
the site repo's compose file.

### Rolling tag — fast iteration, small TOCTOU window

```yaml
services:
  site:
    image: ghcr.io/den-frie-vilje/example-site:staging-latest
```

CI rebuilds, pushes, signs. The tag moves to the new digest. The agent's
next fire pulls the moving tag, cosign-verifies whatever the tag now
points at, and deploys.

- **Latency**: deploy lands within one agent fire (≤ 5 min default).
- **Risk**: there is a brief window — milliseconds, in practice — between
  the agent's `cosign verify` (which resolves the tag → digest at
  verification time) and `docker compose pull` (which resolves it again).
  An attacker with GHCR write access could in theory move the tag in
  that window. The cosign identity check still applies to whatever
  `docker compose pull` ends up resolving, so the attacker would also
  need to produce a valid signature for the substituted digest.
- **Right for**: staging, internal tools, any site where deploy latency
  matters more than end-to-end reproducibility.

### Pinned digest — strict, PR-driven

```yaml
services:
  site:
    image: ghcr.io/den-frie-vilje/example-site@sha256:0123456789abcdef…
```

The compose file names the exact bytes to deploy. Updates require a PR
that changes the digest line. The agent's `cosign verify` and
`docker compose pull` both resolve to the literal digest — no TOCTOU
window at all.

- **Latency**: same as a normal merge cycle. CI builds + signs the new
  image; a PR updates the compose file's digest; merge; agent picks up
  the change on its next fire.
- **Win**: every deployed digest is auditable in `git log compose.production.yml`
  and was reviewed before landing. Re-running an arbitrarily old deploy
  is `git checkout <commit> -- compose.production.yml`.
- **Right for**: production. Especially worth it for sites where the
  threat model includes "GHCR credential compromise" as a real concern.

### How to discover the digest after a build

The `build-and-sign.yml` workflow's job summary prints the digest of
every push:

```
- Image tag (immutable): staging-2026-04-27T10-14-22Z-abc12345
- Image tag (moving): staging-latest
- Digest: sha256:0123456789abcdef…
```

For a PR-driven digest bump:

```sh
# In the site repo, after a CI run for the new build:
gh run view <run-id> --log | grep '^- Digest:'
# Or pull the digest from the registry directly:
docker manifest inspect ghcr.io/den-frie-vilje/<site>:production-latest \
    | jq -r '.config.digest'
```

Then edit `deploy/compose.production.yml`, commit, open a PR. The PR
diff is exactly the digest change, which is the artifact your reviewer
approves.

### Roadmap: auto-PR for production digest bumps

Manual PR-per-deploy is fine for low-frequency production releases. If
the cadence picks up, a follow-up reusable workflow can do this
automatically: after `build-and-sign.yml` succeeds on `main`, open a PR
against `compose.production.yml` updating the digest. The PR still
requires review (per branch protection), so the operator is still in the
loop — they just don't have to type the digest by hand.

This is currently **not implemented** — listed in the repo README's
roadmap. Open if/when it's wanted.

## Synology / DSM constraints encoded in the agent

These are Synology-specific facts the agent works around — listed here so
nothing surprises an operator who hasn't read the script.

- **bash 4.4, not 5.x**. DSM 7.2.x ships `bash 4.4.23(1)-release`. No
  bash-5 features (`wait -n -p`, `readarray -d`, `${var@Q}`).
- **`/bin/sh` is ash, not bash.** The agent uses `#!/bin/bash` and the
  Task Scheduler command line invokes `/bin/bash <path>` explicitly to
  avoid accidental ash interpretation.
- **DSM Task Scheduler env is minimal.** `PATH=/usr/bin:/bin`,
  `~/.bashrc` not sourced, `$HOME` may be unset. The agent sets `PATH`,
  `LC_ALL=C`, and `HOME` explicitly at the top.
- **BusyBox `flock` has no `-w SECONDS`.** The per-site lock loop polls
  with `flock -n` + `sleep 1` instead.
- **`docker compose` v2 vs `docker-compose` v1** — Container Manager
  versions vary across DSM 7.2 sub-releases. The agent probes at startup
  and uses whichever works.
- **Task Scheduler "Every N minutes" defaults `Last run` to +1 hour.**
  Documented in the schedule step above. If the agent stops firing after
  an hour, this is why.
- **`/etc/crontab` edits are overwritten** by Task Scheduler. Don't add
  cron entries by hand on DSM.
- **Custom systemd units in `/etc/systemd/system/` are not preserved**
  across DSM updates. Hence Task Scheduler is recommended.

## Troubleshooting

### "signature verification FAILED"

Cosign refused to validate one or more images. Possible causes:

- **The signature artifact is private on GHCR** — the most common
  cause on first deploy of a new image. `cosign verify` reports
  "no signatures found" because the anonymous fetch of the
  `sha256-<digest>.sig` tag returns HTTP 401. Fix: make the package
  public per [§7](#7-make-ghcr-signature-artifacts-public-per-image-one-time)
  of the bootstrap. Diagnose with:
  ```sh
  curl -sSI 'https://ghcr.io/v2/den-frie-vilje/<image>/manifests/sha256-<digest>.sig'
  # 401 → package is private; 404 → never pushed; 200 → readable
  ```
- The image was never signed (CI ran a workflow other than
  `build-and-sign.yml`). Confirm the site's caller workflow points at
  `build-and-sign.yml` and re-trigger a build.
- The signing identity regex doesn't match. The agent expects
  `^https://github\.com/den-frie-vilje/[^/]+/\.github/workflows/build-and-sign\.yml@refs/heads/(main|staging)$`.
  If you renamed the workflow or the org, update both ends.
- Sigstore Fulcio/Rekor is having an outage. Verify with
  `curl -fSs https://fulcio.sigstore.dev/api/v2/configuration` and
  `curl -fSs https://rekor.sigstore.dev/api/v1/log`. If Sigstore is down,
  the agent fails closed — by design, no deploys until it's back.

### "could not acquire lock within 60s"

Another `deploy-agent.sh` invocation is mid-deploy for that site. Usually
benign on a busy fire. Check with:

```sh
ls -la /run/lock/nas-sites-deploy/
ps -ef | grep deploy-agent
```

### Agent runs but nothing happens

The agent only deploys when image digests change OR no container is
running. To force a redeploy:

```sh
sudo docker compose -p <project> -f <compose-file> down
sudo /volume1/docker/nas-sites/deploy-agent.sh <domain> <env>
```

### Where are the logs?

- DSM Task Scheduler: `/volume1/docker/nas-sites/state/runs/<task>/<ts>/stdout`
  if "Output result to a folder" is enabled.
- syslog (always): `sudo tail -f /var/log/messages | grep nas-sites-deploy`,
  or via DSM Log Center.
- systemd: `journalctl -u nas-sites-deploy.service -n 200`.

## Security model

### What the design defends against

| Capability | Requires |
|---|---|
| Deploy code to the NAS | An image cosign-signed by `build-and-sign.yml@refs/heads/(main\|staging)` of a `den-frie-vilje/*` repo, AND a commit on the watched branch of the site repo, AND the agent's next fire to land. |
| Modify what the agent does (e.g. disable the cosign step) | Operator sudo to overwrite `/volume1/docker/nas-sites/deploy-agent.sh`. The agent itself never reads from a git clone at runtime. |
| Trigger an out-of-band deploy | Shell access on the NAS as `deploy` or `root`. There is no remote trigger. |
| Deploy a forged image (no valid signature) | Either a cosign signing key (none exists in keyless mode) or CI control on a permitted branch matching the identity regex. Branch protection + signed commits on the site repo close this further. |

The agent fires from DSM Task Scheduler, runs as `deploy`, and verifies
every image with cosign before invoking `docker compose`. A failure to
verify aborts the deploy for that site without pulling unverified bytes
onto the host.

### What "running as deploy" does and doesn't buy

The agent runs as the `deploy` user, not root. This is **defense in depth,
not blast-radius reduction**. Be honest about both halves:

**What it does NOT fix.** `deploy` is in the `docker` group so it can
reach `/var/run/docker.sock`, and **docker-socket access is functionally
root-equivalent**: anyone with write access to that socket can
`docker run --privileged -v /:/host alpine chroot /host sh` and become
host root in one command. So an attacker who achieves arbitrary code
execution as `deploy` (e.g. by exploiting a bug in the agent) gets root
trivially.

**What it does fix.** Several real things:

1. **Bugs that don't reach docker are bounded by `deploy`'s file
   permissions.** A `rm -rf $UNSET_VAR/` or a command-injection bug that
   doesn't shell out to docker damages only what `deploy` can write —
   not `/etc/`, not other users' home dirs, not the rootfs.
2. **The agent script itself cannot be tampered with by `deploy`.**
   `deploy-agent.sh` is `root:root 0755` — `deploy` reads + executes,
   cannot overwrite. Updating the agent requires operator sudo. A
   compromised `deploy` shell (e.g. via a malicious `image:` reference
   surviving cosign somehow, or an unrelated Container Manager
   vulnerability that pivots into the deploy process) cannot replace
   the agent and persist.
3. **Site configs cannot be rewritten by `deploy`.** `sites.d/*.env` and
   per-stack `<env>.env` are `root:docker 0640` — readable by the agent,
   not writable. Secrets cannot be exfiltrated by tampering with the
   files (they can still be read by `deploy` — that's the threat model
   for "agent compromise = secrets gone," same as any agent design).
4. **Audit visibility.** `ps`, `journalctl`, Task Scheduler email,
   `/var/log/messages` all attribute the agent to `deploy`. Any
   root-owned process becomes a louder signal in routine inspection.

### Residual risks the operator should track

- **Docker socket = root.** Stated above; restated because it's the
  central caveat. The boundary between "can trigger deploys" and "can
  do anything as root" is one `docker run`. Hardening this further
  requires either (a) replacing docker.sock with a per-verb proxy (e.g.
  Tecnativa docker-socket-proxy in front of the daemon, with a fixed
  allowlist of compose-needed verbs), or (b) running the deploy agent
  fully outside docker (host systemd unit calling `/usr/bin/docker`
  through a sudoers entry). Both are larger changes worth considering
  if the threat model expands.
- **Cosign keyless trusts the GitHub OIDC chain.** A compromise of
  GitHub Actions' OIDC issuer or Sigstore Fulcio would let an attacker
  mint a valid signature. Both are widely-trusted public infrastructure,
  but they are external trust dependencies of this design.
- **Boot-up window.** Container Manager resets the docker socket's group
  ownership on boot or package restart. The boot-up Task Scheduler task
  re-applies it, but there is a brief (~30 s) window where the agent
  fails closed. That is a hard fail rather than an unsafe fall-through —
  agent fires during the window error out and retry next interval.
- **For production, prefer pinning images to digests** (`@sha256:…`) in
  `compose.production.yml` and updating via PR. This eliminates the
  TOCTOU window between cosign verifying a tag and `docker compose pull`
  resolving it. The agent supports both forms; the policy is per-site.
- **The DSM admin account** is outside this threat model. Anyone with
  DSM admin can replace the agent script, edit Task Scheduler, install
  packages, etc. The CD pipeline cannot be more secure than DSM's own
  admin boundary.
