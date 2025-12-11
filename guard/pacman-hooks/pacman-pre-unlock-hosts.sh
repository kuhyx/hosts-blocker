#!/usr/bin/env bash
# Non-interactive pre-transaction hook to temporarily unlock /etc/hosts

set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hosts-guard-common.sh
source "$SCRIPT_DIR/hosts-guard-common.sh"

# Remove protective attributes
remove_host_attrs

# Stop guard services
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
