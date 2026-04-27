#!/bin/bash
# Pull the latest nas-sites and re-install the deploy agent script onto the
# NAS. This is the canonical way to apply an upstream agent update — running
# it is the explicit operator action that closes the security gap "push to
# nas-sites/main" → "code execution on the NAS."
#
# What this script does, with confirmation at each step:
#   1. git -C /volume1/docker/nas-sites/repo pull (fast-forward only)
#   2. show the diff between the running agent and the upstream agent
#   3. ask the operator to confirm
#   4. cp+chmod+chown the new agent into place at root:root 0755
#
# It does NOT restart anything — the next DSM Task Scheduler fire of the
# agent (within 5 min by default) will run the new code.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO_DIR="${REPO_DIR:-/volume1/docker/nas-sites/repo}"
AGENT_DST="${AGENT_DST:-/volume1/docker/nas-sites/deploy-agent.sh}"
AGENT_SRC="$REPO_DIR/nas-agent/deploy-agent.sh"

require_dsm
require_root

heading "Update nas-sites deploy agent"
plan "git pull (fast-forward) in $REPO_DIR"
plan "compare $AGENT_SRC against $AGENT_DST"
plan "if different and you confirm, install src → dst at root:root 0755"

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "ERROR: $REPO_DIR is not a git clone — bootstrap first." >&2
    echo "       See docs/PULL-DEPLOY-MODEL.md §One-time bootstrap." >&2
    exit 1
fi

heading "1/3 Pulling nas-sites"
run git -C "$REPO_DIR" fetch --depth 1 origin main
run git -C "$REPO_DIR" reset --hard origin/main

if [ ! -f "$AGENT_SRC" ]; then
    echo "ERROR: $AGENT_SRC missing after pull. Repo layout changed?" >&2
    exit 1
fi

heading "2/3 Diff (running vs. upstream)"
if [ -f "$AGENT_DST" ] && cmp -s "$AGENT_SRC" "$AGENT_DST"; then
    echo "Agent is already up to date. Nothing to do."
    exit 0
fi
if [ -f "$AGENT_DST" ]; then
    diff -u "$AGENT_DST" "$AGENT_SRC" || true
else
    echo "Agent not yet installed at $AGENT_DST — this is a first install."
fi

if ! confirm "Install $AGENT_SRC → $AGENT_DST (root:root 0755)?"; then
    echo "Aborted by operator."
    exit 0
fi

heading "3/3 Installing"
install_file 0755 root root "$AGENT_SRC" "$AGENT_DST"

echo
echo "Done. The next DSM Task Scheduler fire will run the new agent."
echo "Manual smoke test:"
echo "  sudo -u deploy $AGENT_DST"
