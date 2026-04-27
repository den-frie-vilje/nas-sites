#!/bin/bash
# One-time setup of the deploy user, docker group membership, and
# /var/run/docker.sock group ownership for the pull-only agent on a fresh
# Synology DSM NAS.
#
# Idempotent: safe to re-run if you're not sure whether earlier steps landed.
# Each mutating step asks for explicit confirmation.
#
# What this script does:
#   1. Create the `deploy` user with locked password (interactive login off)
#   2. Create the `docker` group (Container Manager may have done this)
#   3. Add `deploy` to the `docker` group (re-applying every existing member
#      because synogroup --member REPLACES the member list, it does not
#      append — this is a Synology gotcha)
#   4. chown root:docker + chmod 660 on /var/run/docker.sock so `deploy` can
#      reach it (Container Manager resets this on every restart — see
#      tools/install-boot-tasks.sh for the persistent fix)
#   5. Verify deploy can `docker info`

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_dsm
require_root

heading "Bootstrap: deploy user + docker group + socket permissions"
plan "create user 'deploy' (locked password)"
plan "create group 'docker' if absent"
plan "set 'docker' group members to {existing members + deploy}"
plan "chown root:docker /var/run/docker.sock; chmod 660"
plan "verify 'sudo -u deploy docker info' works"

confirm "Proceed?" || { echo "Aborted by operator."; exit 0; }

# ─── 1. deploy user ────────────────────────────────────────────────────────
heading "1/5 deploy user"
if synouser --get deploy > /dev/null 2>&1; then
    echo "User 'deploy' already exists; skipping create."
else
    # synouser --add <name> <password> <fullname> <expired> <email> <flag>
    # password "" means "set later"; we lock it immediately below.
    run synouser --add deploy "" "nas-sites deploy agent" 0 "" 0
fi
# Lock interactive login regardless of how the user was created. This must
# be the literal '!' character — it's what Linux uses to mark a password
# field as unusable.
run synouser --setpw deploy '!'

# ─── 2. docker group ───────────────────────────────────────────────────────
heading "2/5 docker group"
if synogroup --get docker > /dev/null 2>&1; then
    echo "Group 'docker' already exists; skipping create."
else
    run synogroup --add docker
fi

# ─── 3. add deploy to docker group ─────────────────────────────────────────
heading "3/5 docker group membership"
# GOTCHA: synogroup --member <group> <users…> REPLACES the member list with
# the supplied users. To add 'deploy' without dropping existing members, we
# enumerate the current members from /etc/group and append.
existing_members=$(getent group docker | awk -F: '{print $4}' | tr ',' ' ')
new_members=$(printf '%s deploy\n' "$existing_members" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
echo "Current members of 'docker': ${existing_members:-<none>}"
echo "After this step:             $new_members"
if confirm "Apply (this REPLACES the docker group member list)?"; then
    # shellcheck disable=SC2086  # intentional word-splitting of $new_members
    run synogroup --member docker $new_members
else
    echo "Skipped membership change."
fi

# ─── 4. socket ownership ───────────────────────────────────────────────────
heading "4/5 docker.sock group ownership"
if [ ! -S /var/run/docker.sock ]; then
    echo "WARN: /var/run/docker.sock not present. Container Manager not running?"
    echo "      Start Container Manager from DSM Package Center, then re-run this script."
    exit 1
fi
run chown root:docker /var/run/docker.sock
run chmod 660 /var/run/docker.sock
echo
echo "NOTE: Container Manager resets these on every restart and on every reboot."
echo "      Run tools/install-boot-tasks.sh to persist this via a Triggered Task."

# ─── 5. verify ─────────────────────────────────────────────────────────────
heading "5/5 verify deploy can reach docker"
if sudo -u deploy docker info > /dev/null 2>&1; then
    echo "OK — 'sudo -u deploy docker info' succeeded."
else
    echo "FAIL — 'sudo -u deploy docker info' did not succeed."
    echo "       Check group membership took effect (deploy may need to log out/in)."
    exit 1
fi

echo
echo "Bootstrap complete. Next steps:"
echo "  sudo $SCRIPT_DIR/install-boot-tasks.sh   # persist socket chown across reboots"
echo "  sudo $SCRIPT_DIR/bootstrap-site.sh       # add the first site"
