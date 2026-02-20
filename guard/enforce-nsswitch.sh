#!/bin/bash
# Template guard script to enforce canonical /etc/nsswitch.conf
# Ensures "hosts:" line always contains "files" before "dns"
# This prevents bypassing /etc/hosts by removing "files" from nsswitch.conf
# Installed to /usr/local/sbin/enforce-nsswitch.sh by setup_hosts_guard.sh

set -euo pipefail

CANONICAL_SOURCE="/usr/local/share/locked-nsswitch.conf"
TARGET="/etc/nsswitch.conf"
LOG_FILE="/var/log/nsswitch-guard.log"

log() {
	printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

# Function to validate that "hosts:" line has correct format
# Must contain "files" before "dns" (or "dns" not present)
validate_hosts_line() {
	local line="$1"

	# Check if "files" is present
	if ! echo "$line" | grep -qw "files"; then
		return 1
	fi

	# If dns is present, files must come before it
	if echo "$line" | grep -qw "dns"; then
		local files_pos dns_pos
		files_pos=$(echo "$line" | grep -bo '\bfiles\b' | head -1 | cut -d: -f1)
		dns_pos=$(echo "$line" | grep -bo '\bdns\b' | head -1 | cut -d: -f1)
		if [[ -n "$files_pos" && -n "$dns_pos" && "$files_pos" -gt "$dns_pos" ]]; then
			return 1
		fi
	fi

	return 0
}

# Check current nsswitch.conf hosts line
current_hosts_line=$(grep '^hosts:' "$TARGET" 2>/dev/null || echo "")

if [[ -z "$current_hosts_line" ]]; then
	log "CRITICAL: No 'hosts:' line found in $TARGET - restoring from canonical"
	if [[ -f "$CANONICAL_SOURCE" ]]; then
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable attribute on $TARGET"
		log "Restored $TARGET from canonical copy"
	else
		log "ERROR: Canonical source not found at $CANONICAL_SOURCE"
		exit 1
	fi
	exit 0
fi

if ! validate_hosts_line "$current_hosts_line"; then
	log "TAMPERING DETECTED: 'hosts:' line is invalid or missing 'files' before 'dns'"
	log "Current line: $current_hosts_line"

	if [[ -f "$CANONICAL_SOURCE" ]]; then
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable attribute on $TARGET"
		log "Restored $TARGET from canonical copy"
	else
		log "ERROR: Canonical source not found at $CANONICAL_SOURCE"
		# Emergency fix: add "files" back to hosts line
		chattr -i "$TARGET" 2>/dev/null || true
		if grep -q '^hosts:.*dns' "$TARGET"; then
			sed -i 's/^hosts:\(.*\)dns/hosts:\1files dns/' "$TARGET"
		elif grep -q '^hosts:.*resolve' "$TARGET"; then
			sed -i 's/^hosts:\(.*\)resolve/hosts: files\1resolve/' "$TARGET"
		else
			sed -i 's/^hosts:/hosts: files/' "$TARGET"
		fi
		chattr +i "$TARGET" 2>/dev/null || true
		log "Emergency fix applied: added 'files' to hosts line"
	fi
	exit 0
fi

# If canonical exists, check for any drift
if [[ -f "$CANONICAL_SOURCE" ]]; then
	if ! cmp -s "$CANONICAL_SOURCE" "$TARGET"; then
		log "Drift detected in $TARGET (but hosts line valid) - restoring canonical"
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable attribute"
		log "Restored $TARGET from canonical copy"
	else
		log "No drift detected in $TARGET"
	fi
else
	log "Creating initial canonical snapshot"
	mkdir -p "$(dirname "$CANONICAL_SOURCE")"
	cp "$TARGET" "$CANONICAL_SOURCE"
	chmod 644 "$CANONICAL_SOURCE"
	chattr +i "$CANONICAL_SOURCE" 2>/dev/null || log "Failed to protect canonical copy"
fi

# Ensure immutable attribute is set
chattr -i "$TARGET" 2>/dev/null || true
chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable attribute on $TARGET"

log "nsswitch.conf enforcement complete"
