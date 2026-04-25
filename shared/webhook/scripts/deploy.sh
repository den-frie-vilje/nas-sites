#!/bin/bash
# Unified deploy script — one copy of this serves every site on
# the NAS. Called by the shared webhook container on valid
# POSTs to /hooks/deploy/<domain>/<env>.
#
# Usage: deploy.sh <domain> <env>
#   e.g. deploy.sh skovbyesexologi.com staging
#
# Both args are supplied by hooks.yaml as static strings per
# hook entry — never from the request payload — so an attacker
# can't redirect a deploy to a different site by crafting the
# JSON body.
#
# Derives everything else from $domain + $env:
#   branch              = main (prod) | staging (stg)
#   repo clone          = /volume1/docker/<domain>/repo
#   stack working dir   = /volume1/docker/<domain>/<env>
#   compose file        = <repo>/deploy/compose.<env>.yml
#   project name        = <domain>-<env>, dots→dashes
#                         (docker-compose forbids dots)
#
# CF purge + HMAC secret names use the convention:
#   <DOMAIN_SAFE>_<ENV>_<NAME>
#   where DOMAIN_SAFE = uppercase, dots→underscores
# e.g. SKOVBYESEXOLOGI_COM_PRODUCTION_CF_API_TOKEN
# Secrets live in webhook.env; the script reads them via bash
# indirection so one shared script serves every site.
set -euo pipefail

DOMAIN="${1:-}"
ENV_NAME="${2:-}"
[ -n "$DOMAIN" ]   || { echo "ERR: usage: $0 <domain> <env>"; exit 2; }
[ -n "$ENV_NAME" ] || { echo "ERR: usage: $0 <domain> <env>"; exit 2; }

case "$ENV_NAME" in
    staging)    BRANCH=staging ;;
    production) BRANCH=main ;;
    *) echo "ERR: unknown env '$ENV_NAME'"; exit 2 ;;
esac

REPO="/volume1/docker/$DOMAIN/repo"
STACK_DIR="/volume1/docker/$DOMAIN/$ENV_NAME"
COMPOSE_FILE="$REPO/deploy/compose.$ENV_NAME.yml"
ENV_FILE="$STACK_DIR/$ENV_NAME.env"

# Compose project name — '.' disallowed, so dots become dashes.
# Used via `-p` so the compose YAML stays site-agnostic.
PROJECT="$(echo "$DOMAIN-$ENV_NAME" | tr '.' '-')"

# DOMAIN_SAFE for env-var lookups: uppercase, dots→underscores.
DOMAIN_SAFE="$(echo "$DOMAIN" | tr '[:lower:].' '[:upper:]_')"
ENV_UP="$(echo "$ENV_NAME" | tr '[:lower:]' '[:upper:]')"

echo "[$(date -Iseconds)] [$PROJECT] deploy starting"

# Per-site repo clones are owned by the `deploy:users` user on
# the NAS, but the webhook container runs as root. Git 2.35+
# refuses to operate on repos owned by a different user
# (CVE-2022-24765 hardening), erroring out with "detected
# dubious ownership". Trust all directories — this container's
# only job is deploy automation on paths we provisioned, so
# it's not actually untrusted territory.
git config --global --add safe.directory '*' 2>/dev/null || true

# Idempotent fast-forward. Reset to FETCH_HEAD rather than
# `origin/$BRANCH` so this works even when the initial clone
# was shallow + single-branch (which pins the remote's fetch
# refspec to one branch and never creates tracking refs for
# others). `reset --hard` beats `pull --ff-only` — automation
# wins even if someone hand-edited the clone.
git -C "$REPO" fetch --depth 1 origin "$BRANCH"
git -C "$REPO" reset --hard FETCH_HEAD

