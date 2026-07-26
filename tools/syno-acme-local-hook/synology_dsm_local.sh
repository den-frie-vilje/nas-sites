#!/usr/bin/env bash
# acme.sh deploy hook: put a renewed certificate into the DSM cert store
# locally, without the HTTP-based synology_dsm hook that ships with acme.sh.
#
# WHY: the upstream synology_dsm hook needs a DSM admin username and
# password (and either disabled 2FA or a temporary admin user) stored in
# acme.sh's account.conf — i.e. an on-disk credential with full DSM admin
# rights. This hook works entirely locally as root. No on-disk credential.
#
# HOW (established by on-NAS probing on DSM 7.2.2, July 2026 — see
# docs/SYNOTOOLS-HARDENING.md for the probe record):
#
#   - Finding and CREATING cert slots works through the local synowebapi
#     binary (SYNO.Core.Certificate.CRT list / SYNO.Core.Certificate
#     import without id).
#   - REPLACING an existing slot via synowebapi import id=... always
#     fails with {"error":{"code":5511}} on DSM 7.2.2, whatever the file
#     location, name, or key format. Replacement is therefore done the
#     way the DSM community has done it for years: overwrite the PEM
#     files in /usr/syno/etc/certificate/_archive/<id>/, propagate to
#     every service directory holding a copy of the same cert (matched
#     by fingerprint under /usr/syno/etc/certificate and
#     /usr/local/etc/certificate), regenerate the web config with
#     synow3tool --gen-all, and restart nginx. Service bindings live in
#     the _archive/INFO file keyed by slot id and are untouched.
#
# Use exactly like the stock hook:
#   acme.sh --deploy -d <domain> --deploy-hook synology_dsm_local
#
# Install with: tools/syno-acme-local-hook/install.sh
# (which copies this file into <acme-home>/deploy/ and sets it executable).
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
#   SYNO_Default       — set to "1" to mark a NEWLY CREATED slot as DSM's
#                        default. Replacing an existing slot never changes
#                        its default status. Persisted like SYNO_Certificate.

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

_syno_fp() {
    openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null
}

