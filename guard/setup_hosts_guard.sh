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
UNINSTALL=0
DELAY=45
DRY_RUN=0

######################################################################
# Helpers
######################################################################
msg() { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
note() { printf '\e[1;34m[i]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf 'DRY-RUN: %s\n' "$*"; else eval "$@"; fi }

require_root() { if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi }

usage() { sed -n '1,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; }

######################################################################
# Parse args
######################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-snapshot) FORCE_SNAPSHOT=1 ; shift ;;
    --no-snapshot) DO_SNAPSHOT=0 ; shift ;;
    --skip-bind) ENABLE_BIND=0 ; shift ;;
    --skip-path-watch) ENABLE_PATH=0 ; shift ;;
    --delay) DELAY=${2:-} ; [[ -z ${DELAY} ]] && { err '--delay requires value'; exit 2; } ; shift 2 ;;
    --dry-run) DRY_RUN=1 ; shift ;;
    --uninstall) UNINSTALL=1 ; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
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

INSTALL_ENFORCE="/usr/local/sbin/enforce-hosts.sh"
INSTALL_UNLOCK="/usr/local/sbin/unlock-hosts"
CANON="/usr/local/share/locked-hosts"
HOSTS="/etc/hosts"

SYSTEMD_DIR="/etc/systemd/system"

######################################################################
# Uninstall flow
######################################################################
if [[ $UNINSTALL -eq 1 ]]; then
  note "Uninstalling hosts guard components ( protections removed )"
  for u in hosts-guard.path hosts-guard.service hosts-bind-mount.service; do
    if systemctl list-unit-files | grep -q "^$u"; then
      run systemctl disable --now "$u" || true
    fi
  done
  for f in \
    "$INSTALL_ENFORCE" \
    "$INSTALL_UNLOCK" \
    "$SYSTEMD_DIR/hosts-guard.service" \
    "$SYSTEMD_DIR/hosts-guard.path" \
    "$SYSTEMD_DIR/hosts-bind-mount.service"; do
      if [[ -e $f ]]; then run rm -f "$f"; fi
  done
  note "Leaving canonical snapshot at $CANON (remove manually if undesired)."
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
  [[ -f $req ]] || { err "Missing template: $req"; exit 1; }
done

if [[ ! -f "$HOSTS" ]]; then
  err "$HOSTS does not exist. Run your hosts/install.sh first."
  exit 1
fi

######################################################################
# Snapshot
######################################################################
if [[ $DO_SNAPSHOT -eq 1 ]]; then
  if [[ -f "$CANON" && $FORCE_SNAPSHOT -eq 0 ]]; then
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
# Install systemd units
######################################################################
msg "Deploying systemd units"
run install -m 644 "$UNIT_GUARD_SERVICE" "$SYSTEMD_DIR/hosts-guard.service"
run install -m 644 "$UNIT_GUARD_PATH" "$SYSTEMD_DIR/hosts-guard.path"
run install -m 644 "$UNIT_BIND_SERVICE" "$SYSTEMD_DIR/hosts-bind-mount.service"

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

msg "Performing initial enforcement"
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
echo "Canonical copy: $CANON" 
echo "Enforce script: $INSTALL_ENFORCE" 
echo "Unlock command: sudo $INSTALL_UNLOCK" 
echo "Delay (seconds): $DELAY" 
echo "Auto-revert path watch: $([[ $ENABLE_PATH -eq 1 ]] && echo enabled || echo disabled)" 
echo "Read-only bind mount: $([[ $ENABLE_BIND -eq 1 ]] && echo enabled || echo disabled)" 
echo
echo "Test flow:" 
echo "  sudo sed -i '1s/.*/# tamper test/' /etc/hosts  # Should revert automatically" 
echo "  sudo $INSTALL_UNLOCK                        # Intentional edit workflow" 
echo
echo "Uninstall:" 
echo "  sudo $0 --uninstall" 
echo
exit 0
