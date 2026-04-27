#!/usr/bin/env bash
# acme.sh deploy hook: import a renewed certificate into the DSM cert store
# using the local synowebapi binary instead of the HTTP-based synology_dsm
# hook that ships with acme.sh.
#
# WHY: the upstream synology_dsm hook needs a DSM admin username and
# password (and either disabled 2FA or a temporary admin user) stored in
# acme.sh's account.conf — i.e. an on-disk credential with full DSM admin
# rights. This hook bypasses HTTP entirely and calls synowebapi as root,
# which DSM permits without re-authenticating. No on-disk credential.
#
# Use exactly like the stock hook:
#   acme.sh --deploy -d <domain> --deploy-hook synology_dsm_local
#
# Install with: tools/syno-acme-local-hook/install.sh
# (which copies this file into ~/.acme.sh/deploy/ and sets it executable).
#
# ENV (all optional):
#   SYNO_Certificate   — friendly name to bind to (e.g. "wildcard-prod"). If
#                        unset, this hook lets DSM auto-name the cert.
#   SYNO_Create        — set to "1" to create the cert slot if it doesn't
#                        exist. Without this, an unknown SYNO_Certificate
#                        is an error.
#   SYNO_Default       — set to "1" to mark the imported cert as DSM's
#                        default. Default 0 (don't change default state).
#
# Compatibility note: this hook was tested against DSM 7.2.2. The
# synowebapi cert-import call is undocumented but has been stable across
# DSM 7.0 → 7.2.x as used by zaxbux/syno-acme and the upstream acme.sh
# hook over HTTP. If a future DSM major release breaks it, the failure
# will be loud — synowebapi prints a JSON error and this hook exits
# non-zero, which acme.sh treats as a failed deploy and will not silently
# leave a stale cert in place.

# acme.sh's deploy_hook contract: define a function named
# `synology_dsm_local_deploy` taking (domain, key_file, cert_file, ca_file,
# fullchain_file). It runs in acme.sh's bash context with the _info / _err
# helpers available.

synology_dsm_local_deploy() {
    _cdomain="$1"
    _ckey="$2"
    _ccert="$3"
    _cca="$4"
    _cfullchain="$5"

    _debug _cdomain    "$_cdomain"
    _debug _ckey       "$_ckey"
    _debug _ccert      "$_ccert"
    _debug _cca        "$_cca"
    _debug _cfullchain "$_cfullchain"

    # Capability probe — fail clearly if we're not on DSM or synowebapi
    # isn't reachable.
    if [ ! -x /usr/syno/bin/synowebapi ]; then
        _err "synology_dsm_local: /usr/syno/bin/synowebapi not found — this hook only works on DSM."
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        _err "synology_dsm_local: must run as root (try: sudo acme.sh ...)"
        return 1
    fi

    # Friendly-name handling. If SYNO_Certificate is unset, list existing
    # certs and let DSM auto-name. If set, look up the existing id; if
    # missing and SYNO_Create=1, create with this name.
    _syno_desc="${SYNO_Certificate:-}"
    _syno_create="${SYNO_Create:-0}"
    _syno_default="${SYNO_Default:-0}"

    _info "synology_dsm_local: importing certificate for $_cdomain"
    _existing_id=""
    if [ -n "$_syno_desc" ]; then
        # SYNO.Core.Certificate.CRT method=list returns JSON. Extract id by
        # matching desc field; case-sensitive match on the friendly name.
        _list=$(/usr/syno/bin/synowebapi --exec-fastwebapi \
            api=SYNO.Core.Certificate.CRT method=list version=1 2>&1) || {
            _err "synology_dsm_local: SYNO.Core.Certificate.CRT list failed"
            _err "$_list"
            return 1
        }
        # crude JSON extraction sufficient for `desc` field. Quoted, no nested
        # objects expected at this level.
        _existing_id=$(printf '%s' "$_list" \
            | tr ',' '\n' \
            | awk -v desc="$_syno_desc" '
                /"id"/  {gsub(/[":,]/, ""); split($0, a, " "); cur_id=a[2]}
                /"desc"/{gsub(/[":,]/, ""); split($0, a, " "); if (a[2] == desc) print cur_id}
              ' \
            | head -n1)
        if [ -z "$_existing_id" ] && [ "$_syno_create" != "1" ]; then
            _err "synology_dsm_local: no cert with desc='$_syno_desc' and SYNO_Create not set."
            _err "Set SYNO_Create=1 to create a new cert slot, or pick an existing SYNO_Certificate."
            return 1
        fi
    fi

    # Build the import call. Args:
    #   key_tmp     = private key file
    #   cert_tmp    = leaf cert file
    #   inter_cert_tmp = chain (intermediates), optional
    #   id          = existing cert id, "" to create new
    #   desc        = friendly name
    #   as_default  = "true" / "false"
    _as_default="false"; [ "$_syno_default" = "1" ] && _as_default="true"

    _import_args=(
        api=SYNO.Core.Certificate
        method=import
        version=1
        "key_tmp=$_ckey"
        "cert_tmp=$_ccert"
        "as_default=$_as_default"
    )
    [ -f "$_cca" ] && _import_args+=("inter_cert_tmp=$_cca")
    [ -n "$_existing_id" ] && _import_args+=("id=$_existing_id")
    [ -n "$_syno_desc" ]   && _import_args+=("desc=$_syno_desc")

    _info "synology_dsm_local: synowebapi --exec-fastwebapi ${_import_args[*]}"
    _result=$(/usr/syno/bin/synowebapi --exec-fastwebapi "${_import_args[@]}" 2>&1) || {
        _err "synology_dsm_local: cert import failed"
        _err "$_result"
        return 1
    }

    # synowebapi returns {"success":true,...} on success and {"success":false,
    # "error":{"code":N,...}} on failure. Refuse to silently treat anything
    # other than success:true as a win.
    if printf '%s' "$_result" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        _info "synology_dsm_local: cert imported OK"
        return 0
    fi

    _err "synology_dsm_local: synowebapi returned non-success:"
    _err "$_result"
    return 1
}
