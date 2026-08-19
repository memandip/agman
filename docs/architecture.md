# Architecture: how agman works, and what's proposed next

Drafted 2026-08-12, expanded 2026-08-19 to cover the whole system, not just the two proposed
features. Companion to `docs/business.md` (market research, competitive landscape, business
case) and `docs/session-pooling.md` (in-flight work generalizing session pooling to Codex and
Gemini — referenced below, not re-described here).

---

## Overview — two layers

agman splits into a core CLI and an optional shell layer, the pyenv/direnv pattern:

1. **Core CLI** (`bin/agman`, pure bash, `main()` at `bin/agman:2571`) — owns profile storage,
   activation, and state. Everything except mutating the *current shell's* environment.
2. **Shell integration** (emitted by `agman init zsh|bash`, opt-in via `eval` in the rc file) —
   makes `use`/`off` also export/unset `CLAUDE_CONFIG_DIR` in the current shell, and adds a
   `chpwd`/`PROMPT_COMMAND` hook for per-project auto-switching. A child process cannot set its
   parent's environment, so this split is what makes `use` feel machine-global while the shell
   hook remains a strictly per-process affordance layered on top.

Layer 1 alone is a complete product — every command below works with zero shell setup. Layer 2 is
purely a convenience for people who also want per-terminal divergence.

---

## Storage & layout

```
~/.agman/                       # AGMAN_HOME
├── .state/                     # shared session/history pool (see below)
├── <profile>/
│   ├── .agman-layout            # layout version marker
│   ├── claude/                  # → symlinked at ~/.claude when active
│   ├── claude.json              # → symlinked at ~/.claude.json when active
│   ├── codex/                   # → symlinked at ~/.codex when active
│   └── gemini/                  # → symlinked at ~/.gemini when active
└── global/                     # auto-created backup of pre-agman config, itself a normal profile
```

`LAYOUT_VERSION` (`bin/agman:33`, currently `"2"`) is bumped only when this on-disk shape changes
in a way that needs migration. Layout-1 profiles (the original `~/.agman/<name>/` = a bare Claude
config dir, no per-tool subdirectory) are detected by shape and migrated automatically on the
next `use`, after a full pre-migration backup — `migrate_profile()` (`bin/agman:249`) and `agman
migrate` run the same pass explicitly.

---

## Activation — symlink-based, not environment-based

`agman use <name>` symlinks every managed config path at the profile. Selection precedence,
highest first:

1. **`CLAUDE_CONFIG_DIR` set in a shell** — wins in that shell only, never overridden by `use`.
2. **The config symlinks set by `agman use`** — machine-wide for all new sessions, no shell
   integration needed. This is the *only* mechanism that reaches Gemini CLI, which has no
   config-directory environment variable at all — the reason agman is symlink-based rather than
   the simpler env-var design it started with (`docs/design.md` §"v0.2 — symlink activation").
3. **Nothing** — stock config, untouched behavior.

