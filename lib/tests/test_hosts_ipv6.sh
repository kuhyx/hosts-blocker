#!/usr/bin/env bash
# Every live "0.0.0.0 domain" block needs a ":: domain" twin.
#
# The upstream StevenBlack list is IPv4-only. With only an A-side entry, an
# AAAA lookup falls through to DNS (2026-11-20: `getent hosts reddit.com`
# returned reddit's real IPv6 addresses), so any IPv6-capable client reaches
# the blocked site. Both hosts builders -- write_hosts_file (/etc/hosts) and
# generate_hosts_file.sh (the LAN feed) -- must add the pairs, once each.
#
# Nothing here touches /etc or the network: the cache is a fixture and curl is
# a shim that always fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"
# shellcheck source=../hosts_write.sh
. "${REPO_ROOT}/lib/hosts_write.sh"

printf '#!/usr/bin/env bash\nexit 22\n' >"${FAKE_BIN}/curl"
chmod +x "${FAKE_BIN}/curl"

readonly CACHE="${TEST_TMPDIR}/stevenblack.cache"
readonly OUT="${TEST_TMPDIR}/generated.hosts"
cat >"$CACHE" <<'FIXTURE'
# Title: StevenBlack/hosts (fixture)
127.0.0.1 localhost
::1 localhost
0.0.0.0 0.0.0.0
0.0.0.0 reddit.com
0.0.0.0 trailing.example # ads with redirects
0.0.0.0 facebook.com
0.0.0.0 www.linkedin.com
0.0.0.0 delio.com.pl
FIXTURE

# v6 domain list of a hosts file, one per line, duplicates kept.
v6_domains() { awk '$1 == "::" {print $2}' "$1"; }

# Asserts shared by both builders' output.
check_pairs() {
	local file="$1" who="$2" d
	for d in reddit.com trailing.example youtube.com delio.com.pl loverslab.com; do
		if grep -qxF ":: $d" "$file"; then _t_pass "$who: :: $d"; else _t_fail "$who: :: $d missing (IPv6 leak)"; fi
	done
	_t_eq "0.0.0.0 reddit.com|:: reddit.com" \
		"$(grep -A1 -xF '0.0.0.0 reddit.com' "$file" | paste -sd'|')" "$who: pair sits next to its v4 line"
	for d in 0.0.0.0 facebook.com www.linkedin.com localhost; do
		if grep -qxF ":: $d" "$file"; then _t_fail "$who: :: $d must not be added"; else _t_pass "$who: no :: $d"; fi
	done
	_t_eq "" "$(v6_domains "$file" | sort | uniq -d | head -3)" "$who: no duplicate :: lines"
	_t_eq "" "$(awk '$1 == "0.0.0.0" && $2 != "0.0.0.0" {print $2}' "$file" | sort -u |
		comm -23 - <(v6_domains "$file" | sort -u) | head -3)" "$who: every live v4 block has a v6 twin"
}

echo "generate_hosts_file.sh pairs every block with ::"
if HOSTS_CACHE="$CACHE" bash "${REPO_ROOT}/generate_hosts_file.sh" "$OUT" >/dev/null 2>"${TEST_TMPDIR}/gen.err"; then
	_t_pass "generator exits 0"
else
	_t_fail "generator exits 0 ($(tail -3 "${TEST_TMPDIR}/gen.err"))"
fi
check_pairs "$OUT" generator

echo "pair_ipv6_blocks (the /etc/hosts path) pairs every block with ::"
readonly STAGED="${TEST_TMPDIR}/staged.hosts"
{
	sed -E 's/^(0\.0\.0\.0 (facebook\.com|www\.linkedin\.com))/#\1/' "$CACHE"
	cat "${REPO_ROOT}/custom_entries.hosts"
} >"$STAGED"
if pair_ipv6_blocks "$STAGED" >"${TEST_TMPDIR}/paired.hosts" 2>/dev/null; then
	_t_pass "pair_ipv6_blocks exits 0"
else
	_t_fail "pair_ipv6_blocks exits 0"
fi
check_pairs "${TEST_TMPDIR}/paired.hosts" pair_ipv6_blocks
_t_eq "$(grep -cv '^::' "$STAGED")" "$(grep -cv '^::' "${TEST_TMPDIR}/paired.hosts")" \
	"pair_ipv6_blocks keeps every non-:: line"

echo "write_hosts_file runs the pairing before it verifies and swaps"
body="$(declare -f write_hosts_file)"
_t_has "$body" "pair_ipv6_blocks" "write_hosts_file calls pair_ipv6_blocks"
pair_at="$(grep -n 'pair_ipv6_blocks' <<<"$body" | head -1 | cut -d: -f1 || true)"
verify_at="$(grep -n 'verify_unblocks' <<<"$body" | head -1 | cut -d: -f1 || true)"
if [[ -n $pair_at && -n $verify_at ]] && ((pair_at < verify_at)); then
	_t_pass "pairing runs before verify_unblocks"
else
	_t_fail "pairing runs before verify_unblocks"
fi

echo "verify_unblocks also rejects a live :: block on an unblocked domain"
printf ':: facebook.com\n' >"${TEST_TMPDIR}/v6_unblock.hosts"
if verify_unblocks "${TEST_TMPDIR}/v6_unblock.hosts" >/dev/null 2>&1; then
	_t_fail ":: facebook.com must fail verify_unblocks"
else
	_t_pass ":: facebook.com fails verify_unblocks"
fi

_t_summary
