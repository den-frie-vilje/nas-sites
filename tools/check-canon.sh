#!/usr/bin/env bash
# check-canon.sh: measure every site in tools/canon-sites.txt against the
# patterns in docs/SITE-CANON.md and print the fleet scorecard.
#
# Repository probes read the site's staging branch through the GitHub API
# (gh CLI, authenticated); origin probes curl the live staging host. The
# script needs gh, curl, and jq. It changes nothing anywhere.
#
# Usage: tools/check-canon.sh [--strict]
#   --strict  exit 1 if any probe FAILs (default always exits 0; WARN never fails)
set -euo pipefail

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

HERE="$(cd "$(dirname "$0")" && pwd)"
SITES_FILE="$HERE/canon-sites.txt"
FAILS=0

# Newest release tag on this repository, for the SC-5 pin-freshness probe.
# sort -V so v10 beats v9; empty when no tag has been released yet.
LATEST_TAG="$(gh api repos/den-frie-vilje/nas-sites/tags --jq '.[].name' 2>/dev/null | sort -V | tail -1 || true)"

# fetch_file <repo> <path> -> file body on stdout, empty if absent
fetch_file() {
  gh api "repos/$1/contents/$2?ref=staging" --jq .content 2>/dev/null | base64 -d 2>/dev/null || true
}

# verdict <sc> <PASS|FAIL|WARN|NA> <detail>
verdict() {
  printf '  %-5s %-4s %s\n' "$1" "$2" "$3"
  [ "$2" = "FAIL" ] && FAILS=$((FAILS + 1)) || true
}

