#!/usr/bin/env bash
# Non-interactive pre-transaction hook to temporarily unlock /etc/hosts

set -euo pipefail

TARGET=/etc/hosts
LOGTAG=hosts-guard-hook

stop_units_if_present() {
  local units=(hosts-bind-mount.service hosts-guard.path)
  for u in "${units[@]}"; do
    if command -v systemctl > /dev/null 2>&1; then
      if systemctl list-unit-files 2> /dev/null | grep -q "^$u"; then
        systemctl stop "$u" > /dev/null 2>&1 || true
      fi
    fi
  done
}

is_ro_mount() { findmnt -no OPTIONS -T "$TARGET" 2> /dev/null | grep -qw ro; }

mount_layers_count() { awk '$5=="/etc/hosts"{c++} END{print c+0}' /proc/self/mountinfo 2> /dev/null || echo 0; }
cleanup_mount_stacks() {
  local i=0
  # Unmount bind layers until /etc/hosts is no longer a mountpoint
  if command -v mountpoint > /dev/null 2>&1; then
    while mountpoint -q "$TARGET"; do
      umount -l "$TARGET" > /dev/null 2>&1 || break
      i=$((i + 1))
      ((i > 20)) && break
    done
  else
    # Fallback to best-effort using mountinfo count
    local cnt
    cnt=$(mount_layers_count)
    while ((cnt > 1)); do
      umount -l "$TARGET" > /dev/null 2>&1 || break
      i=$((i + 1))
      ((i > 20)) && break
      cnt=$(mount_layers_count)
    done
  fi
}

# Drop protective attributes if present
if command -v lsattr > /dev/null 2>&1; then
  attrs=$(lsattr -d "$TARGET" 2> /dev/null || true)
  echo "$attrs" | grep -q " i " && chattr -i "$TARGET" > /dev/null 2>&1 || true
  echo "$attrs" | grep -q " a " && chattr -a "$TARGET" > /dev/null 2>&1 || true
fi

stop_units_if_present

logger -t "$LOGTAG" "pre: unlocking /etc/hosts (starting)"
echo "$(date -Is) pre-unlock" >> /run/hosts-guard-hook.log 2> /dev/null || true

# Always collapse any existing layers; we'll operate on the plain file
cleanup_mount_stacks

# If someone managed a ro single-layer mount, ensure rw by remounting or collapsing again
if is_ro_mount; then
  mount -o remount,rw "$TARGET" > /dev/null 2>&1 || cleanup_mount_stacks
fi

logger -t "$LOGTAG" "pre: unlocking /etc/hosts (done)"

exit 0
