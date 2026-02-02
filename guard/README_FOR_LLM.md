# Hosts Guard System - LLM Reference Guide

> **For AI assistants**: This document explains how the hosts guard system works so you can make correct modifications.

## System Purpose

Prevent tampering with `/etc/hosts` to maintain website blocking (YouTube, social media, etc.) as part of a digital wellbeing system.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PROTECTION LAYERS                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Layer 1: Immutable Attribute                                       │
│  ─────────────────────────────                                      │
│  /etc/hosts has chattr +i (cannot be modified even by root)         │
│                                                                     │
│  Layer 2: Canonical Copy                                            │
│  ───────────────────────                                            │
│  /usr/local/share/locked-hosts contains the "true" version          │
│  If /etc/hosts differs, it gets overwritten from this copy          │
│                                                                     │
│  Layer 3: Path Watcher (systemd)                                    │
│  ──────────────────────────────                                     │
│  hosts-guard.path watches /etc/hosts for ANY change                 │
│  hosts-guard.service runs enforce-hosts.sh when triggered           │
│                                                                     │
│  Layer 4: Read-Only Bind Mount                                      │
│  ────────────────────────────                                       │
│  hosts-bind-mount.service mounts /etc/hosts read-only               │
│  Even if chattr is removed, write operations fail                   │
│                                                                     │
│  Layer 5: Custom Entries Protection                                 │
│  ─────────────────────────────────                                  │
│  /etc/hosts.custom-entries.state tracks blocked domains             │
│  Prevents removal of domains from install.sh                        │
│                                                                     │
│  Layer 6: nsswitch.conf Protection (NEW)                            │
│  ───────────────────────────────────────                            │
│  Prevents bypass via /etc/nsswitch.conf manipulation                │
│  Ensures "files" always appears in hosts: line before "dns"         │
│  nsswitch-guard.path watches for changes                            │
│  Canonical copy at /usr/local/share/locked-nsswitch.conf            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose | Protection |
|------|---------|------------|
| `/etc/hosts` | Active hosts file | chattr +i, bind mount |
| `/usr/local/share/locked-hosts` | Canonical source of truth | chattr +i |
| `/etc/hosts.custom-entries.state` | Tracks custom blocked domains | chattr +i |
| `/etc/hosts.stevenblack` | Cached upstream hosts file | None |
| `/etc/nsswitch.conf` | Name service switch config | chattr +i, path watcher |
| `/usr/local/share/locked-nsswitch.conf` | Canonical nsswitch copy | chattr +i |
| `/usr/local/sbin/enforce-hosts.sh` | Restoration script | File permissions |
| `/usr/local/sbin/enforce-nsswitch.sh` | nsswitch enforcement | File permissions |
| `/usr/local/sbin/unlock-hosts` | Psychological unlock script | File permissions |
| `/etc/systemd/system/hosts-guard.path` | Path watcher unit | systemd |
| `/etc/systemd/system/hosts-guard.service` | Enforcement service | systemd |
| `/etc/systemd/system/hosts-bind-mount.service` | RO bind mount | systemd |
| `/etc/systemd/system/nsswitch-guard.path` | nsswitch watcher | systemd |
| `/etc/systemd/system/nsswitch-guard.service` | nsswitch enforce | systemd |

## Key Scripts

### hosts/install.sh
- Downloads StevenBlack hosts list (cached at `/etc/hosts.stevenblack`)
- Adds custom blocking entries (YouTube, etc.)
- Comments out allowed sites (4chan, Facebook)
- Runs protection check for custom entries
- Sets up initial immutable attribute

### hosts/guard/setup_hosts_guard.sh
Installs all protection layers:
- Creates canonical snapshot
- Installs enforce-hosts.sh and unlock-hosts scripts
- Enables systemd path watcher
- Enables bind mount service
- Installs shell history suppression hooks

### hosts/guard/enforce-hosts.sh
Called when tampering detected:
```bash
# Compares /etc/hosts to canonical
# If different: restores from canonical, logs event
# Re-applies chattr +i
```

### hosts/guard/psychological/unlock-hosts.sh
Legitimate edit workflow:
1. Prompts for reason (logged)
2. Stops protection services
3. Waits 45 seconds (cooling off)
4. Opens editor
5. Updates canonical if changes made
6. Re-enables all protections

## Pacman Integration

The pacman wrapper calls these hooks during package transactions:
- `/usr/local/share/hosts-guard/pacman-pre-unlock-hosts.sh` - Before transaction
- `/usr/local/share/hosts-guard/pacman-post-relock-hosts.sh` - After transaction

These temporarily unlock hosts for package manager operations.

## Common Tasks

### Adding a New Blocked Domain

1. Edit `hosts/install.sh`
2. Find the heredoc section after `# Custom blocking entries`
3. Add line: `0.0.0.0 newdomain.com`
4. Run: `sudo ~/linux-configuration/hosts/install.sh`

```bash
# Example: Block example.com
# In hosts/install.sh, add to heredoc:
0.0.0.0 example.com
0.0.0.0 www.example.com
```

### Allowing a Previously Blocked Domain

**This is intentionally difficult.** You must:
1. Remove entry from install.sh heredoc
2. Remove protection: `sudo chattr -i /etc/hosts.custom-entries.state`
3. Edit state file to remove domain
4. Re-run install.sh

### Checking Protection Status

```bash
# Check immutable attribute
lsattr /etc/hosts
# Should show: ----i--------e-- /etc/hosts

# Check services
systemctl status hosts-guard.path hosts-guard.service hosts-bind-mount.service

# Check canonical exists
ls -la /usr/local/share/locked-hosts
```

### Legitimate Editing

```bash
sudo /usr/local/sbin/unlock-hosts
# Enter reason when prompted
# Wait 45 seconds
# Edit in your $EDITOR
# Changes auto-saved to canonical
```

## nsswitch.conf Protection (Layer 6)

**Why this matters:** A user could bypass ALL /etc/hosts protections by simply editing `/etc/nsswitch.conf` and removing `files` from the `hosts:` line. This protection layer prevents that.

### How it works:
- `nsswitch-guard.path` watches `/etc/nsswitch.conf` for changes
- `nsswitch-guard.service` runs `enforce-nsswitch.sh` when triggered
- Canonical copy stored at `/usr/local/share/locked-nsswitch.conf`
- Validates that `hosts:` line contains `files` before `dns`
- Auto-restores from canonical if tampered

### Check nsswitch protection status:
```bash
lsattr /etc/nsswitch.conf
systemctl status nsswitch-guard.path
```

## Troubleshooting

### "Cannot modify /etc/hosts"
This is expected! Use the unlock script:
```bash
sudo /usr/local/sbin/unlock-hosts
```

### Path watcher not running
```bash
sudo systemctl start hosts-guard.path
sudo systemctl enable hosts-guard.path
```

### Bind mount preventing access
```bash
# Temporarily disable (not recommended)
sudo systemctl stop hosts-bind-mount.service
```

### Custom entries protection blocking install
The protection mechanism detected you're trying to remove previously blocked domains. This is intentional. To proceed, manually edit the state file (see "Allowing a Previously Blocked Domain").

## DO NOT

1. ❌ Edit `/etc/nsswitch.conf` to bypass hosts (this defeats the purpose)
2. ❌ Stop `hosts-guard.path` without understanding consequences
3. ❌ Delete `/usr/local/share/locked-hosts` (breaks restoration)
4. ❌ Remove entries from install.sh without updating state file
5. ❌ Use `chattr -i` without going through unlock-hosts
