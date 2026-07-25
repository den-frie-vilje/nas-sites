# Test rig for the local DSM deploy hook

There is no practical way to run DSM itself in CI (Synology's virtual DSM
requires KVM), so this rig tests `synology_dsm_local.sh` against the next
best thing: the real acme.sh renewal machinery end to end, with only the
DSM binary replaced by a faithful mock.

What runs where:

- **acme.sh** — real, cloned from upstream. Issuance, deploy-conf
  persistence, and the `--cron` renewal path are the genuine article.
- **ACME CA** — [Pebble](https://github.com/letsencrypt/pebble),
  Let's Encrypt's own test server, issuing a real wildcard certificate
  via dns-01 against `pebble-challtestsrv`.
- **DSM** — `mock-synowebapi`, installed as `/usr/syno/bin/synowebapi`.
  It reproduces the two cert-store behaviours the hook depends on:
  import with `id=` replaces a slot in place keeping service bindings,
  import without `id=` creates a new unbound slot; and `list` prints
  object keys alphabetically, so `desc` precedes `id`.

The scenario is the July 2026 production incident: deploy once with
`SYNO_*` env vars set, bind services to the slot, then renew from a clean
environment the way DSM Task Scheduler does. The rig fails unless the
bound slot ends up serving the renewed certificate with no orphan slots.

## Running

Root in a disposable container (it writes `/usr/syno/bin/synowebapi`):

```sh
sudo tools/syno-acme-local-hook/test/run-harness.sh
```

First run fetches acme.sh and Pebble into `test/work/` (gitignored).
Exit 0 means pass; 1 means the renewal stranded the cert; 2 means the
rig itself broke before the interesting part.

## Files

- `run-harness.sh` — the scenario, start to verdict.
- `mock-synowebapi` — the DSM cert-store mock (python3).
- `dns_cts.sh` — acme.sh dnsapi hook that answers Pebble's dns-01
  challenges via pebble-challtestsrv's management API. Test rig only;
  never install this on a NAS.
