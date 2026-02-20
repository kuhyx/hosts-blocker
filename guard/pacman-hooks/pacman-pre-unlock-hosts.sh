#!/usr/bin/env bash
# pacman-pre-unlock-hosts.sh - Temporarily unlock guarded config files before pacman
# Unlocks: /etc/hosts, /etc/nsswitch.conf, /etc/systemd/resolved.conf
set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hosts-guard-common.sh
source "$SCRIPT_DIR/hosts-guard-common.sh"

# Remove protective attributes from all guarded files
remove_all_guard_attrs
sudo rm /etc/hosts

# Stop guard services (hosts, nsswitch, resolved watchers)
stop_units_if_present

log_hook "pre" "unlocking(start)"

# Collapse any existing mount layers
collapse_mounts

# Ensure writable by remounting if still read-only
if is_ro_mount; then
	mount -o remount,rw "$TARGET" >/dev/null 2>&1 || collapse_mounts
fi

log_hook "pre" "unlocking(done)"

exit 0
