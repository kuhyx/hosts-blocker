#!/usr/bin/env bash
# Tests for which domains the hosts build blocks and which it unblocks.
#
# loverslab.com and delio.com.pl were on the unblock list; kuhy moved them to
# the block side (2026-11-20). Two checks keep them there:
#   1. generate_hosts_file.sh, run on a fixture upstream list, must emit live
#      0.0.0.0 (and :: for loverslab) lines for them, while the remaining
#      unblocks (facebook, linkedin) stay commented out.
#   2. No unblock path names them: the seds in lib/hosts_write.sh and
#      generate_hosts_file.sh, install.sh's PROTECTED_UNBLOCK_LIST, and
#      UNBLOCK_VERIFY_DOMAINS.
# delio.com.pl is also a custom entry appended after the seds, so check 1
# passes for it either way; check 2 is what catches a delio unblock.
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
# shellcheck source=../hosts_protect_unblock.sh
. "${REPO_ROOT}/lib/hosts_protect_unblock.sh"

readonly BLOCKED=(loverslab.com www.loverslab.com cdn.loverslab.com static.loverslab.com delio.com.pl www.delio.com.pl
	# Lookalikes of the whatsapp unblock: scam domains that must stay blocked.
	www.downloads-whatsapp.com whatsappsupport.net whatsapp.com.evil.example)
readonly V6_BLOCKED=(loverslab.com www.loverslab.com cdn.loverslab.com static.loverslab.com delio.com.pl)
readonly STILL_UNBLOCKED=(facebook.com www.facebook.com linkedin.com
	# kuhy unblocked WhatsApp permanently (2026-11-23), like Messenger, to reach people.
	whatsapp.com web.whatsapp.com dyn.web.whatsapp.com whatsapp.net mmg.whatsapp.net)

printf '#!/usr/bin/env bash\nexit 22\n' >"${FAKE_BIN}/curl"
chmod +x "${FAKE_BIN}/curl"

readonly CACHE="${TEST_TMPDIR}/stevenblack.cache"
readonly OUT="${TEST_TMPDIR}/generated.hosts"
{
	echo '# Title: StevenBlack/hosts (fixture)'
	for d in "${BLOCKED[@]}" "${STILL_UNBLOCKED[@]}" filler.example; do
		echo "0.0.0.0 $d"
	done
} >"$CACHE"

echo "generate_hosts_file.sh: blocks loverslab and delio, keeps other unblocks"
if HOSTS_CACHE="$CACHE" bash "${REPO_ROOT}/generate_hosts_file.sh" "$OUT" >/dev/null 2>"${TEST_TMPDIR}/gen.err"; then
	_t_pass "generator exits 0"
else
	_t_fail "generator exits 0 ($(tail -3 "${TEST_TMPDIR}/gen.err"))"
fi
for d in "${BLOCKED[@]}"; do
	if grep -qxF "0.0.0.0 $d" "$OUT"; then _t_pass "0.0.0.0 $d"; else _t_fail "0.0.0.0 $d missing"; fi
done
# An IPv4-only entry lets the AAAA lookup fall through to DNS, so the site
# still loads over IPv6 unless a :: line blocks it too.
for d in "${V6_BLOCKED[@]}"; do
	if grep -qxF ":: $d" "$OUT"; then _t_pass ":: $d"; else _t_fail ":: $d missing (IPv6 leak)"; fi
done
for d in "${STILL_UNBLOCKED[@]}"; do
	if grep -qxF "0.0.0.0 $d" "$OUT"; then _t_fail "$d must stay unblocked"; else _t_pass "$d still unblocked"; fi
done

echo "no unblock path names loverslab or delio"
for f in lib/hosts_write.sh generate_hosts_file.sh; do
	hits="$(grep -nE '^[[:space:]]*(sudo )?sed .*(loverslab|delio)' "${REPO_ROOT}/$f" || true)"
	_t_eq "" "$hits" "no unblock sed in $f"
done
hits="$(extract_unblock_entries_from_script "${REPO_ROOT}/install.sh" | grep -E 'loverslab|delio' || true)"
_t_eq "" "$hits" "install.sh PROTECTED_UNBLOCK_LIST"
hits="$(printf '%s\n' "${UNBLOCK_VERIFY_DOMAINS[@]}" | grep -E 'loverslab|delio' || true)"
_t_eq "" "$hits" "UNBLOCK_VERIFY_DOMAINS"
# The facebook unblock is still expected, so the list itself must survive.
_t_has "${UNBLOCK_VERIFY_DOMAINS[*]}" "facebook.com" "UNBLOCK_VERIFY_DOMAINS keeps facebook.com"

echo "whatsapp is on every unblock path"
for d in whatsapp.com whatsapp.net; do
	_t_has "${UNBLOCK_VERIFY_DOMAINS[*]}" "$d" "UNBLOCK_VERIFY_DOMAINS has $d"
	_t_has "$(extract_unblock_entries_from_script "${REPO_ROOT}/install.sh")" "$d" "install.sh PROTECTED_UNBLOCK_LIST has $d"
done

_t_summary
