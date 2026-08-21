#!/usr/bin/env bash
# lib/tests/hosts_harness.sh — shared fixture for the hosts/install.sh split.
#
# Sourced, not executed. Scope is deliberately narrow: only the two anti-tamper
# guards and their helpers are exercised here. The install phases themselves
# write /etc/hosts, unmount the guard's bind mount and restart
# systemd-resolved, so running them under test would take down the very
# protection they exist to install — they are covered by the textual
# wrap-verification in the evidence instead.
#
# The state-file paths were already variables in the pre-split script, so a
# test can point them at a tmpdir. chattr is shimmed because the real one
# cannot mark a file immutable on a tmpfs and would abort the guard.
set -euo pipefail

PASS=0
FAIL=0

_t_pass() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

_t_eq() {
	local want="$1"
	local got="$2"
	local what="$3"
	if [[ "$got" == "$want" ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want '${want}', got '${got}')"
	fi
}

_t_has() {
	local haystack="$1"
	local needle="$2"
	local what="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want a substring '${needle}')"
	fi
}

# The guards return 0 to allow the install and 1 to block it. Which way they
# fail is the entire point, so assert on the exit status explicitly rather than
# letting `set -e` decide.
_t_allows() {
	local what="$2"
	if ("$1"); then
		_t_pass "$what"
	else
		_t_fail "$what (the guard blocked when it should have allowed)"
	fi
}

_t_blocks() {
	local what="$2"
	if ("$1"); then
		_t_fail "$what (the guard allowed when it should have blocked)"
	else
		_t_pass "$what"
	fi
}

_t_summary() {
	printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]]
}

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

readonly FAKE_BIN="${TEST_TMPDIR}/fake_bin"
mkdir -p "${FAKE_BIN}"

# chattr cannot set the immutable bit on a tmpfs and exits non-zero; the guards
# tolerate that with `|| true`, but shimming it keeps the test output clean and
# makes "was the state file locked" observable.
cat >"${FAKE_BIN}/chattr" <<'CHATTRSHIM'
#!/usr/bin/env bash
printf '%s\n' "chattr $*" >>"${HOSTS_TEST_CALLS}"
exit 0
CHATTRSHIM
chmod +x "${FAKE_BIN}/chattr"

export HOSTS_TEST_CALLS="${TEST_TMPDIR}/calls"
export PATH="${FAKE_BIN}:${PATH}"

# --- globals the guards read ------------------------------------------------

export CUSTOM_ENTRIES_STATE_FILE="${TEST_TMPDIR}/custom.state"
export UNBLOCK_STATE_FILE="${TEST_TMPDIR}/unblock.state"

# A fake install.sh plus the custom_entries.hosts beside it. The guards resolve
# the data file from the script path, so this reproduces the real layout.
readonly FAKE_ROOT="${TEST_TMPDIR}/root"
readonly FAKE_SCRIPT="${FAKE_ROOT}/install.sh"

# Stage the "new" entry lists the guards will read: the custom blocklist as a
# data file, and the unblock list as marked-up comments inside the script.
stage_script() { # <custom-domain>... -- <unblock-domain>...
	mkdir -p "${FAKE_ROOT}"
	local mode="custom"
	local custom=()
	local unblock=()
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--" ]]; then
			mode="unblock"
			continue
		fi
		if [[ "$mode" == "custom" ]]; then
			custom+=("$arg")
		else
			unblock+=("$arg")
		fi
	done

	{
		printf '# Custom blocking entries\n'
		local d
		for d in "${custom[@]}"; do
			printf '0.0.0.0 %s\n' "$d"
		done
	} >"${FAKE_ROOT}/custom_entries.hosts"

	{
		printf '#!/bin/bash\n'
		printf '# PROTECTED_UNBLOCK_LIST_START\n'
		local d
		for d in "${unblock[@]}"; do
			printf '# %s\n' "$d"
		done
		printf '# PROTECTED_UNBLOCK_LIST_END\n'
	} >"${FAKE_SCRIPT}"
}

# Seed the saved state the guards compare against.
stage_custom_state() {
	printf '%s\n' "$@" | sort -u >"${CUSTOM_ENTRIES_STATE_FILE}"
}

stage_unblock_state() {
	printf '%s\n' "$@" | sort -u >"${UNBLOCK_STATE_FILE}"
}

reset_state() {
	rm -rf "${FAKE_ROOT}"
	rm -f "${CUSTOM_ENTRIES_STATE_FILE}" "${UNBLOCK_STATE_FILE}"
	# Markers a test sets to steer a shim (e.g. curl_fails) are part of the
	# machine that test describes, so they reset too -- otherwise a failure
	# marker leaks into the next group and it passes for the wrong reason.
	rm -f "$(dirname "${HOSTS_TEST_CALLS}")"/curl_fails \
		"$(dirname "${HOSTS_TEST_CALLS}")"/remote_body
	: >"${HOSTS_TEST_CALLS}"
	mkdir -p "${FAKE_ROOT}"
}
reset_state
