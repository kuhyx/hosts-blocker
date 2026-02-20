#!/bin/bash
# One-shot installer for hosts guard + psychological friction + read-only bind mount
# Layers implemented:
#  - Canonical snapshot of /etc/hosts at /usr/local/share/locked-hosts
#  - Enforcement script (/usr/local/sbin/enforce-hosts.sh)
#  - Systemd path-based auto-revert (hosts-guard.path + hosts-guard.service)
#  - Read-only bind mount (hosts-bind-mount.service)
#  - Delayed edit workflow (/usr/local/sbin/unlock-hosts)
#
# This script is idempotent. Re-running updates installed artifacts safely.
#
# Usage:
#   sudo ./setup_hosts_guard.sh [options]
# Options:
#   --force-snapshot        Overwrite canonical snapshot even if it exists
#   --no-snapshot           Skip creating canonical snapshot (assume already present)
#   --skip-bind             Do not enable read-only bind mount service
#   --skip-path-watch       Do not enable path watch auto-revert
#   --delay N               Set unlock delay seconds (default 45)
#   --dry-run               Show actions without performing changes
#   --uninstall             Remove installed units/scripts (does NOT restore original hosts)
#   -h|--help               Show help
#
# Exit codes:
#   0 success, 1 generic failure, 2 argument error

set -euo pipefail

######################################################################
# Defaults / Config
######################################################################
FORCE_SNAPSHOT=0
DO_SNAPSHOT=1
ENABLE_BIND=1
ENABLE_PATH=1
ENABLE_NSSWITCH=1
UNINSTALL=0
DELAY=45
DRY_RUN=0
INSTALL_SHELL_HOOKS=1
INSTALL_AUDIT_RULE=1
ADD_ALIAS_STUB=1

######################################################################
# Helpers
######################################################################
msg() { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
note() { printf '\e[1;34m[i]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err() { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; }
run() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'DRY-RUN:'
		if [ "$#" -gt 0 ]; then
			printf ' %q' "$@"
		fi
		printf '\n'
	else
		"$@"
	fi
}

require_root() { if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi; }

usage() { sed -n '1,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; }

######################################################################
# Parse args
######################################################################
while [[ $# -gt 0 ]]; do
	case "$1" in
	--force-snapshot)
		FORCE_SNAPSHOT=1
		shift
		;;
	--no-snapshot)
		DO_SNAPSHOT=0
		shift
		;;
	--skip-bind)
		ENABLE_BIND=0
		shift
		;;
	--skip-path-watch)
		ENABLE_PATH=0
		shift
		;;
	--skip-nsswitch)
		ENABLE_NSSWITCH=0
		shift
		;;
	--delay)
		DELAY=${2:-}
		[[ -z ${DELAY} ]] && {
			err '--delay requires value'
			exit 2
		}
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--no-shell-hooks)
		INSTALL_SHELL_HOOKS=0
		shift
		;;
	--shell-hooks)
		INSTALL_SHELL_HOOKS=1
		shift
		;;
	--no-audit)
		INSTALL_AUDIT_RULE=0
		shift
		;;
	--audit)
		INSTALL_AUDIT_RULE=1
		shift
		;;
	--no-alias-stub)
		ADD_ALIAS_STUB=0
		shift
		;;
	--alias-stub)
		ADD_ALIAS_STUB=1
		shift
		;;
	--uninstall)
		UNINSTALL=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unknown argument: $1"
		usage
		exit 2
		;;
	esac
done

require_root "$@"

######################################################################
# Paths
######################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEMPLATE_ENFORCE="$SCRIPT_DIR/enforce-hosts.sh"
TEMPLATE_UNLOCK="$SCRIPT_DIR/psychological/unlock-hosts.sh"
UNIT_GUARD_SERVICE="$SCRIPT_DIR/hosts-guard.service"
UNIT_GUARD_PATH="$SCRIPT_DIR/hosts-guard.path"
UNIT_BIND_SERVICE="$SCRIPT_DIR/hosts-bind-mount.service"
TEMPLATE_ENFORCE_NSSWITCH="$SCRIPT_DIR/enforce-nsswitch.sh"
UNIT_NSSWITCH_SERVICE="$SCRIPT_DIR/nsswitch-guard.service"
UNIT_NSSWITCH_PATH="$SCRIPT_DIR/nsswitch-guard.path"

INSTALL_ENFORCE="/usr/local/sbin/enforce-hosts.sh"
INSTALL_UNLOCK="/usr/local/sbin/unlock-hosts"
INSTALL_ENFORCE_NSSWITCH="/usr/local/sbin/enforce-nsswitch.sh"
CANON="/usr/local/share/locked-hosts"
CANON_NSSWITCH="/usr/local/share/locked-nsswitch.conf"
HOSTS="/etc/hosts"
NSSWITCH="/etc/nsswitch.conf"

