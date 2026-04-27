#!/bin/bash
# nas-sites pull-only deploy agent.
#
# This script is OPERATOR-INSTALLED on the NAS at:
#   /volume1/docker/nas-sites/deploy-agent.sh
#
# It is NEVER auto-updated from any git repo at runtime. Updates require
# operator action: pull the nas-sites repo, then
#   sudo install -m 0755 -o root -g root \
#     <clone>/nas-agent/deploy-agent.sh \
#     /volume1/docker/nas-sites/deploy-agent.sh
# This is what makes "push access to nas-sites/main" stop short of "code
# execution on the NAS" — the agent only runs operator-installed bytes.
#
# Privilege model: invoked as the `deploy` user (member of the `docker`
# group), not as root. Docker-socket access is functionally root-equivalent
# so this is defense in depth, not a blast-radius reduction. The agent
# script itself is root:root 0755 — `deploy` reads + executes, cannot
# rewrite. Updates require operator sudo. See docs/PULL-DEPLOY-MODEL.md
# §Security model for the full reasoning and the boot-up task that
# re-applies /var/run/docker.sock group ownership after Container Manager
# restarts.
#
# Behaviour per fire (typically scheduled every 5–15 minutes):
#   for each /volume1/docker/nas-sites/sites.d/*.env:
#     - source the per-(site, env) config file
#     - git fetch + reset --hard origin/<branch> in the site repo clone
#     - read the compose file
#     - cosign-verify every image: ref against our GitHub Actions OIDC
#       signing identity (fails closed — no signature ⇒ no deploy)
#     - if any image digest differs from what's running OR no container is
#       running yet ⇒ docker compose pull && up -d --wait
#     - else ⇒ skip (no-op deploy on subsequent fires)
#     - optional Cloudflare cache purge on actual deploy
#
# Manual invocation:
#   sudo /volume1/docker/nas-sites/deploy-agent.sh                       # all sites
#   sudo /volume1/docker/nas-sites/deploy-agent.sh skovbyesexologi.com   # one site, both envs
#   sudo /volume1/docker/nas-sites/deploy-agent.sh skovbyesexologi.com staging
#
# Designed for Synology DSM 7.2.2+ Task Scheduler. DSM-specific quirks
# encoded inline; see docs/PULL-DEPLOY-MODEL.md for the operator manual.

set -uo pipefail

# DSM Task Scheduler runs scripts with a minimal env. PATH is /usr/bin:/bin
# only by default — set explicitly so docker, git, jq, etc. resolve
# regardless of how the script is invoked. LC_ALL=C avoids locale-dependent
# sort/date behaviour drift between manual SSH (UTF-8) and Task Scheduler
# (POSIX). HOME may be unset under Task Scheduler even with run-as-root —
# point it at $HOME if set, otherwise the calling user's home directory.
# When run as `deploy` via Task Scheduler, $HOME may be unset; fall back
# to /var/services/homes/deploy (DSM convention) or /tmp as a last resort.
export PATH=/usr/local/bin:/usr/bin:/bin
export LC_ALL=C
if [ -z "${HOME:-}" ]; then
    if [ -d /var/services/homes/deploy ]; then
        export HOME=/var/services/homes/deploy
    else
        export HOME=/tmp
    fi
fi

# ─── Configuration ──────────────────────────────────────────────────────────

# Everything the agent reads/writes lives under /volume1/docker/nas-sites/
# so it's covered by the same offsite backup as the rest of the docker
# stack and survives DSM updates (the rootfs is regenerated on update;
# /volume1 is not). Lock files are the only exception — they live on
# tmpfs at /tmp/ because they MUST be cleared on reboot (a stale lockfile
# on persistent storage would block deploys after an unclean shutdown)
# AND /tmp is universally writable across DSM versions, where /run/lock
# may be root-only.
SITES_DIR="${SITES_DIR:-/volume1/docker/nas-sites/sites.d}"
DOCKER_ROOT="${DOCKER_ROOT:-/volume1/docker}"
STATE_DIR="${STATE_DIR:-/volume1/docker/nas-sites/state}"
LOCK_DIR="${LOCK_DIR:-/tmp/nas-sites-deploy}"

# Pinned tool images. Bumped via PR + operator re-cp of this script (no
# auto-update). cosign at v2.4 is the current stable line as of 2026-04;
# yq v4 is the current major.
COSIGN_IMAGE="${COSIGN_IMAGE:-ghcr.io/sigstore/cosign/cosign:v2.4.1}"
YQ_IMAGE="${YQ_IMAGE:-mikefarah/yq:4}"

