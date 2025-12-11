#!/usr/bin/env bash
# Post-transaction hook to re-apply hosts guard protections (single-layer ro bind)

set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hosts-guard-common.sh
source "$SCRIPT_DIR/hosts-guard-common.sh"

ENFORCE=/usr/local/sbin/enforce-hosts.sh

log_hook "post" "relocking(start)"

# Collapse any stacked mounts first
collapse_mounts

# Run enforcement script if available
if [[ -x $ENFORCE ]]; then
	"$ENFORCE" >/dev/null 2>&1 || true
fi

# Apply protections
apply_immutable
apply_ro_bind_mount

# Start the path watcher
start_path_watcher

log_hook "post" "relocking(done)"

exit 0
