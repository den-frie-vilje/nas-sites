#!/usr/bin/env bash
# End-to-end test rig for the synology_dsm_local acme.sh deploy hook,
# without a DSM box: real acme.sh + real ACME wildcard issuance against
# Pebble (Let's Encrypt's test CA) with dns-01 validation via
# pebble-challtestsrv, deploying into a mock synowebapi (see
# mock-synowebapi in this directory) that reproduces DSM 7.2 cert-store
# semantics — including the two behaviours that matter:
#
#   - import with id= replaces a slot in place, keeping service bindings;
#     import without id= creates a NEW slot with nothing bound to it;
#   - list output prints object keys alphabetically, so "desc" precedes
#     "id" (this order broke the hook's original id lookup).
#
# The scenario is the production incident of July 2026: operator deploys
# once with SYNO_* env vars set, binds services to the slot in the DSM
# GUI, then DSM Task Scheduler renews with a CLEAN environment. The rig
# asserts that after that renewal the bound slot serves the renewed
# certificate and no orphan slot exists.
#
# Requirements: root in a DISPOSABLE container (it writes a mock to
# /usr/syno/bin/synowebapi), bash, curl, git, openssl, python3, and
# network access to github.com on first run (acme.sh + Pebble are
# fetched into test/work/, which is gitignored).
#
# Usage:
#   run-harness.sh [path-to-hook-file]   # default: ../synology_dsm_local.sh
#
# Exit 0 = renewal correctly replaced the bound cert slot.
# Exit 1 = the bug: renewal left the bound slot serving the old cert.
# Exit 2 = rig failure (issuance or initial deploy broke).

set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="${1:-$RIG/../synology_dsm_local.sh}"
WORK="$RIG/work"
ACME_SRC="$WORK/acme.sh"
ACME_HOME="$WORK/test-acme-home"
export SYNO_MOCK_STATE="$WORK/mock-state.json"
export SYNO_MOCK_LOG="$WORK/mock-synowebapi.log"
DOMAIN="site.dfv.test"
DESC="wildcard-test"
PEBBLE_VERSION="v2.6.0"
export no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost"

say() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (writes /usr/syno/bin)"; exit 2; }
[ -f "$HOOK_FILE" ] || { echo "hook file not found: $HOOK_FILE"; exit 2; }

# ---- fetch dependencies (first run only) -----------------------------------
mkdir -p "$WORK/bin"
if [ ! -d "$ACME_SRC" ]; then
  say "fetching acme.sh"
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$ACME_SRC"
fi
for tool in pebble pebble-challtestsrv; do
  if [ ! -x "$WORK/bin/$tool" ]; then
    say "fetching $tool $PEBBLE_VERSION"
    curl -sSL "https://github.com/letsencrypt/pebble/releases/download/$PEBBLE_VERSION/$tool-linux-amd64.tar.gz" \
      | tar xz -C "$WORK" "$tool-linux-amd64/linux/amd64/$tool"
    mv "$WORK/$tool-linux-amd64/linux/amd64/$tool" "$WORK/bin/$tool"
    rm -rf "$WORK/$tool-linux-amd64"
    chmod +x "$WORK/bin/$tool"
  fi
done

# ---- clean slate -----------------------------------------------------------
pkill -f pebble-challtestsrv 2>/dev/null; pkill -f 'bin/pebble' 2>/dev/null
sleep 0.5
rm -rf "$ACME_HOME" "$SYNO_MOCK_STATE" "$SYNO_MOCK_LOG"

# ---- mock DSM binary -------------------------------------------------------
mkdir -p /usr/syno/bin
cp "$RIG/mock-synowebapi" /usr/syno/bin/synowebapi
chmod +x /usr/syno/bin/synowebapi

