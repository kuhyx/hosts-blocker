#!/usr/bin/env bash
# lib/hosts_guard.sh — the guard lifecycle around the write.
#
# stop_hosts_guard takes down the path watcher, the bind mount and the
# immutable attribute so /etc/hosts can be written; restart_hosts_guard puts
# them back; save_protection_state records the baseline the next run compares
# against. Sourced by install.sh.

# Enable systemd-resolved and make it read /etc/hosts. Without
# ReadEtcHosts=yes it ignores the file entirely and every blocked domain
# resolves normally, which defeats the whole install.
enable_resolved_reads_hosts() {
	# Enable systemd-resolved
	sudo systemctl enable systemd-resolved

	# ============================================================================
	# ENSURE systemd-resolved READS /etc/hosts
	# ============================================================================
	# Without this, systemd-resolved ignores /etc/hosts entries entirely,
	# allowing blocked domains to resolve via DNS.
	RESOLVED_CONF="/etc/systemd/resolved.conf"
	if grep -q '^ReadEtcHosts=no' "$RESOLVED_CONF" 2>/dev/null; then
		echo "Fixing systemd-resolved: setting ReadEtcHosts=yes..."
		sudo sed -i 's/^ReadEtcHosts=no/ReadEtcHosts=yes/' "$RESOLVED_CONF"
		sudo systemctl restart systemd-resolved
	elif ! grep -q '^ReadEtcHosts=yes' "$RESOLVED_CONF" 2>/dev/null; then
		echo "Enabling ReadEtcHosts=yes in systemd-resolved..."
		if grep -q '^#ReadEtcHosts=' "$RESOLVED_CONF" 2>/dev/null; then
			sudo sed -i 's/^#ReadEtcHosts=.*/ReadEtcHosts=yes/' "$RESOLVED_CONF"
		else
			echo 'ReadEtcHosts=yes' | sudo tee -a "$RESOLVED_CONF" >/dev/null
		fi
		sudo systemctl restart systemd-resolved
	fi

}

# Take down the guard so /etc/hosts can be written: stop the path watcher,
# unmount the read-only bind mount, and clear the immutable/append-only
# attributes. restart_hosts_guard puts all three back.
stop_hosts_guard() {
	# ============================================================================
	# TEMPORARILY DISABLE HOSTS GUARD PROTECTIONS FOR INSTALLATION
	# ============================================================================
	# The guard system uses a read-only bind mount and path watcher that prevent
	# any writes to /etc/hosts. We must stop them before installing, then restart.
	GUARD_SERVICES_STOPPED=0

	for svc in hosts-bind-mount.service hosts-guard.path; do
		if systemctl is-active --quiet "$svc" 2>/dev/null; then
			echo "Stopping $svc for installation..."
			systemctl stop "$svc" 2>/dev/null || true
			GUARD_SERVICES_STOPPED=1
		fi
	done

	# If bind mount is still active, unmount it
	if findmnt /etc/hosts >/dev/null 2>&1; then
		echo "Unmounting read-only bind mount on /etc/hosts..."
		umount /etc/hosts 2>/dev/null || mount -o remount,rw,bind /etc/hosts 2>/dev/null || true
	fi

	# Remove all attributes from /etc/hosts to allow modifications
	sudo chattr -i -a /etc/hosts 2>/dev/null || true

}

# Bring the guard back up after the write: restart the services stopped by
# stop_hosts_guard so /etc/hosts is protected again.
restart_hosts_guard() {

	# ============================================================================
	# RESTART HOSTS GUARD SERVICES
	# ============================================================================
	if [[ $GUARD_SERVICES_STOPPED -eq 1 ]]; then
		echo "Restarting hosts guard services..."
		# Update the canonical copy so the guard doesn't revert our changes
		if [[ -f /usr/local/share/locked-hosts ]]; then
			cp /etc/hosts /usr/local/share/locked-hosts
			echo "  Updated canonical snapshot."
		fi
		for svc in hosts-bind-mount.service hosts-guard.path; do
			if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
				systemctl start "$svc" 2>/dev/null || true
				echo "  Restarted $svc"
			fi
		done
	fi

	# ============================================================================
}

# Record the custom and unblock entry lists that were just installed, so the
# next run's protection checks have a baseline to compare against.
save_protection_state() {
	# SAVE CUSTOM ENTRIES STATE FOR FUTURE PROTECTION CHECKS
	# ============================================================================
	echo "Saving custom entries state for protection mechanism..."
	# The install script whose entry lists are being checked. Defaults to the
	# running script, which is what production always wants; a test points it
	# at a fixture instead, since these guards are the part of this file where
	# a silent regression matters most.
	script_path="$(readlink -f "${HOSTS_INSTALL_SCRIPT_PATH:-$0}")"
	current_custom_entries=$(extract_custom_entries_from_script "$script_path")
	# Remove immutable from state file if it exists
	chattr -i "$CUSTOM_ENTRIES_STATE_FILE" 2>/dev/null || true
	save_custom_entries_state "$current_custom_entries"
	echo "✅ Custom entries state saved to $CUSTOM_ENTRIES_STATE_FILE"

	# Save unblock entries state for future protection checks
	current_unblock_entries=$(extract_unblock_entries_from_script "$script_path")
	save_unblock_entries_state "$current_unblock_entries"
	echo "✅ Unblock entries state saved to $UNBLOCK_STATE_FILE"

	# Optionally flush DNS caches
	if [[ $FLUSH_DNS -eq 1 ]]; then
		echo "Flushing DNS caches..."
		sudo systemd-resolve --flush-caches
		sudo systemctl restart NetworkManager.service
	else
		echo "DNS cache flush skipped (use --flush-dns to enable)."
	fi

	# ============================================================================
}
