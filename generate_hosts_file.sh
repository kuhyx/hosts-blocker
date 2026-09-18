#!/bin/bash
# ============================================================
# generate_hosts_file.sh
#
# Generates a full hosts file (StevenBlack base + custom entries
# from install.sh) to a path of your choice, without touching the
# live /etc/hosts or running any privileged operations.
#
# Used by:
#   - phone_focus_mode/deploy.sh (to create a canonical hosts
#     file to push to a rooted Android device).
#
# Keeps the custom-entries heredoc in install.sh as the single
# source of truth: this script extracts it via the same sed
# pattern install.sh uses for its protection check.
#
# Usage:
#   generate_hosts_file.sh <output_path>
#   generate_hosts_file.sh -                     # stdout
#   HOSTS_CACHE=/tmp/sb.cache generate_hosts_file.sh out
# ============================================================

set -euo pipefail

OUT="${1:-}"
if [[ -z $OUT ]]; then
	echo "Usage: $0 <output_path>|-" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"
# The custom blocking entries live in their own data file. They used to be a
# heredoc inside install.sh, and this script still grepped for that marker long
# after the extraction -- which silently produced an EMPTY custom section, so the
# LAN/phone feed blocked nothing custom while /etc/hosts blocked correctly.
CUSTOM_ENTRIES="$SCRIPT_DIR/custom_entries.hosts"
URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts"
# Default cache location: same as install.sh so both reuse the same file.
CACHE="${HOSTS_CACHE:-/etc/hosts.stevenblack}"
# Fall back to a per-user cache if /etc/hosts.stevenblack is not readable,
# or if we don't have write access (install.sh runs as root; this script
# may not). Avoid interactive `mv` prompts by checking writability up front.
if [[ ! -r $CACHE ]] || [[ -e $CACHE && ! -w $CACHE ]] || [[ ! -w $(dirname "$CACHE") ]]; then
	CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/phone_focus_mode/hosts.stevenblack"
	mkdir -p "$(dirname "$CACHE")"
fi

if [[ ! -f $INSTALL_SH ]]; then
	echo "ERROR: cannot find install.sh at $INSTALL_SH" >&2
	exit 1
fi

if [[ ! -f $CUSTOM_ENTRIES ]]; then
	echo "ERROR: cannot find custom entries at $CUSTOM_ENTRIES" >&2
	exit 1
fi

# ---- Fetch or reuse cache ----
need_download=0
if [[ ! -f $CACHE ]]; then
	need_download=1
else
	# Refresh if older than 7 days
	if [[ -n $(find "$CACHE" -mtime +7 -print 2>/dev/null) ]]; then
		need_download=1
	fi
fi

if [[ $need_download -eq 1 ]]; then
	tmp_dl="$(mktemp)"
	if curl -LfsS --max-time 30 "$URL" -o "$tmp_dl"; then
		mv -f "$tmp_dl" "$CACHE"
	else
		rm -f "$tmp_dl"
		if [[ ! -f $CACHE ]]; then
			echo "ERROR: failed to download $URL and no cache present" >&2
			exit 1
		fi
		echo "WARNING: download failed, using stale cache at $CACHE" >&2
	fi
fi

# ---- Build output ----
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cp "$CACHE" "$TMP"

# Apply the same unblocks install.sh does so generated file matches PC /etc/hosts.
sed -i 's/^0\.0\.0\.0 4chan\.com/#0.0.0.0 4chan.com/' "$TMP"
sed -i 's/^0\.0\.0\.0 www\.4chan\.com/#0.0.0.0 www.4chan.com/' "$TMP"
sed -i 's/^0\.0\.0\.0 4chan\.org/#0.0.0.0 4chan.org/' "$TMP"
sed -i 's/^0\.0\.0\.0 boards\.4chan\.org/#0.0.0.0 boards.4chan.org/' "$TMP"
sed -i 's/^0\.0\.0\.0 sys\.4chan\.org/#0.0.0.0 sys.4chan.org/' "$TMP"
sed -i 's/^0\.0\.0\.0 www\.4chan\.org/#0.0.0.0 www.4chan.org/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.com)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?messenger\.com)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?fbcdn\.net)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.net)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?fbsbx\.com)/#\1/' "$TMP"
sed -i 's/^0\.0\.0\.0 delio\.com.pl/#0.0.0.0 delio.com.pl/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?linkedin\.com)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?licdn\.com)/#\1/' "$TMP"
sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?loverslab\.com)/#\1/' "$TMP"


# Append the custom entries from their data file, the same file install.sh
# appends to /etc/hosts, so the LAN feed and /etc/hosts stay in sync.
{
	echo ""
	cat "$CUSTOM_ENTRIES"
} >>"$TMP"

# Gate, not a warning: a feed that lost its custom entries looks healthy by line
# count alone (the upstream list is ~175k lines), which is exactly how the empty
# feed went unnoticed. Fail closed instead of shipping a blocklist that blocks
# nothing custom.
custom_expected=$(grep -cE '^0\.0\.0\.0[[:space:]]' "$CUSTOM_ENTRIES" || true)
custom_got=$(grep -cE '^0\.0\.0\.0[[:space:]]' "$TMP" || true)
if ((custom_expected > 0)) && ((custom_got < custom_expected)); then
	echo "ERROR: custom entries missing from generated feed" >&2
	echo "       expected at least $custom_expected, found $custom_got" >&2
	exit 1
fi

if [[ $OUT == "-" ]]; then
	cat "$TMP"
else
	mkdir -p "$(dirname "$OUT")"
	cp "$TMP" "$OUT"
	chmod 644 "$OUT" 2>/dev/null || true
fi
