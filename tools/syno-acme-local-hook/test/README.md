# Test rig for the local DSM deploy hook

DSM itself cannot run in CI (Synology's virtual DSM requires KVM), so
this rig tests `synology_dsm_local.sh` against the real acme.sh renewal
machinery end to end, with only the DSM side replaced by mocks.

What runs where:

- **acme.sh**: real, cloned from upstream. Issuance, deploy-conf
  persistence, and the `--cron` renewal path are the genuine article.
- **ACME CA**: [Pebble](https://github.com/letsencrypt/pebble),
  Let's Encrypt's test server, issuing a real wildcard certificate via
  dns-01 against `pebble-challtestsrv`.
- **DSM**: `mock-synowebapi` as `/usr/syno/bin/synowebapi`, a fake
  cert-store tree under `/usr/syno/etc/certificate` and
  `/usr/local/etc/certificate`, and a logging `synow3tool` stub. The
  mocks reproduce the DSM 7.2.2 constraints listed in
  [the hook README](../README.md):
  import with `id=` always fails, created slots materialise as
  `_archive/<id>/` PEM directories, and list output prints keys
  alphabetically.

The scenario: issue a wildcard-primary cert (so every acme.sh path
contains a literal `*`), deploy once with `SYNO_*` env vars set, bind
the slot into service directories in both certificate trees, plant a
decoy certificate with its own service directory, then renew via
`--cron` in a clean environment the way DSM Task Scheduler does. The
rig passes only if the bound slot and its service copies end up serving
the renewed certificate, nginx is reloaded and never restarted, the
decoy is untouched, and no orphan slots exist.

## Running

Root in a disposable container (it writes under `/usr/syno` and
`/usr/local/etc`):

```sh
sudo tools/syno-acme-local-hook/test/run-harness.sh [path-to-hook-file]
```

First run fetches acme.sh and Pebble into `test/work/` (gitignored).
Exit 0: pass. Exit 1: the renewal left the bound slot stale. Exit 2:
the rig itself broke before the interesting part.

## Files

- `run-harness.sh`: the scenario, start to verdict.
- `mock-synowebapi`: the DSM cert-store mock (python3).
- `dns_cts.sh`: acme.sh dnsapi hook answering Pebble's dns-01
  challenges via pebble-challtestsrv's management API. Test rig only;
  never install on a NAS.
