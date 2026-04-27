# Common helpers for tools/*.sh — sourced, not executed directly.
# All operator scripts use these so the prompt-and-confirm UX is uniform.

# Refuse to run on non-DSM hosts unless explicitly overridden. The synouser /
# synogroup / synowebapi tools only exist on DSM; running these scripts on a
# laptop would either silently no-op or eat real local config.
require_dsm() {
    if [ "${ALLOW_NON_DSM:-0}" = "1" ]; then return 0; fi
    if [ -r /etc.defaults/VERSION ] && grep -q "^os_name=" /etc.defaults/VERSION 2>/dev/null; then
        return 0
    fi
    cat >&2 <<EOF
ERROR: this script expects to run on Synology DSM.
       /etc.defaults/VERSION is missing or doesn't look like DSM.
       Set ALLOW_NON_DSM=1 to override (for testing only).
EOF
    exit 2
}

# Refuse to run unless invoked with sudo / as root.
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: $0 must be run as root (try: sudo $0)" >&2
        exit 2
    fi
}

# Refuse to run unless every named tool is on PATH. Use this at the top of
# any script that depends on a non-bash-builtin command, so we fail at
# startup with a clear diagnostic instead of partway through with a cryptic
# "command not found." DSM is a stripped-down embedded Linux — many tools
# considered "always present" elsewhere are absent (`getent`, `jq`,
# `python3`, `realpath` flags, `column`, `envsubst`, GNU `install`, etc).
require_tools() {
    local missing=()
    local t
    for t in "$@"; do
        command -v "$t" > /dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: $0 needs these tools, which are not on PATH:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        echo "PATH was: $PATH" >&2
        exit 2
    fi
}

# Refuse to run unless the `deploy` user has read+write access to the given
# path (defaults to /volume1/docker). The agent + bootstrap scripts assume
# deploy access is granted via Synology ACL on /volume1/docker (DSM Control
# Panel → Shared Folder → docker → Edit → Permissions → Enable Windows ACL
# + grant deploy Read/Write). If that's not in place, fail loudly with
# diagnostic output rather than discovering it half-way through a deploy
# with confusing chown errors.
require_deploy_can_write() {
    local target="${1:-/volume1/docker}"

    if ! synouser --get deploy > /dev/null 2>&1; then
        echo "ERROR: 'deploy' user does not exist." >&2
        echo "       Run tools/bootstrap-deploy-user.sh first." >&2
        exit 2
    fi

    if [ ! -e "$target" ]; then
        echo "ERROR: $target does not exist." >&2
        exit 2
    fi

    if sudo -u deploy test -w "$target" && sudo -u deploy test -r "$target"; then
        return 0
    fi

    {
        echo "ERROR: 'deploy' user cannot read+write $target"
        echo
        echo "This usually means one of:"
        echo "  1. ACLs are enabled on $target but 'deploy' is not granted access."
        echo "     Fix in DSM: Control Panel → Shared Folder → docker → Edit"
        echo "                 → Permissions tab → add user 'deploy' with Read/Write."
        echo "  2. ACLs are NOT enabled on $target and Unix ownership excludes deploy."
        echo "     Fix in DSM: same path; check 'Enable Windows ACL'."
        echo "                 OR shell: sudo chown -R deploy:users $target"
        echo "  3. Container Manager just restarted and reset some permissions."
        echo "     Re-run the boot-up Task Scheduler job manually:"
        echo "                 sudo chown root:docker /var/run/docker.sock"
        echo "                 sudo chmod 660 /var/run/docker.sock"
        echo
        echo "Diagnostic snapshot:"
        echo "  Path:      $target"
        echo "  Unix:      $(stat -c 'owner=%U:%G mode=%a' "$target" 2>/dev/null || echo unknown)"
        echo "  ACL state: $(synoacltool --get "$target" 2>&1 | head -3 | tr '\n' '|')"
        echo "  As deploy: $(sudo -u deploy ls -ld "$target" 2>&1 | head -1)"
    } >&2
    exit 2
}

# Print a section heading in the operator's terminal.
heading() {
    printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"
}

# Print a single planned action so the operator can review before confirming.
plan() {
    printf '  • %s\n' "$*"
}

# Prompt for explicit Y/N. Default = N. The operator must type 'y' or 'yes'.
# Returns 0 on yes, 1 on no.
confirm() {
    local prompt="${1:-Proceed?}"
    local response
    printf '\n%s [y/N] ' "$prompt"
    read -r response
    case "${response,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Prompt for free-form input. Echoes the user's response on stdout.
ask() {
    local prompt="$1"
    local default="${2:-}"
    local response
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r response
    printf '%s' "${response:-$default}"
}

# Print a line and execute it. Used so operators see exactly what's happening.
run() {
    printf '\033[2m  $ %s\033[0m\n' "$*"
    "$@"
}

# Idempotent file install (replaces GNU `install`, which is NOT on stock DSM —
# DSM ships BusyBox utilities, and BusyBox has no `install` applet).
# Usage: install_file <mode> <user> <group> <src> <dst>
install_file() {
    local mode="$1" owner="$2" group="$3" src="$4" dst="$5"
    run cp -f "$src" "$dst"
    run chmod "$mode" "$dst"
    run chown "$owner:$group" "$dst"
}

# Idempotent empty-file create with permissions.
create_empty_file() {
    local mode="$1" owner="$2" group="$3" dst="$4"
    run touch "$dst"
    run chmod "$mode" "$dst"
    run chown "$owner:$group" "$dst"
}
