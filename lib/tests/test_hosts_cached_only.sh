#!/usr/bin/env bash
# Tests for install.sh --cached-only: build /etc/hosts from the cached
# upstream list without any network call.
#
# The bug these guard (2026-11-20): every browser launch runs install.sh via
# the browser-preexec-wrapper before the browser starts, and install.sh always
# refreshed the upstream list first (a ranged header fetch, then curl
# --max-time 120 for the body). A stalled network delayed the browser by up to
# ~2 min. The wrapper now passes --cached-only; the hourly timer still
# downloads.
#
# curl is shimmed to hang like a dead network (sleep 300, ignoring
# --max-time), so any curl call shows up as a timeout. install.sh itself runs
# from a copy whose phase libs are stubs: the real phases write /etc/hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"

# Generous next to the few ms a cache-only run takes, far below the hang.
readonly FAST_BUDGET_SEC=5

cat >"${FAKE_BIN}/curl" <<'CURLSHIM'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >>"${HOSTS_TEST_CALLS}"
# exec, so timeout(1) kills the sleep itself and no orphan keeps a pipe open.
exec sleep 300
CURLSHIM
cat >"${FAKE_BIN}/logger" <<'LOGGERSHIM'
#!/usr/bin/env bash
printf '%s\n' "logger $*" >>"${HOSTS_TEST_CALLS}"
LOGGERSHIM
chmod +x "${FAKE_BIN}/curl" "${FAKE_BIN}/logger"

CACHE="${TEST_TMPDIR}/hosts.stevenblack"

stage_cache() {
	printf '# Date: 01 January 2026 00:00:00 (UTC)\n0.0.0.0 blocked.example\n' >"${CACHE}"
}

# Run "$@" under timeout; sets RC and ELAPSED (seconds, 2 decimals).
run_timed() { # <timeout-sec> <cmd>...
	local limit="$1"
	shift
	local start=$EPOCHREALTIME
	set +e
	timeout "$limit" "$@" >"${TEST_TMPDIR}/out" 2>&1
	RC=$?
	set -e
	ELAPSED=$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN { printf "%.2f", e - s }')
}

assert_fast() { # <what>
	if awk -v e="$ELAPSED" -v b="$FAST_BUDGET_SEC" 'BEGIN { exit !(e <= b) }'; then
		_t_pass "$1 (${ELAPSED}s)"
	else
		_t_fail "$1 (took ${ELAPSED}s, budget ${FAST_BUDGET_SEC}s)"
	fi
}

assert_no_curl() { # <what>
	if grep -q '^curl ' "${HOSTS_TEST_CALLS}"; then
		_t_fail "$1 (curl ran: $(grep -m1 '^curl ' "${HOSTS_TEST_CALLS}"))"
	else
		_t_pass "$1"
	fi
}

assert_called() { # <step> <what>
	if grep -qx "$1" "${HOSTS_TEST_CALLS}"; then _t_pass "$2"; else _t_fail "$2"; fi
}

assert_not_called() { # <step> <what>
	if grep -qx "$1" "${HOSTS_TEST_CALLS}"; then _t_fail "$2"; else _t_pass "$2"; fi
}

# --- refresh_upstream_cache --------------------------------------------------

refresh() { # <timeout-sec> [env assignments...]
	local limit="$1"
	shift
	run_timed "$limit" env "$@" URL=http://test.invalid/hosts LOCAL_CACHE="${CACHE}" \
		"${SCRIPT_DIR}/call_lib_fn.sh" "${REPO_DIR}/lib/hosts_cache.sh" refresh_upstream_cache
}

echo "== refresh_upstream_cache: control, the curl shim really hangs =="
reset_state
stage_cache
refresh 2 CACHED_ONLY=0
_t_eq "124" "$RC" "without --cached-only a dead network stalls the refresh"

echo "== refresh_upstream_cache CACHED_ONLY=1, cache present =="
reset_state
stage_cache
refresh 6 CACHED_ONLY=1
_t_eq "0" "$RC" "it succeeds on the cached list"
assert_fast "it returns at once"
assert_no_curl "it makes no network call"

echo "== refresh_upstream_cache CACHED_ONLY=1, empty cache =="
reset_state
: >"${CACHE}"
refresh 6 CACHED_ONLY=1
_t_eq "1" "$RC" "an empty cache is no usable list"
assert_no_curl "it does not fall back to the network"

