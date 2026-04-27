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

heading "Install local-synowebapi acme.sh deploy hook"

ACME_HOME="${ACME_HOME:-/usr/local/share/acme.sh}"
if [ ! -d "$ACME_HOME" ]; then
    # Fall back to the operator's $HOME/.acme.sh (acme.sh's default).
    ACME_HOME=$(ask "acme.sh home dir" "$HOME/.acme.sh")
fi

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
local one, edit ~/.acme.sh/<cert>/<cert>.conf (or run acme.sh --deploy
once with the new hook), then remove the credentials from acme.sh's
account.conf:

  acme.sh --deploy -d <domain> --deploy-hook synology_dsm_local

Then in account.conf, you can safely delete:
  SAVED_SYNO_Username=...
  SAVED_SYNO_Password=...
  SAVED_SYNO_DeviceID=... (if present from the 2FA dance)
  SAVED_SYNO_OTPCode=...

Optional env vars for the new hook (all optional):
  SYNO_Certificate=<friendly-name>   # bind to a specific cert slot by name
  SYNO_Create=1                      # allow creating a new slot if missing
  SYNO_Default=1                     # mark the imported cert as default

Run a renewal end-to-end as a smoke test before relying on this in
production:
  acme.sh --renew -d <domain> --force

If the import succeeds, DSM Control Panel → Security → Certificate will
show the new "valid from / to" dates within seconds.

EOF
