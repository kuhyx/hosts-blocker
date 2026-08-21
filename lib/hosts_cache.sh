#!/usr/bin/env bash
# lib/hosts_cache.sh — keep the local copy of the upstream StevenBlack list
# current.
#
# The cache holds the RAW upstream file, without our own entries, so a refresh
# never has to re-derive what we added. Sourced by install.sh.

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

# Decide whether the cached upstream blocklist is current, and re-download
# it if not. The cache holds the RAW upstream file, without our additions.
refresh_upstream_cache() {
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

}
