#!/usr/bin/env bash
# Tests for lib/hosts_cache.sh — keeping the local copy of the upstream
# StevenBlack list current.
#
# The date parsing is what decides whether a download happens at all: the
# upstream file carries a "# Date:" header, and a cache whose header is not
# older than the remote one is reused. Misreading that header means either
# re-downloading a 4 MB file on every install, or never refreshing at all.
#
# curl is shimmed, so nothing here touches the network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"

# Fake curl. `-o <file>` writes whatever $DEV/remote_body holds; a
# $DEV/curl_fails marker makes every invocation fail, which is what exercises
# the "keep using the stale cache" path.
cat >"${FAKE_BIN}/curl" <<'CURLSHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "curl $*" >>"${HOSTS_TEST_CALLS}"
dev="$(dirname "${HOSTS_TEST_CALLS}")"
[[ -f "${dev}/curl_fails" ]] && exit 22
out=""
prev=""
ranged=0
max_time=0
for a in "$@"; do
	[[ "$prev" == "-o" ]] && out="$a"
	[[ "$a" == Range:* ]] && ranged=1
	[[ "$a" == --max-time ]] && max_time=1
	prev="$a"
done
# The full download is the one call with -o and no Range header. full_fails
# makes only that call fail; full_hangs makes it stall like a dead server:
# real curl gives up with exit 28 when it has --max-time, and without one it
# would wait forever (exec, so timeout(1) kills the sleep itself and no
# orphan keeps a pipe open).
# range_fails: servers that ignore Range; the piped fallback is then used.
[[ $ranged -eq 1 && -f "${dev}/range_fails" ]] && exit 22
# pipe_exit23: after a good body on stdout, curl dies with 23 (write error)
# because head closed the pipe early; the header it delivered is still good.
if [[ -z "$out" && -f "${dev}/pipe_exit23" ]]; then
	cat "${dev}/remote_body"
	exit 23
fi
if [[ -n "$out" && $ranged -eq 0 ]]; then
	[[ -f "${dev}/full_fails" ]] && exit 22
	if [[ -f "${dev}/full_hangs" ]]; then
		[[ $max_time -eq 1 ]] && exit 28
		exec sleep 30
	fi
fi
body="${dev}/remote_body"
[[ -f "$body" ]] || : >"$body"
if [[ -n "$out" ]]; then
	cat "$body" >"$out"
else
	cat "$body"
fi
exit 0
CURLSHIM
chmod +x "${FAKE_BIN}/curl"

DEV="$(dirname "${HOSTS_TEST_CALLS}")"

# shellcheck source=../hosts_cache.sh
. "${SCRIPT_DIR}/../hosts_cache.sh"

# The lib reads $URL; point it somewhere obviously fake so a missing shim would
# be an immediate failure rather than a real request.
URL="http://test.invalid/hosts"

write_dated_file() { # <path> <date-header-or-empty>
	{
		[[ -n "${2:-}" ]] && printf '# Date: %s (UTC)\n' "$2"
		printf '# Title: fake\n0.0.0.0 blocked.example\n'
	} >"$1"
}

echo "== extract_date_epoch_from_file =="
reset_state
f="${TEST_TMPDIR}/dated"
write_dated_file "$f" "01 January 2026 00:00:00"
_t_eq "1767225600" "$(extract_date_epoch_from_file "$f")" "a dated header parses to epoch seconds"

write_dated_file "$f" ""
_t_eq "" "$(extract_date_epoch_from_file "$f")" "a file with no Date header yields nothing"

write_dated_file "$f" "not a real date"
_t_eq "" "$(extract_date_epoch_from_file "$f")" "an unparsable date yields nothing rather than a bad epoch"

_t_eq "" "$(extract_date_epoch_from_file "${TEST_TMPDIR}/no-such-file")" \
	"a missing file yields nothing"

echo "== fetch_remote_header =="
reset_state
write_dated_file "${DEV}/remote_body" "02 February 2026 00:00:00"
out="${TEST_TMPDIR}/header"
if fetch_remote_header "$out"; then
	_t_pass "a successful fetch reports success"
else
	_t_fail "a successful fetch reports success"
fi
_t_eq "1769990400" "$(extract_date_epoch_from_file "$out")" "the fetched header is readable"
if grep -q 'Range: bytes=0-4095' "${HOSTS_TEST_CALLS}"; then
	_t_pass "it asks for a byte range rather than the whole file"
else
	_t_fail "it asks for a byte range rather than the whole file"
fi

echo "== fetch_remote_header: both attempts fail =="
reset_state
: >"${DEV}/curl_fails"
if fetch_remote_header "${TEST_TMPDIR}/header2"; then
	_t_fail "a total fetch failure reports failure"
else
	_t_pass "a total fetch failure reports failure"
fi

echo "== fetch_remote_header: curl fails, caller without pipefail =="
# install.sh and the timers do not set pipefail; the test shell does, which
# hid that "curl | head" reports head's success. call_lib_fn.sh is a fresh
# process without pipefail, like production.
reset_state
: >"${DEV}/curl_fails"
rc_line="$(URL="$URL" timeout 10 "${SCRIPT_DIR}/call_lib_fn.sh" "${SCRIPT_DIR}/../hosts_cache.sh" \
	fetch_remote_header "${TEST_TMPDIR}/header3" 2>&1 || true)"