# Replace the PEM files of an existing slot in place: the _archive/<id>
# directory plus every service directory currently holding a copy of the
# same certificate. All touched files are backed up under $2/backup and
# restored if the copy or its verification fails, so a broken run cannot
# leave the store half-written.
_syno_replace_slot_files() {
    _rid="$1"
    _stage="$2"
    _arch="/usr/syno/etc/certificate/_archive/$_rid"

    if [ ! -f "$_arch/cert.pem" ] || [ ! -f "$_arch/privkey.pem" ]; then
        _err "synology_dsm_local: $_arch has no cert.pem/privkey.pem — slot id '$_rid' has no archive dir."
        return 1
    fi
    _old_fp=$(_syno_fp "$_arch/cert.pem")
    _new_fp=$(_syno_fp "$_stage/cert.pem")
    if [ -z "$_new_fp" ]; then
        _err "synology_dsm_local: cannot fingerprint staged cert $_stage/cert.pem"
        return 1
    fi

    # The archive dir, plus every service dir serving a copy of the old
    # cert. Fingerprint matching sidesteps parsing _archive/INFO: DSM
    # copies the slot's PEMs into each bound service's own directory
    # (system/default, ReverseProxy/<uuid>, WebStation vhosts under
    # /usr/local, ...), so "same cert as the slot" is the binding.
    _targets_file="$_stage/targets"
    printf '%s\n' "$_arch" > "$_targets_file"
    for _base in /usr/syno/etc/certificate /usr/local/etc/certificate; do
        [ -d "$_base" ] || continue
        find "$_base" -name cert.pem 2>/dev/null | while IFS= read -r _cf; do
            case "$_cf" in */_archive/*) continue ;; esac
            [ "$(_syno_fp "$_cf")" = "$_old_fp" ] || continue
            dirname "$_cf"
        done >> "$_targets_file"
    done

    _bak="$_stage/backup"
    _idx=0
    _copy_failed=0
    while IFS= read -r _d; do
        _idx=$((_idx + 1))
        mkdir -p "$_bak/$_idx"
        printf '%s' "$_d" > "$_bak/$_idx/.path"
        cp "$_d"/*.pem "$_bak/$_idx/" 2>/dev/null
        _info "synology_dsm_local: updating $_d"
        for _f in privkey cert chain fullchain; do
            [ -f "$_stage/$_f.pem" ] || continue
            cp "$_stage/$_f.pem" "$_d/$_f.pem" || _copy_failed=1
        done
        [ "$_copy_failed" -ne 0 ] && break
    done < "$_targets_file"

    if [ "$_copy_failed" -ne 0 ] || [ "$(_syno_fp "$_arch/cert.pem")" != "$_new_fp" ]; then
        _err "synology_dsm_local: file replacement failed — restoring previous certificate files."
        for _b in "$_bak"/*; do
            [ -f "$_b/.path" ] || continue
            _d=$(cat "$_b/.path")
            cp "$_b"/*.pem "$_d/" 2>/dev/null
        done
        return 1
    fi

    # Regenerate nginx config from the updated files and restart it so
    # the new cert is actually served. gen-all failure is only a warning
    # (not all DSM setups have web portals); a failed nginx restart is an
    # error the operator must see, even though the store is updated.
    if [ -x /usr/syno/bin/synow3tool ]; then
        /usr/syno/bin/synow3tool --gen-all >/dev/null 2>&1 \
            || _err "synology_dsm_local: warning: synow3tool --gen-all failed"
    fi
    if [ -x /usr/syno/bin/synosystemctl ]; then
        /usr/syno/bin/synosystemctl restart nginx || {
            _err "synology_dsm_local: certificate files updated but nginx restart failed."
            _err "Restart it manually: /usr/syno/bin/synosystemctl restart nginx"
            return 1
        }
    fi
    return 0
}

# Create a new slot through synowebapi (the path that works on DSM 7.2.2),
# then verify the friendly name resolves to a slot.
_syno_create_slot() {
    _stage="$1"
    _as_default="false"; [ "$_syno_default" = "1" ] && _as_default="true"

    _import_args=(
        api=SYNO.Core.Certificate
        method=import
        version=1
        "key_tmp=$_stage/privkey.pem"
        "cert_tmp=$_stage/cert.pem"
        "as_default=$_as_default"
        "desc=$_syno_desc"
    )
    [ -f "$_stage/chain.pem" ] && _import_args+=("inter_cert_tmp=$_stage/chain.pem")

    _info "synology_dsm_local: synowebapi --exec-fastwebapi ${_import_args[*]}"
    _result=$(/usr/syno/bin/synowebapi --exec-fastwebapi "${_import_args[@]}" 2>&1)
    if [ $? -ne 0 ] || ! printf '%s' "$_result" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        _err "synology_dsm_local: cert import failed:"
        _err "$_result"
        return 1
    fi

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
    return 0
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

    _info "synology_dsm_local: deploying certificate for $_cdomain into slot '$_syno_desc'"
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

    # Stage the files under plain names, in a directory NEXT TO the
    # acme.sh home (the parent of the cert's own directory). A wildcard
    # cert whose primary name is the wildcard has a literal '*' in every
    # acme.sh path, which is unsafe to hand to DSM tooling, and synowebapi
    # cannot see the calling shell's /tmp (it runs with a private /tmp
    # namespace) — staging next to the home avoids both.
    _stage_parent="$(dirname "$(dirname "$_ckey")")"
    _tmp_dir="$(mktemp -d "$_stage_parent/.synology_dsm_local.XXXXXX")" || {
        _err "synology_dsm_local: mktemp failed under $_stage_parent"
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
    [ -f "$_cfullchain" ] && cp "$_cfullchain" "$_tmp_dir/fullchain.pem"
    chmod 600 "$_tmp_dir"/*.pem

    if [ -n "$_existing_id" ]; then
        _final_id="$_existing_id"
        _syno_replace_slot_files "$_existing_id" "$_tmp_dir"
        _deploy_rc=$?
    else
        _syno_create_slot "$_tmp_dir"   # sets _final_id on success
        _deploy_rc=$?
    fi
    rm -rf "$_tmp_dir"
    [ "$_deploy_rc" -ne 0 ] && return 1

    # Persist the config in the cert's deploy conf so the next scheduled
    # renewal, running with a clean environment, targets the same slot.
    _savedeployconf SYNO_Certificate "$_syno_desc" "base64"
    _savedeployconf SYNO_Create "$_syno_create"
    _savedeployconf SYNO_Default "$_syno_default"

    _info "synology_dsm_local: certificate deployed OK into slot '$_syno_desc' (id=$_final_id)"
    return 0
}