echo "== refresh_upstream_cache CACHED_ONLY=1, no cache =="
reset_state
rm -f "${CACHE}"
refresh 6 CACHED_ONLY=1
_t_eq "1" "$RC" "with no cache it fails"
assert_no_curl "it does not fall back to the network"
_t_has "$(cat "${HOSTS_TEST_CALLS}")" "logger -t hosts-blocker" \
	"the failure reaches the journal (the wrapper discards stderr)"

# --- install.sh --------------------------------------------------------------
# A copy of install.sh beside stub phase libs that only record their names.
# The real hosts_cache.sh is the one lib under test. The sudo re-exec and the
# cache path are rewritten in the copy only; both rewrites are checked, so a
# drifted install.sh fails here instead of running the real thing.

stage_install_copy() {
	local root="${TEST_TMPDIR}/inst"
	rm -rf "$root"
	mkdir -p "$root/lib"
	sed -e 's/^if \[\[ .EUID -ne 0 \]\]; then$/if false; then/' \
		-e "s|^LOCAL_CACHE=\"/etc/hosts.stevenblack\"$|LOCAL_CACHE=\"${CACHE}\"|" \
		"${REPO_DIR}/install.sh" >"$root/install.sh"
	grep -qx 'if false; then' "$root/install.sh" || return 1
	grep -qx "LOCAL_CACHE=\"${CACHE}\"" "$root/install.sh" || return 1
	cp "${REPO_DIR}/lib/hosts_cache.sh" "$root/lib/"
	local lib
	for lib in hosts_protect_custom hosts_protect_unblock hosts_guard hosts_write \
		hosts_browser_doh hosts_browser_urlfilter hosts_guard_setup; do
		: >"$root/lib/${lib}.sh"
	done
	# Every phase install.sh calls, as a stub that records its own name.
	cat >"$root/lib/hosts_lock.sh" <<'STUBS'
_stub() { printf '%s\n' "$1" >>"${HOSTS_TEST_CALLS}"; }
acquire_install_lock() { _stub acquire_install_lock; }
check_custom_entries_protection() { _stub check_custom_entries_protection; }
check_unblock_entries_protection() { _stub check_unblock_entries_protection; }
enable_resolved_reads_hosts() { _stub enable_resolved_reads_hosts; }
stop_hosts_guard() { _stub stop_hosts_guard; }
write_hosts_file() { _stub write_hosts_file; }
setup_hosts_guards() { _stub setup_hosts_guards; }
restart_hosts_guard() { _stub restart_hosts_guard; }
save_protection_state() { _stub save_protection_state; }
disable_browser_doh() { _stub disable_browser_doh; }
apply_browser_urlfilter() { _stub apply_browser_urlfilter; }
restart_browsers() { _stub restart_browsers; }
STUBS
	INSTALL_COPY="$root/install.sh"
}

echo "== install.sh --cached-only, cache present, network dead =="
reset_state
stage_cache
if stage_install_copy; then
	_t_pass "install.sh copy staged with its re-exec and cache path rewritten"
else
	_t_fail "install.sh copy staged with its re-exec and cache path rewritten"
fi
run_timed 6 bash "${INSTALL_COPY}" --skip-if-busy --cached-only
_t_eq "0" "$RC" "install.sh --cached-only succeeds"
assert_fast "install.sh --cached-only does not wait on the network"
assert_no_curl "install.sh --cached-only makes no curl call"
assert_called write_hosts_file "it still writes /etc/hosts from the cache"
assert_called setup_hosts_guards "it still re-arms the hosts guard"

echo "== install.sh --cached-only, no cache =="
reset_state
rm -f "${CACHE}"
stage_install_copy
run_timed 6 bash "${INSTALL_COPY}" --skip-if-busy --cached-only
_t_eq "1" "$RC" "install.sh --cached-only with no cache exits 1"
assert_no_curl "it does not fall back to the network"
assert_not_called stop_hosts_guard "the guard stays up"
assert_not_called write_hosts_file "/etc/hosts is not touched"

echo "== install.sh without --cached-only still refreshes =="
reset_state
stage_cache
stage_install_copy
run_timed 2 bash "${INSTALL_COPY}"
_t_eq "124" "$RC" "a plain run still goes to the network (the timer keeps downloading)"

echo "== CACHED_ONLY cannot be injected through the environment =="
reset_state
stage_cache
stage_install_copy
run_timed 2 env CACHED_ONLY=1 bash "${INSTALL_COPY}"
_t_eq "124" "$RC" "only the flag turns it on (install.sh is re-exec'd with sudo -E)"

_t_summary
