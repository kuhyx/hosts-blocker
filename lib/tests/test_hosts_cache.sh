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
for a in "$@"; do
	[[ "$prev" == "-o" ]] && out="$a"
	prev="$a"
done
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

_t_summary
