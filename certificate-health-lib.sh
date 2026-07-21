#!/bin/sh

certificate_path_is_healthy() {
    _certificate_path="$1"
    [ -n "$_certificate_path" ] || return 1
    if [ -f "$_certificate_path" ]; then
        [ -r "$_certificate_path" ]
        return
    fi
    [ -d "$_certificate_path" ] && [ -r "$_certificate_path" ] || return 1
    for _certificate_candidate in "$_certificate_path"/* "$_certificate_path"/.[!.]*; do
        [ -f "$_certificate_candidate" ] && return 0
    done
    return 1
}

certificate_file_matches_key() {
    _certificate_file="$1"
    _key_file="$2"
    _server_name=${3:-}
    [ -f "$_certificate_file" ] && [ -r "$_certificate_file" ] \
        && [ -f "$_key_file" ] && [ -r "$_key_file" ] || return 1
    openssl x509 -in "$_certificate_file" -noout -checkend 0 >/dev/null 2>&1 \
        || return 1
    _not_before=$(openssl x509 -in "$_certificate_file" -noout -startdate 2>/dev/null \
        | sed 's/^notBefore=//') || return 1
    _not_before_epoch=$(date -u -d "$_not_before" +%s 2>/dev/null) || return 1
    _now_epoch=${GTAGOD_CERT_NOW_EPOCH:-}
    if [ -z "$_now_epoch" ]; then
        _now_epoch=$(date -u +%s 2>/dev/null) || return 1
    fi
    case "$_now_epoch" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_not_before_epoch" -le "$_now_epoch" ] || return 1
    _not_after=$(openssl x509 -in "$_certificate_file" -noout -enddate 2>/dev/null \
        | sed 's/^notAfter=//') || return 1
    _not_after_epoch=$(date -u -d "$_not_after" +%s 2>/dev/null) || return 1
    [ "$_now_epoch" -lt "$_not_after_epoch" ] || return 1
    if [ -n "$_server_name" ]; then
        case "$_server_name" in
            \*.*) _certificate_host="gtagod-health.${_server_name#*.}" ;;
            *) _certificate_host=$_server_name ;;
        esac
        openssl verify -partial_chain -trusted "$_certificate_file" \
            -verify_hostname "$_certificate_host" "$_certificate_file" \
            >/dev/null 2>&1 || return 1
    fi
    _certificate_public_key=$(
        openssl x509 -in "$_certificate_file" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum 2>/dev/null \
            | awk '{print $1}'
    )
    _private_public_key=$(
        openssl pkey -in "$_key_file" -pubout -outform DER 2>/dev/null \
            | sha256sum 2>/dev/null \
            | awk '{print $1}'
    )
    [ -n "$_certificate_public_key" ] \
        && [ "$_certificate_public_key" = "$_private_public_key" ]
}

certificate_pair_is_healthy() {
    _certificate_path="$1"
    _key_path="$2"
    _server_name=${3:-}
    [ -n "$_certificate_path" ] && [ -n "$_key_path" ] || return 1
    if [ -f "$_certificate_path" ]; then
        certificate_file_matches_key "$_certificate_path" "$_key_path" "$_server_name"
        return
    fi
    certificate_path_is_healthy "$_certificate_path" || return 1
    _certificate_entries="/tmp/gtagod-certificate-entries.$$"
    _certificate_entries_sorted="/tmp/gtagod-certificate-entries-sorted.$$"
    _certificate_aggregate="/tmp/gtagod-certificate-aggregate.$$"
    : > "$_certificate_entries" || return 1
    : > "$_certificate_aggregate" || {
        rm -f "$_certificate_entries"
        return 1
    }
    for _certificate_candidate in "$_certificate_path"/* "$_certificate_path"/.[!.]*; do
        [ -f "$_certificate_candidate" ] || continue
        if [ -L "$_certificate_candidate" ]; then
            _certificate_link=$(readlink "$_certificate_candidate" 2>/dev/null) || continue
            case "$_certificate_link" in */*) ;; *) continue ;; esac
        fi
        printf '%s\n' "$_certificate_candidate" >> "$_certificate_entries" || {
            rm -f "$_certificate_entries" "$_certificate_aggregate"
            return 1
        }
    done
    if ! LC_ALL=C sort "$_certificate_entries" > "$_certificate_entries_sorted" \
        || ! mv "$_certificate_entries_sorted" "$_certificate_entries"; then
        rm -f "$_certificate_entries" "$_certificate_entries_sorted" \
            "$_certificate_aggregate"
        return 1
    fi
    while IFS= read -r _certificate_candidate; do
        _certificate_candidate=${_certificate_candidate%"$(printf '\r')"}
        if openssl x509 -in "$_certificate_candidate" -noout >/dev/null 2>&1; then
            cat "$_certificate_candidate" >> "$_certificate_aggregate" || {
                rm -f "$_certificate_entries" "$_certificate_entries_sorted" \
                    "$_certificate_aggregate"
                return 1
            }
            printf '\n' >> "$_certificate_aggregate"
        fi
    done < "$_certificate_entries"
    rm -f "$_certificate_entries" "$_certificate_entries_sorted"
    _certificate_result=0
    certificate_file_matches_key \
        "$_certificate_aggregate" "$_key_path" "$_server_name" \
        || _certificate_result=$?
    rm -f "$_certificate_aggregate"
    return "$_certificate_result"
}
