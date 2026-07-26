#!/bin/bash
# Install the local-synowebapi acme.sh deploy hook into ~/.acme.sh/deploy/.
#
# What this script does, with confirmations:
#   1. Detect acme.sh's home directory (default ~/.acme.sh)
#   2. Show the diff between the installed hook (if any) and the upstream
#   3. Copy synology_dsm_local.sh into <acme-home>/deploy/
#   4. Print the next-steps acme.sh command to switch existing certs over

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

require_dsm
require_root
require_tools cmp diff cp chmod chown

heading "Install local-synowebapi acme.sh deploy hook"

# Detect the acme.sh home. This script runs as root, so $HOME/.acme.sh
# would resolve to /root/.acme.sh — almost never where acme.sh actually
# lives on a DSM box. Our convention installs it under the admin user's
# DSM home, so probe the likely locations in order and only ask when
# none of them exists.
if [ -z "${ACME_HOME:-}" ]; then
    for _candidate in \
        /volume1/homes/admin/.acme.sh \
        /usr/local/share/acme.sh; do
        if [ -d "$_candidate/deploy" ]; then
            ACME_HOME="$_candidate"
            break
        fi
    done
fi
if [ -z "${ACME_HOME:-}" ] || [ ! -d "$ACME_HOME" ]; then
    ACME_HOME=$(ask "acme.sh home dir" "/volume1/homes/admin/.acme.sh")
fi
echo "acme.sh home: $ACME_HOME"

if [ ! -d "$ACME_HOME/deploy" ]; then
    echo "ERROR: $ACME_HOME/deploy does not exist." >&2
    echo "       Either acme.sh isn't installed, or its home is somewhere else." >&2
    exit 1
fi

SRC="$SCRIPT_DIR/synology_dsm_local.sh"
DST="$ACME_HOME/deploy/synology_dsm_local.sh"

plan "install $SRC → $DST (root:root 0644)"
plan "leave the upstream synology_dsm.sh in place — both can coexist"

if [ -f "$DST" ]; then
    if cmp -s "$SRC" "$DST"; then
        echo "Already installed and up to date. Nothing to do."
        exit 0
    fi
    echo "Diff (installed vs. new):"
    diff -u "$DST" "$SRC" || true
fi

confirm "Install?" || { echo "Aborted by operator."; exit 0; }

install_file 0644 root root "$SRC" "$DST"

cat <<EOF

Installed.

To switch an existing cert from the credentialed synology_dsm hook to the
local one, run an explicit deploy once with the new hook. SYNO_Certificate
is REQUIRED: it names the DSM cert slot the renewals will keep replacing
(the "friendly name" shown in DSM Control Panel -> Security -> Certificate).
The hook saves it in the cert's deploy conf, so scheduled renewals reuse
it without any environment set up.

The hook needs root, acme.sh refuses plain sudo, and root's default
acme.sh home is /root/.acme.sh — so always run from a root shell (sudo su)
and pass --home. With this install's detected home, the command is:

  SYNO_Certificate='<friendly-name>' \\
  $ACME_HOME/acme.sh --home $ACME_HOME \\
    --deploy -d '<domain>' --ecc --deploy-hook synology_dsm_local

(drop --ecc for an RSA cert; quote the domain — wildcards glob)

Further env vars (persisted the same way):
  SYNO_Create=1                      # allow creating a new slot if missing
  SYNO_Default=1                     # mark a newly created slot as default

Then in $ACME_HOME/account.conf, you can safely delete:
  SAVED_SYNO_Username=...
  SAVED_SYNO_Password=...
  SAVED_SYNO_DeviceID=... (if present from the 2FA dance)
  SAVED_SYNO_OTPCode=...

The DSM Task Scheduler entry that runs the renewal must run as root and
pass the same home, e.g.:
  $ACME_HOME/acme.sh --cron --home $ACME_HOME

Run a renewal end-to-end as a smoke test before relying on this in
production:
  $ACME_HOME/acme.sh --home $ACME_HOME --renew -d '<domain>' --ecc --force

If the deploy succeeds, DSM Control Panel → Security → Certificate will
show the new "valid from / to" dates within seconds.

EOF
