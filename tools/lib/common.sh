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
