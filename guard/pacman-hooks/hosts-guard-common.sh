#!/usr/bin/env bash
# Shared functions for hosts-guard pacman hooks
# This file is sourced by pacman-pre-unlock-hosts.sh and pacman-post-relock-hosts.sh

TARGET=/etc/hosts
NSSWITCH=/etc/nsswitch.conf
RESOLVED_CONF=/etc/systemd/resolved.conf
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d
LOGTAG=hosts-guard-hook

# Check if target has a read-only mount
is_ro_mount() {
	findmnt -no OPTIONS -T "$TARGET" 2>/dev/null | grep -qw ro
}

# Count mount layers for the target
mount_layers_count() {
	awk '$5=="/etc/hosts"{c++} END{print c+0}' /proc/self/mountinfo 2>/dev/null || echo 0
}

# Collapse all bind mount layers
collapse_mounts() {
	local i=0
	if command -v mountpoint >/dev/null 2>&1; then
		while mountpoint -q "$TARGET"; do
			umount -l "$TARGET" >/dev/null 2>&1 || break
			i=$((i + 1))
			((i > 20)) && break
		done
	else
		local cnt
		cnt=$(mount_layers_count)
		while ((cnt > 1)); do
			umount -l "$TARGET" >/dev/null 2>&1 || break
			i=$((i + 1))
			((i > 20)) && break
			cnt=$(mount_layers_count)
		done
	fi
}

# Stop systemd units related to hosts guard
stop_units_if_present() {
	local units=(hosts-bind-mount.service hosts-guard.path nsswitch-guard.path resolved-guard.path)
	for u in "${units[@]}"; do
		if command -v systemctl >/dev/null 2>&1; then
			if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
				systemctl stop "$u" >/dev/null 2>&1 || true
			fi
		fi
	done
}

# Remove immutable/append-only attributes from a file
_remove_attrs_for() {
	local f="$1"
	if [[ -e "$f" ]] && command -v lsattr >/dev/null 2>&1; then
		chattr -ia "$f" >/dev/null 2>&1 || true
	fi
}

# Remove immutable/append-only attributes from all guarded files
remove_host_attrs() {
	_remove_attrs_for "$TARGET"
}

remove_all_guard_attrs() {
	_remove_attrs_for "$TARGET"
	_remove_attrs_for "$NSSWITCH"
	_remove_attrs_for "$RESOLVED_CONF"
	_remove_attrs_for "$RESOLVED_DROPIN"
}

# Apply immutable attribute to all guarded files
apply_immutable() {
	if command -v chattr >/dev/null 2>&1; then
		chattr +i "$TARGET" >/dev/null 2>&1 || true
		chattr +i "$NSSWITCH" >/dev/null 2>&1 || true
		chattr +i "$RESOLVED_CONF" >/dev/null 2>&1 || true
		# Lock drop-in dir to prevent creation of override files
		if [[ -d "$RESOLVED_DROPIN" ]]; then
			chattr +i "$RESOLVED_DROPIN" >/dev/null 2>&1 || true
		fi
	fi
}

# Apply a single read-only bind mount layer
apply_ro_bind_mount() {
	mount --bind "$TARGET" "$TARGET" >/dev/null 2>&1 || true
	mount -o remount,ro,bind "$TARGET" >/dev/null 2>&1 || true
}

# Start all path watcher services
start_path_watcher() {
	if command -v systemctl >/dev/null 2>&1; then
		systemctl start hosts-guard.path >/dev/null 2>&1 || true
		systemctl start nsswitch-guard.path >/dev/null 2>&1 || true
		systemctl start resolved-guard.path >/dev/null 2>&1 || true
	fi
}

# Log to system logger and run log file
log_hook() {
	local phase="$1"
	local state="$2"
	logger -t "$LOGTAG" "$phase: $state"
	echo "$(date -Is) $phase-$state" >>/run/hosts-guard-hook.log 2>/dev/null || true
}
