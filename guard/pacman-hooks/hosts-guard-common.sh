#!/usr/bin/env bash
# Shared functions for hosts-guard pacman hooks
# This file is sourced by pacman-pre-unlock-hosts.sh and pacman-post-relock-hosts.sh

TARGET=/etc/hosts
LOGTAG=hosts-guard-hook

# Check if target has a read-only mount
is_ro_mount() {
  findmnt -no OPTIONS -T "$TARGET" 2> /dev/null | grep -qw ro
}

# Count mount layers for the target
mount_layers_count() {
  awk '$5=="/etc/hosts"{c++} END{print c+0}' /proc/self/mountinfo 2> /dev/null || echo 0
}

# Collapse all bind mount layers
collapse_mounts() {
  local i=0
  if command -v mountpoint > /dev/null 2>&1; then
    while mountpoint -q "$TARGET"; do
      umount -l "$TARGET" > /dev/null 2>&1 || break
      i=$((i + 1))
      ((i > 20)) && break
    done
  else
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

# Stop systemd units related to hosts guard
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

# Remove immutable/append-only attributes
remove_host_attrs() {
  if command -v lsattr > /dev/null 2>&1; then
    local attrs
    attrs=$(lsattr -d "$TARGET" 2> /dev/null || true)
    if echo "$attrs" | grep -q " i "; then
      chattr -i "$TARGET" > /dev/null 2>&1 || true
    fi
    if echo "$attrs" | grep -q " a "; then
      chattr -a "$TARGET" > /dev/null 2>&1 || true
    fi
  fi
}

# Apply immutable attribute
apply_immutable() {
  if command -v chattr > /dev/null 2>&1; then
    chattr +i "$TARGET" > /dev/null 2>&1 || true
  fi
}

# Apply a single read-only bind mount layer
apply_ro_bind_mount() {
  mount --bind "$TARGET" "$TARGET" > /dev/null 2>&1 || true
  mount -o remount,ro,bind "$TARGET" > /dev/null 2>&1 || true
}

# Start the path watcher service
start_path_watcher() {
  if command -v systemctl > /dev/null 2>&1; then
    systemctl start hosts-guard.path > /dev/null 2>&1 || true
  fi
}

# Log to system logger and run log file
log_hook() {
  local phase="$1"
  local state="$2"
  logger -t "$LOGTAG" "$phase: $state"
  echo "$(date -Is) $phase-$state" >> /run/hosts-guard-hook.log 2> /dev/null || true
}
