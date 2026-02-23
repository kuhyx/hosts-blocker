#!/bin/bash

# Re-run with sudo if not root
if [[ $EUID -ne 0 ]]; then
	exec sudo -E bash "$0" "$@"
fi

# Options
# Default: do NOT flush DNS caches unless explicitly requested
FLUSH_DNS=0

# Parse CLI flags
for arg in "$@"; do
	case "$arg" in
	--flush-dns)
		FLUSH_DNS=1
		;;
	--no-flush-dns)
		FLUSH_DNS=0
		;;
	-h | --help)
		echo "Usage: $0 [--flush-dns|--no-flush-dns]"
		exit 0
		;;
	esac
done

# ============================================================================
# CUSTOM ENTRIES PROTECTION MECHANISM
# ============================================================================
# This prevents easy removal of custom blocked entries by requiring that:
# 1. New installation has AT LEAST as many custom entries as before, OR
# 2. Any removed entries are replaced by NEW entries not previously blocked
# If neither condition is met, installation is blocked.
# ============================================================================

CUSTOM_ENTRIES_STATE_FILE="/etc/hosts.custom-entries.state"

# Extract custom blocked entries from a hosts file or heredoc section
# Returns only the "0.0.0.0 domain.com" lines (normalized, sorted, unique)
extract_custom_entries_from_script() {
	# Extract entries from the heredoc in this script (between EOF markers after "Custom blocking entries")
	local script_path="$1"
	sed -n '/^# Custom blocking entries$/,/^EOF$/p' "$script_path" |
		grep -E '^0\.0\.0\.0[[:space:]]+' |
		awk '{print $2}' |
		sort -u
}

# Extract custom entries from the current /etc/hosts (entries after "# Custom blocking entries" marker)
extract_custom_entries_from_hosts() {
	local hosts_file="$1"
	if [[ ! -f $hosts_file ]]; then
		return
	fi
	sed -n '/^# Custom blocking entries$/,$p' "$hosts_file" |
		grep -E '^0\.0\.0\.0[[:space:]]+' |
		awk '{print $2}' |
		sort -u
}

# Load previously saved custom entries state
load_saved_custom_entries() {
	if [[ -f $CUSTOM_ENTRIES_STATE_FILE ]]; then
		sort -u "$CUSTOM_ENTRIES_STATE_FILE"
	fi
}

# Save current custom entries to state file
save_custom_entries_state() {
	local entries="$1"
	echo "$entries" | sort -u >"$CUSTOM_ENTRIES_STATE_FILE"
	chmod 644 "$CUSTOM_ENTRIES_STATE_FILE"
	chattr +i "$CUSTOM_ENTRIES_STATE_FILE" 2>/dev/null || true
}

# Helper function to count non-empty lines
count_lines() {
	local input="$1"
	if [[ -z $input ]]; then
		echo 0
	else
		echo "$input" | grep -c . 2>/dev/null || echo 0
	fi
}

