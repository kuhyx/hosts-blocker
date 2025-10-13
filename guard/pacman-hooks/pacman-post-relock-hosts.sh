#!/usr/bin/env bash
# Post-transaction hook to re-apply hosts guard protections (single-layer ro bind)

TARGET=/etc/hosts
ENFORCE=/usr/local/sbin/enforce-hosts.sh
LOGTAG=hosts-guard-hook

mount_layers_count() { awk '$5=="/etc/hosts"{c++} END{print c+0}' /proc/self/mountinfo 2>/dev/null || echo 0; }
collapse_mounts() {
  local i=0
  if command -v mountpoint >/devnull 2>&1; then
    while mountpoint -q "$TARGET"; do
      umount -l "$TARGET" >/dev/null 2>&1 || break
      i=$((i+1))
      (( i > 20 )) && break
    done
  else
    local cnt
    cnt=$(mount_layers_count)
    while (( cnt > 1 )); do
      umount -l "$TARGET" >/dev/null 2>&1 || break
      i=$((i+1))
      (( i > 20 )) && break
      cnt=$(mount_layers_count)
    done
  fi
}

# Ensure we end with a single read-only bind mount layer
logger -t "$LOGTAG" "post: relocking /etc/hosts (starting)"
echo "$(date -Is) post-relock(start)" >> /run/hosts-guard-hook.log 2>/dev/null || true
collapse_mounts

if [[ -x "$ENFORCE" ]]; then
  "$ENFORCE" >/dev/null 2>&1 || true
fi

# Apply exactly one ro bind layer
mount --bind "$TARGET" "$TARGET" >/dev/null 2>&1 || true
mount -o remount,ro,bind "$TARGET" >/dev/null 2>&1 || true

# Start only the path watcher; avoid bind-mount service (we already bound once)
if command -v systemctl >/dev/null 2>&1; then
  systemctl start hosts-guard.path >/dev/null 2>&1 || true
fi

logger -t "$LOGTAG" "post: relocking /etc/hosts (done)"
echo "$(date -Is) post-relock(done)" >> /run/hosts-guard-hook.log 2>/dev/null || true

exit 0
