# hosts-blocker

System-wide domain blocking via `/etc/hosts`, built on the
[StevenBlack](https://github.com/StevenBlack/hosts) fakenews-gambling-porn-social
feed plus a local custom-entry list.

Extracted from the `testsAndMisc` monorepo with full history.

## Install

```bash
sudo ./install.sh              # default: do not flush DNS caches
sudo ./install.sh --flush-dns  # flush caches after writing
```

`install.sh` re-execs itself under `sudo` if needed and resolves its own
`lib/` directory, so it runs correctly from any checkout location.

## Expected checkout location

Scripts in the `testsAndMisc` monorepo invoke this repo's `install.sh` and
`generate_hosts_file.sh` by absolute path, resolved as
`<invoking user's home>/hosts-blocker`. Cloning it elsewhere means those
callers cannot find it — they fail loudly with a clone instruction rather than
silently skipping the blocker.

```bash
git clone https://github.com/kuhyx/hosts-blocker ~/src/hosts-blocker
```

## Layout

| Path | Role |
| --- | --- |
| `install.sh` | Flag parsing, protection gates, and the phase order |
| `generate_hosts_file.sh` | Builds a hosts file from a feed for the DNS blocker |
| `custom_entries.hosts` | Hand-maintained additional blocked domains |
| `lib/` | One file per install phase (cache, write, guard, DoH, protection) |
| `lib/tests/` | The unit's test suite — `lib/tests/run_all.sh` |
| `guard/plugins/` | guard-lib plugins for `resolved.conf` and `nsswitch.conf` |

## The two protection mechanisms

Both exist to make weakening the blocker require deliberate effort rather than
a quiet edit:

- **Custom entries** — an install must keep at least as many custom entries as
  the previous run, or replace any removed ones with genuinely new domains.
- **Unblock list** — adding a domain to the whitelist between
  `PROTECTED_UNBLOCK_LIST_START`/`END` in `install.sh` is refused until the
  state file is manually cleared.

## Enforcement does not rely on immutable sources

The files in this repo are **not** `chattr +i`. Making a git-tracked file
immutable breaks git tooling: `pre-commit run --all-files` opens every file
`rb+` and dies with `PermissionError`, so no push from a normal checkout can
succeed. It also breaks pre-commit's stash of unstaged changes, silently
reverting unrelated edits.

Enforcement instead comes from the installed artifacts: `/etc/hosts` is
`chattr +i`, and guard-lib's `hosts` file-guard instance
(`guardctl file-guard status hosts`) watches and re-enforces it against a
canonical snapshot. Editing a source file here changes nothing until
`install.sh` is re-run as root.

## Guard plugins

`guard/plugins/` holds the `resolved` and `nsswitch` guard-lib plugins. The
installed copies live at `/usr/local/share/guard-lib-plugins/` — the guards
name that path, not a repo path, so this repo can move without disturbing
them.

## Tests

```bash
./lib/tests/run_all.sh
```

The suite writes only to `mktemp` directories and needs no root.
