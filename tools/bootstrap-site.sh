#!/bin/bash
# Add a single (site, environment) pair to the pull-only deploy agent.
# Run twice per new site: once for staging, once for production.
#
# What this script does, with confirmations:
#   1. Prompt for DOMAIN, ENV_NAME, REPO, BRANCH, COMPOSE_FILE_REL
#   2. Create /volume1/docker/<domain>/{repo,<env>}/ owned by deploy:users
#   3. git clone the site repo at the chosen branch (if not already cloned)
#   4. Create the per-stack <env>.env at root:deploy 0640 and open $EDITOR on it
#   5. Create the per-(site, env) sites.d/<domain>.<env>.env from the template,
#      open $EDITOR on it for secret values
#   6. Smoke-test: run the deploy agent with a one-site filter

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO_DIR="${REPO_DIR:-/volume1/docker/nas-sites/repo}"
SITES_D="${SITES_D:-/volume1/docker/nas-sites/sites.d}"
SITE_TEMPLATE="$REPO_DIR/nas-agent/sites.env.example"
AGENT="${AGENT:-/volume1/docker/nas-sites/deploy-agent.sh}"
EDITOR="${EDITOR:-vi}"

require_dsm
require_root
require_tools git sed mkdir cp chmod chown

heading "Bootstrap a (site, env) for the pull-only agent"

DOMAIN=$(ask "Domain (e.g. example.com)")
ENV_NAME=$(ask "Environment (staging|production)" "staging")
REPO_DEFAULT="den-frie-vilje/$DOMAIN"
REPO=$(ask "GitHub repo (owner/name)" "$REPO_DEFAULT")
BRANCH_DEFAULT="$ENV_NAME"; [ "$ENV_NAME" = "production" ] && BRANCH_DEFAULT="main"
BRANCH=$(ask "Branch to track" "$BRANCH_DEFAULT")
COMPOSE_FILE_REL=$(ask "Compose file path inside repo" "deploy/compose.$ENV_NAME.yml")

case "$ENV_NAME" in
    staging|production) ;;
    *) echo "ERROR: ENV_NAME must be 'staging' or 'production'" >&2; exit 1 ;;
esac

STACK_DIR="/volume1/docker/$DOMAIN/$ENV_NAME"
SITE_REPO_DIR="/volume1/docker/$DOMAIN/repo"
ENV_FILE="$STACK_DIR/$ENV_NAME.env"
SITES_D_FILE="$SITES_D/$DOMAIN.$ENV_NAME.env"

heading "Plan"
plan "create dir $SITE_REPO_DIR (deploy:users 0755)"
plan "git clone https://github.com/$REPO at branch $BRANCH → $SITE_REPO_DIR (skip if exists)"
plan "create dir $STACK_DIR (deploy:users 0755)"
plan "create empty $ENV_FILE (root:deploy 0640) and open in \$EDITOR"
plan "copy $SITE_TEMPLATE → $SITES_D_FILE (root:deploy 0640) and open in \$EDITOR"
plan "smoke-test: run agent with filter ($DOMAIN $ENV_NAME)"

confirm "Proceed?" || { echo "Aborted by operator."; exit 0; }

# ─── 1. dirs ───────────────────────────────────────────────────────────────
heading "1/5 directories"
run mkdir -p "$SITE_REPO_DIR" "$STACK_DIR"

# ─── 2. site repo clone ────────────────────────────────────────────────────
heading "2/5 site repo clone"
if [ -d "$SITE_REPO_DIR/.git" ]; then
    echo "$SITE_REPO_DIR already a git clone; skipping clone."
else
    run git clone --depth 1 -b "$BRANCH" "https://github.com/$REPO.git" "$SITE_REPO_DIR"
fi
run chown -R deploy:users "/volume1/docker/$DOMAIN"

# ─── 3. per-stack env file ────────────────────────────────────────────────
heading "3/5 per-stack env file ($ENV_FILE)"
if [ -f "$ENV_FILE" ]; then
    echo "$ENV_FILE already exists; leaving as-is. Re-edit by hand if needed."
else
    create_empty_file 0640 root deploy "$ENV_FILE"
fi
echo "Opening \$EDITOR ($EDITOR) — populate CADDY_PORT, OAuth secrets, etc."
echo "(Save and quit when done. The deploy agent will pick up changes on next fire.)"
confirm "Open $ENV_FILE in $EDITOR now?" && run "$EDITOR" "$ENV_FILE"

# ─── 4. sites.d entry ──────────────────────────────────────────────────────
heading "4/5 agent config ($SITES_D_FILE)"
if [ ! -f "$SITE_TEMPLATE" ]; then
    echo "ERROR: $SITE_TEMPLATE missing — pull nas-sites first." >&2
    exit 1
fi
mkdir -p "$SITES_D"
if [ -f "$SITES_D_FILE" ]; then
    echo "$SITES_D_FILE already exists; leaving as-is. Re-edit by hand if needed."
else
    install_file 0640 root deploy "$SITE_TEMPLATE" "$SITES_D_FILE"
    # Pre-populate the values we asked for so the operator only has to fill
    # in secrets in $EDITOR.
    sed -i \
        -e "s|^DOMAIN=.*|DOMAIN=\"$DOMAIN\"|" \
        -e "s|^ENV_NAME=.*|ENV_NAME=\"$ENV_NAME\"|" \
        -e "s|^REPO=.*|REPO=\"$REPO\"|" \
        -e "s|^BRANCH=.*|BRANCH=\"$BRANCH\"|" \
        -e "s|^COMPOSE_FILE_REL=.*|COMPOSE_FILE_REL=\"$COMPOSE_FILE_REL\"|" \
        "$SITES_D_FILE"
fi
echo "Opening \$EDITOR ($EDITOR) — fill in CF_API_TOKEN / CF_ZONE_ID if you want CF cache purge."
confirm "Open $SITES_D_FILE in $EDITOR now?" && run "$EDITOR" "$SITES_D_FILE"

# ─── 5. smoke test ─────────────────────────────────────────────────────────
heading "5/5 smoke test"
if [ ! -x "$AGENT" ]; then
    echo "WARN: $AGENT not installed. Run tools/update-agent.sh first."
    exit 0
fi
echo "Running: sudo -u deploy $AGENT $DOMAIN $ENV_NAME"
echo "(Cosign verify + first deploy can take a minute or two.)"
if confirm "Run now?"; then
    run sudo -u deploy "$AGENT" "$DOMAIN" "$ENV_NAME"
else
    echo "Skipped. Wait for the next scheduled fire (within 5 min)."
fi

echo
echo "Done. The DSM Web Station vhost for $DOMAIN.$ENV_NAME still needs to"
echo "be created in the GUI — that part isn't scriptable, see"
echo "docs/NAS-BOOTSTRAP.md."