# Shell hook destinations (user agnostic system-wide skeleton + etc profile.d)
ZSH_FILTER_SNIPPET="/etc/zsh/hosts_guard_history_filter.zsh"
BASH_FILTER_SNIPPET="/etc/profile.d/hosts_guard_history_filter.sh"

SYSTEMD_DIR="/etc/systemd/system"

######################################################################
# Uninstall flow
######################################################################
if [[ $UNINSTALL -eq 1 ]]; then
	note "Uninstalling hosts guard components ( protections removed )"
	for u in hosts-guard.path hosts-guard.service hosts-bind-mount.service nsswitch-guard.path nsswitch-guard.service; do
		if systemctl list-unit-files | grep -q "^$u"; then
			run systemctl disable --now "$u" || true
		fi
	done
	for f in \
		"$INSTALL_ENFORCE" \
		"$INSTALL_UNLOCK" \
		"$INSTALL_ENFORCE_NSSWITCH" \
		"$SYSTEMD_DIR/hosts-guard.service" \
		"$SYSTEMD_DIR/hosts-guard.path" \
		"$SYSTEMD_DIR/hosts-bind-mount.service" \
		"$SYSTEMD_DIR/nsswitch-guard.service" \
		"$SYSTEMD_DIR/nsswitch-guard.path" \
		"$ZSH_FILTER_SNIPPET" \
		"$BASH_FILTER_SNIPPET"; do
		if [[ -e $f ]]; then run rm -f "$f"; fi
	done
	note "Leaving canonical snapshots at $CANON and $CANON_NSSWITCH (remove manually if undesired)."
	if [[ $DRY_RUN -eq 0 ]]; then systemctl daemon-reload; fi
	msg "Uninstall complete"
	exit 0
fi

######################################################################
# Pre-flight checks
######################################################################
note "Script directory: $SCRIPT_DIR"
note "Repository root: $REPO_ROOT"

for req in "$TEMPLATE_ENFORCE" "$TEMPLATE_UNLOCK" "$UNIT_GUARD_SERVICE"; do
	[[ -f $req ]] || {
		err "Missing template: $req"
		exit 1
	}
done

if [[ ! -f $HOSTS ]]; then
	err "$HOSTS does not exist. Run your hosts/install.sh first."
	exit 1
fi

######################################################################
# Snapshot
######################################################################
if [[ $DO_SNAPSHOT -eq 1 ]]; then
	if [[ -f $CANON && $FORCE_SNAPSHOT -eq 0 ]]; then
		note "Canonical snapshot exists (use --force-snapshot to overwrite)"
	else
		msg "Creating canonical snapshot at $CANON"
		run install -m 644 -D "$HOSTS" "$CANON"
	fi
else
	note "Skipping snapshot creation (--no-snapshot)"
fi

######################################################################
# Install scripts
######################################################################
msg "Installing enforcement script -> $INSTALL_ENFORCE"
run install -m 755 "$TEMPLATE_ENFORCE" "$INSTALL_ENFORCE"

msg "Installing unlock script -> $INSTALL_UNLOCK"
run install -m 755 "$TEMPLATE_UNLOCK" "$INSTALL_UNLOCK"

# Adjust delay in unlock script if different from default
if [[ $DELAY -ne 45 ]]; then
	msg "Adjusting unlock delay to $DELAY seconds"
	if [[ $DRY_RUN -eq 1 ]]; then
		echo "DRY-RUN: would patch $INSTALL_UNLOCK"
	else
		# Replace DELAY_SECONDS=... line
		sed -i -E "s/^(DELAY_SECONDS=).*/\\1$DELAY/" "$INSTALL_UNLOCK" || warn "Failed to adjust delay"
	fi
fi

######################################################################
# Install shell history filters (optional)
######################################################################
if [[ $INSTALL_SHELL_HOOKS -eq 1 ]]; then
	msg "Installing shell history suppression hooks for unlock command"
	# Pattern matches commands invoking unlock-hosts (with or without sudo) & setup script force snapshot
	# Zsh: use zshaddhistory function
	if command -v zsh >/dev/null 2>&1; then
		if [[ $DRY_RUN -eq 1 ]]; then
			echo "DRY-RUN: would create $ZSH_FILTER_SNIPPET"
		else
			cat >"$ZSH_FILTER_SNIPPET" <<'ZEOF'
# Added by hosts guard setup – suppress unlock-hosts commands from Zsh history
autoload -Uz add-zsh-hook 2>/dev/null || true
_hosts_guard_history_filter() {
  emulate -L zsh
  setopt extendedglob
  local line="$1"
  local _pattern='(^|;|&&|\|\|)\s*(sudo\s+)?(/usr/local/sbin/)?unlock-hosts(\s|;|$)'
  if [[ $line =~ ${_pattern} ]]; then
    return 1
  fi
  return 0
}
if typeset -f add-zsh-hook >/dev/null 2>&1; then
  add-zsh-hook zshaddhistory _hosts_guard_history_filter 2>/dev/null || true
