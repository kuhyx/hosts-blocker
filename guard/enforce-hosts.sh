#!/bin/bash
# Template guard script to enforce canonical /etc/hosts
# This will be installed into /usr/local/sbin/enforce-hosts.sh by a setup script.

set -euo pipefail

CANONICAL_SOURCE="/usr/local/share/locked-hosts"
TARGET="/etc/hosts"
LOG_FILE="/var/log/hosts-guard.log"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

if [[ ! -f "$CANONICAL_SOURCE" ]]; then
    log "Canonical hosts not found at $CANONICAL_SOURCE; aborting enforcement"
    exit 0
fi

if ! cmp -s "$CANONICAL_SOURCE" "$TARGET"; then
    log "Difference detected – restoring $TARGET from canonical copy"
    cp "$CANONICAL_SOURCE" "$TARGET"
    chmod 644 "$TARGET"
else
    log "No drift detected (contents identical)"
fi

# Re-apply protective attributes: immutable first, then read-only bind mount handled by separate unit
chattr -i -a "$TARGET" 2>/dev/null || true
chattr +i "$TARGET" || log "Failed to set immutable attribute"

log "Enforcement complete"