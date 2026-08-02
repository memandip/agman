# agman

**agman** — **ag**ent **man**ager. Config profiles for AI coding agents: switch between complete work/personal setups the way `AWS_PROFILE` switches AWS accounts. Manages [Claude Code](https://code.claude.com/docs), [Codex CLI](https://developers.openai.com/codex), and [Gemini CLI](https://github.com/google-gemini/gemini-cli).

A profile is everything your agents *are* in a given context — instructions, settings, rules, skills, agents, plugins, MCP servers — kept as one config tree per tool under `~/.agman/<name>`:

```
~/.agman/work/claude/       ->  ~/.claude
~/.agman/work/claude.json   ->  ~/.claude.json
~/.agman/work/codex/        ->  ~/.codex
~/.agman/work/gemini/       ->  ~/.gemini
```

`agman use` activates a profile by symlinking each tool's config path at it — no shell setup required, and it applies to every new session on this machine, IDE extensions included. One pure-bash script, no dependencies, works on macOS (stock bash 3.2), Linux, WSL, and Git Bash.

| Tool | Config paths | Env override |
|---|---|---|
| Claude Code | `~/.claude`, `~/.claude.json` | `CLAUDE_CONFIG_DIR` |
| Codex CLI | `~/.codex` | `CODEX_HOME` |
| Gemini CLI | `~/.gemini` | none — symlink switching is the only way |

Only tools you actually have are touched: a profile covers a tool when it holds config for that tool, the CLI is on your PATH, or its config path exists. Restrict the set explicitly with `AGMAN_TOOLS="claude codex"` if you'd rather manage a subset. Gemini CLI is the reason agman switches by symlink rather than environment variables — it has no config-dir override at all, so nothing else generalizes.

```console
$ agman create personal              # empty profile with a starter CLAUDE.md
$ agman create work --copy-current   # seeded from your current configs
$ agman use work
Switched to profile 'work' (tools: claude codex gemini).
Seeded this profile with your current Claude account (no re-login needed).
Your original configs were backed up as the 'global' profile.
$ claude                             # every new session now uses 'work'
$ agman off                          # fully restore your original configs
```

## How it works

`agman use <name>` symlinks every managed config path at the profile (including `~/.claude.json`, so user-scope MCP servers follow it):

- The **first** time you switch, your original configs are moved into `~/.agman/global` — a normal profile named `global`. Switch back to it anytime with `agman use global`, or run `agman off` to physically restore it and stop managing `~/.claude` entirely.
- The symlink doubles as the marker: a **real directory** means agman isn't managing that tool; a **symlink into `~/.agman/`** means that profile is active. `agman current` (or `ls -l ~/.claude`) tells you which.
- agman refuses to touch a config symlink it didn't create (e.g. dotfiles managers) and skips that tool entirely rather than half-activating it; it also refuses to remove the active profile.

Selection precedence, highest first:

1. **`CLAUDE_CONFIG_DIR` set in a shell** — wins in that shell only, never overridden. Use `agman env`, `agman run`, or `agman exec` for per-shell/per-process profiles alongside the global switch.
2. **The config symlinks** set by `agman use` — machine-wide for all new sessions, no shell integration needed. This is the only mechanism that works for Gemini CLI.
3. **Nothing** — stock `~/.claude`, untouched behavior.

Running sessions keep the config they started with; switching affects new sessions.

## Sessions: `claude --resume` keeps working across switches

Claude Code stores a resumable session inside the config directory, at
`<config dir>/projects/<encoded-cwd>/<session-id>.jsonl`. Swapping that directory per profile
would strand every earlier session, so agman keeps session and history state in one shared
place that all profiles symlink:

```
~/.agman/.state/projects/        <- session transcripts (and auto memory)
~/.agman/.state/history.jsonl    <- prompt history
~/.agman/.state/todos, file-history, shell-snapshots, session-env, sessions
```

The practical effect: `claude --resume <id>` finds your session no matter which profile is
active, and a session started under one profile is resumable under another. What stays
per-profile is the persona — `CLAUDE.md`, settings, rules, skills, agents, plugins, MCP
servers.

Upgrading from an earlier agman recovers history automatically: the next `agman use` merges
whatever each profile is holding into shared state, file by file, and never overwrites. Since
transcripts are UUID-named, collisions effectively don't happen; if one does, your copy is
kept aside as `projects.agman-conflict` rather than being lost, and both `agman doctor` and
`agman off` list anything kept aside so it doesn't sit unnoticed.

`agman off` turns the shared links back into real directories under `~/.claude`, so a restored
config works without agman. Set `AGMAN_SHARE_STATE=0` if you would rather each profile keep
its own history — for example to keep client work strictly separate — at the cost of
cross-profile resuming.

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

### Giving a profile its own account

To have a profile authenticate as a *different* Claude account — a work login separate from
your personal one:

```bash
agman login work      # runs 'claude setup-token', then paste the token (hidden input)
agman logout work     # back to your shared account
```

This stores a long-lived token (`claude setup-token`, valid about a year and it does **not**
rotate) at mode `600` inside the profile, and points the profile's `settings.json` at a small
helper script through Claude Code's `apiKeyHelper` setting. Because that setting applies to
the CLI, the VS Code extension, and the Agent SDK, the profile's account follows you into
IDEs — which an environment variable could not do.

Deliberately *not* used: snapshotting Keychain entries or `.credentials.json`. Refresh tokens
rotate on every use, so a snapshot is already stale by the time you switch back, and
restoring it logs you out.

Limits of `setup-token` credentials, worth knowing before you rely on them:

- requires a Pro, Max, Team, or Enterprise plan
- model requests only: no Remote Control and no claude.ai connectors (locally configured MCP
  servers still work)
- managed setups that pin `forceLoginOrgUUID` reject environment credentials, so this path
  may be blocked on company-managed machines
- expires after about a year; rerun `agman login` to replace it

Cloning a profile never copies its account: the token, helper, and `apiKeyHelper` setting are
stripped, so the clone starts on your shared login.

## Per-project profiles

A repository can name the profile it wants in a `.agman` file at its root:

```
profile: acme-work
```

Then `agman use` and `agman run` with no argument read it, from that directory or any
subdirectory:

```bash
cd ~/work/acme && agman use      # activates acme-work
```

Because the file arrives with a clone, it is untrusted input: agman asks once before
honouring it and records the decision. In a non-interactive shell it refuses rather than
switching silently.

With the shell integration installed, entering the directory switches that terminal
automatically and leaving it switches back:

```bash
eval "$(agman init zsh)"   # or: init bash
```

That auto-switch works by exporting `CLAUDE_CONFIG_DIR`, so it is **terminal-only** — IDE
extensions don't inherit a shell's environment and keep following `agman use`. A
`CLAUDE_CONFIG_DIR` you set by hand always wins; the hook only manages the value it set.

Note that Claude Code already scopes plenty of things per project natively — `./CLAUDE.md`,
`./.claude/settings.json`, `./.claude/rules/`, `./.claude/skills/`, `./.claude/agents/`, and
`./.mcp.json`. Reach for a `.agman` file when you need to change something with no project
scope at all: the account, user-scope MCP servers, installed plugins, or the whole persona.

## Install

Homebrew (macOS and Linux):

```bash
brew install memandip/agman/agman
```

That first install also trusts the tap, so from then on the short name works for everything:

```bash
brew install agman
brew upgrade agman
```

To use the short name from the start, trust the tap explicitly first — Homebrew will not
resolve a bare formula name from an untrusted third-party tap:

```bash
brew tap memandip/agman
brew trust memandip/agman
brew install agman
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
| `use [name]` | Activate: symlink each tool's config path → profile. With no name, reads the nearest `.agman` file. First use backs up your originals as the `global` profile, and migrates older profiles to the current layout |
| `off` | Deactivate and physically restore your original configs |
| `current` | Show the active profile and which tools it covers |
| `list` | List profiles; `(active: …)` shows the live tools |
| `dir <name>` / `env <name>` | Print a profile's Claude config dir / `export` lines for every tool that supports one. `dir --for-cwd` resolves the nearest trusted `.agman` file |
| `run [name] [-- args]` | Launch `claude` once under a profile without switching globally. With no name, reads the nearest `.agman` file |
| `exec <name> -- <cmd>` | Run any command with `CLAUDE_CONFIG_DIR` and `CODEX_HOME` set |
| `rename <old> <new>` / `remove <name>` | Manage profiles (rename repoints active symlinks; remove refuses if active) |
| `migrate` | Move profiles to the current layout and relink (runs automatically on `use`) |
| `login <name>` / `logout <name>` | Give a profile its own Claude account, or return it to your shared login |
| `cloud <subcommand>` | Sync profiles with an [agman cloud](https://github.com/memandip/agman-cloud) server: `login`, `push [name]`, `pull <name> [--as <local>] [--force]`, `init <org-slug>` (new profile from a team default), `list`, `status`, `logout`. Pushes are versioned and encrypted at rest server-side. **A synced profile is a persona, not a login:** account material (the identity file, `.credentials.json`, per-profile tokens, codex/gemini auth, any `.env`) and ephemeral state (sessions, history, caches) stay local by default and are stripped on pull; a push is refused if a synced file looks like it holds a secret. `--include-secrets` (push) / `--with-secrets` (pull) opt into carrying account material for your own machine-to-machine restore. Pulls treat a downloaded profile as untrusted — they strip `hooks`/`apiKeyHelper` from `settings.json`, never touch shared-state symlinks, back up an existing profile first, and refuse the active profile without `--force`. Reinstallable plugin artifacts (plugin caches, marketplace clones, catalog data) are never synced in either direction; pull reinstalls them into the pulled profile from its own references (`settings.json` enabledPlugins + `plugins/known_marketplaces.json`) via the `claude` CLI — set `AGMAN_CLOUD_NO_INSTALL=1` to skip. `https` is required (override with `AGMAN_CLOUD_INSECURE=1`); the API key is passed to `curl` via a mode-600 file, never the command line |
| `update` | Self-update from git or GitHub |
| `doctor` | Diagnose setup: tool detection, per-path link state, per-profile auth, layout version |
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

- ~~Profile syncing between machines~~ — shipped as `agman cloud` (0.8.0), backed by the [agman cloud](https://github.com/memandip/agman-cloud) companion service
- **Profile sharing over git**: `push`/`pull` to a repository you own, and a `.agman` file that fetches a profile that isn't local yet
- **More tools**: Qwen Code and Kimi CLI adapters, once their config layouts are verified against the real CLIs
- fish shell support, tab completions
- `--fresh-auth` seeding (exclude copied credentials)

## License

MIT
