#!/bin/bash
# Guard script to enforce canonical /etc/systemd/resolved.conf
# Ensures ReadEtcHosts=yes and prevents DNS-over-TLS bypass of /etc/hosts
# Installed to /usr/local/sbin/enforce-resolved.sh by setup_hosts_guard.sh

set -euo pipefail

CANONICAL_SOURCE="/usr/local/share/locked-resolved.conf"
TARGET="/etc/systemd/resolved.conf"
DROPIN_DIR="/etc/systemd/resolved.conf.d"
LOG_FILE="/var/log/resolved-guard.log"

log() {
	printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

# Validate that resolved.conf has correct settings to honour /etc/hosts
# Critical settings:
#   ReadEtcHosts=yes   — must be present and set to yes
#   DNSOverTLS=no      — must NOT be opportunistic/yes (bypasses local hosts)
validate_resolved() {
	local file="$1"

	# ReadEtcHosts must be explicitly yes (not commented, not "no")
	local read_hosts
	read_hosts=$(grep -E '^\s*ReadEtcHosts\s*=' "$file" 2>/dev/null | tail -1 |
		sed 's/.*=\s*//' | tr -d '[:space:]')
	if [[ "$read_hosts" != "yes" ]]; then
		log "INVALID: ReadEtcHosts='$read_hosts' (expected 'yes') in $file"
		return 1
	fi

	# DNSOverTLS must not be set to yes or opportunistic
	local dot
	dot=$(grep -E '^\s*DNSOverTLS\s*=' "$file" 2>/dev/null | tail -1 |
		sed 's/.*=\s*//' | tr -d '[:space:]')
	if [[ -n "$dot" && "$dot" != "no" ]]; then
		log "INVALID: DNSOverTLS='$dot' (must be 'no' or commented out) in $file"
		return 1
	fi

	return 0
}

# Remove any drop-in overrides that could bypass protections
enforce_no_dropins() {
	if [[ -d "$DROPIN_DIR" ]]; then
		local count
		count=$(find "$DROPIN_DIR" -name '*.conf' -type f 2>/dev/null | wc -l)
		if [[ "$count" -gt 0 ]]; then
			log "TAMPERING: Found $count drop-in config(s) in $DROPIN_DIR — removing"
			find "$DROPIN_DIR" -name '*.conf' -type f -delete
			log "Removed all drop-in overrides"
		fi
		# Lock the directory itself to prevent new drop-ins
		chattr +i "$DROPIN_DIR" 2>/dev/null || log "Failed to lock $DROPIN_DIR"
	else
		# Create and lock the directory to prevent creation with overrides
		mkdir -p "$DROPIN_DIR"
		chattr +i "$DROPIN_DIR" 2>/dev/null || log "Failed to lock $DROPIN_DIR"
		log "Created and locked empty $DROPIN_DIR"
	fi
}

# Main enforcement logic
log "Starting resolved.conf enforcement"

# 1. Handle drop-in overrides first
enforce_no_dropins

# 2. Check current resolved.conf
if [[ ! -f "$TARGET" ]]; then
	log "CRITICAL: $TARGET does not exist"
	if [[ -f "$CANONICAL_SOURCE" ]]; then
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable on $TARGET"
		log "Restored $TARGET from canonical copy"
	else
		log "ERROR: No canonical source at $CANONICAL_SOURCE — cannot restore"
		exit 1
	fi
fi

if ! validate_resolved "$TARGET"; then
	log "TAMPERING DETECTED in $TARGET"

	if [[ -f "$CANONICAL_SOURCE" ]]; then
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable on $TARGET"
		log "Restored $TARGET from canonical copy"
	else
		log "No canonical source — applying emergency fix"
		chattr -i "$TARGET" 2>/dev/null || true

		# Fix ReadEtcHosts
		if grep -qE '^\s*ReadEtcHosts\s*=' "$TARGET"; then
			sed -i -E 's/^\s*ReadEtcHosts\s*=.*/ReadEtcHosts=yes/' "$TARGET"
		elif grep -q '^\[Resolve\]' "$TARGET"; then
			sed -i '/^\[Resolve\]/a ReadEtcHosts=yes' "$TARGET"
		else
			printf '\n[Resolve]\nReadEtcHosts=yes\n' >>"$TARGET"
		fi

		# Fix DNSOverTLS
		if grep -qE '^\s*DNSOverTLS\s*=' "$TARGET"; then
			sed -i -E 's/^\s*DNSOverTLS\s*=.*/#DNSOverTLS=no/' "$TARGET"
		fi

		chattr +i "$TARGET" 2>/dev/null || true
		log "Emergency fix applied"
	fi

	# Restart resolved to pick up changes
	systemctl restart systemd-resolved 2>/dev/null || log "Failed to restart systemd-resolved"
	exit 0
fi

# 3. If canonical exists, check for any drift
if [[ -f "$CANONICAL_SOURCE" ]]; then
	if ! cmp -s "$CANONICAL_SOURCE" "$TARGET"; then
		log "Drift detected in $TARGET — restoring canonical"
		chattr -i "$TARGET" 2>/dev/null || true
		cp "$CANONICAL_SOURCE" "$TARGET"
		chmod 644 "$TARGET"
		chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable"
		log "Restored $TARGET from canonical copy"
		systemctl restart systemd-resolved 2>/dev/null || log "Failed to restart systemd-resolved"
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

# 4. Ensure immutable attribute is set on live file
chattr -i "$TARGET" 2>/dev/null || true
chattr +i "$TARGET" 2>/dev/null || log "Failed to set immutable on $TARGET"

log "resolved.conf enforcement complete"
