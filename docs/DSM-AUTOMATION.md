# DSM automation boundaries

Which DSM operations this repository scripts through Synology's CLI
surfaces (`synowebapi`, `synogroup`, `synow3tool`, ...) and which stay in
the GUI. The rule: script an operation only where the mechanism is
dependable across DSM versions and the win is recurring; one-time setup
steps stay as documented GUI walkthroughs.

## Scripted

| Operation | Mechanism | Where |
|---|---|---|
| Certificate deployment (list, create, replace, nginx reload) | `synowebapi`, cert-store files, `synow3tool` | [`tools/syno-acme-local-hook/`](../tools/syno-acme-local-hook/) — see its README for the DSM constraints that shape it |
| Add a user to a group | `synogroup --member` (documented in Synology's Administration CLI Guide) | bootstrap scripts in [`tools/`](../tools/) |
| Docker socket GID | `stat -c %g /var/run/docker.sock` | deploy agent and bootstrap scripts |
| DSM version | `cat /etc.defaults/VERSION` | `tools/lib/common.sh` |

## GUI only

| Operation | Reason |
|---|---|
| Scheduled Tasks | `SYNO.Core.TaskScheduler` payload is community-derived and undocumented; a one-time GUI click suffices at current NAS count. |
| Boot-triggered tasks | `SYNO.Core.EventScheduler` create payload is poorly understood; the GUI entry persists across DSM updates. |
| Web Station vhosts | No candidate API works cleanly, and DSM 7.2 and 7.3 both changed vhost handling. If GUI clicks stop scaling, replace Web Station with a containerised reverse proxy rather than scripting it. |
| Firewall rules | Rules do not survive DSM updates regardless of how they are created. |

GUI walkthroughs for the one-time steps live in
[NAS-BOOTSTRAP.md](NAS-BOOTSTRAP.md) and
[PULL-DEPLOY-MODEL.md](PULL-DEPLOY-MODEL.md).