_t_has "$rc_line" "rc=1" "a failing curl fails the header fetch even without pipefail"

echo "== fetch_remote_header: curl exit 23 after a good header =="
reset_state
write_dated_file "${DEV}/remote_body" "02 February 2026 00:00:00"
: >"${DEV}/range_fails"
: >"${DEV}/pipe_exit23"
rc_line="$(URL="$URL" timeout 10 "${SCRIPT_DIR}/call_lib_fn.sh" "${SCRIPT_DIR}/../hosts_cache.sh" \
	fetch_remote_header "${TEST_TMPDIR}/header4" 2>&1 || true)"
_t_has "$rc_line" "rc=0" "head closing the pipe on a good fetch still counts as success"
_t_eq "1769990400" "$(extract_date_epoch_from_file "${TEST_TMPDIR}/header4")" \
	"the header kept after the early close is readable"

echo "== download_remote_full_to =="
reset_state
write_dated_file "${DEV}/remote_body" "03 March 2026 00:00:00"
full="${TEST_TMPDIR}/full"
if download_remote_full_to "$full"; then
	_t_pass "a full download reports success"
else
	_t_fail "a full download reports success"
fi
_t_eq "1772496000" "$(extract_date_epoch_from_file "$full")" "the downloaded file is the remote body"

reset_state
: >"${DEV}/curl_fails"
if download_remote_full_to "${TEST_TMPDIR}/full2"; then
	_t_fail "a failed download reports failure"
else
	_t_pass "a failed download reports failure"
fi

echo "== download_remote_full_to: a stalled server =="
reset_state
: >"${DEV}/full_hangs"
set +e
URL="$URL" timeout 10 "${SCRIPT_DIR}/call_lib_fn.sh" "${SCRIPT_DIR}/../hosts_cache.sh" \
	download_remote_full_to "${TEST_TMPDIR}/full3" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 124 && $rc -ne 0 ]]; then
	_t_pass "a stalled download gives up on its own and reports failure (rc $rc)"
else
	_t_fail "a stalled download gives up on its own and reports failure (rc $rc; 124 = hung)"
fi
_t_has "$(cat "${HOSTS_TEST_CALLS}")" "--connect-timeout 10 --max-time 120" \
	"the full download carries connect and total timeouts"

# refresh_upstream_cache runs as root inside install.sh. A failed download
# must leave the cached list in use, and must return (not exit) so the caller
# decides what happens to the guard. Run in a subshell: it sets an EXIT trap.
run_refresh() { # sets RC and OUT
	set +e
	OUT="$(URL="$URL" LOCAL_CACHE="$LOCAL_CACHE" timeout 10 "${SCRIPT_DIR}/call_lib_fn.sh" \
		"${SCRIPT_DIR}/../hosts_cache.sh" refresh_upstream_cache 2>&1)"
	RC=$?
	set -e
}
LOCAL_CACHE="${TEST_TMPDIR}/hosts.stevenblack"
for mode in full_fails full_hangs; do
	echo "== refresh_upstream_cache: outdated cache, ${mode} =="
	reset_state
	write_dated_file "$LOCAL_CACHE" "01 January 2026 00:00:00"
	cp "$LOCAL_CACHE" "${TEST_TMPDIR}/cache.before"
	write_dated_file "${DEV}/remote_body" "05 May 2026 00:00:00"
	: >"${DEV}/${mode}"
	run_refresh
	_t_has "$OUT" "rc=0" "${mode}: falls back to the cached list and returns 0 (got rc ${RC})"
	if cmp -s "$LOCAL_CACHE" "${TEST_TMPDIR}/cache.before"; then
		_t_pass "${mode}: the cached list is left byte-identical"
	else
		_t_fail "${mode}: the cached list is left byte-identical"
	fi
done

echo "== refresh_upstream_cache: offline, outdated cache =="
reset_state
write_dated_file "$LOCAL_CACHE" "01 January 2026 00:00:00"
cp "$LOCAL_CACHE" "${TEST_TMPDIR}/cache.before"
: >"${DEV}/curl_fails"
run_refresh
_t_has "$OUT" "rc=0" "offline: keeps the cached list and returns 0 (got rc ${RC})"
if grep -q -- '--max-time 120' "${HOSTS_TEST_CALLS}"; then
	_t_fail "offline: no full download is attempted"
else
	_t_pass "offline: no full download is attempted"
fi
if cmp -s "$LOCAL_CACHE" "${TEST_TMPDIR}/cache.before"; then
	_t_pass "offline: the cached list is left byte-identical"
else
	_t_fail "offline: the cached list is left byte-identical"
fi

echo "== refresh_upstream_cache: no cache, download fails =="
reset_state
rm -f "$LOCAL_CACHE"
write_dated_file "${DEV}/remote_body" "05 May 2026 00:00:00"
: >"${DEV}/full_fails"
run_refresh
_t_has "$OUT" "rc=1" "with nothing cached it returns 1 to the caller instead of exiting"

_t_summary
