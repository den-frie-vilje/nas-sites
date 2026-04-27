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
TS="${3:-}"
[ -n "$DOMAIN" ]   || { echo "ERR: usage: $0 <domain> <env> [<ts>]"; exit 2; }
[ -n "$ENV_NAME" ] || { echo "ERR: usage: $0 <domain> <env> [<ts>]"; exit 2; }

case "$ENV_NAME" in
    staging)    BRANCH=staging ;;
    production) BRANCH=main ;;
    *) echo "ERR: unknown env '$ENV_NAME'"; exit 2 ;;
esac

# Phase 4 / H1 — replay-attack hardening.
#
# CI sends a Unix timestamp `ts` in the request body, included
# in the HMAC signature; hooks.yaml passes it through to us
# as $3. Reject if the timestamp is more than 5 min off the
# server's clock in either direction. With a stable HMAC
# secret, an attacker who captures a valid signed POST could
# otherwise replay it indefinitely; ts freshness narrows that
# window to a 5-min replay buffer (and surfaces clock skew
# loudly when it shows up).
#
# Optional during the rollout window: if $3 is empty, we're
# running against an OLD hooks.yaml (from before this change
# self-propagated). Warn but accept — by the next fire the
# self-update will have shipped the new hooks.yaml and ts will
# arrive. After we've seen one cycle of "ts received", future
# work can make this strict.
if [ -n "$TS" ]; then
    # Bash regex — confirm $3 is a positive integer before
    # arithmetic (a malformed value would crash `set -e` later).
    if ! [[ "$TS" =~ ^[0-9]+$ ]]; then
        echo "ERR: ts must be a positive integer Unix timestamp; got '$TS'"
        exit 3
    fi
    NOW=$(date +%s)
    SKEW=$((NOW - TS))
    ABS_SKEW=${SKEW#-}
    if [ "$ABS_SKEW" -gt 300 ]; then
        echo "ERR: ts freshness check failed: skew ${SKEW}s > 300s"
        echo "  request ts: $TS, server now: $NOW"
        echo "  if this is a legitimate deploy, check NTP sync on the NAS"
        echo "  (we accept ±5 min skew either direction)"
        exit 3
    fi
else
    echo "[$(date -Iseconds)] warn: no ts arg (older hooks.yaml propagating); skipping freshness check this fire"
fi

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
        # Write through the bind mount instead of `cp`. /etc/webhook/hooks.yaml
        # is a SINGLE-FILE bind from compose.yml's
        # `./webhook/hooks.yaml:/etc/webhook/hooks.yaml`. BusyBox cp fails
        # against single-file binds with "File exists" because its
        # create-and-truncate path conflicts with the kernel-level bind.
        # `cat > dst` uses open(O_WRONLY|O_CREAT|O_TRUNC) which truncates
        # the existing inode in place — works through the bind cleanly.
        # (deploy.sh self-replace above uses cp because /scripts is a
        # directory bind, where cp works normally.)
        cat "$NEW_HOOKS" > /etc/webhook/hooks.yaml
    fi
else
    # Loud failure: surfaces a misbootstrapped NAS instead of
    # silently freezing self-update like the previous regression.
    echo "[$(date -Iseconds)] warn: $NAS_SITES is not a git clone — self-update disabled (see nas-sites/docs/NAS-BOOTSTRAP.md)"
fi

cd "$STACK_DIR"

# Per-site serialization. Two simultaneous deploy.sh runs for
# the same site (back-to-back pushes, CI-side retry overlapping
# the original, manual workflow_dispatch firing while a push
# is in flight) would otherwise race over docker-compose state.
#
# BusyBox flock (Alpine util-linux build inside the webhook
# container) supports `-n` (non-blocking) and `-u` (unlock)
# but NOT `-w SEC` (which is a CONFIG-dependent feature in
# BusyBox; the build shipped here doesn't include it — verified
# empirically when `-w` made flock print its short usage and
# return non-zero). So we poll with `flock -n` in a sleep
# loop instead.
#
# Stale-lock semantics: flock(2) holds against the open fd,
# NOT against the filename. The kernel auto-releases on any
# process exit — clean exit, crash, SIGKILL, OOM kill,
# container restart, kernel panic, reboot. An orphan
# /tmp/deploy-*.lock file with no live holder is just a file;
# the next flock -n attempt acquires immediately. There is no
# scenario where a stale lock blocks a deploy.
#
# The trap removes the lock file on graceful exit purely for
# /tmp hygiene — correctness does NOT depend on it firing
# (it doesn't fire on SIGKILL, but that's fine per the above).
#
# Placement: AFTER the self-update block on purpose. The
# re-exec there closes fd 200 and momentarily releases the
# lock, letting a queued sibling steal it. Self-update racing
# is fine: both runs cp the same source bytes, last-writer
# wins, both then exec the new code and both arrive here for
# the lock.
#
# 600 attempts × 1s = 10min max wait: if the first deploy is
# genuinely wedged we bail rather than queueing forever.
LOCK_FILE="/tmp/deploy-${PROJECT}.lock"
exec 200>"$LOCK_FILE"
LOCK_ATTEMPTS=0
until flock -n 200; do
    LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
    if [ "$LOCK_ATTEMPTS" -ge 600 ]; then
        echo "[$(date -Iseconds)] [$PROJECT] could not acquire deploy lock within 10min — bailing"
        exit 1
    fi
    sleep 1
done
trap 'rm -f "$LOCK_FILE"' EXIT

COMPOSE_ARGS=(-p "$PROJECT" -f "$COMPOSE_FILE")
[ -f "$ENV_FILE" ] && COMPOSE_ARGS+=(--env-file "$ENV_FILE")

docker compose "${COMPOSE_ARGS[@]}" pull site

# First pass: apply any compose/env/volume changes across all
# services (idempotent — unchanged services are untouched).
# When the site image digest changes, compose v2 may cascade-
# recreate Caddy + sveltia-auth via `depends_on`. That can
# briefly drop the live CI→webhook connection mid-deploy, but
# the CI side's smart retry in build-and-notify.yml waits long
# enough between attempts (180s) that any retry happens AFTER
# this script's own --wait has finished — no concurrent
# execution.
#
# `--wait` (Phase 8 / M3): block until every recreated
# container reports healthy via its compose healthcheck. If
# anything in the stack is wedged (e.g. caddy in a crash loop
# from a bad Caddyfile, sveltia-auth missing OAuth env vars),
# we surface the failure HERE instead of forging ahead to the
# force-recreate of `site` and reporting a misleading
# "site exited (0)" downstream. Fails-fast on a broken stack.
docker compose "${COMPOSE_ARGS[@]}" up -d --wait

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
