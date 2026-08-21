#!/usr/bin/env bash
# lib/hosts_protect_custom.sh — the anti-tamper guard on the CUSTOM blocking
# entries.
#
# Refuses the install when the custom block list has shrunk against the state
# file saved by the previous run, so entries cannot be quietly dropped by
# editing this repo. Sourced by install.sh.

# Extract custom blocked entries from a hosts file or heredoc section
# Returns only the "0.0.0.0 domain.com" lines (normalized, sorted, unique)
# The custom blocking entries used to live in a heredoc inside install.sh, and
# this read them by slicing between "# Custom blocking entries" and the heredoc
# terminator. They are now a data file beside it, so the whole file is the list
# and no slicing is needed.
#
# The argument is still the script path, because that is what every caller has
# and the data file sits at a known place relative to it. Passing a path with no
# data file beside it yields an empty list, which check_custom_entries_protection
# treats as "everything was removed" and refuses -- the safe direction.
extract_custom_entries_from_script() {
	local script_path="$1"
	local entries_file
	entries_file="$(dirname "$script_path")/custom_entries.hosts"
	[[ -f $entries_file ]] || return 0
	grep -E '^0\.0\.0\.0[[:space:]]+' "$entries_file" |
		awk '{print $2}' |
		sort -u
}

# Extract custom entries from the current /etc/hosts (entries after "# Custom blocking entries" marker)
extract_custom_entries_from_hosts() {
	local hosts_file="$1"
	if [[ ! -f $hosts_file ]]; then
		return
	fi
	sed -n '/^# Custom blocking entries$/,$p' "$hosts_file" |
		grep -E '^0\.0\.0\.0[[:space:]]+' |
		awk '{print $2}' |
		sort -u
}

# Load previously saved custom entries state
load_saved_custom_entries() {
	if [[ -f $CUSTOM_ENTRIES_STATE_FILE ]]; then
		sort -u "$CUSTOM_ENTRIES_STATE_FILE"
	fi
}

# Save current custom entries to state file
save_custom_entries_state() {
	local entries="$1"
	echo "$entries" | sort -u >"$CUSTOM_ENTRIES_STATE_FILE"
	chmod 644 "$CUSTOM_ENTRIES_STATE_FILE"
	chattr +i "$CUSTOM_ENTRIES_STATE_FILE" 2>/dev/null || true
}

# Helper function to count non-empty lines
count_lines() {
	local input="$1"
	if [[ -z $input ]]; then
		echo 0
	else
		echo "$input" | grep -c . 2>/dev/null || echo 0
	fi
}

# Main protection check
check_custom_entries_protection() {
	local script_path
	# The install script whose entry lists are being checked. Defaults to the
	# running script, which is what production always wants; a test points it
	# at a fixture instead, since these guards are the part of this file where
	# a silent regression matters most.
	script_path="$(readlink -f "${HOSTS_INSTALL_SCRIPT_PATH:-$0}")"

	# Get new entries from the script's heredoc
	local new_entries
	new_entries=$(extract_custom_entries_from_script "$script_path")
	local new_count
	new_count=$(count_lines "$new_entries")

	# Get saved/existing entries (prefer state file, fall back to current /etc/hosts)
	local saved_entries
	saved_entries=$(load_saved_custom_entries)
	if [[ -z $saved_entries ]]; then
		# First run or state file missing - extract from current /etc/hosts if it has our marker
		# The live hosts file, overridable so a test can supply a fixture; this
		# is a read, never a write.
		saved_entries=$(extract_custom_entries_from_hosts "${HOSTS_FILE_PATH:-/etc/hosts}")
	fi
	local saved_count
	saved_count=$(count_lines "$saved_entries")

	# If no saved state exists, this is first installation - allow it
	if [[ $saved_count -eq 0 ]]; then
		echo "ℹ️  First installation detected - no protection check needed."
		return 0
	fi

	# Find entries that were removed
	local removed_entries
	removed_entries=$(comm -23 <(echo "$saved_entries") <(echo "$new_entries"))
	local removed_count
	removed_count=$(count_lines "$removed_entries")

	# Find entries that are new
	local added_entries
	added_entries=$(comm -13 <(echo "$saved_entries") <(echo "$new_entries"))
	local added_count
	added_count=$(count_lines "$added_entries")

	echo ""
	echo "📊 Custom Entries Protection Check:"
	echo "   Previously blocked: $saved_count entries"
	echo "   Currently in script: $new_count entries"
	echo "   Removed: $removed_count | Added: $added_count"

	# RULE 1: No entries removed - always OK
	if [[ $removed_count -eq 0 ]]; then
		echo "   ✅ No entries removed - protection check passed."
		return 0
	fi

	# RULE 2: Entries were removed - BLOCK INSTALLATION
	echo ""
	echo "============================================================"
	echo "  ❌ INSTALLATION BLOCKED - CUSTOM ENTRIES REMOVED"
	echo "============================================================"
	echo ""
	echo "You are attempting to REMOVE the following blocked entries:"
	while IFS= read -r entry; do
		echo "  - $entry"
	done <<<"$removed_entries"
	echo ""
	echo "This is NOT allowed. The only way to unblock sites is to:"
	echo ""
	echo "  1. Manually edit /etc/hosts (requires removing chattr protection)"
	echo "  2. Delete the state file /etc/hosts.custom-entries.state"
	echo "     (also protected with chattr)"
	echo ""
	echo "These manual steps are intentionally difficult to prevent"
	echo "impulsive unblocking. If you really need to unblock something,"
	echo "you'll have to work for it."
	echo ""
	return 1
}
