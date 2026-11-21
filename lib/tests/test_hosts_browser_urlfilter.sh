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
# The guard extension is built under the tmpdir too, never /usr/share or /var.
# Chromium flags files: one with a user-owned --load-extension list, one with
# other flags only, one that does not exist.
FLAGS_LIST="${TEST_TMPDIR}/flags/list.conf"
FLAGS_OTHER="${TEST_TMPDIR}/flags/other.conf"
FLAGS_MISSING="${TEST_TMPDIR}/flags/missing.conf"
mkdir -p "${TEST_TMPDIR}/flags"
printf '%s\n' '--load-extension=/home/u/ext-a,/usr/lib/ublock-origin' >"$FLAGS_LIST"
printf '%s\n' '--password-store=basic' >"$FLAGS_OTHER"
export URLFILTER_CHROMIUM_FLAGS_FILES="$FLAGS_LIST $FLAGS_OTHER $FLAGS_MISSING"
export URLGUARD_SHARE_DIR="${TEST_TMPDIR}/share/fb-spa-guard"
export URLGUARD_KEY="${TEST_TMPDIR}/state/guard.pem"

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
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/two_step_verification") != null' "$chromium_policy")" "the 2FA step messenger.com actually redirects to is allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/common") != null' "$chromium_policy")" "the auth pages' helper iframes (common/referer_frame.php) are allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/messages") != null' "$chromium_policy")" "Messenger's own home, facebook.com/messages, is allowlisted"
_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/messenger_media") != null' "$chromium_policy")" "Messenger attachments (messenger_media) are allowlisted"
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
_t_eq "true" "$(jq '.policies.WebsiteFilter.Block | index("https://facebook.com/*") != null' "$FF_FILE")" "the bare facebook.com host is blocked, not only *.facebook.com"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Exceptions | index("https://l.facebook.com/*") != null' "$FF_FILE")" "the bare link-shim host is excepted (LibreWolf: *.host misses the bare host)"
_t_eq "true" "$(jq '.policies.WebsiteFilter.Exceptions | index("https://facebook.com/login*") != null' "$FF_FILE")" "login is excepted on the bare host too"
chmod 0600 "$LW_FILE"
apply_browser_urlfilter >/dev/null 2>&1
_t_eq "644" "$(stat -c %a "$LW_FILE")" "a root-only policies.json is made readable by the browser"
_t_eq "no" "$(_exists "$MISSING_FILE")" "a policies.json that does not exist is not created"

printf '\n# fb-spa-guard: closes the in-page route gap the policy cannot see\n'
guard_id="$(cut -d' ' -f2 "$URLGUARD_SHARE_DIR/.stamp")"
_t_eq "32" "${#guard_id}" "the extension id is 32 chars"
_t_eq "Cr24" "$(head -c4 "$URLGUARD_SHARE_DIR/guard.crx")" "guard.crx is a CRX container"
_t_eq "${guard_id};file://${URLGUARD_SHARE_DIR}/update.xml" "$(jq -r '.ExtensionInstallForcelist[0]' "$chromium_policy")" "Chromium force-installs the guard from the local update manifest"
_t_has "$(cat "$URLGUARD_SHARE_DIR/update.xml")" "appid='${guard_id}'" "update.xml names the same id"
_t_eq "$(jq -c . <<<"$(printf '%s\n' "${URLFILTER_ALLOWED_PATHS[@]}" | jq -R . | jq -sc .)")" \
	"$(unzip -p "$URLGUARD_SHARE_DIR/guard.xpi" background.js | sed -n 's/^const ALLOWED_PATHS = \(.*\);$/\1/p' | jq -c .)" "the guard's allowed paths are the policy's allowed paths"
_t_eq "force_installed" "$(jq -r --arg id "$URLGUARD_GECKO_ID" '.policies.ExtensionSettings[$id].installation_mode' "$LW_FILE")" "LibreWolf force-installs the guard"
_t_eq "file://${URLGUARD_SHARE_DIR}/guard.xpi" "$(jq -r --arg id "$URLGUARD_GECKO_ID" '.policies.ExtensionSettings[$id].install_url' "$LW_FILE")" "the XPI is installed from the share dir"
_t_eq "force_installed" "$(jq -r '.policies.ExtensionSettings["leechblockng@proginosko.com"].installation_mode' "$FF_FILE")" "LeechBlock force-install still survives with the guard added"

printf '\n# Unpacked guard for browsers that ignore forced installs (ungoogled-chromium)\n'
unpacked="$URLGUARD_SHARE_DIR/unpacked"
_t_eq "yes" "$(_exists "$unpacked/manifest.json")" "an unpacked copy of the guard is published"
_t_eq "--load-extension=/home/u/ext-a,/usr/lib/ublock-origin,${unpacked}" "$(cat "$FLAGS_LIST")" "the guard is appended to the existing --load-extension list"
_t_eq "1" "$(grep -c -- '--load-extension' "$FLAGS_LIST")" "no second --load-extension flag (Chromium would ignore it)"
_t_eq "--password-store=basic
--load-extension=${unpacked}" "$(cat "$FLAGS_OTHER")" "a flags file without the flag gets one, other flags kept"
_t_eq "no" "$(_exists "$FLAGS_MISSING")" "a missing flags file is not created"

printf '\n# Private windows are disabled in every family\n'
_t_eq "1" "$(jq '.IncognitoModeAvailability' "$chromium_policy")" "Chromium incognito is disabled by policy"
_t_eq "true" "$(jq '.policies.DisablePrivateBrowsing' "$FF_FILE")" "Firefox private browsing is disabled by policy"
_t_eq "true" "$(jq '.policies.DisablePrivateBrowsing' "$LW_FILE")" "LibreWolf private browsing is disabled by policy"

_t_eq "true" "$(jq '.URLAllowlist | index("facebook.com/login.php") != null' "$chromium_policy")" "login.php, where a logged-out /messages bounces, is allowlisted (else the guard loops)"

printf '\n# LibreWolf only installs the unsigned guard with signature enforcement off\n'
_t_eq "false" "$(jq '.policies.Preferences["xpinstall.signatures.required"].Value' "$LW_FILE")" "LibreWolf accepts the unsigned guard (policy pref)"
_t_eq "locked" "$(jq -r '.policies.Preferences["xpinstall.signatures.required"].Status' "$LW_FILE")" "the signature pref is locked, not user-revertible"

printf '\n# Idempotence: a second run rewrites nothing\n'
before="$(cat "$chromium_policy" "$FF_FILE" "$LW_FILE" "$URLGUARD_SHARE_DIR/guard.crx" "$FLAGS_LIST" "$FLAGS_OTHER" | sha256sum)"
touch -d '2000-01-01' "$chromium_policy" "$FF_FILE" "$LW_FILE"
second_run="$(apply_browser_urlfilter 2>&1)"
after="$(cat "$chromium_policy" "$FF_FILE" "$LW_FILE" "$URLGUARD_SHARE_DIR/guard.crx" "$FLAGS_LIST" "$FLAGS_OTHER" | sha256sum)"
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
