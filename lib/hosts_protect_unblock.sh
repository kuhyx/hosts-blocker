#!/usr/bin/env bash
# lib/hosts_protect_unblock.sh — the anti-tamper guard on the UNBLOCK list.
#
# The mirror of hosts_protect_custom.sh: it refuses the install when the
# whitelist has GROWN, so domains cannot be quietly un-blocked. Sourced by
# install.sh.

# Extract whitelisted domains from the protected list embedded in this script
extract_unblock_entries_from_script() {
	local script_path="$1"
	# The two marker lines match the domain pattern themselves -- they are
	# word characters and underscores -- so a plain grep pulled
	# PROTECTED_UNBLOCK_LIST_START and _END into the whitelist as if they were
	# domains. They then went into the saved state, and renaming either marker
	# would have read as the whitelist growing and blocked the install. Drop
	# them explicitly rather than relying on the pattern to exclude them.
	sed -n '/^# PROTECTED_UNBLOCK_LIST_START$/,/^# PROTECTED_UNBLOCK_LIST_END$/p' "$script_path" |
		grep -E '^# [a-zA-Z0-9._-]+$' |
		sed 's/^# //' |
		grep -vxE 'PROTECTED_UNBLOCK_LIST_(START|END)' |
		sort -u
}

# Save current unblock entries to immutable state file
save_unblock_entries_state() {
	local entries="$1"
	chattr -i "$UNBLOCK_STATE_FILE" 2>/dev/null || true
	echo "$entries" | sort -u >"$UNBLOCK_STATE_FILE"
	chmod 644 "$UNBLOCK_STATE_FILE"
	chattr +i "$UNBLOCK_STATE_FILE" 2>/dev/null || true
}

# Block installation if the unblock list has grown (more sites being whitelisted)
check_unblock_entries_protection() {
	local script_path
	# The install script whose entry lists are being checked. Defaults to the
	# running script, which is what production always wants; a test points it
	# at a fixture instead, since these guards are the part of this file where
	# a silent regression matters most.
	script_path="$(readlink -f "${HOSTS_INSTALL_SCRIPT_PATH:-$0}")"

	local new_entries
	new_entries=$(extract_unblock_entries_from_script "$script_path")
	local new_count
	new_count=$(count_lines "$new_entries")

	if [[ ! -f $UNBLOCK_STATE_FILE ]]; then
		echo "ℹ️  First unblock-list run — no protection check needed."
		return 0
	fi

	local saved_entries
	saved_entries=$(sort -u "$UNBLOCK_STATE_FILE")
	local saved_count
	saved_count=$(count_lines "$saved_entries")

	# Entries added since last install
	local added_entries
	added_entries=$(comm -13 <(echo "$saved_entries") <(echo "$new_entries"))
	local added_count
	added_count=$(count_lines "$added_entries")

	echo ""
	echo "📊 Unblock Entries Protection Check:"
	echo "   Previously whitelisted: $saved_count domains"
	echo "   Currently in script:    $new_count domains"
	echo "   Newly added: $added_count"

	if [[ $added_count -eq 0 ]]; then
		echo "   ✅ No new unblocks — protection check passed."
		return 0
	fi

	echo ""
	echo "============================================================"
	echo "  ❌ INSTALLATION BLOCKED — NEW UNBLOCK ENTRIES DETECTED"
	echo "============================================================"
	echo ""
	echo "You are attempting to WHITELIST these additional domains:"
	while IFS= read -r entry; do
		echo "  + $entry"
	done <<<"$added_entries"
	echo ""
	echo "To proceed, manually delete the state file first:"
	echo "  sudo chattr -i $UNBLOCK_STATE_FILE && sudo rm $UNBLOCK_STATE_FILE"
	echo ""
	return 1
}