# Main protection check
check_custom_entries_protection() {
	local script_path
	script_path="$(readlink -f "$0")"

	# Get new entries from the script's heredoc
	local new_entries
	new_entries=$(extract_custom_entries_from_script "$script_path")
	local new_count
	new_count=$(count_lines "$new_entries")

	# Get saved/existing entries (prefer state file, fall back to current /etc/hosts)
	local saved_entries
	saved_entries=$(load_saved_custom_entries)
	if [[ -z $saved_entries ]]; then
		# First run or state file missing - extract from current /etc/hosts if it has our marker
		saved_entries=$(extract_custom_entries_from_hosts "/etc/hosts")
	fi
	local saved_count
	saved_count=$(count_lines "$saved_entries")

	# If no saved state exists, this is first installation - allow it
	if [[ $saved_count -eq 0 ]]; then
		echo "ℹ️  First installation detected - no protection check needed."
		return 0
	fi

	# Find entries that were removed
	local removed_entries
	removed_entries=$(comm -23 <(echo "$saved_entries") <(echo "$new_entries"))
	local removed_count
	removed_count=$(count_lines "$removed_entries")

	# Find entries that are new
	local added_entries
	added_entries=$(comm -13 <(echo "$saved_entries") <(echo "$new_entries"))
	local added_count
	added_count=$(count_lines "$added_entries")

	echo ""
	echo "📊 Custom Entries Protection Check:"
	echo "   Previously blocked: $saved_count entries"
	echo "   Currently in script: $new_count entries"
	echo "   Removed: $removed_count | Added: $added_count"

	# RULE 1: No entries removed - always OK
	if [[ $removed_count -eq 0 ]]; then
		echo "   ✅ No entries removed - protection check passed."
		return 0
	fi

	# RULE 2: Entries were removed - BLOCK INSTALLATION
	echo ""
	echo "============================================================"
	echo "  ❌ INSTALLATION BLOCKED - CUSTOM ENTRIES REMOVED"
	echo "============================================================"
	echo ""
	echo "You are attempting to REMOVE the following blocked entries:"
	while IFS= read -r entry; do
		echo "  - $entry"
	done <<<"$removed_entries"
	echo ""
	echo "This is NOT allowed. The only way to unblock sites is to:"
	echo ""
	echo "  1. Manually edit /etc/hosts (requires removing chattr protection)"
	echo "  2. Delete the state file /etc/hosts.custom-entries.state"
	echo "     (also protected with chattr)"
	echo ""
	echo "These manual steps are intentionally difficult to prevent"
	echo "impulsive unblocking. If you really need to unblock something,"
	echo "you'll have to work for it."
	echo ""
	return 1
}

# Run the protection check
if ! check_custom_entries_protection; then
	exit 1
fi

# Enable systemd-resolved
sudo systemctl enable systemd-resolved

# ============================================================================
# ENSURE systemd-resolved READS /etc/hosts
# ============================================================================
# Without this, systemd-resolved ignores /etc/hosts entries entirely,
# allowing blocked domains to resolve via DNS.
RESOLVED_CONF="/etc/systemd/resolved.conf"
if grep -q '^ReadEtcHosts=no' "$RESOLVED_CONF" 2>/dev/null; then
	echo "Fixing systemd-resolved: setting ReadEtcHosts=yes..."
	sudo sed -i 's/^ReadEtcHosts=no/ReadEtcHosts=yes/' "$RESOLVED_CONF"
	sudo systemctl restart systemd-resolved
elif ! grep -q '^ReadEtcHosts=yes' "$RESOLVED_CONF" 2>/dev/null; then
	echo "Enabling ReadEtcHosts=yes in systemd-resolved..."
	if grep -q '^#ReadEtcHosts=' "$RESOLVED_CONF" 2>/dev/null; then
		sudo sed -i 's/^#ReadEtcHosts=.*/ReadEtcHosts=yes/' "$RESOLVED_CONF"
	else
		echo 'ReadEtcHosts=yes' | sudo tee -a "$RESOLVED_CONF" >/dev/null
	fi
	sudo systemctl restart systemd-resolved
fi

# Remove all attributes from /etc/hosts to allow modifications
sudo chattr -i -a /etc/hosts 2>/dev/null || true

# Source and local cache configuration
URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts"
# Cache stores the RAW upstream file (without our custom modifications)
LOCAL_CACHE="/etc/hosts.stevenblack"

# Helpers
extract_date_epoch_from_file() {
	# Grep "# Date:" line and convert to epoch seconds (UTC)
	local f="$1"
	local line
	line=$(grep -m1 '^# Date:' "$f" 2>/dev/null | sed -E 's/^# Date:[[:space:]]*(.*)[[:space:]]*\(UTC\).*/\1 UTC/')
	if [[ -n $line ]]; then
		date -u -d "$line" +%s 2>/dev/null || echo ""
	else
		echo ""
	fi
}

fetch_remote_header() {
	# Try to fetch only the first ~4KB using HTTP Range; fallback to piping to head
	local out="$1"
	if curl -LfsS --max-time 10 -H 'Range: bytes=0-4095' "$URL" -o "$out"; then
		return 0
	fi
	# Fallback – may download more, but we only keep first lines
	if curl -LfsS --max-time 10 "$URL" | head -n 20 >"$out"; then
		return 0
	fi
	return 1
}

