#!/usr/bin/env bash
# lib/hosts_browser_urlfilter.sh — URL-level browser policy: block the
# facebook.com feed while leaving Messenger usable.
#
# /etc/hosts cannot express this: facebook.com and messenger.com are both in
# the protected unblock list because Messenger's login and link shim live on
# facebook.com, and hosts has no notion of a path. Managed browser policy has,
# so the rule lives here. Sourced by install.sh.
#
# Two deliberate differences from hosts_browser_doh.sh:
#   1. Nothing here sets DOH_POLICY_CHANGED. Chromium re-reads its managed
#      policy directory on its own; Firefox reads policies.json at startup.
#      Neither is worth SIGKILLing every open browser for (install.sh runs on
#      every browser launch).
#   2. Firefox-family files are MERGED with jq, never overwritten: the same
#      policies.json carries LeechBlock's force-install and LibreWolf's own
#      defaults, and a whole-file write would silently delete them.

# Hosts blocked outright. A bare host in a Chromium URLBlocklist entry matches
# the host and every subdomain; the Firefox match pattern below says the same.
URLFILTER_BLOCKED_HOSTS=(facebook.com)

# Paths on facebook.com that Messenger still needs: its login and 2FA
# checkpoint, the OAuth dialog, and the l./lm. link shim every link a friend
# sends goes through. Widen from measured traffic, not from guesses.
URLFILTER_ALLOWED_HOSTS=(messenger.com l.facebook.com lm.facebook.com)
URLFILTER_ALLOWED_PATHS=(login checkpoint x/oauth dialog/oauth)

# Overridable so the tests can point every write at a tmpdir.
URLFILTER_CHROMIUM_DIRS="${URLFILTER_CHROMIUM_DIRS:-/etc/chromium/policies/managed /etc/opt/chrome/policies/managed}"
URLFILTER_FIREFOX_POLICY_FILES="${URLFILTER_FIREFOX_POLICY_FILES:-/etc/firefox/policies/policies.json /usr/lib/firefox/distribution/policies.json /etc/librewolf/policies/policies.json /usr/lib/librewolf/distribution/policies.json}"
URLFILTER_CHROMIUM_FILE="facebook-except-messenger.json"

# The Chromium policy object: URLBlocklist plus the URLAllowlist that
# punches Messenger back through it.
urlfilter_chromium_policy() {
	local allowed=() host path
	for host in "${URLFILTER_ALLOWED_HOSTS[@]}"; do
		allowed+=("$host")
	done
	for host in "${URLFILTER_BLOCKED_HOSTS[@]}"; do
		for path in "${URLFILTER_ALLOWED_PATHS[@]}"; do
			allowed+=("${host}/${path}")
		done
	done
	jq -n \
		--argjson block "$(jq -n --args '$ARGS.positional' "${URLFILTER_BLOCKED_HOSTS[@]}")" \
		--argjson allow "$(jq -n --args '$ARGS.positional' "${allowed[@]}")" \
		'{URLBlocklist: $block, URLAllowlist: $allow}'
}

# Firefox WebsiteFilter: a Block list and an Exceptions list of match patterns.
# `*.facebook.com` matches the bare host too, so one pattern per scheme covers
# the whole domain.
urlfilter_firefox_block_json() {
	local out=() host scheme
	for host in "${URLFILTER_BLOCKED_HOSTS[@]}"; do
		for scheme in https http; do
			out+=("${scheme}://*.${host}/*")
		done
	done
	jq -n --args '$ARGS.positional' "${out[@]}"
}

urlfilter_firefox_exceptions_json() {
	local out=() host path
	for host in "${URLFILTER_ALLOWED_HOSTS[@]}"; do
		out+=("https://*.${host}/*")
	done
	for host in "${URLFILTER_BLOCKED_HOSTS[@]}"; do
		for path in "${URLFILTER_ALLOWED_PATHS[@]}"; do
			out+=("https://*.${host}/${path}*")
		done
	done
	jq -n --args '$ARGS.positional' "${out[@]}"
}

# Write $2 to $1 only when it differs. Same idea as write_policy_if_changed
# in hosts_browser_doh.sh, minus the browser-kill flag (see header).
urlfilter_write_if_changed() {
	local path="$1" content="$2"
	if [[ -f $path ]] && [[ "$(cat "$path")" == "$content" ]]; then
		return 1
	fi
	printf '%s\n' "$content" >"$path"
}

# Chromium family: one new file per managed dir. The dir merges every JSON
# it holds, so disable-doh.json and the rest are untouched.
apply_chromium_urlfilter() {
	local dir policy
	policy="$(urlfilter_chromium_policy)"
	for dir in $URLFILTER_CHROMIUM_DIRS; do
		# disable_browser_doh already created the dir for every browser
		# that is present; a missing dir means no such browser.
		[[ -d $dir ]] || continue
		if urlfilter_write_if_changed "$dir/$URLFILTER_CHROMIUM_FILE" "$policy"; then
			echo "   URL filter written: $dir/$URLFILTER_CHROMIUM_FILE"
		fi
	done
}

# Firefox family: merge WebsiteFilter into each policies.json that exists.
# Existing Block/Exceptions entries (LibreWolf ships a localhost pair) are
# kept; ours are unioned in, so a re-run is a no-op.
apply_firefox_urlfilter() {
	local file merged block exceptions
	block="$(urlfilter_firefox_block_json)"
	exceptions="$(urlfilter_firefox_exceptions_json)"
	for file in $URLFILTER_FIREFOX_POLICY_FILES; do
		[[ -f $file ]] || continue
		if ! merged="$(jq --argjson block "$block" --argjson exc "$exceptions" '
			.policies |= (. // {}) |
			.policies.WebsiteFilter |= (. // {}) |
			.policies.WebsiteFilter.Block |= ((. // []) + $block | unique) |
			.policies.WebsiteFilter.Exceptions |= ((. // []) + $exc | unique)
		' "$file")"; then
			echo "WARNING: $file is not valid JSON; URL filter not merged" >&2
			continue
		fi
		if urlfilter_write_if_changed "$file" "$merged"; then
			echo "   URL filter merged into: $file (takes effect on next start)"
		fi
	done
}

# jq is the only dependency and the merge is unsafe without it, so install
# it rather than degrade: a missing tool is the installer's job, not a note.
ensure_jq() {
	command -v jq >/dev/null 2>&1 && return 0
	if command -v pacman >/dev/null 2>&1; then
		pacman -S --needed --noconfirm jq
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get install -y jq
	fi
	command -v jq >/dev/null 2>&1
}

apply_browser_urlfilter() {
	echo ""
	echo "Applying facebook.com feed block (Messenger allowed) to browsers..."
	if ! ensure_jq; then
		echo "ERROR: jq unavailable and could not be installed; URL filter not applied" >&2
		return 1
	fi
	apply_chromium_urlfilter
	apply_firefox_urlfilter
}
