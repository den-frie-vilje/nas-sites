#!/usr/bin/env bash
# acme.sh dnsapi hook for pebble-challtestsrv (test rig only).
# Sets/clears TXT records via the challenge test server's management API
# so Pebble's dns-01 validation (pointed at challtestsrv's DNS) succeeds.

CTS_MGMT="${CTS_MGMT:-http://127.0.0.1:8055}"

dns_cts_add() {
  fulldomain="$1"
  txtvalue="$2"
  _info "dns_cts: set-txt ${fulldomain} -> ${txtvalue}"
  response=$(curl -s -X POST "$CTS_MGMT/set-txt" \
    -d "{\"host\":\"${fulldomain}.\",\"value\":\"${txtvalue}\"}")
  _debug response "$response"
  return 0
}

dns_cts_rm() {
  fulldomain="$1"
  txtvalue="$2"
  _info "dns_cts: clear-txt ${fulldomain}"
  curl -s -X POST "$CTS_MGMT/clear-txt" \
    -d "{\"host\":\"${fulldomain}.\"}" >/dev/null
  return 0
}
