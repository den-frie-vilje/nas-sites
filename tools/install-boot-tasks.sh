#!/bin/bash
# Persist the docker.sock group ownership across reboots and Container
# Manager restarts.
#
# This script does NOT use synowebapi to create the Triggered Task — the
# undocumented EventScheduler create payload is brittle and drifts across
# DSM versions. Instead, it walks the operator through the DSM Task
# Scheduler GUI clicks (the only path Synology actually supports), and
# writes out the exact command to paste into the Run-command field.
#
# After the operator pastes the command, the task survives DSM updates
# (Task Scheduler entries are stored in a sqlite DB at
# /usr/syno/etc/esynoscheduler/synoscheduler.db that's preserved across
# upgrades).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_dsm
require_root
# This script only walks the operator through GUI clicks — no heavy
# tooling needed beyond bash builtins.

heading "Persist docker.sock group ownership across reboots"

cat <<EOF

Container Manager resets /var/run/docker.sock to root:root 660 on every
reboot and on every package restart. Without persistence, the deploy
agent fails closed every time the NAS boots until you re-apply ownership
by hand.

The fix is a DSM Task Scheduler "Triggered Task" with event=Boot-up that
re-applies the chown. Synology's APIs for creating this kind of task are
undocumented and unstable — the supported way is to add it via the GUI
once. This script gives you the exact paste-ready command.

EOF

confirm "Walk through the GUI steps?" || { echo "Aborted by operator."; exit 0; }

cat <<'EOF'

  ╭──────────────────────────────────────────────────────────────────╮
  │ 1.  Control Panel → Task Scheduler                               │
  │ 2.  Create → Triggered Task → User-defined script                │
  │ 3.  General tab                                                  │
  │       Task:    docker-socket-deploy-group                        │
  │       User:    root                                              │
  │       Event:   Boot-up                                           │
  │       Enabled: ☑                                                 │
  │ 4.  Task Settings tab                                            │
  │       Run command: (paste the line below, between the lines)     │
  ╰──────────────────────────────────────────────────────────────────╯

  ─────────────────────────────────────────────────────────────────
  chown root:docker /var/run/docker.sock && chmod 660 /var/run/docker.sock
  ─────────────────────────────────────────────────────────────────

  5.  Save.
  6.  (Optional, recommended) right-click the task → Run, and verify
      that 'sudo -u deploy docker info' still works.

EOF

if confirm "Open the Task Scheduler help URL in your default browser? (no on a headless ssh session)"; then
    # synowebapi can do this, but a plain link is more portable.
    echo "URL: https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler"
fi

echo
echo "Note: there is a brief window after boot (~30 s) where Container Manager"
echo "has started but this task hasn't fired yet. The agent fails closed during"
echo "that window — that's expected; the next 5-min agent fire after the boot"
echo "task lands will succeed."
