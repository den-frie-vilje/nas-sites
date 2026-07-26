# Synotools hardening

Synology DSM ships a few CLI surfaces — `synouser`, `synogroup`,
`synowebapi`, `synosetkeyvalue`, `synopkg`, `synowebapi --exec-fastwebapi`
— that can replace some operations otherwise done by clicking through the
DSM GUI or by calling DSM's HTTP API with admin credentials. This doc
records what was researched, what is worth replacing, and what is
deliberately left alone.

The single highest-value win is replacing `acme.sh`'s `synology_dsm` deploy
hook with a local `synowebapi` call. Implementation lives in
[`tools/syno-acme-local-hook/`](../tools/syno-acme-local-hook/).

## What was researched

| Operation | API | Documented? | Verdict |
|---|---|---|---|
| Import SSL cert into DSM cert store | `synowebapi --exec-fastwebapi api=SYNO.Core.Certificate method=import` | No, but battle-tested by zaxbux/syno-acme + acme.sh upstream | **Replace.** Removes the on-disk DSM admin credential. |
| Create a Scheduled Task (deploy agent) | `synowebapi api=SYNO.Core.TaskScheduler method=create` | No (community-derived) | Skip for now. Worth doing later if multi-NAS bootstrap matters; one-time GUI click is good enough for one or two NASes. |
| Create a Triggered Task on Boot-up | `synowebapi api=SYNO.Core.EventScheduler` | No, and create-method payload is poorly understood | **Skip.** Use the GUI; the entry persists across DSM updates either way. |
| Create a DSM Web Station vhost | None of the candidate APIs work cleanly; mustache template hacks are fragile | No | **Skip — actively avoid.** DSM 7.2 broke vhost handling repeatedly; DSM 7.3 renamed the GUI surface. If we outgrow GUI clicks, replace Web Station with a containerized reverse proxy rather than scripting Web Station. |
| Add a DSM firewall rule | `synowebapi api=SYNO.Core.Security.Firewall.Profile` | No, and rules don't survive DSM updates anyway | **Skip.** Initial setup via GUI; long-term, build a "post-upgrade firewall reconciler" boot-triggered task. |
| Add a user to a group | `synogroup --member` | Yes (Synology DiskStation Administration CLI Guide) | Already in use. |
| Get the docker socket GID | `stat -c %g /var/run/docker.sock` | Standard | Already in use. |
| Get the DSM version | `cat /etc.defaults/VERSION` | Standard | Already in use. |

Sources for the research: zaxbux/syno-acme reference implementation, the
n4s4/synology-api Python wrapper's namespace inventory, the SynoForum +
Synology Community discussions on Web Station 7.2 vhost regressions and
DSM 7.3 firewall regressions, the upstream `acme.sh/deploy/synology_dsm.sh`
hook, and Synology's `DSM_Login_Web_API_Guide` PDF.

## What's actually implemented in this repo

### `tools/syno-acme-local-hook/synology_dsm_local.sh`

A drop-in replacement for acme.sh's `synology_dsm` deploy hook. Same
contract — same arguments, same `--deploy-hook synology_dsm_local`
invocation — but calls `/usr/syno/bin/synowebapi --exec-fastwebapi` as
root instead of POSTing to DSM's HTTPS endpoint with stored credentials.

What this removes from disk:

- `SAVED_SYNO_Username` in acme.sh's `account.conf`
- `SAVED_SYNO_Password` in `account.conf`
- `SAVED_SYNO_DeviceID` (set when the upstream hook does the 2FA
  device-trust dance)
- `SAVED_SYNO_OTPCode` (transient, but written to disk if the operator
  ever set it via env var)

In aggregate: a full DSM admin credential that, if leaked, gives full
control of the NAS. Net win.

### `tools/syno-acme-local-hook/install.sh`

Interactive installer. Detects acme.sh's home dir, shows the diff of any
existing hook, copies the hook into `<acme-home>/deploy/`, prints the
acme.sh command to switch existing certs over and the env vars cleanup
needed in `account.conf`.

## Migration steps

1. Bootstrap the new hook (once per NAS):

   ```sh
   sudo /volume1/docker/nas-sites/repo/tools/syno-acme-local-hook/install.sh
   ```

2. Switch each cert that currently uses `synology_dsm` to
   `synology_dsm_local`. acme.sh stores the deploy-hook name per cert in
   `~/.acme.sh/<domain>/<domain>.conf`:

   ```sh
   sed -i 's|^Le_DeployHook=.*|Le_DeployHook="synology_dsm_local"|' \
       ~/.acme.sh/<domain>/<domain>.conf
   ```

   Or run an explicit deploy with the new hook (which acme.sh saves):

   ```sh
   acme.sh --deploy -d <domain> --deploy-hook synology_dsm_local
   ```