download_remote_full_to() {
	local out="$1"
	curl -LfsS "$URL" -o "$out"
}

# Decide whether to use cache or update
TMP_REMOTE_HEAD=$(mktemp)
trap 'rm -f "$TMP_REMOTE_HEAD"' EXIT

REMOTE_AVAILABLE=0
if fetch_remote_header "$TMP_REMOTE_HEAD"; then
	REMOTE_AVAILABLE=1
fi

NEED_UPDATE=0

if [[ -f $LOCAL_CACHE ]]; then
	local_epoch=$(extract_date_epoch_from_file "$LOCAL_CACHE")
else
	local_epoch=""
fi

if [[ $REMOTE_AVAILABLE -eq 1 ]]; then
	remote_epoch=$(extract_date_epoch_from_file "$TMP_REMOTE_HEAD")
	if [[ -n $local_epoch && -n $remote_epoch && $local_epoch -ge $remote_epoch ]]; then
		echo "Using cached StevenBlack hosts (up-to-date)."
	else
		echo "Cached version is missing or outdated; downloading latest StevenBlack hosts..."
		NEED_UPDATE=1
	fi
else
	if [[ -f $LOCAL_CACHE ]]; then
		echo "No internet; using cached StevenBlack hosts."
	else
		echo "Error: No internet and no cached StevenBlack hosts found." >&2
		exit 1
	fi
fi

# Ensure we have a fresh cache if needed
if [[ $NEED_UPDATE -eq 1 ]]; then
	TMP_DL=$(mktemp)
	if download_remote_full_to "$TMP_DL"; then
		# Save raw upstream to cache
		sudo mv "$TMP_DL" "$LOCAL_CACHE"
		sudo chmod 644 "$LOCAL_CACHE"
		echo "Saved latest StevenBlack hosts to cache: $LOCAL_CACHE"
	else
		rm -f "$TMP_DL"
		echo "Error: Failed to download latest StevenBlack hosts." >&2
		exit 1
	fi
fi

# Install the base hosts from cache into /etc/hosts
echo "Installing base hosts from cache to /etc/hosts..."
sudo cp "$LOCAL_CACHE" /etc/hosts

# Comment out any 4chan blocking entries from the downloaded file
echo "Allowing 4chan by commenting out any blocking entries..."
sudo sed -i 's/^0\.0\.0\.0 4chan\.com/#0.0.0.0 4chan.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.com/#0.0.0.0 www.4chan.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 4chan\.org/#0.0.0.0 4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 boards\.4chan\.org/#0.0.0.0 boards.4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 sys\.4chan\.org/#0.0.0.0 sys.4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.org/#0.0.0.0 www.4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 www\.facebook\.com/#0.0.0.0 www.facebook.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 messenger\.com/#0.0.0.0 messenger.com/' /etc/hosts

# Add custom entries for YouTube and Discord
echo "Adding custom entries for YouTube and Discord..."
tee -a /etc/hosts >/dev/null <<'EOF'

# Custom blocking entries
# YouTube
0.0.0.0 youtube.com
0.0.0.0 www.youtube.com
0.0.0.0 m.youtube.com
0.0.0.0 youtu.be
0.0.0.0 youtube-nocookie.com
0.0.0.0 www.youtube-nocookie.com
0.0.0.0 youtubei.googleapis.com
0.0.0.0 youtube.googleapis.com
0.0.0.0 yt3.ggpht.com
0.0.0.0 ytimg.com
0.0.0.0 i.ytimg.com
0.0.0.0 s.ytimg.com
0.0.0.0 i9.ytimg.com
0.0.0.0 googlevideo.com
0.0.0.0 r1---sn-4g5e6nls.googlevideo.com
0.0.0.0 r1---sn-4g5lne7s.googlevideo.com

