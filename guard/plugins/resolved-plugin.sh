#!/bin/bash
# guard-lib plugin for the "resolved" file-guard instance.
# Ensures /etc/systemd/resolved.conf honours /etc/hosts (ReadEtcHosts=yes)
# and doesn't bypass it via DNS-over-TLS, and keeps the resolved.conf.d
# drop-in directory empty so a drop-in can't silently override these
# settings. Translated from the pre-guard-lib enforce-resolved.sh - see
# that file's git history for the original standalone version.

RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"

# Called unconditionally at the start of every enforce pass (not just on
# drift), matching the original script's behavior of policing the
# drop-in directory every time regardless of resolved.conf's own state.
pre_action() {
    if [[ -d "$RESOLVED_DROPIN_DIR" ]]; then
        local count
        count=$(find "$RESOLVED_DROPIN_DIR" -name '*.conf' -type f 2>/dev/null | wc -l)
        if [[ "$count" -gt 0 ]]; then
            chattr -i "$RESOLVED_DROPIN_DIR" 2>/dev/null || true
            find "$RESOLVED_DROPIN_DIR" -name '*.conf' -type f -delete
        fi
    else
        mkdir -p "$RESOLVED_DROPIN_DIR"
    fi
    chattr +i "$RESOLVED_DROPIN_DIR" 2>/dev/null || true
}

validate() {
    local file="$1"

    local read_hosts
    read_hosts=$(grep -E '^\s*ReadEtcHosts\s*=' "$file" 2>/dev/null | tail -1 |
        sed 's/.*=\s*//' | tr -d '[:space:]')
    [[ "$read_hosts" == "yes" ]] || return 1

    local dot
    dot=$(grep -E '^\s*DNSOverTLS\s*=' "$file" 2>/dev/null | tail -1 |
        sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$dot" && "$dot" != "no" ]]; then
        return 1
    fi

    return 0
}

# Only called when no canonical copy exists yet to restore from instead.
emergency_fix() {
    chattr -i "$TARGET" 2>/dev/null || true

    if grep -qE '^\s*ReadEtcHosts\s*=' "$TARGET"; then
        sed -i -E 's/^\s*ReadEtcHosts\s*=.*/ReadEtcHosts=yes/' "$TARGET"
    elif grep -q '^\[Resolve\]' "$TARGET"; then
        sed -i '/^\[Resolve\]/a ReadEtcHosts=yes' "$TARGET"
    else
        printf '\n[Resolve]\nReadEtcHosts=yes\n' >>"$TARGET"
    fi

    if grep -qE '^\s*DNSOverTLS\s*=' "$TARGET"; then
        sed -i -E 's/^\s*DNSOverTLS\s*=.*/#DNSOverTLS=no/' "$TARGET"
    fi
}

post_restore_action() {
    systemctl restart systemd-resolved 2>/dev/null || true
}
