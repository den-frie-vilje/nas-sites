# syno-acme-local-hook

An acme.sh deploy hook that installs renewed certificates into the DSM
cert store entirely locally, as root. It has the same contract as the
stock `synology_dsm` hook (`--deploy-hook synology_dsm_local`) but
stores no DSM credential: the stock hook's `SAVED_SYNO_Username`,
`SAVED_SYNO_Password`, `SAVED_SYNO_DeviceID`, and `SAVED_SYNO_OTPCode`
entries in `account.conf` are not needed and can be deleted.

## DSM constraints

Verified on DSM 7.2.2; the hook's design follows from them.

| Operation | Mechanism | Status |
|---|---|---|
| List certificates | `synowebapi --exec-fastwebapi api=SYNO.Core.Certificate.CRT method=list` | Works. Undocumented. JSON keys print alphabetically; `desc` precedes `id`. |
| Create a certificate slot | `synowebapi --exec-fastwebapi api=SYNO.Core.Certificate method=import` without `id` | Works with local file paths and RSA, SEC1 EC, or PKCS#8 EC keys. Undocumented. |
| Replace a certificate slot | the same call with `id=` | **Broken.** Always returns error 5511 through `--exec-fastwebapi`, whatever the files. Works only through the HTTP upload flow. |
| Reload nginx after a cert change | `synow3tool --gen-all` then `synow3tool --nginx=reload` | Works; creates no systemd jobs. This is DSM's own `ExecReload` for the nginx unit. Never restart the nginx unit: a unit restart cascades into package start/stop jobs and can deadlock the package system. |

Error codes for `SYNO.Core.Certificate` import, per the zaxbux/syno-acme
error map: 5510 illegal certificate file, 5511 illegal key file, 5512
illegal intermediate file. The 5511 returned by replace-by-id is a
misnomer; the failure is the code path, not the key.

## Behaviour

`synology_dsm_local.sh`:

- `SYNO_Certificate` (required) names the DSM cert slot, matching the
  friendly name in DSM Control Panel → Security → Certificate. The hook
  persists it, with `SYNO_Create` and `SYNO_Default`, in the cert's
  deploy conf via `_savedeployconf`, so scheduled renewals run with no
  environment. An empty name is an error: importing without a name would
  create a new unbound slot on every renewal.
- The key, cert, chain, and fullchain PEMs are staged under plain names
  in a `mktemp -d` directory next to the acme.sh home. Wildcard-primary
  certs have a literal `*` in every acme.sh path, which is unsafe to
  hand to DSM tooling, and synowebapi cannot see the calling shell's
  `/tmp`.
- If the named slot does not exist and `SYNO_Create=1`, the slot is
  created through synowebapi.
- If the named slot exists, its files are replaced in place: the four
  PEMs in `/usr/syno/etc/certificate/_archive/<id>/`, plus every service
  directory holding a copy of the same certificate, matched by SHA-256
  fingerprint under `/usr/syno/etc/certificate` and
  `/usr/local/etc/certificate` (system default, reverse proxies, Web
  Station vhosts). Only directories holding the replaced certificate are
  touched; other slots and the `_archive/INFO` bindings file are not.
  All touched files are backed up first and restored on failure.
- nginx is then reloaded with `synow3tool --gen-all` and
  `synow3tool --nginx=reload`. The nginx unit is never restarted.
- The hook refuses to run as non-root and prints the correct root-shell
  invocation.

`install.sh`: interactive installer. Detects the acme.sh home
(`/volume1/homes/admin/.acme.sh`, then `/usr/local/share/acme.sh`, then
asks), shows the diff against any installed hook, copies the hook into
`<acme-home>/deploy/`, and prints the switch-over commands with real
paths.

`test/`: DSM-free end-to-end rig. See [test/README.md](test/README.md).

## Operating it

On our NASes acme.sh lives in the admin user's DSM home:
`/volume1/homes/admin/.acme.sh`. The hook needs root, acme.sh refuses
plain `sudo`, and a root shell's default acme.sh home is
`/root/.acme.sh`, so every acme.sh command runs inside `sudo su` with
`--home` passed explicitly. Once root has run acme.sh against this home,
some files in it are root-owned; manual acme.sh runs must be from a root
shell from then on.

```sh
ACME_HOME=/volume1/homes/admin/.acme.sh
```

1. Install the hook (once per NAS, and after every hook change):

   ```sh
   sudo /volume1/docker/nas-sites/repo/tools/syno-acme-local-hook/install.sh
   ```

2. Bind each cert to its DSM slot with one explicit deploy. Add `--ecc`
   for ECC certs; quote the domain, wildcards glob:

   ```sh
   SYNO_Certificate='<friendly-name-in-DSM-GUI>' \
   $ACME_HOME/acme.sh --home $ACME_HOME \
     --deploy -d '<domain>' --ecc --deploy-hook synology_dsm_local
   ```

   DSM Control Panel → Security → Certificate shows the new "Valid
   from / to" within seconds.

3. Remove the stock hook's credentials from `$ACME_HOME/account.conf`:

   ```sh
   sed -i '/^SAVED_SYNO_/d' $ACME_HOME/account.conf
   ```

   If `synouser --get sc-acmesh-tmp` reports a leftover temporary admin
   user from the stock hook, delete it: `sudo synouser --del sc-acmesh-tmp`.

4. Task Scheduler entry for renewals: user-defined script, user **root**,
   daily, with abnormal-termination email enabled:

   ```sh
   /volume1/homes/admin/.acme.sh/acme.sh --cron --home /volume1/homes/admin/.acme.sh >> /volume1/homes/admin/.acme.sh/cron.log 2>&1
   ```

## Risks

- The list and create calls are undocumented. A future DSM release can
  change them; the hook fails loudly (non-zero exit, acme.sh reports a
  failed deploy) rather than leaving a stale cert silently.
- The replacement path depends on the DSM cert-store layout
  (`_archive/<id>/`, per-service PEM copies). A future DSM release can
  change it; the fingerprint verification fails loudly in that case.
- Deploy success is not serving success. Monitor certificate expiry on
  the served endpoints independently of acme.sh's exit status.
- The hook runs as root from the acme.sh cron job and does no extra
  sandboxing. A compromised acme.sh is root either way; the hook adds no
  new surface.
