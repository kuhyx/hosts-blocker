#!/bin/bash
# Guided, delayed unlock procedure to intentionally slow down impulsive edits.
set -euo pipefail

TARGET=/etc/hosts
CANON=/usr/local/share/locked-hosts
LOG=/var/log/hosts-guard.log
EDITOR_CMD=${EDITOR:-nano}
DELAY_SECONDS=45

log() { printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }

require_root() { if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi }
require_root "$@"

log "Requested intentional /etc/hosts modification session."
echo "This action is logged. A cooling-off delay of $DELAY_SECONDS seconds applies." >&2

for s in hosts-bind-mount.service hosts-guard.path; do
    if systemctl is-active --quiet "$s"; then
        log "Stopping $s"
        systemctl stop "$s" || true
    fi
    if systemctl is-enabled --quiet "$s"; then
        log "(Will re-enable later)"
    fi
done

# Remove attributes to allow edit
chattr -i -a "$TARGET" 2>/dev/null || true

echo "Countdown:" >&2
for ((i=DELAY_SECONDS; i>0; i--)); do
    printf '\rEdit window opens in %2d seconds... Press Ctrl+C to abort.' "$i" >&2
    sleep 1
done
echo >&2

# Launch editor
sha_before=$(sha256sum "$TARGET" | awk '{print $1}')
"$EDITOR_CMD" "$TARGET"
sha_after=$(sha256sum "$TARGET" | awk '{print $1}')

if [[ "$sha_before" == "$sha_after" ]]; then
    log "No changes made to $TARGET."
else
    log "Changes detected. Updating canonical copy and re-enforcing."
    cp "$TARGET" "$CANON"
fi

# Re-run enforcement
/usr/local/sbin/enforce-hosts.sh || log "Enforcement script returned non-zero"

# Restart watchers and bind mount
systemctl start hosts-guard.path || true
systemctl start hosts-bind-mount.service || true

log "Unlock session complete."
echo "Done." >&2
