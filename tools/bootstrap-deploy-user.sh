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
require_tools awk tr sort grep synouser synogroup chown chmod

heading "Bootstrap: deploy user + docker group + socket permissions"
plan "create user 'deploy' (locked password)"
plan "create group 'docker' if absent"
plan "set 'docker' group members to {existing members + deploy}"
plan "chown root:docker /var/run/docker.sock; chmod 660"
plan "verify 'sudo -u deploy docker info' works"

confirm "Proceed?" || { echo "Aborted by operator."; exit 0; }

# Helper: add USER to GROUP without dropping existing members.
# `synogroup --member` REPLACES the list; we read existing members from
# /etc/group, union with the new user, then re-apply the full set.
# `getent` would be the obvious tool — but it's glibc-only and absent on
# DSM (BusyBox has no getent applet). awk on /etc/group works on every
# version of DSM.
add_user_to_group() {
    local user="$1" group="$2"
    local existing new
    existing=$(awk -F: -v g="$group" '$1 == g {print $4}' /etc/group | tr ',' ' ')
    new=$(printf '%s %s\n' "$existing" "$user" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    echo "  $group members were: ${existing:-<none>}"
    echo "  $group members will be: $new"
    # shellcheck disable=SC2086  # intentional word-splitting of $new
    run synogroup --member "$group" $new
}

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
# Single group does double duty: docker-socket access AND read access to
# the agent's secret files (sites.d/*.env, per-stack <env>.env). A
# separate `deploy` group adds no protection because anyone in `docker`
# can `docker run --privileged -v /:/host alpine cat /host/<secret>` and
# get root anyway. The single-group model is honest about that.
heading "2/5 docker group"
if synogroup --get docker > /dev/null 2>&1; then
    echo "Group 'docker' already exists; skipping create."
else
    run synogroup --add docker
fi

# ─── 3. add deploy to docker group ─────────────────────────────────────────
heading "3/5 docker group membership"
add_user_to_group deploy docker

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

# ─── 5. verify user + group + ACL ──────────────────────────────────────────
heading "5/5 verify deploy can reach docker + has /volume1/docker access"
if sudo -u deploy docker info > /dev/null 2>&1; then
    echo "OK — 'sudo -u deploy docker info' succeeded."
else
    echo "FAIL — 'sudo -u deploy docker info' did not succeed."
    echo "       Check group membership took effect (deploy may need to log out/in)."
    exit 1
fi
if sudo -u deploy id -nG | tr ' ' '\n' | grep -qx docker; then
    echo "OK — deploy is a member of the 'docker' group."
else
    echo "FAIL — deploy is NOT in the 'docker' group. Re-check step 3."
    exit 1
fi

# Synology ACL grant on /volume1/docker is the operator's manual step.
# This script can't grant ACLs (synoacltool writes are undocumented +
# brittle); we surface here whether the grant is in place so the operator
# knows what's left before bootstrap-site.sh.
if sudo -u deploy test -w /volume1/docker && sudo -u deploy test -r /volume1/docker; then
    echo "OK — deploy can read+write /volume1/docker."
    echo "     (Whether via Synology ACL or Unix perms, doesn't matter — both work.)"
    DEPLOY_HAS_DOCKER_ACCESS=1
else
    DEPLOY_HAS_DOCKER_ACCESS=0
    cat <<'EOF'

╭──────────────────────────────────────────────────────────────────╮
│ ⚠ deploy cannot read+write /volume1/docker yet.                  │
│                                                                  │
│ Before running bootstrap-site.sh, grant 'deploy' access to       │
│ /volume1/docker via Synology ACL:                                │
│                                                                  │
│   DSM Control Panel → Shared Folder → docker → Edit              │
│     → Permissions tab                                            │
│     → "Enable Windows ACL" should be checked                     │
│     → Add user 'deploy' with Read/Write                          │
│     → Apply (let DSM re-apply ACL recursively if asked)          │
│                                                                  │
│ Then verify: sudo -u deploy touch /volume1/docker/.deploy-probe  │
│              sudo -u deploy rm    /volume1/docker/.deploy-probe  │
│                                                                  │
│ User/group setup is already complete; no need to re-run this     │
│ script. Continue with the operator manual after the ACL grant.   │
╰──────────────────────────────────────────────────────────────────╯
EOF
fi

echo
echo "Bootstrap complete."
if [ "$DEPLOY_HAS_DOCKER_ACCESS" = "1" ]; then
    echo "Next steps:"
    echo "  sudo $SCRIPT_DIR/install-boot-tasks.sh   # persist socket chown across reboots"
    echo "  sudo $SCRIPT_DIR/bootstrap-site.sh       # add the first site"
else
    echo "BLOCKED on the DSM ACL grant above. Apply it, then continue with"
    echo "  sudo $SCRIPT_DIR/install-boot-tasks.sh"
    echo "  sudo $SCRIPT_DIR/bootstrap-site.sh"
fi
