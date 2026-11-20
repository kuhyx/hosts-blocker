#!/usr/bin/env bash
# lib/hosts_lock.sh — one install.sh run at a time.
#
# This script is started by the hourly maintenance timer, by every browser
# launch (the /usr/local/bin wrappers) AND by hosts-file-monitor, which reacts
# to /etc/hosts changing -- including the changes this script makes. On
# 2026-09-18 20:01 two runs interleaved: the second run's `cp` of the raw
# StevenBlack list landed after the first run's unblock seds, the guard
# snapshotted that as canonical, and facebook.com -- deliberately unblocked --
# was silently blocked until someone noticed. A waiting run redoes the same
# idempotent work once the lock frees. Sourced by install.sh.

# A browser launch passes --skip-if-busy: it runs before every browser start,
# so it must not sit behind another run for minutes (it once could, for up to
# 300 s). A busy lock means another run is already refreshing /etc/hosts; the
# blocks themselves stay enforced by chattr +i and the file guard either way.
HOSTS_BLOCKER_LOCK="${HOSTS_BLOCKER_LOCK:-/run/lock/hosts-blocker.lock}"
readonly HOSTS_LOCK_WAIT_SEC=300
readonly HOSTS_LOCK_BUSY_WAIT_SEC=5

# Take the install lock on fd 9 (held until the process exits), or exit:
# 0 with --skip-if-busy (fail-open: the other run does the work), else 1.
acquire_install_lock() {
	local skip_if_busy=0 arg
	for arg in "$@"; do
		[[ $arg == --skip-if-busy ]] && skip_if_busy=1
	done
	local wait_sec=$HOSTS_LOCK_WAIT_SEC
	((skip_if_busy)) && wait_sec=$HOSTS_LOCK_BUSY_WAIT_SEC

	exec 9>"$HOSTS_BLOCKER_LOCK"
	flock -w "$wait_sec" 9 && return 0

	if ((skip_if_busy)); then
		# The wrapper discards stderr, so the journal is where this shows up.
		logger -t hosts-blocker "install.sh --skip-if-busy: $HOSTS_BLOCKER_LOCK busy for ${wait_sec}s; another run is refreshing, skipping" || true
		echo "install.sh: another run holds $HOSTS_BLOCKER_LOCK; it is refreshing, skipping" >&2
		exit 0
	fi
	echo "install.sh: another run held $HOSTS_BLOCKER_LOCK for ${wait_sec}s; giving up" >&2
	exit 1
}