else
  zshaddhistory() { _hosts_guard_history_filter "$1"; }
fi
ZEOF
			chmod 644 "$ZSH_FILTER_SNIPPET"
		fi
	fi

	# Bash: rely on HISTCONTROL and PROMPT_COMMAND filter
	if command -v bash >/dev/null 2>&1; then
		if [[ $DRY_RUN -eq 1 ]]; then
			echo "DRY-RUN: would create $BASH_FILTER_SNIPPET"
		else
			cat >"$BASH_FILTER_SNIPPET" <<'BEOF'
# Added by hosts guard setup – suppress unlock-hosts commands from Bash history
export HISTCONTROL=ignoredups:erasedups
_hosts_guard_hist_filter() {
  local last_cmd
  local _pattern='(^|;|&&|\|\|)\s*(sudo\s+)?(/usr/local/sbin/)?unlock-hosts(\s|;|$)'
  last_cmd=$(history 1 2>/dev/null | sed -E 's/^ *[0-9]+ +//')
  if [[ -n $last_cmd && $last_cmd =~ ${_pattern} ]]; then
    local id
    id=$(history 1 2>/dev/null | awk '{print $1}')
    if [[ -n $id ]]; then history -d $id 2>/dev/null || true; fi
    history -w 2>/dev/null || true
    history -c || true
    history -r 2>/dev/null || true
  fi
}
case :${PROMPT_COMMAND-}: in
  *:_hosts_guard_hist_filter:* ) ;;
  * ) PROMPT_COMMAND="_hosts_guard_hist_filter${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
esac
BEOF
			chmod 644 "$BASH_FILTER_SNIPPET"
		fi
	fi
else
	note "Skipping shell history hooks (--no-shell-hooks)"
fi

######################################################################
# Add alias stub to discourage raw invocation (shell-level friction)
######################################################################
if [[ $ADD_ALIAS_STUB -eq 1 ]]; then
	PROFILE_STUB="/etc/profile.d/hosts_guard_alias_stub.sh"
	if [[ $DRY_RUN -eq 1 ]]; then
		echo "DRY-RUN: would create $PROFILE_STUB"
	else
		cat >"$PROFILE_STUB" <<'ASTUB'
# Added by hosts guard setup – discourages casual use of unlock-hosts name
if command -v unlock-hosts >/dev/null 2>&1; then
  alias unlock-hosts='command_not_found_handle 2>/dev/null || echo "Use: sudo /usr/local/sbin/unlock-hosts (logged & delayed)"'
fi
ASTUB
		chmod 644 "$PROFILE_STUB"
	fi
fi

######################################################################
# Audit rule to record executions (requires auditd)
######################################################################
if [[ $INSTALL_AUDIT_RULE -eq 1 ]]; then
	if command -v auditctl >/dev/null 2>&1; then
		audit_rule_str="-w /usr/local/sbin/unlock-hosts -p x -k hosts_unlock"
		audit_rule_args=(-w /usr/local/sbin/unlock-hosts -p x -k hosts_unlock)
		if auditctl -l 2>/dev/null | grep -Fq "/usr/local/sbin/unlock-hosts"; then
			note "Audit rule already present"
		else
			run auditctl "${audit_rule_args[@]}" || warn "Failed to add audit rule (runtime)"
			if [[ $DRY_RUN -eq 1 ]]; then
				echo "DRY-RUN: would create /etc/audit/rules.d/hosts_unlock.rules"
			else
				echo "$audit_rule_str" >/etc/audit/rules.d/hosts_unlock.rules
			fi
		fi
	else
		warn "auditctl not found; skipping audit rule (install auditd to enable)"
	fi
fi

######################################################################
# Install systemd units
######################################################################
msg "Deploying systemd units"
run install -m 644 "$UNIT_GUARD_SERVICE" "$SYSTEMD_DIR/hosts-guard.service"
run install -m 644 "$UNIT_GUARD_PATH" "$SYSTEMD_DIR/hosts-guard.path"
run install -m 644 "$UNIT_BIND_SERVICE" "$SYSTEMD_DIR/hosts-bind-mount.service"
run install -m 644 "$UNIT_NSSWITCH_SERVICE" "$SYSTEMD_DIR/nsswitch-guard.service"
run install -m 644 "$UNIT_NSSWITCH_PATH" "$SYSTEMD_DIR/nsswitch-guard.path"

if [[ $DRY_RUN -eq 0 ]]; then systemctl daemon-reload; fi

