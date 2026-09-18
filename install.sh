#!/bin/bash

# Re-run with sudo if not root
if [[ $EUID -ne 0 ]]; then
	exec sudo -E bash "$0" "$@"
fi

# One run at a time. This script is started by the hourly maintenance timer,
# by every browser launch (the /usr/local/bin wrappers) AND by
# hosts-file-monitor, which reacts to /etc/hosts changing -- including the
# changes this script makes. On 2026-09-18 20:01 two runs interleaved: the
# second run's `cp` of the raw StevenBlack list landed after the first run's
# unblock seds, the guard snapshotted that as canonical, and facebook.com --
# deliberately unblocked -- was silently blocked until someone noticed. A
# waiting run redoes the same idempotent work once the lock frees.
HOSTS_BLOCKER_LOCK="${HOSTS_BLOCKER_LOCK:-/run/lock/hosts-blocker.lock}"
exec 9>"$HOSTS_BLOCKER_LOCK"
if ! flock -w 300 9; then
	echo "install.sh: another run held $HOSTS_BLOCKER_LOCK for 5 minutes; giving up" >&2
	exit 1
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
# shellcheck source=lib/hosts_browser_urlfilter.sh
. "$LIB_DIR/hosts_browser_urlfilter.sh"
# shellcheck source=lib/hosts_guard_setup.sh
. "$LIB_DIR/hosts_guard_setup.sh"

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
#
# That claim is only true because setup_hosts_guards (lib/hosts_guard_setup.sh)
# runs below and REGISTERS those instances. It used to be a lie on any machine
# where a one-shot migration script in the testsAndMisc monorepo had not been
# run by hand: chattr +i with nothing watching it. Do not remove that call
# without also deleting this paragraph.
# ============================================================================

# ============================================================================
# MAIN
# ============================================================================
# The phases above are defined in the order they run, and run here in that same
# order. Split out of a single top-level block so the file fits the 250-line
# cap; the sequence is unchanged, including the guard being taken down before
# the write and restarted immediately after it.
enable_resolved_reads_hosts
# Both gates are hard stops: a write while /etc/hosts is still a mountpoint,
# or one whose unblock seds did not take, must not reach setup_hosts_guards --
# that is the step which snapshots whatever is on disk as the canonical copy.
if ! stop_hosts_guard; then
	echo "install.sh: could not take the hosts guard down; nothing written" >&2
	restart_hosts_guard
	exit 1
fi
refresh_upstream_cache
if ! write_hosts_file; then
	echo "install.sh: /etc/hosts write failed verification; guard restarted, canonical NOT updated" >&2
	restart_hosts_guard
	exit 1
fi
# Register the file-guard instances only AFTER the write: the instance
# snapshots a canonical copy of the target and pins it with a bind mount, so
# registering earlier would canonicalise the pre-write file. A failure here is
# loud but non-fatal -- the hosts file is already written and chattr +i'd, and
# aborting would leave the box less protected than finishing does.
setup_hosts_guards || echo "WARNING: hosts guard registration failed - see above" >&2
restart_hosts_guard
save_protection_state
disable_browser_doh
apply_browser_urlfilter
restart_browsers
