#!/usr/bin/env bash
# Tests for the two anti-tamper guards: lib/hosts_protect_custom.sh and
# lib/hosts_protect_unblock.sh.
#
# These are the highest-stakes functions in the file. They exist to stop the
# blocklist being quietly weakened by editing this repo — the custom guard
# refuses when blocked domains are REMOVED, the unblock guard refuses when the
# whitelist GROWS. A split that silently disabled either would be invisible
# until the day it mattered, so both directions of both guards get a case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"
# shellcheck source=../hosts_protect_custom.sh
. "${SCRIPT_DIR}/../hosts_protect_custom.sh"
# shellcheck source=../hosts_protect_unblock.sh
. "${SCRIPT_DIR}/../hosts_protect_unblock.sh"

export HOSTS_INSTALL_SCRIPT_PATH="${FAKE_SCRIPT}"

echo "== extract_custom_entries_from_script =="
reset_state
stage_script a.com b.com c.com -- x.com
_t_eq "a.com
b.com
c.com" "$(extract_custom_entries_from_script "${FAKE_SCRIPT}")" \
	"the blocked domains are read out of the data file"

reset_state
mkdir -p "${FAKE_ROOT}"
printf '#!/bin/bash\n' >"${FAKE_SCRIPT}"
# No data file beside the script: the list reads as empty, which the guard
# treats as "everything was removed" and refuses. Failing safe is the point.
_t_eq "" "$(extract_custom_entries_from_script "${FAKE_SCRIPT}")" \
	"a missing data file yields an empty list rather than an error"

echo "== extract_custom_entries_from_hosts =="
reset_state
hosts_fixture="${TEST_TMPDIR}/hosts.sample"
{
	printf '127.0.0.1 localhost\n'
	printf '0.0.0.0 upstream-junk.com\n'
	printf '# Custom blocking entries\n'
	printf '0.0.0.0 mine-one.com\n'
	printf '0.0.0.0 mine-two.com\n'
} >"$hosts_fixture"
_t_eq "mine-one.com
mine-two.com" "$(extract_custom_entries_from_hosts "$hosts_fixture")" \
	"only entries after the marker count as ours"

reset_state
# A machine with no /etc/hosts at all is the pre-install state; reading it must
# yield an empty list rather than an error, or the first install could not run.
_t_eq "" "$(extract_custom_entries_from_hosts "${TEST_TMPDIR}/no-such-hosts")" \
	"a missing hosts file yields an empty list"

echo "== count_lines =="
_t_eq "0" "$(count_lines "")" "an empty string counts as zero, not one"
_t_eq "1" "$(count_lines "one")" "a single entry counts as one"
_t_eq "3" "$(count_lines "$(printf 'a\nb\nc')")" "three entries count as three"

echo "== load_saved_custom_entries =="
reset_state
_t_eq "" "$(load_saved_custom_entries)" "no state file reads as empty"
stage_custom_state b.com a.com
_t_eq "a.com
b.com" "$(load_saved_custom_entries)" "a state file reads back sorted"

echo "== save_custom_entries_state =="
reset_state
save_custom_entries_state "$(printf 'z.com\na.com\n')"
_t_eq "a.com
z.com" "$(cat "${CUSTOM_ENTRIES_STATE_FILE}")" "the saved state is sorted and unique"
if grep -q "chattr +i" "${HOSTS_TEST_CALLS}"; then
	_t_pass "the state file is made immutable after writing"
else
	_t_fail "the state file is made immutable after writing"
fi

echo "== check_custom_entries_protection: first run =="
reset_state
stage_script a.com b.com -- x.com
# No state file and nothing in /etc/hosts to fall back on means this is the
# first install, which must be allowed or the system could never be set up.
CUSTOM_ENTRIES_STATE_FILE="${TEST_TMPDIR}/nonexistent.state"
# The fallback reads the live hosts file, which on a real machine already has
# our entries; point it at an empty fixture so this is genuinely a first run.
HOSTS_FILE_PATH="${TEST_TMPDIR}/empty.hosts"
: >"${HOSTS_FILE_PATH}"
out="$(check_custom_entries_protection || true)"
_t_has "$out" "First installation" "a first run is allowed"
CUSTOM_ENTRIES_STATE_FILE="${TEST_TMPDIR}/custom.state"
unset HOSTS_FILE_PATH

echo "== check_custom_entries_protection: nothing removed =="
reset_state
stage_script a.com b.com -- x.com
stage_custom_state a.com b.com
_t_allows check_custom_entries_protection "an unchanged list is allowed"

echo "== check_custom_entries_protection: entries added =="
reset_state
stage_script a.com b.com c.com -- x.com
stage_custom_state a.com b.com
_t_allows check_custom_entries_protection "adding entries is allowed"

echo "== check_custom_entries_protection: an entry removed is BLOCKED =="
reset_state
stage_script a.com -- x.com
stage_custom_state a.com b.com
_t_blocks check_custom_entries_protection "removing a blocked domain is refused"
out="$(check_custom_entries_protection || true)"
_t_has "$out" "INSTALLATION BLOCKED" "the refusal is stated plainly"
_t_has "$out" "b.com" "the removed domain is named"

echo "== check_custom_entries_protection: swapping entries is still a removal =="
reset_state
# Same count, different contents. A count-only check would pass this, which is
# exactly the hole the removed-set comparison exists to close.
stage_script a.com NEW.com -- x.com
stage_custom_state a.com b.com
_t_blocks check_custom_entries_protection "swapping one domain for another is refused"

echo "== extract_unblock_entries_from_script =="
reset_state
stage_script a.com -- one.com two.com
_t_eq "one.com
two.com" "$(extract_unblock_entries_from_script "${FAKE_SCRIPT}")" \
	"the whitelist is read from between the markers"

echo "== check_unblock_entries_protection: first run =="
reset_state
stage_script a.com -- one.com
UNBLOCK_STATE_FILE="${TEST_TMPDIR}/nonexistent-unblock.state"
_t_allows check_unblock_entries_protection "a first run is allowed"
UNBLOCK_STATE_FILE="${TEST_TMPDIR}/unblock.state"

echo "== check_unblock_entries_protection: unchanged =="
reset_state
stage_script a.com -- one.com two.com
stage_unblock_state one.com two.com
_t_allows check_unblock_entries_protection "an unchanged whitelist is allowed"

echo "== check_unblock_entries_protection: shrinking is allowed =="
reset_state
# Removing a domain from the whitelist means blocking MORE, which is always
# the safe direction and must never be refused.
stage_script a.com -- one.com
stage_unblock_state one.com two.com
_t_allows check_unblock_entries_protection "removing a whitelist entry is allowed"

echo "== check_unblock_entries_protection: growing is BLOCKED =="
reset_state
stage_script a.com -- one.com two.com three.com
stage_unblock_state one.com two.com
_t_blocks check_unblock_entries_protection "adding a whitelist entry is refused"
out="$(check_unblock_entries_protection || true)"
_t_has "$out" "three.com" "the newly whitelisted domain is named"

echo "== save_unblock_entries_state =="
reset_state
save_unblock_entries_state "$(printf 'z.com\na.com\n')"
_t_eq "a.com
z.com" "$(cat "${UNBLOCK_STATE_FILE}")" "the saved whitelist is sorted and unique"

_t_summary