######################################################################
# Enable / Start
######################################################################
if [[ $ENABLE_PATH -eq 1 ]]; then
	msg "Enabling path watch (auto-revert)"
	run systemctl enable --now hosts-guard.path
else
	note "Skipping path watch (--skip-path-watch)"
fi

if [[ $ENABLE_BIND -eq 1 ]]; then
	msg "Enabling read-only bind mount"
	run systemctl enable --now hosts-bind-mount.service
else
	note "Skipping bind mount (--skip-bind)"
fi

if [[ $ENABLE_NSSWITCH -eq 1 ]]; then
	msg "Enabling nsswitch.conf protection (hosts bypass prevention)"
	msg "Installing nsswitch enforcement script -> $INSTALL_ENFORCE_NSSWITCH"
	run install -m 755 "$TEMPLATE_ENFORCE_NSSWITCH" "$INSTALL_ENFORCE_NSSWITCH"

	# Ensure 'files' is present in the hosts line before snapshotting
	if [[ -f "$NSSWITCH" ]]; then
		hosts_line=$(grep '^hosts:' "$NSSWITCH" 2>/dev/null || echo "")
		if [[ -n "$hosts_line" ]] && ! echo "$hosts_line" | grep -qw 'files'; then
			msg "Adding 'files' to nsswitch.conf hosts line (was: $hosts_line)"
			if echo "$hosts_line" | grep -qw 'resolve'; then
				run sed -i 's/^hosts:\(.*\)resolve/hosts: files\1resolve/' "$NSSWITCH"
			elif echo "$hosts_line" | grep -qw 'dns'; then
				run sed -i 's/^hosts:\(.*\)dns/hosts:\1files dns/' "$NSSWITCH"
			else
				run sed -i 's/^hosts:/hosts: files/' "$NSSWITCH"
			fi
			msg "nsswitch.conf hosts line fixed: $(grep '^hosts:' "$NSSWITCH")"
		fi
	fi

	# Create nsswitch canonical snapshot if needed
	if [[ -f "$NSSWITCH" ]]; then
		if [[ ! -f "$CANON_NSSWITCH" ]]; then
			msg "Creating canonical nsswitch.conf snapshot at $CANON_NSSWITCH"
			run cp "$NSSWITCH" "$CANON_NSSWITCH"
			run chmod 644 "$CANON_NSSWITCH"
			chattr +i "$CANON_NSSWITCH" 2>/dev/null || warn "Failed to protect canonical nsswitch copy"
		fi
	fi

	run systemctl enable --now nsswitch-guard.path

	# Perform initial nsswitch enforcement
	if [[ $DRY_RUN -eq 1 ]]; then
		echo "DRY-RUN: would run $INSTALL_ENFORCE_NSSWITCH"
	else
		"$INSTALL_ENFORCE_NSSWITCH" || warn "nsswitch enforcement returned non-zero"
	fi
else
	note "Skipping nsswitch protection (--skip-nsswitch)"
fi

msg "Performing initial hosts enforcement"
if [[ $DRY_RUN -eq 1 ]]; then
	echo "DRY-RUN: would run $INSTALL_ENFORCE"
else
	"$INSTALL_ENFORCE" || warn "Enforcement returned non-zero"
fi

######################################################################
# Summary
######################################################################
echo
msg "Hosts guard setup complete"
echo "Canonical hosts copy: $CANON"
echo "Canonical nsswitch copy: $CANON_NSSWITCH"
echo "Enforce script: $INSTALL_ENFORCE"
echo "nsswitch enforce: $INSTALL_ENFORCE_NSSWITCH"
echo "Unlock command: sudo $INSTALL_UNLOCK"
echo "Delay (seconds): $DELAY"
echo "Auto-revert path watch: $([[ $ENABLE_PATH -eq 1 ]] && echo enabled || echo disabled)"
echo "Read-only bind mount: $([[ $ENABLE_BIND -eq 1 ]] && echo enabled || echo disabled)"
echo "nsswitch protection: $([[ $ENABLE_NSSWITCH -eq 1 ]] && echo enabled || echo disabled)"
echo "Shell history suppression: $([[ $INSTALL_SHELL_HOOKS -eq 1 ]] && echo enabled || echo disabled)"
echo "Audit rule: $([[ $INSTALL_AUDIT_RULE -eq 1 ]] && echo enabled || echo disabled)"
echo "Alias stub: $([[ $ADD_ALIAS_STUB -eq 1 ]] && echo enabled || echo disabled)"
echo
echo "Test flow:"
echo "  sudo sed -i '1s/.*/# tamper test/' /etc/hosts  # Should revert automatically"
echo "  sudo $INSTALL_UNLOCK                        # Intentional edit workflow"
echo
echo "Uninstall:"
echo "  sudo $0 --uninstall"
echo "(Optional) Skip shell history hooks: --no-shell-hooks"
echo
exit 0