# Alternative YouTube Frontends (Invidious, Piped, etc.)
0.0.0.0 invidious.io
0.0.0.0 www.invidious.io
0.0.0.0 invidio.us
0.0.0.0 vid.puffyan.us
0.0.0.0 invidious.snopyta.org
0.0.0.0 yewtu.be
0.0.0.0 invidious.kavin.rocks
0.0.0.0 inv.riverside.rocks
0.0.0.0 invidious.namazso.eu
0.0.0.0 invidious.nerdvpn.de
0.0.0.0 invidious.projectsegfau.lt
0.0.0.0 invidious.slipfox.xyz
0.0.0.0 invidious.privacydev.net
0.0.0.0 invidious.perennialte.ch
0.0.0.0 invidious.protokoll-11.de
0.0.0.0 invidious.einfachzocken.eu
0.0.0.0 invidious.fdn.fr
0.0.0.0 inv.in.projectsegfau.lt
0.0.0.0 invidious.tiekoetter.com
0.0.0.0 invidious.lunar.icu
0.0.0.0 iv.ggtyler.dev
0.0.0.0 iv.melmac.space
0.0.0.0 piped.video
0.0.0.0 www.piped.video
0.0.0.0 piped.kavin.rocks
0.0.0.0 piped.mha.fi
0.0.0.0 piped.mint.lgbt
0.0.0.0 piped.projectsegfau.lt
0.0.0.0 piped.privacydev.net
0.0.0.0 piped.smnz.de
0.0.0.0 piped.adminforge.de
0.0.0.0 watch.whatever.social
0.0.0.0 piped.lunar.icu
0.0.0.0 viewtube.io
0.0.0.0 www.viewtube.io
0.0.0.0 freetube.io
0.0.0.0 www.freetube.io
0.0.0.0 tubo.media
0.0.0.0 www.tubo.media
0.0.0.0 materialious.nadeko.net
0.0.0.0 clipious.org
0.0.0.0 www.clipious.org
0.0.0.0 newpipe.net
0.0.0.0 www.newpipe.net
0.0.0.0 newpipe.schabi.org
0.0.0.0 grayjay.app
0.0.0.0 www.grayjay.app
0.0.0.0 libretube.dev
0.0.0.0 www.libretube.dev
0.0.0.0 hyperion.deishelon.com
0.0.0.0 inv.n8pjl.ca
0.0.0.0 inv.zzls.xyz
0.0.0.0 inv.tux.pizza
0.0.0.0 invidious.incogniweb.net
0.0.0.0 invidious.drgns.space
0.0.0.0 invidious.io.lol

# Steam Store

# Discord - media allowed
# 0.0.0.0 cdn.discordapp.com
# 0.0.0.0 media.discordapp.net
# 0.0.0.0 images-ext-1.discordapp.net
# 0.0.0.0 images-ext-2.discordapp.net
# 0.0.0.0 attachments-1.discordapp.net
# 0.0.0.0 attachments-2.discordapp.net
# 0.0.0.0 tenor.com
# 0.0.0.0 giphy.com

