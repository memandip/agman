# agman — design (v0.1, 2026-07-23)

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

1. **Core CLI** (`bin/agman`, pure bash): owns profile storage and state. Everything except mutating the current shell's environment.
2. **Shell integration** (emitted by `agman init zsh|bash`, added via `eval` in the rc file): a `agman()` function that makes `use`/`off` also export/unset `CLAUDE_CONFIG_DIR` in the current shell, and a `claude()` wrapper that injects the persistent default at invocation time. A child process cannot set its parent's env — this split is what makes `use` feel global while remaining per-process under the hood.

### Storage

```
~/.agman/            # AGMAN_HOME
├── .default                   # name of the persistent default profile
├── work/                      # a complete CLAUDE_CONFIG_DIR
│   ├── CLAUDE.md  settings.json  skills/  agents/  rules/  plugins/  .claude.json
└── personal/
```

Profile names: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, max 64 chars; `default|off|none|current|help` reserved. Validation is what makes `remove`'s `rm -rf "$AGMAN_HOME/$name"` safe.

### Selection precedence (the contract, v0.2)

1. `CLAUDE_CONFIG_DIR` already set in the environment — per-shell, never overridden by the tool.
2. The `~/.claude` symlink set by `agman use` — machine-wide for all new sessions.
3. Nothing: stock `~/.claude`.

`dir --active` resolves the persistent default (`.default` file) for the optional shell hook; the symlink is the primary activation mechanism and needs no integration.

### v0.2 — symlink activation (2026-07-23)

v0.1 activated profiles purely via `CLAUDE_CONFIG_DIR`, which required shell integration and was ignored by the VS Code extension — first real-world use hit exactly that ("claude still not taking the profile"). v0.2 makes activation physical:

- `use <name>`: if `~/.claude` is a real directory, it is moved to `~/.agman/global` (a normal, switchable profile — the backup); then `~/.claude` is symlinked at the profile. `~/.claude.json` gets the same treatment so user-scope MCP servers follow the profile (an empty `{}` is created in profiles that lack one).
- The symlink is also the state marker: real dir = unmanaged, symlink into `$AGMAN_HOME` = managed (readlink names the active profile). Foreign symlinks (dotfiles managers) are refused, never replaced.
- `off`: removes the symlinks and moves `global` back into place — full physical restore.
- Guards: `remove` refuses the active profile (a dangling `~/.claude` would break Claude); `rename` repoints both symlinks when renaming the active profile; `global` is reserved as a creatable name.
- Trade-off accepted: switching is machine-global for new sessions. Per-shell divergence remains available via `env`/`run`/`exec` and the optional hook (layer 1).
- `create` now defaults to an empty profile with a starter CLAUDE.md; `--copy-current` opts into seeding (was the default in v0.1).
- New `update` command: `git pull --ff-only` when running from a checkout, else download `bin/agman` from `$AGMAN_RAW_URL`, validate with `bash -n`, and atomically swap (same-directory `mktemp` + `mv`).

### Seeding policy

`create <name>` defaults to copying `~/.claude` (explicit: `--from-current`; alternatives: `--empty`, `--from <profile>`). Copy uses an **exclude list** (not an include list) so future config files are picked up by default. Excluded as ephemeral/machine-local: `backups cache downloads file-history ide locks logs paste-cache projects session-env sessions shell-snapshots statsig tasks telemetry todos history.jsonl mcp-needs-auth-cache.json .last-cleanup .DS_Store`. Notably `projects/` (per-project auto-memory + transcripts) is excluded: fresh memory per profile, and personal history never leaks into a work profile.

`~/.claude.json` (user-scope MCP + global state, lives next to the config dir) is copied into the profile as `<profile>/.claude.json`, where Claude Code reads it when `CLAUDE_CONFIG_DIR` is set.

`--link-plugins` symlinks `plugins/` from the seed source instead of copying (shared installs/updates); falls back to copy where symlinks are unavailable (Git Bash without Developer Mode).

## Command surface (v0.1)

`create list use off current dir env run exec rename remove doctor init help version` — see README table. `env` exists so users can get per-shell profiles without any integration (`eval "$(agman env work)"`), mirroring `aws-vault`/`ssh-agent` conventions.

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

`tests/run.sh`: dependency-free, fully sandboxed (fake `$HOME`, temp `AGMAN_HOME`, stub `claude` on PATH that echoes `CLAUDE_CONFIG_DIR`). Covers seeding/excludes, name validation, precedence, run/exec, rename/remove state transitions, and end-to-end shell-hook behavior via `bash -c 'eval "$(agman init bash)"; …'`. CI: Ubuntu + macOS matrix plus shellcheck.

## Naming

Final name: **agman** (**ag**ent **man**ager), decided 2026-07-23 after two earlier candidates: `ccprofile` (too Claude-specific once the multi-agent direction was set) and `loadout` (strong metaphor, dropped in favor of an nvm-style expandable name). Sweep results for `agman`: npm name free, Homebrew formula free, no GitHub project of substance, no software company on it — nearest collisions are an investment firm and unrelated "AGM Tools" businesses, all non-software. Naming pattern follows podman (pod manager → pod-man; agent manager → ag-man).

Rejected acronyms, verified taken or colonized: `acm`, `apm`, `amp` (Sourcegraph's coding agent), `aim` (aimhubio ML tracker), `acp` (Zed's Agent Client Protocol), `alm`, `aipm` ("AI project manager" tools), `prm`, `cam`, and the `*pm`/`*cm` single-prefix space (npm/rpm/gcm/scm/upm/opm). Rejected word families: "switch" (owned by the cc-switch ecosystem in this exact niche), "ctx/context" (now signals memory tools: ctx.rs, aictx, lean-ctx), "env" (drifting toward RL environments).

## Roadmap

- **Multi-agent adapters**: Codex via `CODEX_HOME` (documented upstream, mechanism confirmed); Gemini CLI / Qwen Code / Kimi pending per-tool mechanism verification. Profile layout grows per-tool sections (`~/.agman/<name>/<tool>/`), and the shell wrapper exports one env var per detected tool.
- **v0.2 — auto-switch**: `.agman` file in a project root + cd hook (zsh `chpwd`, bash `PROMPT_COMMAND`, or direnv recipe); precedence slots between env var and persistent default.
- fish support, completions, `--fresh-auth`, profile export/import.
