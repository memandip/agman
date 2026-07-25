# agman

**agman** — **ag**ent **man**ager. Config profiles for AI coding agents: switch between complete work/personal setups the way `AWS_PROFILE` switches AWS accounts. Supports [Claude Code](https://code.claude.com/docs) today; Codex and Gemini CLI adapters are on the roadmap.

A profile is everything your agent *is* in a given context: its own `CLAUDE.md`, settings, rules, skills, agents, plugins, and MCP servers, kept as a complete config directory under `~/.agman/<name>`. `agman use` activates one by symlinking `~/.claude` at it — no shell setup required, and it applies to every new Claude Code session on this machine, IDE extensions included. One pure-bash script, no dependencies, works on macOS (stock bash 3.2), Linux, WSL, and Git Bash.

```console
$ agman create personal              # empty profile with a starter CLAUDE.md
$ agman create work --copy-current   # seeded from your current Claude config
$ agman use work
Switched to profile 'work' (~/.claude -> ~/.agman/work).
Your original Claude config was backed up as the 'global' profile.
$ claude                             # every new session now uses 'work'
$ agman off                          # fully restore your original ~/.claude
```

## How it works

`agman use <name>` symlinks `~/.claude` (and `~/.claude.json`, so user-scope MCP servers follow the profile) at the profile directory:

- The **first** time you switch, your original `~/.claude` is moved to `~/.agman/global` — it becomes a normal profile named `global`. Switch back to it anytime with `agman use global`, or run `agman off` to physically restore it and stop managing `~/.claude` entirely.
- The symlink doubles as the marker: a **real directory** at `~/.claude` means agman isn't managing anything; a **symlink into `~/.agman/`** means that profile is active. `agman current` (or `ls -l ~/.claude`) tells you which.
- agman refuses to touch a `~/.claude` symlink it didn't create (e.g. dotfiles managers), and refuses to remove the active profile.

Selection precedence, highest first:

1. **`CLAUDE_CONFIG_DIR` set in a shell** — wins in that shell only, never overridden. Use `agman env`, `agman run`, or `agman exec` for per-shell/per-process profiles alongside the global switch.
2. **The `~/.claude` symlink** set by `agman use` — machine-wide for all new sessions, no shell integration needed.
3. **Nothing** — stock `~/.claude`, untouched behavior.

Running sessions keep the config they started with; switching affects new sessions.

## Accounts: switching profiles does not log you out

New profiles **inherit your current Claude account**, so switching never drops you at a
login prompt. This needs care because Claude Code splits auth across two places:

- **Account identity** lives in `~/.claude.json`. Claude Code runs first-launch onboarding
  when `hasCompletedOnboarding` is absent, and treats auth as cached when `oauthAccount` is
  set. `agman create` seeds those keys (plus `userID` and `machineID`) from your live config,
  and `agman use` backfills any profile that predates this behavior.
- **Credentials** live in the macOS Keychain, or in `<config dir>/.credentials.json` on
  Linux and Windows. On macOS the symlink keeps the path `~/.claude`, so the Keychain entry
  is shared automatically. On Linux and Windows, agman promotes the credential file to
  `~/.agman/.credentials.json` and symlinks each profile at it, so a token refresh in one
  profile is visible to all of them. `agman off` turns that link back into a real file, so
  your restored config works without agman.

Only account identity is copied — personal project state, history, and caches stay out of
new profiles. A clean structured merge uses `jq` or `python3` when available; with neither
installed agman copies the whole state file instead and says so, rather than silently
breaking your login.

Run `agman doctor` to see per-profile auth state. It reports presence only and never prints
token material.

Giving a profile its **own** account (a separate work login) is Phase 4 on the roadmap; a
profile that already holds its own real `.credentials.json` is left untouched today.

## Install

Homebrew (macOS and Linux):

```bash
brew install memandip/agman/agman
```

From a clone:

```bash
git clone https://github.com/memandip/agman.git && cd agman && ./install.sh
```

Or piped (no clone):

```bash
curl -fsSL https://raw.githubusercontent.com/memandip/agman/main/install.sh | bash
```

Update later with:

```bash
agman update
```

(`update` does a `git pull` when agman runs from a checkout, otherwise downloads the latest release script and swaps it in atomically after validation.)

## Commands

| Command | What it does |
|---|---|
| `create <name>` | New **empty** profile with a starter `CLAUDE.md`, inheriting your current account. Flags: `--copy-current` (seed from current config; skips sessions/cache/history), `--from <profile>`, `--link-plugins` |
| `use <name>` | Activate: symlink `~/.claude` → profile. First use backs up your original config as the `global` profile |
| `off` | Deactivate and physically restore your original `~/.claude` |
| `current` | Show the active profile and how it was selected |
| `list` | List profiles; `(active)` marks the `~/.claude` target |
| `dir <name>` / `env <name>` | Print a profile's directory / an `export CLAUDE_CONFIG_DIR=…` line |
| `run <name> [-- args]` | Launch `claude` once under a profile without switching globally |
| `exec <name> -- <cmd>` | Run any command with `CLAUDE_CONFIG_DIR` set |
| `rename <old> <new>` / `remove <name>` | Manage profiles (rename repoints the symlink; remove refuses if active) |
| `update` | Self-update from git or GitHub |
| `doctor` | Diagnose setup (symlink state, backup presence, stale default, …) |
| `init [zsh\|bash]` | Optional per-shell integration (see below) |

## Per-shell profiles (optional)

The global symlink switch needs no shell setup. If you also want *per-shell* profiles — e.g. a work terminal and a personal terminal at the same time — either eval an export line:

```bash
eval "$(agman env personal)"
```

or add the optional hook to `~/.zshrc` / `~/.bashrc`, which makes `agman use`/`off` also set `CLAUDE_CONFIG_DIR` in the current shell:

```bash
eval "$(agman init zsh)"   # or: init bash
```

## Caveats you should know

- **Switching is machine-global** for new sessions (that's the point). Terminals or IDE windows with running Claude sessions keep the config they launched with.
- `use` requires symlink support; on Windows use WSL, or Git Bash with Developer Mode enabled.
- **Profiles share one account by default** — see [Accounts](#accounts-switching-profiles-does-not-log-you-out). Per-profile accounts are Phase 4 on the roadmap. Treat profile dirs as sensitive: they can hold credentials and MCP tokens.
- **`agman update` and the curl installer need `curl`.** Everything else is bash plus standard tools; `jq` or `python3` improves profile creation but is not required.
- `CLAUDE_CONFIG_DIR` (used by the per-shell layer) is honored by the Claude Code CLI but not officially documented ([anthropics/claude-code#33430](https://github.com/anthropics/claude-code/issues/33430)). The global symlink switch does not depend on it.

## Development

```bash
bash tests/run.sh    # sandboxed: fake HOME, stub claude binary — safe to run anywhere
```

CI runs the suite on Ubuntu + macOS and lints with shellcheck on every push.

## Roadmap

- **Multi-agent adapters**: Codex (via [`CODEX_HOME`](https://developers.openai.com/codex/environment-variables) / `~/.codex`), then Gemini CLI / Qwen Code / Kimi; profiles grow per-tool sections
- `.agman` file for **per-directory auto-switching** (the `.nvmrc`/direnv analog)
- fish shell support, tab completions
- `--fresh-auth` seeding (exclude copied credentials)
- Profile export/import for syncing between machines

## License

MIT