while read -r REPO STAGE_HOST _PROD_HOST; do
  case "$REPO" in ''|\#*) continue ;; esac
  echo "== $REPO ($STAGE_HOST)"

  ROBOTS_ROUTE="$(fetch_file "$REPO" "src/routes/robots.txt/+server.ts")"
  ROBOTS_BODY="$(curl -fsS --max-time 20 "https://$STAGE_HOST/robots.txt" 2>/dev/null || true)"
  HEADERS="$(curl -fsSI --max-time 20 "https://$STAGE_HOST/" 2>/dev/null || true)"
  HOME_HTML="$(curl -fsS --max-time 20 "https://$STAGE_HOST/" 2>/dev/null || true)"

  # SC-1 fail-closed robots route
  if [ -z "$ROBOTS_ROUTE" ]; then
    verdict SC-1 FAIL "no src/routes/robots.txt/+server.ts on staging"
  elif ! grep -q "=== 'true'" <<<"$ROBOTS_ROUTE" || ! grep -q '\$env/static/public' <<<"$ROBOTS_ROUTE"; then
    verdict SC-1 FAIL "route exists but is not the fail-closed static-env compare"
  elif ! grep -q '^Disallow: /$' <<<"$ROBOTS_BODY" || grep -q '^Sitemap:' <<<"$ROBOTS_BODY"; then
    verdict SC-1 FAIL "staging origin robots is not Disallow-all without advert"
  else
    verdict SC-1 PASS "fail-closed route; staging origin bakes Disallow-all, no advert"
  fi

  # SC-2 per-mode env contract
  ENV_STAGING="$(fetch_file "$REPO" ".env.staging")"
  ENV_PROD="$(fetch_file "$REPO" ".env.production")"
  PKG="$(fetch_file "$REPO" "package.json")"
  DOCKERFILE="$(fetch_file "$REPO" "deploy/Dockerfile")"
  if [ -z "$ENV_STAGING" ] || [ -z "$ENV_PROD" ]; then
    verdict SC-2 FAIL "committed .env.staging/.env.production missing"
  elif ! grep -q '^PUBLIC_ALLOW_INDEXING=false' <<<"$ENV_STAGING" || ! grep -q '^PUBLIC_ALLOW_INDEXING=true' <<<"$ENV_PROD"; then
    verdict SC-2 FAIL "PUBLIC_ALLOW_INDEXING not false/true across staging/production"
  elif grep -q 'build -- --mode' <<<"$PKG$(grep -v '^\s*#' <<<"$DOCKERFILE")"; then
    verdict SC-2 FAIL "swallowed 'build -- --mode' present outside comments (silently builds production)"
  else
    verdict SC-2 PASS "per-mode env files committed; no swallowed --mode"
  fi

  # SC-3 staging noindex header backstop
  CADDY="$(fetch_file "$REPO" "deploy/Caddyfile.staging")"
  if ! grep -qi 'X-Robots-Tag' <<<"$CADDY"; then
    verdict SC-3 FAIL "no X-Robots-Tag in deploy/Caddyfile.staging"
  elif ! grep -qi '^x-robots-tag' <<<"$HEADERS"; then
    verdict SC-3 WARN "directive in repo but header not served on staging origin yet"
  else
    verdict SC-3 PASS "header in repo and served on staging origin"
  fi

  # SC-4 git-sha meta
  APP_HTML="$(fetch_file "$REPO" "src/app.html")"
  if ! grep -q 'name="git-sha"' <<<"$APP_HTML"; then
    verdict SC-4 FAIL "src/app.html carries no git-sha meta"
  elif ! grep -q 'name="git-sha" content="[0-9a-f]' <<<"$HOME_HTML"; then
    verdict SC-4 WARN "meta in repo but staging origin serves no populated sha yet"
  else
    verdict SC-4 PASS "git-sha meta in repo and populated on staging origin"
  fi

  # SC-5 reusable workflow pinned by the newest nas-sites tag.
  # A pin that is a tag but not the newest is WARN, so a pin cannot rot
  # unseen; a branch pin is FAIL once any tag exists.
  WFS="$(gh api "repos/$REPO/contents/.github/workflows?ref=staging" --jq '.[].name' 2>/dev/null || true)"
  if [ -z "$LATEST_TAG" ]; then
    verdict SC-5 WARN "no tag released on nas-sites yet, nothing to pin to"
  else
    PIN_STATE="PASS"; PIN_DETAIL="all build-and-sign callers pin $LATEST_TAG"
    SEEN=0
    for WF in $WFS; do
      W="$(fetch_file "$REPO" ".github/workflows/$WF")"
      for REF in $(grep -oE 'build-and-sign\.yml@[A-Za-z0-9._-]+' <<<"$W" | cut -d@ -f2); do
        SEEN=$((SEEN + 1))
        [ "$REF" = "$LATEST_TAG" ] && continue
        if grep -qE '^v[0-9]' <<<"$REF"; then
          [ "$PIN_STATE" != "FAIL" ] && {
            PIN_STATE="WARN"
            PIN_DETAIL="$WF pins $REF, behind the newest tag $LATEST_TAG"
          }
        else
          PIN_STATE="FAIL"
          PIN_DETAIL="$WF pins the branch '$REF', not a tag"
        fi
      done
    done
    # Fail closed: reading nothing is not conformance. An unreadable
    # workflow list or a missing caller must not report PASS.
    if [ "$SEEN" -eq 0 ]; then
      PIN_STATE="FAIL"
      PIN_DETAIL="no build-and-sign caller found (workflows unreadable or absent)"
    fi
    verdict SC-5 "$PIN_STATE" "$PIN_DETAIL"
  fi

  # SC-6 canon mirror
  if [ -n "$(fetch_file "$REPO" "AGENTS.md")" ]; then
    verdict SC-6 PASS "AGENTS.md present at root"
  else
    verdict SC-6 WARN "AGENTS.md absent (rollout pending, proposed pattern)"
  fi

  # SC-8 a reachable editor sign-in. Only sites with a git-CMS are in scope,
  # and the config itself is what says so — no site list to keep in step.
  CMS_CFG="$(fetch_file "$REPO" "static/admin/config.yml")"
  if [ -z "$CMS_CFG" ]; then
    : # no CMS, nothing to sign in to
  elif ! printf '%s' "$CMS_CFG" | grep -q "base_url:"; then
    verdict SC-8 PASS "CMS present, no base_url — no proxy required"
  else
    SC8_STATE="PASS"; SC8_DETAIL="sign-in served: proxy, stripping route, documented credentials"
    COMPOSE="$(fetch_file "$REPO" "deploy/compose.staging.yml")"
    CADDY="$(fetch_file "$REPO" "deploy/Caddyfile.staging")"
    ENVX="$(fetch_file "$REPO" "deploy/staging.env.example")"
    if ! printf '%s' "$COMPOSE" | grep -qi "auth:"; then
      SC8_STATE="FAIL"; SC8_DETAIL="compose.staging.yml declares no auth proxy; sign-in 404s"
    elif ! printf '%s' "$CADDY" | grep -q "handle_path /auth/\*"; then
      SC8_STATE="FAIL"
      if printf '%s' "$CADDY" | grep -q "handle /auth/\*"; then
        SC8_DETAIL="/auth routed with handle, which keeps the prefix; needs handle_path"
      else
        SC8_DETAIL="Caddyfile.staging routes nothing to /auth/*"
      fi
    elif ! printf '%s' "$ENVX" | grep -q "OAUTH_CLIENT_SECRET"; then
      SC8_STATE="FAIL"; SC8_DETAIL="staging.env.example does not document the OAuth credentials"
    fi
    verdict SC-8 "$SC8_STATE" "$SC8_DETAIL"
  fi

  echo
done < "$SITES_FILE"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS probe(s) FAILed."
  [ "$STRICT" -eq 1 ] && exit 1
else
  echo "No FAILs."
fi
exit 0
