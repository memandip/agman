# ccprofile — design (v0.1, 2026-07-23)

## Problem

Claude Code has one user-level config dir (`~/.claude`): global `CLAUDE.md`, settings, rules, skills, agents, plugins, and user-scope MCP servers all apply to every project. Work and personal contexts need different sets of all of those, and sometimes different accounts. There is no native profile feature; the only switching primitive is the `CLAUDE_CONFIG_DIR` environment variable (honored by the CLI, officially undocumented — anthropics/claude-code#33430).

## Goals

- AWS-profile-style UX: named profiles, `use`/`off`, a visible `current`, per-shell overrides, one-shot `run`/`exec`.
- Zero-dependency, cross-platform: single bash script, compatible with bash 3.2 (stock macOS), Linux, WSL, Git Bash.
- Safety: never modify the stock `~/.claude`; inactive == identical to not having the tool installed.
- Incremental delivery: tests + CI from the first commit.

## Non-goals (v0.1)

- Managing credentials or accounts (profiles isolate them as a side effect of separate dirs; we don't touch auth).
- Windows PowerShell/cmd support (Git Bash and WSL only).
- Editing profile contents (that's just editing files in the profile dir).
- Working around the VS Code extension's lack of `CLAUDE_CONFIG_DIR` support (#30538) — out of our control; documented instead.

## Architecture

Two layers, the pyenv/direnv pattern:

1. **Core CLI** (`bin/ccprofile`, pure bash): owns profile storage and state. Everything except mutating the current shell's environment.
2. **Shell integration** (emitted by `ccprofile init zsh|bash`, added via `eval` in the rc file): a `ccprofile()` function that makes `use`/`off` also export/unset `CLAUDE_CONFIG_DIR` in the current shell, and a `claude()` wrapper that injects the persistent default at invocation time. A child process cannot set its parent's env — this split is what makes `use` feel global while remaining per-process under the hood.

### Storage

```
~/.claude-profiles/            # CCPROFILE_HOME
├── .default                   # name of the persistent default profile
├── work/                      # a complete CLAUDE_CONFIG_DIR
│   ├── CLAUDE.md  settings.json  skills/  agents/  rules/  plugins/  .claude.json
└── personal/
```

Profile names: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, max 64 chars; `default|off|none|current|help` reserved. Validation is what makes `remove`'s `rm -rf "$CCPROFILE_HOME/$name"` safe.

### Selection precedence (the contract)

1. `CLAUDE_CONFIG_DIR` already set in the environment — never overridden by the tool.
2. Persistent default (`.default` file), applied only by the shell hook's `claude()` wrapper.
3. Nothing: stock `~/.claude`.

`dir --active` resolves only layer 2; the wrapper checks layer 1 itself. This keeps the resolver dumb and the precedence enforced in exactly one place.

### Seeding policy

`create <name>` defaults to copying `~/.claude` (explicit: `--from-current`; alternatives: `--empty`, `--from <profile>`). Copy uses an **exclude list** (not an include list) so future config files are picked up by default. Excluded as ephemeral/machine-local: `backups cache downloads file-history ide locks logs paste-cache projects session-env sessions shell-snapshots statsig tasks telemetry todos history.jsonl mcp-needs-auth-cache.json .last-cleanup .DS_Store`. Notably `projects/` (per-project auto-memory + transcripts) is excluded: fresh memory per profile, and personal history never leaks into a work profile.

`~/.claude.json` (user-scope MCP + global state, lives next to the config dir) is copied into the profile as `<profile>/.claude.json`, where Claude Code reads it when `CLAUDE_CONFIG_DIR` is set.

`--link-plugins` symlinks `plugins/` from the seed source instead of copying (shared installs/updates); falls back to copy where symlinks are unavailable (Git Bash without Developer Mode).

## Command surface (v0.1)

`create list use off current dir env run exec rename remove doctor init help version` — see README table. `env` exists so users can get per-shell profiles without any integration (`eval "$(ccprofile env work)"`), mirroring `aws-vault`/`ssh-agent` conventions.

## Platform notes

- bash 3.2 compatible: no associative arrays, no `${var,,}`, `${1+"$@"}` forwarding idiom for old-bash `set -u` safety.
- `find -print0 | while read -d ''` for filename safety; `cp -R` preserves symlinks per POSIX.
- shellcheck (`-S warning`) enforced in CI; not assumed locally.

## Risks

| Risk | Mitigation |
|---|---|
| `CLAUDE_CONFIG_DIR` is undocumented and could change | CI test suite + `doctor`; small blast radius (env var is the only coupling point) |
| VS Code extension ignores the env var | Documented; upstream issue linked |
| Seed exclude list drifts as Claude Code evolves | Exclude-list approach copies unknown files by default; list reviewed per release |
| Copied credentials in seeded profiles surprise users | README caveat; `--fresh-auth` planned |

## Testing

`tests/run.sh`: dependency-free, fully sandboxed (fake `$HOME`, temp `CCPROFILE_HOME`, stub `claude` on PATH that echoes `CLAUDE_CONFIG_DIR`). Covers seeding/excludes, name validation, precedence, run/exec, rename/remove state transitions, and end-to-end shell-hook behavior via `bash -c 'eval "$(ccprofile init bash)"; …'`. CI: Ubuntu + macOS matrix plus shellcheck.

## Roadmap

- **v0.2 — auto-switch**: `.claude-profile` file in a project root + cd hook (zsh `chpwd`, bash `PROMPT_COMMAND`, or direnv recipe); precedence slots between env var and persistent default.
- fish support, completions, `--fresh-auth`, profile export/import.
