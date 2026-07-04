#!/bin/bash
# guard-lib plugin for the "nsswitch" file-guard instance.
# Ensures /etc/nsswitch.conf's "hosts:" line always contains "files"
# before "dns", preventing bypass of /etc/hosts blocking. Translated from
# the pre-guard-lib enforce-nsswitch.sh - see that file's git history for
# the original standalone version.

validate() {
    local file="$1"
    local line
    line="$(grep '^hosts:' "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1

    echo "$line" | grep -qw "files" || return 1

    if echo "$line" | grep -qw "dns"; then
        local files_pos dns_pos
        files_pos=$(echo "$line" | grep -bo '\bfiles\b' | head -1 | cut -d: -f1)
        dns_pos=$(echo "$line" | grep -bo '\bdns\b' | head -1 | cut -d: -f1)
        if [[ -n "$files_pos" && -n "$dns_pos" && "$files_pos" -gt "$dns_pos" ]]; then
            return 1
        fi
    fi

    return 0
}

# Only called when no canonical copy exists yet to restore from instead.
emergency_fix() {
    chattr -i "$TARGET" 2>/dev/null || true
    if grep -q '^hosts:.*dns' "$TARGET"; then
        sed -i 's/^hosts:\(.*\)dns/hosts:\1files dns/' "$TARGET"
    elif grep -q '^hosts:.*resolve' "$TARGET"; then
        sed -i 's/^hosts:\(.*\)resolve/hosts: files\1resolve/' "$TARGET"
    else
        sed -i 's/^hosts:/hosts: files/' "$TARGET"
    fi
}