The symlink doubles as the state marker: a real directory means agman isn't managing that tool; a
symlink into `~/.agman/` means a profile is active (`agman current` / `ls -l ~/.claude` reads it
back). agman refuses to touch a config symlink it didn't create — e.g. a dotfiles manager's — and
skips that tool entirely rather than half-activating it (`adapter_can_link` pre-checks every path
of a tool before anything moves, so a refused tool can't leave the profile half-migrated).

`agman off` reverses this: symlinks become real directories again, restoring the original config
byte-for-byte, with agman fully out of the picture.

---

## Adapter registry — one declarative table, not per-tool code paths

Bash 3.2 (stock macOS) has no associative arrays, so tools are declared as **parallel indexed
arrays** rather than a map:

- `ADAPTER_NAMES` (`bin/agman:77`) — `(claude codex gemini)`
- `ADAPTER_LINKS` (`bin/agman:80`) — profile-path:home-path pairs per tool (`.claude`→`~/.claude`,
  `.claude.json`→`~/.claude.json`, etc.)
- `ADAPTER_ENVVARS` (`bin/agman:87`) — the per-shell override each tool honors, or `-` when none
  exists (Gemini)

Adding a tool is one row per array — this is the shape a fourth tool (Qwen Code, Kimi CLI, on the
roadmap) plugs into once its config layout is verified against a real install, not a new code
path. `adapter_index()` (`bin/agman:112`) resolves a name to its row; `adapter_in_scope()`
(`bin/agman:152`) decides whether a given profile actually manages a given tool — true when the
profile holds config for it, the CLI is on `PATH`, or its config path already exists — so
single-tool users see no behavior change and `AGMAN_TOOLS` can restrict the set explicitly.
`cmd_use()` (`bin/agman:1179`) loops this registry to link every in-scope adapter.

**Verified against real installs**, not just vendor docs (Docker + strace, `docs/roadmap.md`
§"Phase 3 verification"): Gemini CLI and Codex CLI both read config *through* the symlink,
neither replaces the symlink while writing (the failure mode that would silently break
profiling), and writes land inside the active profile while an inactive profile's tree stays
untouched.

---

## Session & shared state pooling

Claude Code stores resumable sessions inside its config directory
(`<config dir>/projects/<encoded-cwd>/<session-id>.jsonl`) — the same directory `agman use`
swaps. A naive symlink swap would strand every earlier session behind whichever profile was
active when they were written. Instead, session/history state lives in one place every profile
symlinks into:

```
~/.agman/.state/projects/, history.jsonl, todos/, shell-snapshots/, file-history/, session-env/, sessions/
```

`merge_tree()` (`bin/agman:700`) is a generic, path-based recursive merge; `adopt_shared_state()`
/ `link_shared_state()` (`bin/agman:760`, `:790`) call it against `SHARED_STATE_ENTRIES`
(`bin/agman:52`) from `cmd_use`. A merge never overwrites — a same-path collision is kept aside as
`*.agman-conflict` rather than lost, and both `doctor` and `off` list anything kept aside so
nothing sits unnoticed. `AGMAN_SHARE_STATE=0` opts a profile out, at the cost of cross-profile
`--resume`.

**This pooling exists today only for Claude.** Codex and Gemini's whole config dirs are still
symlinked wholesale per-profile with no sub-path pooling — generalizing the same mechanism to
both is separate, already-scoped work; see `docs/session-pooling.md` for the phased plan and the
verification required before it's built (Codex/Gemini's on-disk session formats are currently
only web-researched, not confirmed against real installs).

---

## Accounts & identity

New profiles inherit the current account by default — switching never drops you at a login
prompt — but this needs care because Claude Code splits auth across two places:

- **Identity** (`oauthAccount`, `hasCompletedOnboarding`, `userID`, `machineID`) lives in
  `~/.claude.json`, which agman keeps as a *sibling* symlink alongside the config dir so it
  follows the same activation. `create` seeds these keys from the live config; `use` backfills
  any profile that predates this.
- **Credentials** live in the macOS Keychain (keyed by config-dir path, so the symlink keeping
  the literal path `~/.claude` means the Keychain entry is naturally shared) or in
  `<config dir>/.credentials.json` on Linux/Windows, which agman promotes to a shared file every
  profile symlinks so a token refresh in one profile is visible to all.

**Giving a profile its own account** (`agman login <name>` / `logout <name>`) stores a one-year,
non-rotating `claude setup-token` value at mode `600` inside the profile, wired in through the
profile's own `settings.json` `apiKeyHelper` — a setting Claude Code honors from the CLI, the VS
Code extension, and the Agent SDK alike, which an environment variable cannot reach. Deliberately
*not* used: snapshotting Keychain/`.credentials.json` entries, since refresh tokens rotate on
every use and a snapshot would already be stale by the time it's restored. Cloning a profile
strips all of this (`strip_account_material`) so a clone starts on the shared login rather than
silently inheriting the source profile's identity.

---

## Per-project selection

A `.agman` file at a repository's root (`profile: <name>`) is read by `use`/`run` with no
argument, searched upward from the working directory. Because it arrives with a clone, it's
untrusted input: agman confirms once and records the decision (`$AGMAN_HOME/.trusted`), and
refuses to switch silently in a non-interactive shell. The shell integration's `chpwd`/
`PROMPT_COMMAND` hook makes this automatic per directory — necessarily terminal-only, since IDE
extensions don't inherit shell environment and keep following the global `agman use` switch
instead.