3. Force a renewal as a smoke test BEFORE removing the old credentials:

   ```sh
   acme.sh --renew -d <domain> --force
   ```

   DSM Control Panel → Security → Certificate should show the updated
   "Valid from / to" within seconds.

4. Once the smoke test passes, remove the credentials from
   `~/.acme.sh/account.conf`:

   ```sh
   sed -i '/^SAVED_SYNO_/d' ~/.acme.sh/account.conf
   ```

5. (Optional) clean up the temporary admin user the upstream hook may
   have left behind. If `synouser --get sc-acmesh-tmp` returns non-zero,
   nothing to do; otherwise:

   ```sh
   sudo synouser --del sc-acmesh-tmp
   ```

## Incident: renewals stranded in an orphan cert slot (July 2026)

The first scheduled renewal after migrating to this hook left the NAS
serving an expired wildcard certificate, even though acme.sh renewed on
schedule and reported success. Two independent bugs in the hook's first
version caused it, both reproduced and fixed via the test rig in
[`tools/syno-acme-local-hook/test/`](../tools/syno-acme-local-hook/test/):

1. **Deploy config was not persisted.** The hook read `SYNO_Certificate`
   straight from the environment, which only exists on the operator's
   initial `--deploy`. DSM Task Scheduler renewals run with a clean
   environment, so the hook imported with no slot name and no id; DSM
   filed the fresh cert in a new, unbound slot, and every service kept
   the old cert until it expired. The hook now round-trips its `SYNO_*`
   settings through acme.sh's `_savedeployconf`/`_getdeployconf`, requires
   `SYNO_Certificate` to be non-empty, and fails loudly otherwise.
2. **The id-by-name lookup assumed the wrong JSON key order.** synowebapi
   prints certificate objects with keys in alphabetical order, so `desc`
   precedes `id`; the original line-oriented awk paired each `desc` with
   the *previous* certificate's id and returned nothing for the first
   match. The lookup now splits per-object and matches the two fields in
   either order, and the hook re-lists after import to verify the name
   resolves to the slot it replaced, refusing to report success otherwise.

A third failure surfaced during recovery, on the first correctly-formed
import: DSM answered `{"error":{"code":5511}}`. On-NAS probing (four
self-contained imports from different locations and key formats) pinned
down two path rules in the DSM 7.2.2 import handler, each sufficient to
produce that error:

- `*_tmp` paths containing a literal `*` are rejected, and a wildcard
  cert whose primary name is the wildcard puts one in every acme.sh
  path (`.../*.example.com_ecc/*.example.com.key`);
- `*_tmp` paths under the calling shell's `/tmp` are rejected — the
  handler evidently runs with a private `/tmp` namespace, so files
  staged there are invisible to it, and the failed open surfaces as
  "illegal key file".

Key format is not a factor: RSA, SEC1 EC, and PKCS#8 EC keys all import
fine from a plain-named path under the acme.sh home. Over HTTP the
handler only ever sees uploaded temp files with tame names in its own
namespace, which is why the same PEM content imports fine through the
GUI. The hook now stages key, cert, and chain under plain names into a
`mktemp -d` directory next to the acme.sh home (the parent of the
cert's own directory) before calling the import, and removes it as soon
as synowebapi returns. Error codes, per the zaxbux/syno-acme reference:
5510 illegal certificate file, 5511 illegal key file, 5512 illegal
intermediate file.

Lesson recorded here because it generalises: an acme.sh deploy hook's
environment variables are gone by the time cron renews; any hook that
needs configuration must persist it with `_savedeployconf` or it will
only ever work on the day it was installed. And when bypassing a DSM
HTTP surface to call the underlying API directly, reproduce what the
HTTP layer would have done to the inputs (here: plain-named temp
files), not just the parameters it would have passed.

## Risks introduced

- The cert-import API is undocumented. If a future DSM major release
  changes the parameter names, the hook will fail loudly (`synowebapi`
  returns a JSON error and the hook exits non-zero, which acme.sh treats
  as a failed deploy). Detection is "next renewal fails" — set up
  monitoring for cert expiry independently, not just deploy success.
- The hook runs as root via the acme.sh cron job. If acme.sh itself is
  compromised, the attacker gets root regardless of which hook is in use,
  so this isn't a new attack surface — but it is worth noting that the
  hook does no extra sandboxing.

## Why we didn't do more

Per the audit summary, every API in `synowebapi` beyond cert import is
either undocumented enough to be brittle (TaskScheduler, EventScheduler),
known to be unstable across DSM versions (Web Station, Firewall), or
already covered by a stable supported tool (`synogroup`). The cost of
scripting them now is meaningfully higher than the cost of maintaining a
GUI walkthrough for the few one-time setup steps that need them.
