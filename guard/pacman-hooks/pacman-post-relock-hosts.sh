#!/usr/bin/env bash
# pacman-post-relock-hosts.sh - Re-apply all guard protections after pacman
# Re-locks: /etc/hosts, /etc/nsswitch.conf, /etc/systemd/resolved.conf
set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hosts-guard-common.sh
source "$SCRIPT_DIR/hosts-guard-common.sh"

ENFORCE=/usr/local/sbin/enforce-hosts.sh
ENFORCE_NSSWITCH=/usr/local/sbin/enforce-nsswitch.sh
ENFORCE_RESOLVED=/usr/local/sbin/enforce-resolved.sh

log_hook "post" "relocking(start)"

# Collapse any stacked mounts first
collapse_mounts

# Run enforcement scripts if available
if [[ -x $ENFORCE ]]; then
	"$ENFORCE" >/dev/null 2>&1 || true
fi
if [[ -x $ENFORCE_NSSWITCH ]]; then
	"$ENFORCE_NSSWITCH" >/dev/null 2>&1 || true
fi
if [[ -x $ENFORCE_RESOLVED ]]; then
	"$ENFORCE_RESOLVED" >/dev/null 2>&1 || true
fi

# Apply protections (immutable on all guarded files)
apply_immutable
apply_ro_bind_mount

# Start all path watchers
start_path_watcher

log_hook "post" "relocking(done)"

exit 0