---

## Cloud sync

`agman cloud` (backed by the separate [agman-cloud](https://github.com/memandip/agman-cloud)
service) pushes/pulls whole profiles, versioned and encrypted at rest server-side. **A synced
profile is a persona, not a login**: account material (identity file, credentials, per-profile
tokens, `.env`) and ephemeral state (sessions, history, caches) stay local by default and are
stripped on pull; a push is refused outright if a synced file looks like it holds a secret.
Reinstallable artifacts (plugin caches, `node_modules`, `.venv`, `.git` clones under a profile's
MCP servers) are never synced either direction — the sources next to them sync, and the target
machine rebuilds them. `agman cloud init <org-slug>` seeds a new profile from a team default —
the current toehold for the org-governance direction discussed in `docs/business.md`
§"Revenue model".

---

## Proposed extension: Tier 1 — cross-tool skills layer

### The shape

Claude Code, Codex CLI, and Gemini CLI have all converged on the same open **Agent Skills
standard** (`SKILL.md`: YAML frontmatter + Markdown body, [agentskills.io](https://agentskills.io)).
Codex and Gemini additionally share a *discovery path convention*, `.agents/skills`, distinct
from Claude's own `.claude/skills`. That means one canonical skill file per profile, mirrored
into two symlink targets, covers all three tools:

```
 ~/.agman/<profile>/skills/<skill-name>/SKILL.md      ◄── the one canonical copy per profile

 ~/.agman/<profile>/claude/skills/<skill-name>  ──symlink──► the canonical copy   (Claude's own path)
 ~/.agents/skills/<skill-name>                  ──symlink──► the canonical copy   (Codex + Gemini's shared path)
```

`~/.agents/skills` sits outside any single tool's config dir — the same situation `~/.claude.json`
is already in today (a sibling path agman manages alongside, not inside, a tool's own directory).
It needs its own top-level machine-global symlink target, the same class of thing agman already
does for identity.

### How it plugs into the existing mechanism

This is `ADAPTER_LINKS` generalized to a new content type, not a new paradigm. On `agman use`,
alongside linking `.claude`/`.codex`/`.gemini`, also link the profile's `skills/` directory into
each tool's discovery path, plus the new `~/.agents/skills` top-level target. No new command is
required to *use* skills — placement happens as part of the existing `use` flow; a skill is just
a file a user or agman drops into the profile's `skills/` directory.

### Before building

Verify, against real installs (same Docker+strace method as elsewhere — `docs/roadmap.md`
§"Phase 3 verification"):
- Codex's exact discovery path precedence — secondary sources disagree on `.agents/skills` vs.
  `.codex/skills`, and on the exact cwd → parent → repo-root → `$HOME/.agents/skills` order.
- Gemini's precedence between `.gemini/skills/` and `.agents/skills/`.

Getting these wrong means a skill silently isn't discovered — low implementation effort, but
load-bearing to verify first rather than guess.

### First skills to ship

A `doctor`-equivalent health-check skill and a `code-review`-equivalent skill — expressed once as
`SKILL.md`, working across all three tools without per-tool translation.

---

## Proposed extension: Tier 2 — profile-aware advisory

### The shape

No model-quality inference, no network calls, no trained classifier — a transparent, flat,
user-editable mapping cross-referenced against what the user's own profiles actually have. The
mapping carries two fields per task-type, not one: which tool, *and* how hard it should think —
both tools already expose a reasoning-effort control in their own config (Claude Code's
`effortLevel`/`alwaysThinkingEnabled` in `settings.json`, Codex's `model_reasoning_effort` in
`config.toml`), so this is a second column in the same file, not new mechanism:

```
 ~/.agman/task-preferences      ◄── flat file, "task-type<TAB>preferred-tool<TAB>effort"
   image      gemini    -
   code       claude    high
   refactor   codex     medium
   (user-editable; shipped defaults are a starting point, sourced from public benchmarks at
    ship time and expected to drift — not a black box, and not a promise to stay current)

                          ┌──────────────────────────────┐
 task-type in ──────────► │        agman advise           │
                          │  1. look up preferred tool     │
                          │     + effort for this task     │
                          │  2. for each profile, ask       │
 profiles + ────────────► │     adapter_in_scope() which    │
 adapter_in_scope()        │     tools it actually has,      │
 (bin/agman:152,           │     AND whether any required     │
  already exists) +        │     plugin/extension is          │
 profile plugin list        │     installed in that profile     │
 (settings.json              │  3. report which profile(s)       │
  enabledPlugins,             │     can actually serve this        │
  already read by              │     task — or say honestly that    │
  cloud sync)                   │     none of your profiles can       │
                          └──────────────────────────────┘
```

The advisory is only ever built from what's actually true of the user's profiles — never a
hypothetical world with every vendor available. If the preferred tool for "image" isn't in any
profile, the report says so rather than pretending.

**Capability isn't always the base tool — sometimes it's a plugin the profile has to actually
have installed.** Image generation is the concrete case: Gemini CLI doesn't generate images by
itself, that's the [Nano Banana extension](https://github.com/gemini-cli-extensions/nanobanana),
installed per-profile like any other plugin. So "can this profile do images" isn't just
`adapter_in_scope(gemini)` — it's that check *and* a look at the profile's installed
plugins/extensions (`settings.json`'s `enabledPlugins`, the same field `agman cloud pull` already
reads to reinstall plugins — see `docs/architecture.md` §"Cloud sync"). Getting this wrong means
the advisory recommends a profile that can't actually do the task.

### Command surface

A new read-only command, structurally a `cmd_doctor`-style report (`cmd_doctor()` at
`bin/agman:1466` is the closest existing analogue): loads the preference file, iterates profiles,
cross-references `adapter_in_scope` plus each profile's installed plugins, prints the result. No
mutation, no side effects — same posture as `doctor` and the proposed `sessions` command.

### Tier 2b — pick-and-run (only after Tier 2 proves useful)

A `--run` flag on the same command that hands off via the existing `cmd_run()`/`cmd_exec()`
(`bin/agman:1376`, `:1392`) once a profile is chosen — still one bounded, human-initiated process
launch. Not a live mid-session switch; agman never runs an agent loop itself, only decides which
whole CLI process to start, under which profile, at what effort level.

**Hard boundary, stated explicitly: this only ever works at task *start*, never mid-conversation.**
If a task is already underway in one tool and the advisory would now recommend a different one,
agman cannot carry that conversation's context across — Claude Code, Codex, and Gemini CLI keep
separate, incompatible session formats, and there is no universal transcript to hand off between
them. Session pooling (`docs/session-pooling.md`) makes history resumable *within* a tool across
profile switches; it does not and cannot bridge *between* tools. So Tier 2b is "tell me before I
start, so I launch in the right profile at the right effort" — never a live handoff.

---

## Model/vendor agnosticism

This system treats Claude Code, Codex CLI, and Gemini CLI identically throughout — one
adapter-driven mechanism (`ADAPTER_NAMES` plus per-adapter registries) applied uniformly, not a
Claude-shaped mechanism with two bolt-ons. Nothing in activation, pooling, accounts, or the
proposed tiers branches on which foundation model backs a given CLI; the only per-tool
differences are literal on-disk paths/formats, a fact about each CLI's storage layer, not a
design choice favoring any vendor. Tier 1's skill placement and Tier 2's advisory both operate
uniformly over `ADAPTER_NAMES` the same way activation and pooling already do — a fourth tool
plugs into the same registries once its layout is verified, no architectural change required.

---

## What's deliberately not architected here

Tier 3 (live, automatic, mid-conversation model routing) has no architecture in this document —
it isn't being designed, only recorded as a considered-and-rejected option. See `docs/business.md`
§"Open feature decision" for the reasoning. Building it would require agman to become a different
kind of program (a conversation loop, a task classifier, network calls) rather than an extension
of the mechanisms above, which is exactly why it's out of scope here.
