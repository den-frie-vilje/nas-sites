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

On our NASes, acme.sh lives in the admin user's DSM home:
`/volume1/homes/admin/.acme.sh`. The hook needs root, acme.sh refuses
plain `sudo`, and a root shell's default acme.sh home is `/root/.acme.sh`
— so every acme.sh command below runs inside `sudo su` and passes
`--home` explicitly. `install.sh` detects this location on its own.

```sh
ACME_HOME=/volume1/homes/admin/.acme.sh
```

1. Bootstrap the new hook (once per NAS):

   ```sh
   sudo /volume1/docker/nas-sites/repo/tools/syno-acme-local-hook/install.sh
   ```

2. Switch each cert that currently uses `synology_dsm` to
   `synology_dsm_local` with one explicit deploy (which acme.sh saves,
   along with the SYNO_* settings). From `sudo su`; add `--ecc` for ECC
   certs and quote the domain, wildcards glob:

   ```sh
   SYNO_Certificate='<friendly-name-in-DSM-GUI>' \
   $ACME_HOME/acme.sh --home $ACME_HOME \
     --deploy -d '<domain>' --ecc --deploy-hook synology_dsm_local
   ```

3. Force a renewal as a smoke test BEFORE removing the old credentials:

   ```sh
   $ACME_HOME/acme.sh --home $ACME_HOME --renew -d '<domain>' --ecc --force
   ```

   DSM Control Panel → Security → Certificate should show the updated
   "Valid from / to" within seconds. The Task Scheduler entry must run
   the same way: as root, with `--cron --home $ACME_HOME`.

4. Once the smoke test passes, remove the credentials from
   `$ACME_HOME/account.conf`:

   ```sh
   sed -i '/^SAVED_SYNO_/d' $ACME_HOME/account.conf
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

A third failure surfaced during recovery: every correctly-formed import
answered `{"error":{"code":5511}}`. Two path theories (a literal `*` in
the acme.sh file paths of a wildcard-primary cert; files staged under
the calling shell's `/tmp`) were each implemented and disproved — the
staged, plain-named, home-adjacent files failed identically. A
parameter bisect over eight on-NAS probe imports then isolated the real
trigger:

- creating a slot (import WITHOUT `id`) works from arbitrary local
  paths, with RSA, SEC1 EC, and PKCS#8 EC keys alike, even with `*` in
  the friendly name;
- replacing a slot (import WITH `id`) ALWAYS fails with 5511 on
  DSM 7.2.2 through `--exec-fastwebapi` — including against a freshly
  created, known-good slot with the very same files that created it.

The nominal meaning of 5511 ("illegal key file", per zaxbux/syno-acme's
error map, alongside 5510 illegal certificate and 5512 illegal
intermediate) is therefore misleading here; replace-by-id evidently
takes a different code path locally than through the HTTP upload flow,
where the same parameters work. zaxbux's replace-by-id was presumably
sound on the DSM version it targeted; it is not on 7.2.2.

The hook now splits by case. Slot creation still goes through
synowebapi (the path that provably works). Slot REPLACEMENT is done the
way the DSM community has long done it: overwrite the four PEMs in
`/usr/syno/etc/certificate/_archive/<id>/`, propagate to every service
directory holding a copy of the same certificate (matched by SHA-256
fingerprint under both `/usr/syno/etc/certificate` and
`/usr/local/etc/certificate`, which covers system default, reverse
proxies, and Web Station vhosts), regenerate the web config with
`synow3tool --gen-all`, and restart nginx with `synosystemctl`. All
touched files are backed up first and restored on any failure, and the
hook still stages the PEMs under plain names next to the acme.sh home
(wildcard-primary certs have `*` in every acme.sh path, which is unsafe
to hand to any tooling).

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
