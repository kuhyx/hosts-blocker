#!/usr/bin/env bash
# Tests for lib/hosts_lock.sh — one install.sh run at a time.
#
# The bug these guard (2026-11-20): every browser launch runs install.sh via
# the browser-preexec-wrapper before the browser starts. With another run
# holding the lock, the launch sat in `flock -w 300` for up to five minutes.
# A browser launch passes --skip-if-busy: a busy lock means another run is
# already refreshing /etc/hosts, so it waits briefly and exits 0. The timer,
# hosts-file-monitor and manual runs keep the long wait.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"

HOSTS_BLOCKER_LOCK="${TEST_TMPDIR}/hosts-blocker.lock"
export HOSTS_BLOCKER_LOCK

# shellcheck source=../hosts_lock.sh
. "${SCRIPT_DIR}/../hosts_lock.sh"

# The skip has to be visible somewhere: the wrapper discards stderr.
cat >"${FAKE_BIN}/logger" <<'LOGGERSHIM'
#!/usr/bin/env bash
printf '%s\n' "logger $*" >>"${HOSTS_TEST_CALLS}"
LOGGERSHIM
chmod +x "${FAKE_BIN}/logger"

HOLDER_PID=""
hold_lock() { # Hold the lock from another process, like a concurrent run.
	flock "${HOSTS_BLOCKER_LOCK}" sleep 30 &
	HOLDER_PID=$!
	# Wait until the holder really owns it, so the cases below are not racy.
	for _ in $(seq 50); do
		flock -n "${HOSTS_BLOCKER_LOCK}" true || return 0
		sleep 0.05
	done
	echo "holder never took the lock" >&2
	return 1
}
release_lock() {
	[[ -n $HOLDER_PID ]] || return 0
	pkill -P "$HOLDER_PID" 2>/dev/null || true
	kill "$HOLDER_PID" 2>/dev/null || true
	wait "$HOLDER_PID" 2>/dev/null || true
	HOLDER_PID=""
}
trap 'release_lock; rm -rf "${TEST_TMPDIR}"' EXIT

# Run acquire_install_lock in a fresh process (it exits on failure), bounded by
# timeout so a red run cannot hang the suite. Sets RC and ELAPSED.
run_acquire() { # <timeout-sec> [args...]
	local limit="$1"
	shift
	local start=$EPOCHREALTIME
	set +e
	timeout "$limit" "${SCRIPT_DIR}/call_lib_fn.sh" "${SCRIPT_DIR}/../hosts_lock.sh" \
		acquire_install_lock "$@" >"${TEST_TMPDIR}/out" 2>&1
	RC=$?
	set -e
	ELAPSED=$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN { printf "%d", e - s }')
}

echo "== free lock =="
reset_state
run_acquire 10
_t_eq "0" "$RC" "a free lock is taken at once"
_t_has "$(cat "${TEST_TMPDIR}/out")" "rc=0" "the run goes on after taking it"
run_acquire 10 --skip-if-busy
_t_has "$(cat "${TEST_TMPDIR}/out")" "rc=0" "--skip-if-busy still takes a free lock"

echo "== busy lock, --skip-if-busy (browser launch) =="
reset_state
hold_lock
run_acquire 20 --skip-if-busy
_t_eq "0" "$RC" "a busy lock with --skip-if-busy exits 0"
if [[ $ELAPSED -le 6 ]]; then
	_t_pass "it gives up within ~5 s (${ELAPSED}s)"
else
	_t_fail "it gives up within ~5 s (took ${ELAPSED}s)"
fi
if grep -q 'rc=' "${TEST_TMPDIR}/out"; then
	_t_fail "it does not run the install while another run holds the lock"
else
	_t_pass "it does not run the install while another run holds the lock"
fi
if grep -q '^logger .*hosts-blocker' "${HOSTS_TEST_CALLS}"; then
	_t_pass "the skip is logged to the journal"
else
	_t_fail "the skip is logged to the journal"
fi

echo "== busy lock, no flag (timer, monitor, manual) =="
run_acquire 8
_t_eq "124" "$RC" "without the flag it keeps waiting past the short window"
release_lock

_t_summary