# Cosign keyless verification parameters. Identity regex matches our CI
# workflow on permitted branches only — staging deploys only what was
# signed by build-and-sign.yml on refs/heads/staging, production only
# what was signed on refs/heads/main. Forging a valid signature requires
# both (a) the ability to run the workflow on a permitted branch (gated
# by GitHub branch protection on the site repo) and (b) the OIDC chain
# back to GitHub Actions.
COSIGN_IDENTITY_REGEX='^https://github\.com/den-frie-vilje/[^/]+/\.github/workflows/build-and-sign\.yml@refs/heads/(main|staging)$'
COSIGN_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# Optional CLI filter
FILTER_DOMAIN="${1:-}"
FILTER_ENV="${2:-}"

# ─── Logging ────────────────────────────────────────────────────────────────

# Dual-write: stdout (captured by Task Scheduler "Output result" if enabled,
# also visible on manual SSH invocation) AND syslog via `logger`, which DSM
# Log Center ingests. `logger` failure is non-fatal so the script still works
# on hosts without syslog.
#
# Timestamp uses an explicit format string instead of `date -Iseconds`
# because BusyBox `date` (which DSM ships) does not support `-I` — only
# GNU `date` does. The literal format here produces ISO-8601 in UTC.
_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log() {
    local msg="[$(_ts)] $*"
    printf '%s\n' "$msg"
    logger -t nas-sites-deploy -- "$*" 2>/dev/null || true
}

err() {
    local msg="[$(_ts)] ERROR: $*"
    printf '%s\n' "$msg" >&2
    logger -t nas-sites-deploy -p user.err -- "ERROR: $*" 2>/dev/null || true
}

# ─── Capability probes ──────────────────────────────────────────────────────
# Fail loudly at startup rather than partway through a deploy. Each probe
# checks one assumption from the DSM audit (see docs/PULL-DEPLOY-MODEL.md
# §Synology constraints).

probe_capabilities() {
    local missing=0

    if ! command -v docker > /dev/null; then
        err "docker not found in PATH ($PATH)"
        missing=1
    fi

    # docker compose v2 (plugin) preferred. Fall back to docker-compose v1
    # if the plugin isn't present — Container Manager versions vary.
    if docker compose version > /dev/null 2>&1; then
        DOCKER_COMPOSE=(docker compose)
    elif command -v docker-compose > /dev/null; then
        DOCKER_COMPOSE=(docker-compose)
        log "warn: using legacy docker-compose v1; v2 plugin recommended"
    else
        err "neither 'docker compose' nor 'docker-compose' available"
        missing=1
    fi

    if ! command -v git > /dev/null; then
        err "git not found in PATH"
        missing=1
    fi

    if ! command -v flock > /dev/null; then
        err "flock not found in PATH"
        missing=1
    fi

    # Probe whether docker actually works for this user. Most common cause
    # on DSM when not running as root: /var/run/docker.sock isn't group-
    # readable by `deploy`, OR Container Manager restarted and reset the
    # group ownership. The boot-up Task Scheduler job documented in
    # PULL-DEPLOY-MODEL.md re-applies it — if it didn't run yet, the agent
    # fails closed here rather than later mid-deploy.
    if ! docker info > /dev/null 2>&1; then
        err "docker daemon unreachable as $(id -un) — check /var/run/docker.sock group ownership; see PULL-DEPLOY-MODEL.md"
        missing=1
    fi

    # Probe sites dir readability. Catches "ran as wrong user" cleanly.
    if [ ! -r "$SITES_DIR" ]; then
        err "$SITES_DIR not readable by $(id -un) — fix ownership or run as the configured deploy user"
        missing=1
    fi

    return "$missing"
}

# ─── Cosign verification ────────────────────────────────────────────────────
# Always fails closed. cosign verify exits non-zero on:
#   - no signature found
#   - signing identity doesn't match the regex
#   - issuer doesn't match
#   - Sigstore (Fulcio/Rekor) lookup failures
#   - tampered signature
# Network failures to Sigstore are also fail-closed by design — we'd rather
# skip a deploy than deploy unverified code.

cosign_verify() {
    local image="$1"
    docker run --rm \
        "$COSIGN_IMAGE" verify \
            --certificate-identity-regexp "$COSIGN_IDENTITY_REGEX" \
            --certificate-oidc-issuer    "$COSIGN_OIDC_ISSUER" \
            "$image" \
        > /dev/null 2>&1
}

# ─── Compose helpers ────────────────────────────────────────────────────────

