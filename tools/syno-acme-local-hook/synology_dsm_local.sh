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
# ENV:
#   SYNO_Certificate   — REQUIRED on the first --deploy: friendly name of the
#                        DSM cert slot to bind to (e.g. "wildcard-prod").
#                        Persisted by acme.sh in the cert's deploy conf, so
#                        scheduled renewals reuse it without any env set.
#                        Importing without a name would create a new unbound
#                        slot on every renewal, so an empty name is an error.
#   SYNO_Create        — set to "1" to create the cert slot if it doesn't
#                        exist. Without this, an unknown SYNO_Certificate
#                        is an error. Persisted like SYNO_Certificate.
#   SYNO_Default       — set to "1" to mark the imported cert as DSM's
#                        default. Default 0 (don't change default state).
#                        Persisted like SYNO_Certificate.
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

# Extract the id of the certificate whose desc equals $2 from the JSON in
# $1 (output of SYNO.Core.Certificate.CRT list). synowebapi emits object
# keys alphabetically, so "desc" precedes "id"; a line-oriented scan that
# remembers the last-seen id therefore pairs a desc with the PREVIOUS
# cert's id. Instead, split the JSON at every '}' — desc and id are
# adjacent top-level keys of each certificate object, with only nested
# objects (issuer, subject, services) after them, so both always land in
# the same fragment — and match the two fields in either order.
_syno_cert_id_by_desc() {
    printf '%s' "$1" | awk -v want="$2" '
        BEGIN { RS = "}" }
        {
            id = ""; d = ""; found_d = 0
            if (match($0, /"id"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^"id"[[:space:]]*:[[:space:]]*"/, "", s); sub(/"$/, "", s)
                id = s
            }
            if (match($0, /"desc"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^"desc"[[:space:]]*:[[:space:]]*"/, "", s); sub(/"$/, "", s)
                d = s; found_d = 1
            }
            if (found_d && d == want && id != "") { print id; exit }
        }'
}

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

    # Capability probe — root first: DSM makes synowebapi executable only
    # by root, so for a non-root user the -x test below fails even though
    # the binary exists, and "not found" would point the operator at the
    # wrong problem. Note acme.sh refuses plain `sudo acme.sh`; use a root
    # shell (sudo su / sudo -i) and pass --home, since root's default
    # acme.sh home is /root/.acme.sh, not the installing user's.
    if [ "$(id -u)" -ne 0 ]; then
        _err "synology_dsm_local: must run as root. acme.sh refuses plain sudo; use a root shell:"
        _err "  sudo su -c \"<acme-home>/acme.sh --home <acme-home> --deploy -d '$_cdomain' --deploy-hook synology_dsm_local\""
        return 1
    fi
    if [ ! -x /usr/syno/bin/synowebapi ]; then
        _err "synology_dsm_local: /usr/syno/bin/synowebapi not found — this hook only works on DSM."
        return 1
    fi

    # Config handling. On an operator-run `--deploy` these come from the
    # environment; acme.sh then persists them (via _savedeployconf below) in
    # the cert's own conf so scheduled renewals — which run with a clean
    # environment — restore them here with _getdeployconf. Without this
    # round-trip a renewal would import with no name and no id, and DSM
    # would file the new cert in a fresh unbound slot while every service
    # kept serving the old, expiring cert.
    _getdeployconf SYNO_Certificate
    _getdeployconf SYNO_Create
    _getdeployconf SYNO_Default
    _syno_desc="${SYNO_Certificate:-}"
    _syno_create="${SYNO_Create:-0}"
    _syno_default="${SYNO_Default:-0}"

    if [ -z "$_syno_desc" ]; then
        _err "synology_dsm_local: SYNO_Certificate is not set (env or saved deploy conf)."
        _err "A friendly name is required so renewals replace the same DSM cert slot"
        _err "instead of creating a new unbound one. Run once with:"
        _err "  SYNO_Certificate=<name> [SYNO_Create=1] acme.sh --deploy -d $_cdomain --deploy-hook synology_dsm_local"
        return 1
    fi

    _info "synology_dsm_local: importing certificate for $_cdomain into slot '$_syno_desc'"
    _list=$(/usr/syno/bin/synowebapi --exec-fastwebapi \
        api=SYNO.Core.Certificate.CRT method=list version=1 2>&1) || {
        _err "synology_dsm_local: SYNO.Core.Certificate.CRT list failed"
        _err "$_list"
        return 1
    }
    _existing_id=$(_syno_cert_id_by_desc "$_list" "$_syno_desc")
    if [ -z "$_existing_id" ] && [ "$_syno_create" != "1" ]; then
        _err "synology_dsm_local: no cert with desc='$_syno_desc' and SYNO_Create not set."
        _err "Set SYNO_Create=1 to create a new cert slot, or pick an existing SYNO_Certificate."
        return 1
    fi

    # Stage the files under plain names before importing. Over HTTP the
    # import handler only ever receives uploaded temp files with tame
    # names; handed acme.sh's real paths it rejects wildcard certs, whose
    # primary name puts a literal '*' in every path
    # (.../*.example.com_ecc/*.example.com.key), with 5511 "illegal key
    # file" (observed on DSM 7.2.2; codes per zaxbux/syno-acme:
    # 5510 = illegal certificate file, 5511 = illegal key file,
    # 5512 = illegal intermediate file).
    _tmp_dir="$(mktemp -d /tmp/synology_dsm_local.XXXXXX)" || {
        _err "synology_dsm_local: mktemp failed"
        return 1
    }
    chmod 700 "$_tmp_dir"
    if ! cp "$_ckey" "$_tmp_dir/privkey.pem" \
        || ! cp "$_ccert" "$_tmp_dir/cert.pem"; then
        _err "synology_dsm_local: failed to stage cert files into $_tmp_dir"
        rm -rf "$_tmp_dir"
        return 1
    fi
    [ -f "$_cca" ] && cp "$_cca" "$_tmp_dir/chain.pem"
    chmod 600 "$_tmp_dir"/*.pem

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
        "key_tmp=$_tmp_dir/privkey.pem"
        "cert_tmp=$_tmp_dir/cert.pem"
        "as_default=$_as_default"
    )
    [ -f "$_tmp_dir/chain.pem" ] && _import_args+=("inter_cert_tmp=$_tmp_dir/chain.pem")
    [ -n "$_existing_id" ] && _import_args+=("id=$_existing_id")
    [ -n "$_syno_desc" ]   && _import_args+=("desc=$_syno_desc")

    _info "synology_dsm_local: synowebapi --exec-fastwebapi ${_import_args[*]}"
    _result=$(/usr/syno/bin/synowebapi --exec-fastwebapi "${_import_args[@]}" 2>&1)
    _import_rc=$?
    rm -rf "$_tmp_dir"
    if [ "$_import_rc" -ne 0 ]; then
        _err "synology_dsm_local: cert import failed"
        _err "$_result"
        return 1
    fi

    # synowebapi returns {"success":true,...} on success and {"success":false,
    # "error":{"code":N,...}} on failure. Refuse to silently treat anything
    # other than success:true as a win.
    if ! printf '%s' "$_result" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        _err "synology_dsm_local: synowebapi returned non-success:"
        _err "$_result"
        return 1
    fi

    # Post-import verification: re-list and confirm the friendly name now
    # resolves to a slot — and, when we replaced an existing slot, to the
    # SAME slot. "success:true with the cert filed somewhere else" is this
    # hook's worst failure mode (services silently keep the old cert), so
    # it must fail loudly rather than report a clean deploy.
    _list=$(/usr/syno/bin/synowebapi --exec-fastwebapi \
        api=SYNO.Core.Certificate.CRT method=list version=1 2>&1) || {
        _err "synology_dsm_local: post-import list failed"
        _err "$_list"
        return 1
    }
    _final_id=$(_syno_cert_id_by_desc "$_list" "$_syno_desc")
    if [ -z "$_final_id" ]; then
        _err "synology_dsm_local: import reported success but no cert with desc='$_syno_desc' exists."
        _err "$_list"
        return 1
    fi
    if [ -n "$_existing_id" ] && [ "$_final_id" != "$_existing_id" ]; then
        _err "synology_dsm_local: import landed in slot '$_final_id' instead of replacing '$_existing_id'."
        _err "Services bound to '$_existing_id' would keep serving the old certificate."
        return 1
    fi

    # Persist the config in the cert's deploy conf so the next scheduled
    # renewal, running with a clean environment, targets the same slot.
    _savedeployconf SYNO_Certificate "$_syno_desc" "base64"
    _savedeployconf SYNO_Create "$_syno_create"
    _savedeployconf SYNO_Default "$_syno_default"

    _info "synology_dsm_local: cert imported OK into slot '$_syno_desc' (id=$_final_id)"
    return 0
}
