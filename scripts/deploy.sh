#!/bin/bash
# Deploy hosts-blocker for real: fast-forward kuhy's live checkout (the one
# the browser wrappers, hosts-file-monitor and the hourly maintenance timer
# run install.sh from), rerun install.sh, then health-check /etc/hosts.
# Idempotent. `--check` runs the health check only.
# Exits non-zero unless every health check passes.
#
# The live checkout may carry uncommitted edits to the block/unblock lists;
# those are kuhy's live intent, so they are kept. `pull --ff-only` still
# refuses when they collide with an incoming change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIVE_DIR="${HOSTS_BLOCKER_LIVE_DIR:-${HOME}/src/hosts-blocker}"
readonly HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
# The StevenBlack fakenews-gambling-porn-social feed is ~160k entries; far
# fewer means the upstream list never made it in.
readonly HOSTS_MIN_ENTRIES="${HOSTS_MIN_ENTRIES:-100000}"
# -n: fail instead of hanging on a password prompt in a board session.
readonly INSTALL_CMD="${HOSTS_BLOCKER_INSTALL_CMD:-sudo -n bash ${LIVE_DIR}/install.sh}"

# shellcheck source=../lib/hosts_write.sh
. "${SCRIPT_DIR}/../lib/hosts_write.sh"

log() { printf 'deploy: %s\n' "$1" >&2; }
fail() {
	printf 'deploy: FAILED -- %s\n' "$1" >&2
	exit 1
}

update_checkout() {
	log "pulling $LIVE_DIR"
	git -C "$LIVE_DIR" fetch -q origin || fail "git fetch in $LIVE_DIR"
	git -C "$LIVE_DIR" pull -q --ff-only origin main ||
		fail "git pull --ff-only in $LIVE_DIR (local edits collide or diverged?)"
}

run_install() {
	log "running install.sh"
	# Word-split on purpose: the default is a command with arguments.
	# shellcheck disable=SC2086
	$INSTALL_CMD || fail "install.sh exited non-zero"
}

health_check() {
	[[ "$(git -C "$LIVE_DIR" rev-parse HEAD)" == "$(git -C "$LIVE_DIR" rev-parse origin/main)" ]] ||
		fail "$LIVE_DIR HEAD is not origin/main"
	[[ -r "$HOSTS_FILE" ]] || fail "$HOSTS_FILE is not readable"

	local entries
	entries="$(grep -c '^0\.0\.0\.0[[:space:]]' "$HOSTS_FILE" || true)"
	((entries >= HOSTS_MIN_ENTRIES)) ||
		fail "$HOSTS_FILE has ${entries} blocked entries, want >= ${HOSTS_MIN_ENTRIES}"

	# Every custom entry from the live checkout must be live in the hosts file.
	local missing
	missing="$(grep '^0\.0\.0\.0[[:space:]]' "${LIVE_DIR}/custom_entries.hosts" |
		awk '{print $2}' | sort -u |
		comm -23 - <(awk '$1 == "0.0.0.0" {print $2}' "$HOSTS_FILE" | sort -u))"
	[[ -z "$missing" ]] || fail "custom entries missing from $HOSTS_FILE: $(head -5 <<<"$missing" | tr '\n' ' ')"

	# An IPv4-only block lets AAAA lookups fall through to DNS: every
	# 0.0.0.0 domain needs its :: twin (lib/hosts_ipv6_pairs.awk).
	local v6_missing
	v6_missing="$(awk '$1 == "0.0.0.0" && $2 != "0.0.0.0" {print $2}' "$HOSTS_FILE" | sort -u |
		comm -23 - <(awk '$1 == "::" {print $2}' "$HOSTS_FILE" | sort -u))"
	[[ -z "$v6_missing" ]] ||
		fail "$(wc -l <<<"$v6_missing") blocks lack a :: IPv6 twin in $HOSTS_FILE: $(head -3 <<<"$v6_missing" | tr '\n' ' ')"

	verify_unblocks "$HOSTS_FILE" >/dev/null || fail "unblocked domains are blocked in $HOSTS_FILE"
	log "healthy: ${entries} blocked entries, each with a :: twin, all custom entries live"
}

main() {
	if [[ "${1:-}" != "--check" ]]; then
		update_checkout
		run_install
	fi
	health_check
	log "deployed $(git -C "$LIVE_DIR" rev-parse --short HEAD)"
}

main "$@"
