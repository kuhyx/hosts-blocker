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
UNBLOCK_VERIFY_DOMAINS=(facebook.com messenger.com fbcdn.net facebook.net linkedin.com licdn.com)

verify_unblocks() {
	local domain live=0
	for domain in "${UNBLOCK_VERIFY_DOMAINS[@]}"; do
		if grep -qE "^0\.0\.0\.0[[:space:]]+([a-zA-Z0-9._-]+\.)?${domain//./\\.}$" /etc/hosts; then
			echo "ERROR: $domain is still blocked in /etc/hosts after the unblock pass" >&2
			live=1
		fi
	done
	if ((live)); then
		echo "ERROR: unblock pass did not take (is /etc/hosts still a mountpoint?)" >&2
		return 1
	fi
	echo "Unblock pass verified: ${#UNBLOCK_VERIFY_DOMAINS[@]} domains resolvable."
}

write_hosts_file() {
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
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.com)/#\1/' /etc/hosts
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?messenger\.com)/#\1/' /etc/hosts
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?fbcdn\.net)/#\1/' /etc/hosts
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?facebook\.net)/#\1/' /etc/hosts
	sudo sed -i 's/^0\.0\.0\.0 delio\.com.pl/#0.0.0.0 delio.com.pl/' /etc/hosts
	sudo sed -i 's/^0\.0\.0\.0 loverslab\.com/#0.0.0.0 loverslab.com/' /etc/hosts

	# Allow LinkedIn and all subdomains (linkedin.com + licdn.com CDN)
	echo "Allowing LinkedIn by commenting out any blocking entries..."
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?linkedin\.com)/#\1/' /etc/hosts
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?licdn\.com)/#\1/' /etc/hosts
	sudo sed -i -E 's/^(0\.0\.0\.0[[:space:]]+[a-zA-Z0-9._-]*\.?loverslab\.com)/#\1/' /etc/hosts

	# Add custom entries for YouTube and Discord
	echo "Adding custom entries for YouTube and Discord..."
	tee -a /etc/hosts >/dev/null <"$CUSTOM_ENTRIES_FILE"

	verify_unblocks

	# Set proper permissions (readable by all, writable only by root)
	sudo chmod 644 /etc/hosts

	# Make the file immutable and append-only for maximum protection
	sudo chattr +ia /etc/hosts
}
