# agman

**Switch between complete setups for your AI coding agents, the way `AWS_PROFILE` switches AWS accounts.**

Works with [Claude Code](https://code.claude.com/docs), [Codex CLI](https://developers.openai.com/codex)
and [Gemini CLI](https://github.com/google-gemini/gemini-cli). One bash script, no dependencies.

```console
$ agman use work       # every new session now uses your work setup
$ agman use personal   # ...and now your personal one
```

A **profile** is everything your agent is in one context: `CLAUDE.md`, settings, rules, skills,
agents, plugins, MCP servers and, if you want, its own account.

- **No shell setup.** Switching applies to every new session on the machine, IDE extensions included.
- **Nothing lost.** `claude --resume` works across profiles, and `agman off` restores your original configs exactly.
- **Safe.** Your originals are backed up first, and agman never touches files it didn't create.

## Install

```bash
brew install memandip/agman/agman
```

<details open>
<summary>Other ways to install</summary>

```bash
# One-line installer
curl -fsSL https://raw.githubusercontent.com/memandip/agman/main/install.sh | bash

# From a clone
git clone https://github.com/memandip/agman.git && cd agman && ./install.sh
```

After the first `brew install`, the short name works: `brew upgrade agman`. To use the short
name from the start, run `brew tap memandip/agman && brew trust memandip/agman` first.

</details>

Update with `agman update` (or `brew upgrade agman`).

## Quick start

```console
$ agman create work --copy-current     # copy your current setup into a 'work' profile
$ agman create personal                # or start an empty one
$ agman use work
Switched to profile 'work' (tools: claude codex gemini).
Your original configs were backed up as the 'global' profile.

$ agman use                            # no name: pick from a menu with ↑/↓ and Enter
$ agman current                        # which profile is active?
$ agman off                            # stop and restore your original configs
```

## Commands

| Command | What it does |
|---|---|
| `agman list` | Show your profiles (also `ls`, `--list`) |
| `agman current` | Show the active profile |
| `agman use [name]` | Switch to a profile; with no name, pick from a menu |
| `agman off` | Stop switching and restore your original configs |
| `agman create <name>` | New profile. `--copy-current` copies your setup, `--from <name>` copies a profile |
| `agman rename <old> <new>` | Rename a profile |
| `agman remove <name>` | Delete a profile (also `rm`; never the active one) |
| `agman login <name>` | Give a profile its own Claude account ([guide](docs/accounts.md)) |
| `agman run [name]` | Start `claude` once with a profile, without switching ([guide](docs/projects.md)) |
| `agman doctor` | Check your setup for problems |
| `agman cloud …` | Sync profiles between machines ([guide](docs/cloud.md)) |
| `agman stealth …` | Block company telemetry, per profile ([guide](docs/stealth.md)) |

Run `agman help` for the full list, or `agman <command> --help` for one command.

## How it works

Each profile is a folder under `~/.agman/<name>`. `agman use` points each tool's config path
at that folder, so switching is instant and needs no shell setup.

<details>
<summary>Show details</summary>

```
~/.claude       ->  ~/.agman/work/claude/
~/.claude.json  ->  ~/.agman/work/claude.json
~/.codex        ->  ~/.agman/work/codex/
~/.gemini       ->  ~/.agman/work/gemini/
```

- The **first** switch moves your original configs into a profile called `global`.
- **Sessions and history are shared** across profiles, so `claude --resume` always works ([details](docs/sessions.md)).
- **Your login is shared** by default, so switching never logs you out ([details](docs/accounts.md)).
- **Only tools you have are managed.** Limit them with `AGMAN_TOOLS="claude codex"`.
- **Sessions already running** keep their config; switching affects new sessions.
- agman **skips any config link it didn't create** (for example from a dotfiles manager) and won't delete the active profile.

Why links instead of environment variables? Gemini CLI has no way to change its config folder,
and IDE extensions don't see shell variables. Links work everywhere.

</details>

## Guides

| Guide | Read it when you want to… |
|---|---|
| [Sessions and history](docs/sessions.md) | understand what's shared, or keep history separate per profile |
| [Accounts and login](docs/accounts.md) | use a different Claude account per profile |
| [Per-project and per-shell profiles](docs/projects.md) | pick a profile per repo, or run two profiles side by side |
| [Cloud sync](docs/cloud.md) | sync profiles between machines or with a team |
| [Stealth](docs/stealth.md) | block company telemetry, per profile |

## Good to know

- **Windows:** needs symlink support. Use WSL, or Git Bash with Developer Mode on.
- **Profile folders are sensitive.** They can hold credentials and MCP tokens.
- **Optional tools:** `curl` for `update` and `cloud`; `jq` or `python3` makes profile creation cleaner. Everything else is plain bash.
- `CLAUDE_CONFIG_DIR`, used by `run`, `env` and the shell hook, works in Claude Code but isn't officially documented ([#33430](https://github.com/anthropics/claude-code/issues/33430)). Normal switching doesn't rely on it.

## Development

```bash
bash tests/run.sh    # sandboxed: fake HOME and a stub claude, safe to run anywhere
```

CI runs the tests on Ubuntu and macOS and checks the scripts with shellcheck.
See [design notes](docs/design.md) and the [roadmap](docs/roadmap.md).

**Planned:** sharing profiles through a git repository, Qwen Code and Kimi CLI support, fish
shell support, tab completion, and `--fresh-auth` (create a profile without copying your login).

## License

MIT