# Extract every image: value from a compose file, one per line, no nulls.
# Uses yq via docker so no host yq installation is required.
compose_images() {
    local compose_file="$1"
    docker run --rm -i "$YQ_IMAGE" \
        '.services[].image' \
        < "$compose_file" \
        | grep -Ev '^(null|---|)$' \
        | sort -u
}

# Compose image IDs as `docker compose images --quiet` would print them.
# Used to detect "did pull change anything?" — IDs differ ⇒ change.
compose_image_ids() {
    "${DOCKER_COMPOSE[@]}" "$@" images --quiet 2>/dev/null | sort -u
}

# Number of running containers in this compose project.
compose_running_count() {
    "${DOCKER_COMPOSE[@]}" "$@" ps --quiet 2>/dev/null | grep -c .
}

# ─── Cloudflare ─────────────────────────────────────────────────────────────

cf_purge() {
    local token="$1" zone="$2"
    [ -n "$token" ] && [ -n "$zone" ] || return 0

    if curl -sSf -X POST \
        "https://api.cloudflare.com/client/v4/zones/${zone}/purge_cache" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data '{"purge_everything":true}' \
        > /dev/null
    then
        log "  CF purge ok"
    else
        log "  warn: CF purge failed (non-fatal — deploy is live)"
    fi
}

# ─── Per-site deploy ────────────────────────────────────────────────────────