# Food Delivery Services
# Polish services
0.0.0.0 pyszne.pl
0.0.0.0 www.pyszne.pl
0.0.0.0 m.pyszne.pl
0.0.0.0 api.pyszne.pl
0.0.0.0 app.pyszne.pl
0.0.0.0 glovo.com
0.0.0.0 www.glovo.com
0.0.0.0 m.glovo.com
0.0.0.0 api.glovo.com
0.0.0.0 glovoapp.com
0.0.0.0 www.glovoapp.com
0.0.0.0 bolt.eu
:: bolt.eu
0.0.0.0 www.bolt.eu
:: www.bolt.eu
0.0.0.0 food.bolt.eu
:: food.bolt.eu
0.0.0.0 m.bolt.eu
:: m.bolt.eu
0.0.0.0 api.bolt.eu
:: api.bolt.eu
0.0.0.0 node.bolt.eu
:: node.bolt.eu
0.0.0.0 gw.bolt.eu
:: gw.bolt.eu
0.0.0.0 client-api.bolt.eu
:: client-api.bolt.eu
0.0.0.0 auth.bolt.eu
:: auth.bolt.eu
0.0.0.0 cdn.bolt.eu
:: cdn.bolt.eu
0.0.0.0 images.bolt.eu
:: images.bolt.eu
0.0.0.0 static.bolt.eu
:: static.bolt.eu
0.0.0.0 assets.bolt.eu
:: assets.bolt.eu
0.0.0.0 fleet.bolt.eu
:: fleet.bolt.eu
0.0.0.0 user.bolt.eu
:: user.bolt.eu
0.0.0.0 courier.bolt.eu
:: courier.bolt.eu
0.0.0.0 rider.bolt.eu
:: rider.bolt.eu
0.0.0.0 restaurant.bolt.eu
:: restaurant.bolt.eu
0.0.0.0 partner-food.bolt.eu
:: partner-food.bolt.eu
0.0.0.0 woltwojta.pl
0.0.0.0 www.woltwojta.pl
0.0.0.0 wolt.com
0.0.0.0 www.wolt.com
0.0.0.0 m.wolt.com
0.0.0.0 api.wolt.com
0.0.0.0 restaurant-api.wolt.com
0.0.0.0 consumer-api.wolt.com
0.0.0.0 jush.pl
0.0.0.0 www.jush.pl
0.0.0.0 m.jush.pl
0.0.0.0 api.jush.pl
0.0.0.0 delio.pl
:: delio.pl
0.0.0.0 www.delio.pl
:: www.delio.pl
0.0.0.0 m.delio.pl
:: m.delio.pl
0.0.0.0 api.delio.pl
:: api.delio.pl
0.0.0.0 app.delio.pl
:: app.delio.pl
0.0.0.0 cdn.delio.pl
:: cdn.delio.pl
0.0.0.0 static.delio.pl
:: static.delio.pl
0.0.0.0 order.delio.pl
:: order.delio.pl
0.0.0.0 delio.com
:: delio.com
0.0.0.0 www.delio.com
:: www.delio.com
0.0.0.0 m.delio.com
:: m.delio.com
0.0.0.0 api.delio.com
:: api.delio.com
0.0.0.0 app.delio.com
:: app.delio.com
0.0.0.0 delio.com.pl
:: delio.com.pl
0.0.0.0 www.delio.com.pl
:: www.delio.com.pl
0.0.0.0 m.delio.com.pl
:: m.delio.com.pl
0.0.0.0 api.delio.com.pl
:: api.delio.com.pl
0.0.0.0 app.delio.com.pl
:: app.delio.com.pl
0.0.0.0 lisek.app
0.0.0.0 www.lisek.app
0.0.0.0 api.lisek.app
0.0.0.0 stava.app
0.0.0.0 www.stava.app
0.0.0.0 api.stava.app
0.0.0.0 biedronka.pl
0.0.0.0 zakupy.biedronka.pl
0.0.0.0 ezakupy.tesco.pl
0.0.0.0 www.ezakupy.tesco.pl
0.0.0.0 barbora.pl
0.0.0.0 www.barbora.pl
0.0.0.0 api.barbora.pl
0.0.0.0 frisco.pl
0.0.0.0 www.frisco.pl
0.0.0.0 api.frisco.pl
0.0.0.0 swiatkwiatow.pl
0.0.0.0 www.swiatkwiatow.pl
0.0.0.0 allegro.pl/kategoria/jedzenie
0.0.0.0 szama.pl
0.0.0.0 www.szama.pl
0.0.0.0 api.szama.pl
0.0.0.0 auchandirect.pl
0.0.0.0 www.auchandirect.pl

