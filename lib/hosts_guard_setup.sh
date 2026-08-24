#!/bin/bash
# Registers the guard-lib file-guard instances that actually enforce the hosts
# blocking: hosts, nsswitch and resolved.
#
# WHY THIS EXISTS: install.sh used to `chattr +i /etc/hosts` and claim in a
# comment that "guard-lib's hosts file-guard instance watches and re-enforces
# it against its canonical snapshot, and the same instance's bind mount pins
# it". That was only true on THIS machine, because a one-shot migration script
# in the testsAndMisc monorepo had been run by hand. A fresh machine following
# the documented install path got immutability with NO watcher, NO canonical
# copy and NO bind mount -- five hardening checks stayed silently skipped.
#
# This lib is the fresh-install half of that migration: install plugins, then
# register the instances. It deliberately does NOT retire the legacy
# hosts-guard pacman hooks and systemd units -- a fresh machine has no legacy
# layer to retire, and that teardown (plus --rollback/--status) stays in the
# monorepo one-shot, which is the only place it makes sense.
#
# Sourced by install.sh. Every function is idempotent: re-running is a no-op.

# guardctl records an ABSOLUTE plugin path in the instance conf, so the plugins
# must live somewhere permanent. Pointing it at this repo checkout (or worse, a
# git worktree) silently breaks enforcement the day that directory moves.
GUARD_SETUP_GUARDCTL="${GUARD_SETUP_GUARDCTL:-/usr/local/bin/guardctl}"
GUARD_SETUP_TARGETS_DIR="${GUARD_SETUP_TARGETS_DIR:-/etc/guard-lib/targets}"
GUARD_SETUP_PLUGIN_INSTALL_DIR="${GUARD_SETUP_PLUGIN_INSTALL_DIR:-/usr/local/share/guard-lib-plugins}"

# Self-relative: this lib ships in the same repo as the plugins it installs.
# Asking extracted_repos.sh where hosts-blocker is would make the extracted
# repo depend on the monorepo it was extracted from.
GUARD_SETUP_PLUGIN_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../guard/plugins" 2>/dev/null && pwd || true)"

# name | target | bind_mount | plugin basename | also_watch
guard_setup_instance_spec() {
	case "$1" in
	hosts) echo "/etc/hosts|yes||" ;;
	nsswitch) echo "/etc/nsswitch.conf|no|nsswitch-plugin.sh|" ;;
	resolved) echo "/etc/systemd/resolved.conf|no|resolved-plugin.sh|/etc/systemd/resolved.conf.d" ;;
	*) return 1 ;;
	esac
}

GUARD_SETUP_INSTANCES=(hosts nsswitch resolved)

guard_setup_registered() { [[ -f "$GUARD_SETUP_TARGETS_DIR/$1.conf" ]]; }

# Returns 1 rather than exiting: this is sourced into install.sh, where an
# `exit` would kill the whole install mid-sequence instead of failing one phase.
guard_setup_available() {
	if [[ ! -x $GUARD_SETUP_GUARDCTL ]]; then
		echo "guard setup: guardctl not found at $GUARD_SETUP_GUARDCTL - run guard-lib's install.sh first" >&2
		return 1
	fi
	local unit
	for unit in guard-file@.path guard-file@.service guard-bind-mount@.service; do
		if [[ ! -f "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$unit" ]]; then
			echo "guard setup: missing systemd template $unit - run guard-lib's install.sh first" >&2
			return 1
		fi
	done
	if [[ -z $GUARD_SETUP_PLUGIN_SRC_DIR || ! -d $GUARD_SETUP_PLUGIN_SRC_DIR ]]; then
		echo "guard setup: plugin sources not found (expected ../guard/plugins beside this lib)" >&2
		return 1
	fi
	# A live pacman transaction would race every chattr and umount below.
	if [[ -e "${PACMAN_DB_LCK:-/var/lib/pacman/db.lck}" ]]; then
		echo "guard setup: ${PACMAN_DB_LCK:-/var/lib/pacman/db.lck} exists - a pacman transaction is in flight" >&2
		return 1
	fi
	return 0
}

guard_setup_install_plugins() {
	mkdir -p "$GUARD_SETUP_PLUGIN_INSTALL_DIR"
	local plugin
	for plugin in "$GUARD_SETUP_PLUGIN_SRC_DIR"/*.sh; do
		[[ -f $plugin ]] || continue
		install -m 755 "$plugin" "$GUARD_SETUP_PLUGIN_INSTALL_DIR/$(basename "$plugin")"
	done
}

# Collapse any stacked bind mounts on the target before re-registering, so the
# guard snapshots the real file rather than whatever is mounted over it.
guard_setup_collapse_mounts() {
	local path="$1" guard=0
	while mountpoint -q "$path" 2>/dev/null; do
		umount "$path" 2>/dev/null || break
		guard=$((guard + 1))
		((guard > 16)) && break
	done
}

guard_setup_register_instance() {
	local name="$1" spec target bind plugin also_watch
	spec="$(guard_setup_instance_spec "$name")" || return 0
	IFS='|' read -r target bind plugin also_watch <<<"$spec"

	if guard_setup_registered "$name"; then
		echo "guard setup: $name already registered"
		return 0
	fi
	if [[ ! -e $target ]]; then
		echo "guard setup: $name target $target does not exist - skipping" >&2
		return 0
	fi

	guard_setup_collapse_mounts "$target"
	chattr -i "$target" 2>/dev/null || true

	local -a args=(file-guard install "$name" --target "$target")
	[[ $bind == "yes" ]] && args+=(--bind-mount)
	[[ -n $plugin ]] && args+=(--plugin "$GUARD_SETUP_PLUGIN_INSTALL_DIR/$plugin")
	[[ -n $also_watch ]] && args+=(--also-watch "$also_watch")

	"$GUARD_SETUP_GUARDCTL" "${args[@]}" || {
		echo "guard setup: failed to register $name" >&2
		return 1
	}
	echo "guard setup: $name registered"
}

# The entry point install.sh calls. MUST run AFTER the hosts file is written:
# the instance snapshots a canonical copy and pins it with a bind mount, so
# registering first would canonicalise the PRE-write file and the guard would
# then fight (or revert) the write it was installed to protect.
setup_hosts_guards() {
	guard_setup_available || return 1
	guard_setup_install_plugins
	local name rc=0
	for name in "${GUARD_SETUP_INSTANCES[@]}"; do
		guard_setup_register_instance "$name" || rc=1
	done
	return "$rc"
}
