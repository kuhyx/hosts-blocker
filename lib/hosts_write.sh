#!/usr/bin/env bash
# lib/hosts_write.sh — write /etc/hosts.
#
# The cached upstream list, then the exceptions we comment back out, then our
# own blocking entries as one ~320-line quoted heredoc, then the permissions
# and the immutable attribute. The heredoc is a single unit: splitting its
# interior would change the file this produces. Sourced by install.sh.

# Write /etc/hosts: the cached upstream list, the per-site exceptions we
# comment back out, then our own blocking entries, and finally the
# permissions and immutable attribute.
#
# The custom entries are one ~320-line quoted heredoc and move as a single
# unit; splitting its interior would change the file this writes.
# The custom blocking entries, as data beside this lib rather than inline.
CUSTOM_ENTRIES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/custom_entries.hosts"

# The domains the seds above must have commented out. A live entry for any
# of them means the unblock silently failed (2026-09-18: every sed lost to a
# still-mounted /etc/hosts) -- fail the run rather than snapshot that file.
UNBLOCK_VERIFY_DOMAINS=(facebook.com messenger.com fbcdn.net facebook.net fbsbx.com linkedin.com licdn.com)

verify_unblocks() {
	local file="${1:-/etc/hosts}" domain live=0
	for domain in "${UNBLOCK_VERIFY_DOMAINS[@]}"; do
		if grep -qE "^0\.0\.0\.0[[:space:]]+([a-zA-Z0-9._-]+\.)?${domain//./\\.}$" "$file"; then
			echo "ERROR: $domain is still blocked in $file after the unblock pass" >&2
			live=1
		fi
	done
	if ((live)); then
		echo "ERROR: unblock pass did not take (is /etc/hosts still a mountpoint?)" >&2
		return 1
	fi
	echo "Unblock pass verified: ${#UNBLOCK_VERIFY_DOMAINS[@]} domains resolvable."
}

# Built here, then renamed over /etc/hosts in one step. Editing /etc/hosts in
# place meant a ~1 s window on every run where the raw upstream list -- with
# facebook.com and friends still blocked -- was live, and a browser that
# resolved a name in that window kept the 0.0.0.0 answer in its DNS cache
# (measured 2026-09-18: Chrome hung on facebook.com/login for a minute after
# each run). The rename is atomic, so resolvers only ever see a finished file.
HOSTS_STAGING="/etc/.hosts.staging"

write_hosts_file() {
	# Build the new file beside its destination (same filesystem, so the
	# final mv is a rename).
	echo "Building the new hosts file at $HOSTS_STAGING..."
	sudo cp "$LOCAL_CACHE" "$HOSTS_STAGING"

	# Comment out any 4chan blocking entries from the downloaded file
	echo "Allowing 4chan by commenting out any blocking entries..."
	sudo sed -i 's/^0\.0\.0\.0 4chan\.com/#0.0.0.0 4chan.com/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.com/#0.0.0.0 www.4chan.com/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 4chan\.org/#0.0.0.0 4chan.org/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 boards\.4chan\.org/#0.0.0.0 boards.4chan.org/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 sys\.4chan\.org/#0.0.0.0 sys.4chan.org/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.org/#0.0.0.0 www.4chan.org/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.com)/#\1/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?messenger\.com)/#\1/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?fbcdn\.net)/#\1/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.net)/#\1/' "$HOSTS_STAGING"
	# fbsbx.com: Facebook's sandbox domain. www.fbsbx.com carries the login
	# captcha / 2FA iframes, lookaside.fbsbx.com the avatars, attachment. and
	# cdn.fbsbx.com Messenger's files. Blocked, Messenger login dies inside
	# the 2FA frame with a plain network error (measured 2026-09-18).
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?fbsbx\.com)/#\1/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 delio\.com.pl/#0.0.0.0 delio.com.pl/' "$HOSTS_STAGING"
	sudo sed -i 's/^0\.0\.0\.0 loverslab\.com/#0.0.0.0 loverslab.com/' "$HOSTS_STAGING"

	# Allow LinkedIn and all subdomains (linkedin.com + licdn.com CDN)
	echo "Allowing LinkedIn by commenting out any blocking entries..."
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?linkedin\.com)/#\1/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?licdn\.com)/#\1/' "$HOSTS_STAGING"
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?loverslab\.com)/#\1/' "$HOSTS_STAGING"

	# Add custom entries for YouTube and Discord
	echo "Adding custom entries for YouTube and Discord..."
	tee -a "$HOSTS_STAGING" >/dev/null <"$CUSTOM_ENTRIES_FILE"

	verify_unblocks "$HOSTS_STAGING" || {
		sudo rm -f "$HOSTS_STAGING"
		return 1
	}

	# Readable by all, writable only by root; then swap it in atomically.
	sudo chmod 644 "$HOSTS_STAGING"
	sudo mv -f "$HOSTS_STAGING" /etc/hosts

	# Make the file immutable and append-only for maximum protection
	sudo chattr +ia /etc/hosts
}