# ---- pebble + challtestsrv -------------------------------------------------
if [ ! -f "$WORK/pebble-https.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$WORK/pebble-https.key" -out "$WORK/pebble-https.pem" \
    -days 30 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
fi
cat > "$WORK/pebble-config.json" <<EOF
{"pebble": {
  "listenAddress": "127.0.0.1:14000",
  "managementListenAddress": "127.0.0.1:15000",
  "certificate": "$WORK/pebble-https.pem",
  "privateKey": "$WORK/pebble-https.key",
  "httpPort": 5002, "tlsPort": 5001,
  "ocspResponderURL": "", "externalAccountBindingRequired": false
}}
EOF
"$WORK/bin/pebble-challtestsrv" -dns01 ":8053" -management ":8055" \
  -http01 "" -https01 "" -tlsalpn01 "" -doh "" \
  > "$WORK/challtestsrv.log" 2>&1 &
PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 \
  "$WORK/bin/pebble" -config "$WORK/pebble-config.json" \
  -dnsserver 127.0.0.1:8053 -strict \
  > "$WORK/pebble.log" 2>&1 &
for i in $(seq 1 50); do
  curl -s --cacert "$WORK/pebble-https.pem" https://127.0.0.1:14000/dir >/dev/null && break
  sleep 0.2
done

# ---- acme.sh install + hooks ----------------------------------------------
say "installing acme.sh into $ACME_HOME"
(cd "$ACME_SRC" && ./acme.sh --install --home "$ACME_HOME" --nocron --noprofile \
  --accountemail ops@dfv.test >/dev/null 2>&1)
cp "$RIG/dns_cts.sh" "$ACME_HOME/dnsapi/dns_cts.sh"
cp "$HOOK_FILE" "$ACME_HOME/deploy/synology_dsm_local.sh"
ACME="$ACME_HOME/acme.sh"

# ---- issue wildcard cert (real ACME, dns-01) -------------------------------
say "issuing $DOMAIN + *.$DOMAIN via Pebble"
"$ACME" --home "$ACME_HOME" --server https://127.0.0.1:14000/dir \
  --ca-bundle "$WORK/pebble-https.pem" \
  --issue --dns dns_cts -d "$DOMAIN" -d "*.$DOMAIN" \
  --dnssleep 2 --keylength ec-256 --log "$ACME_HOME/acme.log" >/dev/null 2>&1 \
  || { echo "ISSUE FAILED"; tail -30 "$ACME_HOME/acme.log"; exit 2; }

# ---- initial deploy, as the operator runs it (env vars set) ----------------
say "initial deploy with SYNO_Certificate=$DESC SYNO_Create=1"
SYNO_Certificate="$DESC" SYNO_Create=1 \
  "$ACME" --home "$ACME_HOME" --deploy -d "$DOMAIN" --ecc \
  --deploy-hook synology_dsm_local \
  || { echo "INITIAL DEPLOY FAILED"; exit 2; }

# ---- operator binds services to the slot in the DSM GUI --------------------
python3 - <<EOF
import json
s = json.load(open("$SYNO_MOCK_STATE"))
slots = [c for c in s["certificates"] if c["desc"] == "$DESC"]
assert len(slots) == 1, f"expected 1 slot named $DESC, got {len(slots)}"
slots[0]["services"] = [{"display_name": "Web Station vhosts", "service": "default"}]
json.dump(s, open("$SYNO_MOCK_STATE", "w"), indent=2, sort_keys=True)
EOF
FP_BEFORE=$(python3 -c "
import json
s = json.load(open('$SYNO_MOCK_STATE'))
print([c['fingerprint'] for c in s['certificates'] if c['services']][0])")
say "services bound; serving fingerprint: $FP_BEFORE"

# ---- simulated DSM Task Scheduler renewal: clean env, no SYNO_* vars -------
say "simulated scheduled renewal (clean environment, --cron --force)"
env -i PATH="$PATH" HOME="$HOME" no_proxy="$no_proxy" NO_PROXY="$NO_PROXY" \
  SYNO_MOCK_STATE="$SYNO_MOCK_STATE" SYNO_MOCK_LOG="$SYNO_MOCK_LOG" \
  "$ACME" --home "$ACME_HOME" --cron --force \
  --ca-bundle "$WORK/pebble-https.pem" >"$WORK/cron.log" 2>&1
CRON_RC=$?
grep -E "Deploy|error|Error" "$WORK/cron.log" | tail -5

# ---- verdict ---------------------------------------------------------------
say "verdict"
FP_LIVE=$(openssl x509 -noout -fingerprint -sha256 \
  -in "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.cer" | cut -d= -f2)
python3 - "$FP_LIVE" "$CRON_RC" "$FP_BEFORE" <<'EOF'
import json, os, sys
fp_live, cron_rc, fp_before = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = json.load(open(os.environ["SYNO_MOCK_STATE"]))
certs = s["certificates"]
bound = [c for c in certs if c["services"]]
print(f"cron exit code:        {cron_rc}")
print(f"cert slots in DSM:     {len(certs)}")
for c in certs:
    tag = "BOUND, serving" if c["services"] else "orphan, serves nothing"
    fresh = "NEW cert" if c["fingerprint"] == fp_live else "OLD cert"
    print(f"  id={c['id']} desc={c['desc']!r:20} [{tag}] [{fresh}]")
ok = (len(bound) == 1 and bound[0]["fingerprint"] == fp_live
      and fp_live != fp_before and len(certs) == 1 and cron_rc == 0)
print("\nRESULT:", "PASS — renewal replaced the bound slot in place"
      if ok else "FAIL — DSM still serves the pre-renewal certificate")
sys.exit(0 if ok else 1)
EOF
