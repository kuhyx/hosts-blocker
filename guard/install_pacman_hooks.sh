#!/usr/bin/env bash
set -euo pipefail

require_root() { if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi; }
require_root "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="/etc/pacman.d/hooks"

install -d -m 755 "$HOOKS_DIR"

# Pre-transaction hook
cat > "$HOOKS_DIR/10-unlock-etc-hosts.hook" << 'HOOK'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Temporarily unlocking /etc/hosts for transaction
When = PreTransaction
Exec = /bin/bash /usr/local/share/hosts-guard/pacman-pre-unlock-hosts.sh
NeedsTargets
HOOK

# Post-transaction hook
cat > "$HOOKS_DIR/90-relock-etc-hosts.hook" << 'HOOK'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Re-locking /etc/hosts after transaction
When = PostTransaction
Exec = /bin/bash /usr/local/share/hosts-guard/pacman-post-relock-hosts.sh
NeedsTargets
HOOK

# Place helper scripts into a shared location
install -d -m 755 /usr/local/share/hosts-guard
install -m 755 "$SCRIPT_DIR/pacman-hooks/pacman-pre-unlock-hosts.sh" /usr/local/share/hosts-guard/
install -m 755 "$SCRIPT_DIR/pacman-hooks/pacman-post-relock-hosts.sh" /usr/local/share/hosts-guard/

echo "Pacman hooks installed into $HOOKS_DIR."
