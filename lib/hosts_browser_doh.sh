#!/usr/bin/env bash
# lib/hosts_browser_doh.sh — stop browsers resolving around /etc/hosts.
#
# DNS-over-HTTPS resolves names over the browser's own encrypted channel and
# never consults /etc/hosts, so leaving it on defeats every entry this script
# installs. Sourced by install.sh.

# Turn off DNS-over-HTTPS in every installed browser. DoH resolves names
# over the browser's own encrypted channel, bypassing /etc/hosts completely.
disable_browser_doh() {
	# DISABLE DNS OVER HTTPS (DoH) IN BROWSERS
	# ============================================================================
	# DoH bypasses /etc/hosts entirely, defeating all our blocking!
	# We disable it in Firefox profiles for all users.
	echo ""
	echo "Disabling DNS over HTTPS (DoH) in browsers..."

	# Get the actual user (not root) who invoked this script
	REAL_USER="${SUDO_USER:-$USER}"
	REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

	# Firefox: disable DoH via user.js
	if [[ -d "$REAL_HOME/.mozilla/firefox" ]]; then
		for profile in "$REAL_HOME/.mozilla/firefox"/*.default*; do
			if [[ -d "$profile" ]]; then
				cat >>"$profile/user.js" <<'FIREFOXEOF'
// Disable DNS over HTTPS (DoH) to ensure /etc/hosts blocking works
// Added by linux-configuration hosts installer
user_pref("network.trr.mode", 5);  // 5 = Off by user choice
user_pref("doh-rollout.enabled", false);
user_pref("doh-rollout.disable-heuristics", true);
FIREFOXEOF
				chown "$REAL_USER:$REAL_USER" "$profile/user.js"
				echo "   Firefox DoH disabled in: $(basename "$profile")"
			fi
		done
	else
		echo "   No Firefox profiles found"
	fi

	# Chromium-based browsers: use policy file
	CHROME_POLICY_DIR="/etc/chromium/policies/managed"
	if [[ -d "/etc/chromium" ]] || command -v chromium &>/dev/null; then
		mkdir -p "$CHROME_POLICY_DIR"
		cat >"$CHROME_POLICY_DIR/disable-doh.json" <<'CHROMEEOF'
{
  "DnsOverHttpsMode": "off",
  "BuiltInDnsClientEnabled": false
}
CHROMEEOF
		echo "   Chromium DoH disabled via policy"
	fi

	# Google Chrome policy
	GCHROME_POLICY_DIR="/etc/opt/chrome/policies/managed"
	if [[ -d "/etc/opt/chrome" ]] || command -v google-chrome &>/dev/null; then
		mkdir -p "$GCHROME_POLICY_DIR"
		cat >"$GCHROME_POLICY_DIR/disable-doh.json" <<'GCHROMEEOF'
{
  "DnsOverHttpsMode": "off",
  "BuiltInDnsClientEnabled": false
}
GCHROMEEOF
		echo "   Google Chrome DoH disabled via policy"
	fi

	echo ""
	echo "✅ Installation complete!"
	echo "   Custom entries protection is now active."
	echo "   Removing blocked entries from the script will be blocked."
	echo "   DNS over HTTPS (DoH) has been disabled in browsers."

	# ============================================================================
}

# Kill running browsers so the DoH policy changes take effect now rather
# than at the user's next restart.
restart_browsers() {
	# FORCE BROWSER RESTART TO APPLY DOH CHANGES
	# ============================================================================
	# Kill all browser processes so DoH changes take effect immediately
	echo ""
	echo "Killing browsers to apply DoH policy changes..."
	BROWSERS_KILLED=0

	for browser in chrome chromium chromium-browser brave brave-browser firefox firefox-esr thorium vivaldi opera; do
		if pgrep -x "$browser" &>/dev/null || pgrep -f "/opt/.*/$browser" &>/dev/null; then
			echo "   Killing $browser..."
			pkill -9 -f "$browser" 2>/dev/null || true
			BROWSERS_KILLED=1
		fi
	done

	# Also kill by common binary paths
	for pattern in "/opt/google/chrome" "/opt/brave" "/opt/thorium" "/usr/lib/firefox" "/usr/lib/chromium"; do
		if pgrep -f "$pattern" &>/dev/null; then
			echo "   Killing processes matching $pattern..."
			pkill -9 -f "$pattern" 2>/dev/null || true
			BROWSERS_KILLED=1
		fi
	done

	if [[ $BROWSERS_KILLED -eq 1 ]]; then
		echo ""
		echo "⚠️  Browsers were killed to apply DNS settings."
		echo "   Reopen your browser - hosts blocking is now enforced."
	else
		echo "   No browsers were running."
	fi

	# ============================================================================
}