deploy_site() {
    local config_file="$1"

    # Per-site config is a sourceable bash file. Sourced inside this function
    # because the caller invokes deploy_site in a subshell (see main loop)
    # so variables don't leak between sites.
    local DOMAIN="" ENV_NAME="" REPO="" BRANCH=""
    local COMPOSE_FILE_REL="" SITE_SERVICE=""
    local CF_API_TOKEN="" CF_ZONE_ID=""

    # shellcheck disable=SC1090
    source "$config_file"

    : "${DOMAIN:?$config_file: DOMAIN unset}"
    : "${ENV_NAME:?$config_file: ENV_NAME unset}"
    : "${REPO:?$config_file: REPO unset}"
    : "${BRANCH:?$config_file: BRANCH unset}"
    : "${COMPOSE_FILE_REL:?$config_file: COMPOSE_FILE_REL unset}"
    : "${SITE_SERVICE:=site}"   # name of the primary service in the compose file

    # Apply optional CLI filters (useful for ad-hoc operator runs).
    if [ -n "$FILTER_DOMAIN" ] && [ "$DOMAIN" != "$FILTER_DOMAIN" ]; then
        return 0
    fi
    if [ -n "$FILTER_ENV" ] && [ "$ENV_NAME" != "$FILTER_ENV" ]; then
        return 0
    fi

    local project repo_dir stack_dir compose_file env_file lock_file
    project="$(printf '%s' "$DOMAIN-$ENV_NAME" | tr '.' '-')"
    repo_dir="$DOCKER_ROOT/$DOMAIN/repo"
    stack_dir="$DOCKER_ROOT/$DOMAIN/$ENV_NAME"
    compose_file="$repo_dir/$COMPOSE_FILE_REL"
    env_file="$stack_dir/$ENV_NAME.env"
    lock_file="$LOCK_DIR/${project}.lock"

    log "[$project] check"

    # ─── Per-site lock ────────────────────────────────────────────────────
    # BusyBox flock on DSM doesn't support -w SECONDS, so poll with -n.
    # 60 attempts × 1s = 60s budget. The agent runs every 5–15 min so a
    # missed fire while a long deploy is in flight is fine — next fire
    # picks up where we left off.
    exec 200>"$lock_file"
    local attempts=0
    until flock -n 200; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            err "[$project] could not acquire lock within 60s — another deploy in flight; skipping"
            return 1
        fi
        sleep 1
    done

    # ─── Pre-flight ───────────────────────────────────────────────────────
    if [ ! -d "$repo_dir/.git" ]; then
        err "[$project] $repo_dir is not a git clone — bootstrap first (see PULL-DEPLOY-MODEL.md)"
        return 1
    fi
    if [ ! -d "$stack_dir" ]; then
        err "[$project] stack dir $stack_dir missing — bootstrap first"
        return 1
    fi

    # Trust the clone regardless of ownership. The deploy user may differ
    # from whoever git-cloned originally; we own the path policy here.
    git config --global --add safe.directory "$repo_dir" 2>/dev/null || true

    # ─── Pull repo state ──────────────────────────────────────────────────
    if ! git -C "$repo_dir" fetch --depth 1 origin "$BRANCH" 2>&1 | sed "s/^/[$project]   git: /"; then
        err "[$project] git fetch failed — skipping"
        return 1
    fi
    git -C "$repo_dir" reset --hard FETCH_HEAD > /dev/null

    if [ ! -f "$compose_file" ]; then
        err "[$project] compose file $compose_file not found in repo at branch $BRANCH"
        return 1
    fi

    # ─── Verify all images ────────────────────────────────────────────────
    # Done BEFORE the docker compose pull so a verification failure aborts
    # without ever pulling unverified bytes onto the host.
    local images verify_failed=0
    if ! images=$(compose_images "$compose_file"); then
        err "[$project] failed to parse compose file"
        return 1
    fi
    if [ -z "$images" ]; then
        err "[$project] no images found in compose file — refusing to deploy nothing"
        return 1
    fi

    while IFS= read -r img; do
        if ! cosign_verify "$img"; then
            err "[$project]   signature verification FAILED: $img"
            verify_failed=1
        fi
    done <<< "$images"

    if [ "$verify_failed" -ne 0 ]; then
        err "[$project] aborting deploy — one or more images failed cosign verification"
        return 1
    fi

    # ─── Detect change ────────────────────────────────────────────────────
    # Pull, then compare image IDs before/after. If unchanged AND a
    # container is currently running, this fire is a no-op. This is what
    # makes the timer-driven model cheap when nothing has changed.
    local compose_args=(-p "$project" -f "$compose_file")
    [ -f "$env_file" ] && compose_args+=(--env-file "$env_file")

    local before after running
    before=$(compose_image_ids "${compose_args[@]}")

    if ! "${DOCKER_COMPOSE[@]}" "${compose_args[@]}" pull --quiet 2>&1 | sed "s/^/[$project]   pull: /"; then
        err "[$project] docker compose pull failed"
        return 1
    fi

    after=$(compose_image_ids "${compose_args[@]}")
    running=$(compose_running_count "${compose_args[@]}")

    if [ "$before" = "$after" ] && [ "$running" -gt 0 ]; then
        log "[$project]   no change — current images already running"
        return 0
    fi

    # ─── Deploy ───────────────────────────────────────────────────────────
    log "[$project]   deploying (images changed or stack not running)"

    # Two passes:
    #   1. up -d  → applies any compose/env/network/volume changes across
    #               the whole stack idempotently.
    #   2. up -d --force-recreate --no-deps <site>  → replaces the site
    #               container even when its image: ref didn't change but
    #               the digest behind a rolling tag did. --no-deps avoids
    #               churning Caddy + sveltia-auth (no brief routing gap).
    if ! "${DOCKER_COMPOSE[@]}" "${compose_args[@]}" up -d --wait 2>&1 \
        | sed "s/^/[$project]   up: /"; then
        err "[$project] docker compose up failed (first pass)"
        return 1
    fi

    if ! "${DOCKER_COMPOSE[@]}" "${compose_args[@]}" up -d --wait \
            --force-recreate --no-deps "$SITE_SERVICE" 2>&1 \
        | sed "s/^/[$project]   recreate: /"; then
        err "[$project] docker compose force-recreate failed (second pass)"
        return 1
    fi

    # ─── Post-deploy ──────────────────────────────────────────────────────
    cf_purge "${CF_API_TOKEN:-}" "${CF_ZONE_ID:-}"
    docker image prune -f > /dev/null 2>&1 || true

    log "[$project]   deploy ok"
    return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    if ! probe_capabilities; then
        err "capability probe failed — aborting"
        exit 2
    fi

    mkdir -p "$LOCK_DIR" "$STATE_DIR"

    if [ ! -d "$SITES_DIR" ]; then
        err "$SITES_DIR not found — no sites configured"
        exit 1
    fi

    local configs=()
    local f
    for f in "$SITES_DIR"/*.env; do
        [ -e "$f" ] && configs+=("$f")
    done

    if [ "${#configs[@]}" -eq 0 ]; then
        log "no site configs in $SITES_DIR — nothing to do"
        exit 0
    fi

    log "agent: ${#configs[@]} site config(s) found"

    local overall=0 config
    for config in "${configs[@]}"; do
        # Subshell isolates sourced variables and the per-site flock fd
        # from the next iteration.
        if ! ( deploy_site "$config" ); then
            overall=1
        fi
    done

    if [ "$overall" -ne 0 ]; then
        err "agent: at least one site failed"
    else
        log "agent: all sites ok"
    fi
    exit "$overall"
}

main "$@"
