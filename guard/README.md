Hosts Guard Components
======================

This directory contains templates for hardening /etc/hosts against impulsive tampering by adding friction, NOT providing absolute security against a determined root user.

Components:
1. enforce-hosts.sh – Idempotent script that: compares /etc/hosts with canonical copy at /usr/local/share/locked-hosts and restores if different; reapplies immutable attribute.
2. systemd units (to be installed under /etc/systemd/system):
   - hosts-guard.service (oneshot enforcement)
   - hosts-guard.path (triggers on PathChanged=/etc/hosts)
   - hosts-bind-mount.service (bind mounts /etc/hosts read-only after boot)
3. psychological/ directory – scripts that add delay + journaling before allowing a maintenance/unlock operation.

Install Flow (suggested):
1. After generating /etc/hosts via your existing hosts/install.sh, copy it to /usr/local/share/locked-hosts.
2. Install enforce-hosts.sh to /usr/local/sbin/ (chmod 755).
3. Place units and enable:
      systemctl daemon-reload
      systemctl enable --now hosts-guard.path
      systemctl enable --now hosts-bind-mount.service
4. (Optional) Use psychological/unlock-hosts.sh as the ONLY sanctioned way to modify hosts (it removes protections temporarily, launches an editor after a delay, and re-enforces on close).

Limitations:
- A root user can still disable units, remount, remove attributes.
- Purpose is to interrupt habit loops and create intentional friction.
