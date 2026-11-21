#!/usr/bin/env bash
# lib/hosts_browser_urlguard.sh — builds and publishes the fb-spa-guard
# extension that hosts_browser_urlfilter.sh force-installs.
#
# Why it exists: URLBlocklist (Chromium) and WebsiteFilter (Firefox) judge
# document loads only. facebook.com is a single-page app, so from any page the
# policy lets through (the 2FA step) its router reaches /reel, /watch and the
# feed with history.pushState, unseen. The extension watches those in-page
# moves and sends the tab back to Messenger. Sourced by install.sh.
#
# install.sh runs on every browser launch, so the CRX is rebuilt only when the
# extension source, the packer or the allowed-path list changes (hash stamp).
# The signing key is generated once, root-only, so the extension id is stable
# and nothing the user can write can re-sign it.

_URLGUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable so the tests can point every write at a tmpdir.
URLGUARD_SRC_DIR="${URLGUARD_SRC_DIR:-${_URLGUARD_LIB_DIR}/../fb-spa-guard}"
URLGUARD_SHARE_DIR="${URLGUARD_SHARE_DIR:-/usr/share/hosts-blocker/fb-spa-guard}"
URLGUARD_KEY="${URLGUARD_KEY:-/var/lib/hosts-blocker/fb-spa-guard.pem}"
URLGUARD_PACKER="${_URLGUARD_LIB_DIR}/crx3_pack.py"
# shellcheck disable=SC2034  # read by hosts_browser_urlfilter.sh
URLGUARD_GECKO_ID="fb-spa-guard@hosts-blocker"

# Set by urlguard_build: the Chromium extension id, empty when not built.
URLGUARD_ID=""

# JSON array of the paths the guard lets Facebook's router keep.
urlguard_allowed_json() {
	jq -nc --args '$ARGS.positional' "${URLFILTER_ALLOWED_PATHS[@]}"
}

urlguard_source_hash() {
	{
		cat "$URLGUARD_SRC_DIR"/* "$URLGUARD_PACKER"
		urlguard_allowed_json
	} | sha256sum | cut -d' ' -f1
}

# Chromium wants a dotted numeric version that rises on every rebuild:
# 1.<days since 2020>.<minute of day>.
urlguard_version() {
	local now
	now="$(date +%s)"
	echo "1.$(((now - 1577836800) / 86400)).$(((now % 86400) / 60))"
}

urlguard_ensure_key() {
	[[ -s $URLGUARD_KEY ]] && return 0
	(umask 077 && mkdir -p "$(dirname "$URLGUARD_KEY")" &&
		openssl genrsa -out "$URLGUARD_KEY" 2048 2>/dev/null)
}

# Build (if stale) and set URLGUARD_ID. Non-fatal: without the extension the
# policy still blocks every direct load, so a failure warns and carries on.
urlguard_build() {
	local stamp="$URLGUARD_SHARE_DIR/.stamp" hash want
	URLGUARD_ID=""
	if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
		echo "WARNING: openssl/python3 missing; fb-spa-guard not built" >&2
		return 1
	fi
	hash="$(urlguard_source_hash)"
	if [[ -f $stamp && -f $URLGUARD_SHARE_DIR/guard.crx ]]; then
		read -r want URLGUARD_ID <"$stamp" || true
		[[ $want == "$hash" && -n $URLGUARD_ID ]] && return 0
	fi
	URLGUARD_ID=""
	if ! urlguard_ensure_key; then
		echo "WARNING: could not create the fb-spa-guard key" >&2
		return 1
	fi
	mkdir -p "$URLGUARD_SHARE_DIR"
	if ! URLGUARD_ID="$(python3 -I "$URLGUARD_PACKER" "$URLGUARD_SRC_DIR" "$URLGUARD_KEY" \
		"$URLGUARD_SHARE_DIR" "$(urlguard_version)" "$(urlguard_allowed_json)")"; then
		URLGUARD_ID=""
		echo "WARNING: fb-spa-guard packing failed" >&2
		return 1
	fi
	chmod 755 "$URLGUARD_SHARE_DIR"
	chmod 644 "$URLGUARD_SHARE_DIR"/guard.crx "$URLGUARD_SHARE_DIR"/guard.xpi \
		"$URLGUARD_SHARE_DIR"/update.xml
	echo "$hash $URLGUARD_ID" >"$stamp"
	echo "   fb-spa-guard built: $URLGUARD_ID"
}

# The account whose ~/.config the browsers read: the sudo caller, else the
# owner of this checkout (the maintenance timer runs install.sh as root).
urlguard_user_home() {
	local user="${SUDO_USER:-$(stat -c %U "$URLGUARD_SRC_DIR")}"
	getent passwd "$user" | cut -d: -f6
}

URLFILTER_CHROMIUM_FLAGS_FILES="${URLFILTER_CHROMIUM_FLAGS_FILES:-$(urlguard_user_home)/.config/chromium-flags.conf}"

# ungoogled-chromium ignores policy-forced extensions (measured 2026-11-21:
# ExtensionInstallForcelist, ExtensionSettings and the external-extensions
# JSON all left the profile empty), so it gets the unpacked guard through
# --load-extension in its flags file. Chromium honours only ONE such flag, so
# the dir is appended to the existing comma list, never added as a second flag.
# Written in place (not renamed) to keep the file owned by the user.
urlguard_merge_flags() {
	local dir="$URLGUARD_SHARE_DIR/unpacked" file line new found
	[[ -n $URLGUARD_ID && -f $dir/manifest.json ]] || return 0
	for file in $URLFILTER_CHROMIUM_FLAGS_FILES; do
		[[ -f $file ]] || continue
		new="" found=0
		while IFS= read -r line || [[ -n $line ]]; do
			if [[ $line == --load-extension=* ]]; then
				found=1
				[[ ",${line#--load-extension=}," == *",$dir,"* ]] || line="$line,$dir"
			fi
			new+="$line"$'\n'
		done <"$file"
		((found)) || new+="--load-extension=$dir"$'\n'
		if [[ $new != "$(cat "$file")"$'\n' ]]; then
			printf '%s' "$new" >"$file"
			echo "   fb-spa-guard added to: $file"
		fi
	done
}