# Self-update from the NAS-side `nas-sites` clone. The webhook
# scripts + hooks.yaml are SHARED across every site on this NAS
# — they live in github.com/den-frie-vilje/nas-sites and the
# NAS keeps a local clone at $NAS_SITES (bootstrap step in
# nas-sites/docs/NAS-BOOTSTRAP.md). On every fire we git-pull
# that clone, then propagate any changes to the webhook's
# mounted /scripts/deploy.sh and /etc/webhook/hooks.yaml.
#
# This way: any commit to nas-sites' shared/webhook/** lands
# on the NEXT deploy fire automatically — no manual `sudo cp`
# per update. The /scripts mount and /etc/webhook/hooks.yaml
# bind are both :rw specifically so this can overwrite them
# (see compose.yml). After overwriting deploy.sh we re-exec
# so the current deploy runs under the new logic, not the
# stale logic that started this process.
#
# History note: pre-extraction, this block read from
# $REPO/deploy/webhook/... (per-site repo). PR #4 moved the
# webhook plumbing OUT of consumer repos into nas-sites, but
# the paths here weren't updated, so self-update silently
# no-op'd between the extraction and this fix.
NAS_SITES=/volume1/docker/webhook/nas-sites
if [ -d "$NAS_SITES/.git" ]; then
    # Non-fatal: a transient network failure shouldn't block a
    # deploy — the cached clone is good enough for a fallback.
    if ! { git -C "$NAS_SITES" fetch --depth 1 origin main \
        && git -C "$NAS_SITES" reset --hard FETCH_HEAD; } 2>/dev/null
    then
        echo "[$(date -Iseconds)] warn: nas-sites fetch failed; using cached clone"
    fi

    NEW_SELF="$NAS_SITES/shared/webhook/scripts/deploy.sh"
    if [ -f "$NEW_SELF" ] && ! cmp -s "$NEW_SELF" "$0"; then
        echo "[$(date -Iseconds)] deploy.sh updated in nas-sites; self-replacing + re-exec"
        cp "$NEW_SELF" "$0"
        chmod +x "$0"
        exec "$0" "$@"
    fi

    NEW_HOOKS="$NAS_SITES/shared/webhook/hooks.yaml"
    if [ -f "$NEW_HOOKS" ] && ! cmp -s "$NEW_HOOKS" /etc/webhook/hooks.yaml; then
        echo "[$(date -Iseconds)] hooks.yaml updated in nas-sites; copying"
        cp "$NEW_HOOKS" /etc/webhook/hooks.yaml
    fi
else
    # Loud failure: surfaces a misbootstrapped NAS instead of
    # silently freezing self-update like the previous regression.
    echo "[$(date -Iseconds)] warn: $NAS_SITES is not a git clone — self-update disabled (see nas-sites/docs/NAS-BOOTSTRAP.md)"
fi

cd "$STACK_DIR"

COMPOSE_ARGS=(-p "$PROJECT" -f "$COMPOSE_FILE")
[ -f "$ENV_FILE" ] && COMPOSE_ARGS+=(--env-file "$ENV_FILE")

docker compose "${COMPOSE_ARGS[@]}" pull site

# First pass: apply any compose/env/volume changes across all
# services (idempotent — unchanged services are untouched).
docker compose "${COMPOSE_ARGS[@]}" up -d

# Second pass: force-recreate the site container specifically.
# Docker Compose's default up skips recreation when the image
# *reference* is unchanged — but the tag (e.g. `staging-latest`)
# is a moving pointer: the reference stays the same while the
# digest behind it changes on every CI push. Without a force
# here, `pull site` brings new layers down but `up -d` keeps
# the running container on the old digest, and the deployed
# content never refreshes.
#
# --no-deps: don't touch Caddy + sveltia-auth (both stay up,
# no brief routing outage during the swap).
# --wait: block until the new site container's healthcheck
# passes — this is the "deploy is live" signal that the CF
# cache purge below can safely fire off.
docker compose "${COMPOSE_ARGS[@]}" up -d --wait --force-recreate --no-deps site

# Optional Cloudflare purge. Per-site vars via indirection:
#   <DOMAIN_SAFE>_<ENV>_CF_API_TOKEN
#   <DOMAIN_SAFE>_<ENV>_CF_ZONE_ID
# Leave unset in webhook.env to skip.
TOKEN_VAR="${DOMAIN_SAFE}_${ENV_UP}_CF_API_TOKEN"
ZONE_VAR="${DOMAIN_SAFE}_${ENV_UP}_CF_ZONE_ID"
TOKEN="${!TOKEN_VAR:-}"
ZONE="${!ZONE_VAR:-}"

if [ -n "$TOKEN" ] && [ -n "$ZONE" ]; then
    echo "purging Cloudflare zone $ZONE..."
    curl -sSf -X POST \
        "https://api.cloudflare.com/client/v4/zones/$ZONE/purge_cache" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data '{"purge_everything": true}' \
    && echo "CF purge ok" \
    || echo "warn: CF purge failed (non-fatal, deploy is still live)"
fi

docker image prune -f || true

echo "[$(date -Iseconds)] [$PROJECT] deploy done"
