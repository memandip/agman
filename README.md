# agman

**agman** — **ag**ent **man**ager. Config profiles for AI coding agents: switch between complete work/personal setups the way `AWS_PROFILE` switches AWS accounts. Supports [Claude Code](https://code.claude.com/docs) today; Codex and Gemini CLI adapters are on the roadmap.

A profile is everything your agent *is* in a given context: its own `CLAUDE.md`, settings, rules, skills, agents, plugins, and MCP servers, kept as a complete config directory. `agman` creates, lists, and switches them by pointing the `CLAUDE_CONFIG_DIR` environment variable at the right directory. One pure-bash script, no dependencies, works on macOS (stock bash 3.2), Linux, WSL, and Git Bash.

```console
$ agman create work        # seeded from your current ~/.claude
$ agman create personal --empty
$ agman use work
Default profile set to 'work'.
$ claude                       # runs with the work profile
$ agman off                # back to stock ~/.claude
```

## Why

Claude Code layers a single global `~/.claude` (instructions, skills, agents, plugins) into **every** project. If your office and personal work need different rule sets, different skills, or different accounts, there is no native profile mechanism — `CLAUDE_CONFIG_DIR` is the only lever, and it's per-process. `agman` gives it AWS-profile ergonomics: named profiles, a persistent default, per-shell overrides, and one-shot runs.

**Guarantee:** your stock `~/.claude` is never modified. Seeding only reads from it, and with no profile active, `claude` runs exactly as if agman were not installed.

## Install

From a clone:

```bash
git clone https://github.com/memandip/agman.git && cd agman && ./install.sh
```

Or piped (no clone):

```bash
curl -fsSL https://raw.githubusercontent.com/memandip/agman/main/install.sh | bash
```

Then add shell integration to `~/.zshrc` or `~/.bashrc` — this is what makes plain `claude` honor your default profile:

```bash
eval "$(agman init zsh)"   # or: init bash
```

## Commands

| Command | What it does |
|---|---|
| `create <name>` | New profile, seeded from `~/.claude` (skips sessions/cache/history). Flags: `--empty`, `--from <profile>`, `--link-plugins` |
| `list` | List profiles; `*` marks the default |
| `use <name>` | Set the persistent default (shell hook also applies it to the current shell) |
| `off` | Clear the default — back to stock `~/.claude` |
| `current` | Show the active profile and how it was selected |
| `dir <name>` / `dir --active` | Print a profile's directory |
| `env <name>` | Print an export line: `eval "$(agman env work)"` |
| `run <name> [-- args]` | Launch `claude` once under a profile, without switching |
| `exec <name> -- <cmd>` | Run any command with `CLAUDE_CONFIG_DIR` set |
| `rename <old> <new>` / `remove <name>` | Manage profiles |
| `doctor` | Diagnose setup (CLI found, stale default, symlink support, …) |
| `init [zsh\|bash]` | Print the shell integration snippet |

## How it works

Selection precedence, highest first:

1. **`CLAUDE_CONFIG_DIR` set in the environment** — never overridden. Per-shell, so two terminals can run different profiles at once (`eval "$(agman env personal)"`).
2. **Persistent default** set by `agman use`, stored in `~/.agman/.default` and applied by the shell hook's `claude()` wrapper.
3. **Nothing set** — stock `~/.claude`, untouched behavior.

Profiles live under `~/.agman/<name>/` (override with `AGMAN_HOME`). Seeding copies your config but excludes ephemeral state: sessions, caches, history, per-project auto-memory, telemetry. Your user-scope `~/.claude.json` (MCP servers, global state) is copied into the profile, since Claude Code reads it from inside the config dir when `CLAUDE_CONFIG_DIR` is set.

## Caveats you should know

- `CLAUDE_CONFIG_DIR` is honored by the Claude Code CLI but **not officially documented** ([anthropics/claude-code#33430](https://github.com/anthropics/claude-code/issues/33430)). It could change; `doctor` and the test suite exist to catch that early.
- The **VS Code extension ignores it** ([anthropics/claude-code#30538](https://github.com/anthropics/claude-code/issues/30538)) — profiles apply to terminal sessions.
- **Auth is per config dir.** A seeded profile inherits credentials copied from `~/.claude` where they exist on disk (Linux); on macOS, credentials live in the Keychain and may be shared. To use a different account in a profile, run `claude /login` inside it once. Treat profile dirs as sensitive.
- On Windows (Git Bash), symlinks may require Developer Mode; `--link-plugins` falls back to copying.

## Development

```bash
bash tests/run.sh    # sandboxed: fake HOME, stub claude binary — safe to run anywhere
```

CI runs the suite on Ubuntu + macOS and lints with shellcheck on every push.

## Roadmap

- **Multi-agent adapters**: Codex (via [`CODEX_HOME`](https://developers.openai.com/codex/environment-variables), mechanism confirmed), then Gemini CLI / Qwen Code / Kimi; profiles grow per-tool sections
- `.agman` file for **per-directory auto-switching** (the `.nvmrc`/direnv analog)
- fish shell support, tab completions
- `--fresh-auth` seeding (exclude copied credentials)
- Profile export/import for syncing between machines

## License

MIT