# International services
0.0.0.0 ubereats.com
0.0.0.0 www.ubereats.com
0.0.0.0 m.ubereats.com
0.0.0.0 api.ubereats.com
0.0.0.0 uber.com
0.0.0.0 www.uber.com
0.0.0.0 m.uber.com
0.0.0.0 api.uber.com
0.0.0.0 cn-geo1.uber.com
0.0.0.0 login.uber.com
0.0.0.0 auth.uber.com
0.0.0.0 riders.uber.com
0.0.0.0 deliveroo.com
0.0.0.0 www.deliveroo.com
0.0.0.0 m.deliveroo.com
0.0.0.0 api.deliveroo.com
0.0.0.0 deliveroo.co.uk
0.0.0.0 www.deliveroo.co.uk
0.0.0.0 foodpanda.com
0.0.0.0 www.foodpanda.com
0.0.0.0 m.foodpanda.com
0.0.0.0 api.foodpanda.com
0.0.0.0 grubhub.com
0.0.0.0 www.grubhub.com
0.0.0.0 m.grubhub.com
0.0.0.0 api.grubhub.com
0.0.0.0 doordash.com
0.0.0.0 www.doordash.com
0.0.0.0 m.doordash.com
0.0.0.0 api.doordash.com
0.0.0.0 justeat.com
0.0.0.0 www.justeat.com
0.0.0.0 m.justeat.com
0.0.0.0 justeat.co.uk
0.0.0.0 www.justeat.co.uk
0.0.0.0 postmates.com
0.0.0.0 www.postmates.com
0.0.0.0 api.postmates.com
0.0.0.0 seamless.com
0.0.0.0 www.seamless.com
0.0.0.0 menulog.com.au
0.0.0.0 www.menulog.com.au
0.0.0.0 delivery.com
0.0.0.0 www.delivery.com
0.0.0.0 getir.com
0.0.0.0 www.getir.com
0.0.0.0 api.getir.com
0.0.0.0 flink.com
0.0.0.0 www.flink.com
0.0.0.0 api.flink.com
0.0.0.0 gorillas.io
0.0.0.0 www.gorillas.io
0.0.0.0 api.gorillas.io
0.0.0.0 gopuff.com
0.0.0.0 www.gopuff.com
0.0.0.0 api.gopuff.com
0.0.0.0 instacart.com
0.0.0.0 www.instacart.com
0.0.0.0 api.instacart.com
0.0.0.0 takeaway.com
0.0.0.0 www.takeaway.com
0.0.0.0 api.takeaway.com

# Fast food chain apps and websites
0.0.0.0 mcdonalds.com
0.0.0.0 www.mcdonalds.com
0.0.0.0 m.mcdonalds.com
0.0.0.0 mcdonalds.pl
0.0.0.0 www.mcdonalds.pl
0.0.0.0 kfc.com
0.0.0.0 www.kfc.com
0.0.0.0 m.kfc.com
0.0.0.0 kfc.pl
0.0.0.0 www.kfc.pl
0.0.0.0 burgerking.com
0.0.0.0 www.burgerking.com
0.0.0.0 m.burgerking.com
0.0.0.0 burgerking.pl
0.0.0.0 www.burgerking.pl
0.0.0.0 pizzahut.com
0.0.0.0 www.pizzahut.com
0.0.0.0 m.pizzahut.com
0.0.0.0 pizzahut.pl
0.0.0.0 www.pizzahut.pl
0.0.0.0 dominos.com
0.0.0.0 www.dominos.com
0.0.0.0 m.dominos.com
0.0.0.0 dominos.pl
0.0.0.0 www.dominos.pl
0.0.0.0 subway.com
0.0.0.0 www.subway.com
0.0.0.0 m.subway.com
0.0.0.0 subway.pl
0.0.0.0 www.subway.pl
EOF

# Set proper permissions (readable by all, writable only by root)
sudo chmod 644 /etc/hosts

# Make the file immutable and append-only for maximum protection
sudo chattr +ia /etc/hosts

# ============================================================================
# SAVE CUSTOM ENTRIES STATE FOR FUTURE PROTECTION CHECKS
# ============================================================================
echo "Saving custom entries state for protection mechanism..."
script_path="$(readlink -f "$0")"
current_custom_entries=$(extract_custom_entries_from_script "$script_path")
# Remove immutable from state file if it exists
chattr -i "$CUSTOM_ENTRIES_STATE_FILE" 2>/dev/null || true
save_custom_entries_state "$current_custom_entries"
echo "✅ Custom entries state saved to $CUSTOM_ENTRIES_STATE_FILE"

# Optionally flush DNS caches
if [[ $FLUSH_DNS -eq 1 ]]; then
	echo "Flushing DNS caches..."
	sudo systemd-resolve --flush-caches
	sudo systemctl restart NetworkManager.service
else
	echo "DNS cache flush skipped (use --flush-dns to enable)."
fi

# ============================================================================
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
