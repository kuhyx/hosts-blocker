#!/usr/bin/env bash
# Tests for scripts/deploy.sh — fast-forward the live checkout, rerun
# install.sh, and refuse to report success unless /etc/hosts really carries
# the blocklist.
#
# Everything runs against a throwaway origin + live clone and a fake hosts
# file; the install step is replaced by a stub so nothing touches /etc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly DEPLOY="${REPO_ROOT}/scripts/deploy.sh"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# A bare origin with two commits and a live clone sitting on the first, so a
# deploy has something to fast-forward.
make_repos() {
	local work="${TEST_TMPDIR}/work"
	rm -rf "$work" "${TEST_TMPDIR}/origin.git" "${TEST_TMPDIR}/live"
	git_q init "$work"
	printf '# custom\n0.0.0.0 blocked-one.example\n0.0.0.0 blocked-two.example\n' >"${work}/custom_entries.hosts"
	git_q -C "$work" add -A
	git_q -C "$work" commit -m one
	git_q clone --bare "$work" "${TEST_TMPDIR}/origin.git"
	git_q clone "${TEST_TMPDIR}/origin.git" "${TEST_TMPDIR}/live"
	printf 'two\n' >"${work}/second"
	git_q -C "$work" add -A
	git_q -C "$work" commit -m two
	git_q -C "$work" push "${TEST_TMPDIR}/origin.git" main
}

# Stub install: writes a hosts file with N filler entries plus the live
# checkout's custom entries, unless told to fail or to drop them.
cat >"${FAKE_BIN}/fake_install" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
dev="$(dirname "${HOSTS_FILE}")"
[[ -f "${dev}/install_fails" ]] && exit 3
{
	echo '# Title: StevenBlack/hosts'
	for i in $(seq 1 "${FILLER:-20}"); do echo "0.0.0.0 filler${i}.example"; done
	[[ -f "${dev}/drop_custom" ]] || grep '^0\.0\.0\.0' "${HOSTS_BLOCKER_LIVE_DIR}/custom_entries.hosts"
} | if [[ -f "${dev}/drop_v6" ]]; then cat; else awk '{print} $1 == "0.0.0.0" {print ":: " $2}'; fi >"${HOSTS_FILE}"
echo ran >>"${dev}/install_calls"
INSTALL
chmod +x "${FAKE_BIN}/fake_install"

run_deploy() {
	HOSTS_BLOCKER_LIVE_DIR="${TEST_TMPDIR}/live" \
		HOSTS_FILE="${TEST_TMPDIR}/hosts" \
		HOSTS_BLOCKER_INSTALL_CMD="${FAKE_BIN}/fake_install" \
		HOSTS_MIN_ENTRIES=10 \
		bash "$DEPLOY" "$@" >"${TEST_TMPDIR}/out" 2>&1
}

reset_state() {
	rm -f "${TEST_TMPDIR}/hosts" "${TEST_TMPDIR}/install_fails" \
		"${TEST_TMPDIR}/drop_custom" "${TEST_TMPDIR}/drop_v6" "${TEST_TMPDIR}/install_calls"
	make_repos
}

echo "deploy: happy path fast-forwards, installs and passes the health check"
reset_state
if run_deploy; then _t_pass "deploy exits 0"; else _t_fail "deploy exits 0 ($(tail -3 "${TEST_TMPDIR}/out"))"; fi
_t_eq "$(git -C "${TEST_TMPDIR}/origin.git" rev-parse main)" \
	"$(git -C "${TEST_TMPDIR}/live" rev-parse HEAD)" "live checkout is at origin/main"
_t_eq "1" "$(cat "${TEST_TMPDIR}/install_calls" 2>/dev/null | wc -l)" "install ran once"

echo "deploy: a second run is idempotent"
if run_deploy; then _t_pass "rerun exits 0"; else _t_fail "rerun exits 0"; fi

echo "deploy: a failed install fails the deploy"
reset_state
touch "${TEST_TMPDIR}/install_fails"
if run_deploy; then _t_fail "install failure exits non-zero"; else _t_pass "install failure exits non-zero"; fi

echo "deploy: a hosts file missing a custom entry fails the health check"
reset_state
touch "${TEST_TMPDIR}/drop_custom"
if run_deploy; then _t_fail "missing custom entry exits non-zero"; else _t_pass "missing custom entry exits non-zero"; fi
_t_has "$(cat "${TEST_TMPDIR}/out")" "blocked-one.example" "failure names the missing domain"

echo "deploy: a block with no :: twin fails the health check (IPv6 leak)"
reset_state
touch "${TEST_TMPDIR}/drop_v6"
if run_deploy; then _t_fail "IPv4-only hosts file exits non-zero"; else _t_pass "IPv4-only hosts file exits non-zero"; fi
_t_has "$(cat "${TEST_TMPDIR}/out")" "IPv6" "failure names the IPv6 gap"

echo "deploy: a hosts file below the entry floor fails the health check"
reset_state
if FILLER=0 HOSTS_MIN_ENTRIES=10 run_deploy; then _t_fail "thin hosts file exits non-zero"; else _t_pass "thin hosts file exits non-zero"; fi

echo "deploy: --check on a checkout behind origin fails without installing"
reset_state
"${FAKE_BIN}/fake_install" 2>/dev/null || true
rm -f "${TEST_TMPDIR}/install_calls"
git -C "${TEST_TMPDIR}/live" fetch -q origin
if HOSTS_FILE="${TEST_TMPDIR}/hosts" HOSTS_BLOCKER_LIVE_DIR="${TEST_TMPDIR}/live" run_deploy --check; then
	_t_fail "--check behind origin exits non-zero"
else
	_t_pass "--check behind origin exits non-zero"
fi
if [[ -f "${TEST_TMPDIR}/install_calls" ]]; then _t_fail "--check must not install"; else _t_pass "--check did not install"; fi

_t_summary
