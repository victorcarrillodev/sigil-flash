#!/bin/sh
# Canonical cache metadata ownership contract.  Call after every replacement.
sigil_cache_meta_fix_permissions() {
    file=$1
    [ -f "$file" ] || return 0
    if id sigil >/dev/null 2>&1 && getent group sigil >/dev/null 2>&1; then
        chown sigil:sigil "$file" || return 1
        expected="$(id -u sigil):$(id -g sigil):660"
    else
        # Development/test hosts may not have the appliance account.
        expected="$(stat -c '%u:%g' "$file"):660"
    fi
    chmod 0660 "$file" || return 1
    [ "$(stat -c '%u:%g:%a' "$file" 2>/dev/null)" = "$expected" ]
}
