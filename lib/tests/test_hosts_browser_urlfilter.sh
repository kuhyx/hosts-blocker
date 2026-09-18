#!/usr/bin/env bash
# Tests for lib/hosts_browser_urlfilter.sh — the facebook.com feed block that
# keeps Messenger working.
#
# The two properties worth pinning are the ones a careless rewrite would
# break silently: the Firefox merge must keep whatever else policies.json
# already holds (LeechBlock's force-install, LibreWolf's own defaults), and a
# second run must change nothing, because install.sh runs on every browser
# launch. Every write goes to a tmpdir; nothing here touches /etc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hosts_harness.sh
. "${SCRIPT_DIR}/hosts_harness.sh"

CHROMIUM_DIR="${TEST_TMPDIR}/chromium/policies/managed"
CHROME_DIR="${TEST_TMPDIR}/chrome/policies/managed"
ABSENT_DIR="${TEST_TMPDIR}/absent/policies/managed"
FF_FILE="${TEST_TMPDIR}/firefox/policies.json"
LW_FILE="${TEST_TMPDIR}/librewolf/policies.json"
MISSING_FILE="${TEST_TMPDIR}/nowhere/policies.json"
mkdir -p "$CHROMIUM_DIR" "$CHROME_DIR" "$(dirname "$FF_FILE")" "$(dirname "$LW_FILE")"

# Firefox: what leechblock_firefox.sh leaves behind. LibreWolf: its shipped
# defaults, including a WebsiteFilter of its own that must survive.
printf '%s\n' '{"policies":{"ExtensionSettings":{"leechblockng@proginosko.com":{"installation_mode":"force_installed"}}}}' >"$FF_FILE"
printf '%s\n' '{"policies":{"DisableTelemetry":true,"WebsiteFilter":{"Block":["https://localhost/*"],"Exceptions":["https://localhost/*"]}}}' >"$LW_FILE"

export URLFILTER_CHROMIUM_DIRS="$CHROMIUM_DIR $CHROME_DIR $ABSENT_DIR"
export URLFILTER_FIREFOX_POLICY_FILES="$FF_FILE $LW_FILE $MISSING_FILE"

# shellcheck source=../hosts_browser_urlfilter.sh
. "${SCRIPT_DIR}/../hosts_browser_urlfilter.sh"

# "yes"/"no" for a path's existence, so the assertion reads as a value.
_exists() {
	if [[ -e $1 ]]; then echo yes; else echo no; fi
}

first_run="$(apply_browser_urlfilter 2>&1)"

printf '\n# Chromium family\n'
chromium_policy="$CHROMIUM_DIR/facebook-except-messenger.json"
_t_eq "yes" "$(_exists "$chromium_policy")" "policy file written to the chromium managed dir"
_t_eq "yes" "$(_exists "$CHROME_DIR/facebook-except-messenger.json")" "policy file written to the chrome managed dir"
_t_eq "no" "$(_exists "$ABSENT_DIR")" "a browser with no managed dir is skipped, not created"
_t_eq "facebook.com" "$(jq -r '.URLBlocklist[0]' "$chromium_policy")" "facebook.com is blocklisted"
_t_eq "1" "$(jq '.URLBlocklist | length' "$chromium_policy")" "only facebook.com is blocklisted"
_t_eq "true" "$(jq '.URLAllowlist | index("messenger.com") != null' "$chromium_policy")" "messenger.com is allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("l.facebook.com") != null' "$chromium_policy")" "the l.facebook.com link shim is allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/login") != null' "$chromium_policy")" "facebook.com/login is allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/checkpoint") != null' "$chromium_policy")" "the 2FA checkpoint is allowlisted"
_t_eq "0" "$(jq '[.URLAllowlist[] | select(. == "facebook.com")] | length' "$chromium_policy")" "the bare feed host is never allowlisted"

printf '\n# Firefox family: merge, do not overwrite\n'
_t_eq "force_installed" "$(jq -r '.policies.ExtensionSettings["leechblockng@proginosko.com"].installation_mode' "$FF_FILE")" "LeechBlock force-install survives the merge"
_t_eq "true" "$(jq '.policies.DisableTelemetry' "$LW_FILE")" "LibreWolf's other policies survive the merge"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Block | index("https://localhost/*") != null' "$LW_FILE")" "LibreWolf's own Block entry survives the merge"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Block | index("https://*.facebook.com/*") != null' "$LW_FILE")" "facebook.com is blocked in LibreWolf"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Block | index("https://*.facebook.com/*") != null' "$FF_FILE")" "facebook.com is blocked in Firefox"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Exceptions | index("https://*.messenger.com/*") != null' "$FF_FILE")" "messenger.com is excepted in Firefox"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Exceptions | index("https://*.l.facebook.com/*") != null' "$FF_FILE")" "the link shim is excepted in Firefox"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Exceptions | index("https://*.facebook.com/login*") != null' "$FF_FILE")" "login is excepted in Firefox"
_t_eq "no" "$(_exists "$MISSING_FILE")" "a policies.json that does not exist is not created"

printf '\n# Idempotence: a second run rewrites nothing\n'
before="$(cat "$chromium_policy" "$FF_FILE" "$LW_FILE" | sha256sum)"
touch -d '2000-01-01' "$chromium_policy" "$FF_FILE" "$LW_FILE"
second_run="$(apply_browser_urlfilter 2>&1)"
after="$(cat "$chromium_policy" "$FF_FILE" "$LW_FILE" | sha256sum)"
_t_eq "$before" "$after" "content is byte-identical after a second run"
_t_eq "2000" "$(date -r "$FF_FILE" +%Y)" "an unchanged policies.json is not rewritten"
_t_eq "2000" "$(date -r "$chromium_policy" +%Y)" "an unchanged chromium policy is not rewritten"
_t_has "$first_run" "URL filter written" "first run reports the write"
_t_eq "0" "$(printf '%s' "$second_run" | grep -c 'URL filter' || true)" "second run reports no write"
_t_eq "1" "$(jq '.policies.WebsiteFilter.Block | map(select(. == "https://*.facebook.com/*")) | length' "$LW_FILE")" "re-running does not duplicate Block entries"

printf '\n# A corrupt policies.json is left alone\n'
printf '%s\n' '{not json' >"$FF_FILE"
corrupt_run="$(apply_browser_urlfilter 2>&1)"
_t_has "$corrupt_run" "not valid JSON" "corrupt file is reported"
_t_eq "{not json" "$(cat "$FF_FILE")" "corrupt file is not overwritten"

printf '\n# Browser kill flag stays untouched\n'
_t_eq "" "${DOH_POLICY_CHANGED:-}" "the URL filter never arms restart_browsers"

_t_summary
