#!/bin/bash

# Re-run with sudo if not root
if [[ $EUID -ne 0 ]]; then
	exec sudo -E bash "$0" "$@"
fi

# Options
# Default: do NOT flush DNS caches unless explicitly requested
FLUSH_DNS=0

# Parse CLI flags
for arg in "$@"; do
	case "$arg" in
	--flush-dns)
		FLUSH_DNS=1
		;;
	--no-flush-dns)
		FLUSH_DNS=0
		;;
	-h | --help)
		echo "Usage: $0 [--flush-dns|--no-flush-dns]"
		exit 0
		;;
	esac
done

# Each phase of the install lives in a lib beside this file; this script
# keeps the flag parsing, the protection-check gates and the order the
# phases run in.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/hosts_protect_custom.sh
. "$LIB_DIR/hosts_protect_custom.sh"
# shellcheck source=lib/hosts_protect_unblock.sh
. "$LIB_DIR/hosts_protect_unblock.sh"
# shellcheck source=lib/hosts_guard.sh
. "$LIB_DIR/hosts_guard.sh"
# shellcheck source=lib/hosts_cache.sh
. "$LIB_DIR/hosts_cache.sh"
# shellcheck source=lib/hosts_write.sh
. "$LIB_DIR/hosts_write.sh"
# shellcheck source=lib/hosts_browser_doh.sh
. "$LIB_DIR/hosts_browser_doh.sh"

# ============================================================================
# CUSTOM ENTRIES PROTECTION MECHANISM
# ============================================================================
# This prevents easy removal of custom blocked entries by requiring that:
# 1. New installation has AT LEAST as many custom entries as before, OR
# 2. Any removed entries are replaced by NEW entries not previously blocked
# If neither condition is met, installation is blocked.
# ============================================================================

CUSTOM_ENTRIES_STATE_FILE="/etc/hosts.custom-entries.state"
UNBLOCK_STATE_FILE="/etc/hosts.unblock-entries.state"

# Run the protection check
if ! check_custom_entries_protection; then
	exit 1
fi

# ============================================================================
# UNBLOCK ENTRIES PROTECTION MECHANISM
# ============================================================================
# This prevents silently expanding the whitelist (i.e. adding MORE domains to
# the sed unblock list) by tracking which domains are whitelisted.  Adding a
# new domain here requires manually clearing the state file first.
# ============================================================================
#
# PROTECTED_UNBLOCK_LIST_START
# 4chan.com
# www.4chan.com
# 4chan.org
# boards.4chan.org
# sys.4chan.org
# www.4chan.org
# facebook.com
# www.facebook.com
# m.facebook.com
# messenger.com
# fbcdn.net
# facebook.net
# delio.com.pl
# loverslab.com
# linkedin.com
# licdn.com
# PROTECTED_UNBLOCK_LIST_END

# Run the unblock protection check
if ! check_unblock_entries_protection; then
	exit 1
fi

# Source and local cache configuration
URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts"
# Cache stores the RAW upstream file (without our custom modifications)
LOCAL_CACHE="/etc/hosts.stevenblack"

# NOTE: this used to `chattr +i` its own source and generate_hosts_file.sh
# ("lock against silent edits"). Do NOT reintroduce that: making a git-tracked
# file immutable breaks git tooling. `pre-commit run --all-files` (which the
# pre-push ci-mirror gate runs) opens every file rb+ via end-of-file-fixer and
# dies with "PermissionError: Operation not permitted", so no push from a normal
# checkout can ever succeed. It also breaks pre-commit's stash of unstaged
# changes (`git checkout -- .` cannot unlink an immutable file), which silently
# reverts unrelated unstaged edits.
#
# Enforcement does not depend on these sources being immutable: /etc/hosts
# itself is chattr +i, guard-lib's "hosts" file-guard instance (guardctl
# file-guard status hosts) watches and re-enforces it against its canonical
# snapshot, and the same instance's bind mount pins it. Editing these sources
# changes nothing until install.sh is re-run as root, which regenerates the
# guarded artifacts.
# ============================================================================

# ============================================================================
# MAIN
# ============================================================================
# The phases above are defined in the order they run, and run here in that same
# order. Split out of a single top-level block so the file fits the 250-line
# cap; the sequence is unchanged, including the guard being taken down before
# the write and restarted immediately after it.
enable_resolved_reads_hosts
stop_hosts_guard
refresh_upstream_cache
write_hosts_file
restart_hosts_guard
save_protection_state
disable_browser_doh
restart_browsers
