# Session pooling: `agman sessions` — agman-owned, pooled session storage across all three tools

Drafted 2026-08-12. Research and design only — no implementation yet. Codex/Gemini on-disk
session formats below are web-sourced and explicitly flagged as unverified; see Phase 0.

---

## Context

Today, agman already pools Claude Code's session transcripts centrally
(`~/.agman/.state/projects/`, shipped in v0.6.0 — see `docs/plan-sessions-run-project.md` §1) so
`claude --resume` keeps working across profile switches — but this pooling is Claude-only. Codex
CLI and Gemini CLI sessions stay wherever each profile's real `.codex`/`.gemini` directory
happens to be, invisible to any other profile and to any unified view.

The goal: agman should own this the same way for all three tools — not a live reader that
re-scans each tool's native files on demand, but a permanent, agman-owned archive, using the same
`merge_tree`/`adopt_shared_state`/`link_shared_state` mechanism Claude already gets, generalized
to Codex and Gemini, with a new `agman sessions` report on top for visibility. Session data
becomes something agman stores and pools itself, consistent with how it already treats Claude's.

Because this reaches into `cmd_use`'s real linking/merging logic (not just a read-only report),
and because Codex's and Gemini's on-disk session formats are currently only web-researched (not
verified against a real install — this repo has an established Docker+strace verification
method, see `docs/roadmap.md` §"Phase 3 verification"), **verification must happen before the
pooling logic is built.** A wrong path assumption here risks silently misplacing real session
files, which is a different order of risk than a report command just under-populating a column.

An earlier, more ambitious option — agman driving model APIs directly and owning the whole
conversation loop, enabling live cross-vendor model switching — was scoped and explicitly
rejected: it breaks the pure-bash/no-dependencies/no-network constraints this project is built on
(CLAUDE.md hard constraints #1–2) and turns agman into a different product. What follows keeps
agman's existing identity: it still doesn't run agents or generate session content, it just owns
**storage of** the content each CLI already generates, for all three tools instead of one.

---

## Current state — pooling exists, but only for Claude

```
 ~/.claude  (machine-global symlink)
     │
     ▼
 ~/.agman/<active-profile>/claude/            ◄── per-profile persona (real files)
     ├── CLAUDE.md, settings.json, skills/, agents/, plugins/   (NOT shared)
     ├── projects/        ──symlink──┐
     ├── history.jsonl    ──symlink──┤
     ├── todos/           ──symlink──┤
     ├── shell-snapshots/ ──symlink──┤
     ├── file-history/    ──symlink──┤
     └── session-env/     ──symlink──┘
                                      │
                                      ▼
                        ~/.agman/.state/        ◄── ONE shared pool, all profiles
                        ├── projects/                point their session sub-paths here
                        ├── history.jsonl             (this is what makes `claude --resume`
                        ├── todos/                     work no matter which profile is active)
                        └── ...

 ~/.agman/<other-profile>/claude/projects/  ──symlink──► same ~/.agman/.state/projects/
 (different persona, same session pool)

 ~/.codex   (symlink) ──► ~/.agman/<active-profile>/codex/    whole dir, NOT pooled
 ~/.gemini  (symlink) ──► ~/.agman/<active-profile>/gemini/   whole dir, NOT pooled
```

Codex/Gemini config (including sessions) is symlinked **wholesale** per profile
(`ADAPTER_LINKS`, `bin/agman:80-84`) — there is no equivalent of the `projects/`-style
sub-symlinking that makes Claude's session data pool centrally. A Codex or Gemini session
created under `work` is invisible to `personal`, and lost from view entirely if `work` is ever
removed.

---

## Proposed state — the same pooling pattern, generalized to all three tools

```
 ~/.claude  ──► <profile>/claude/  ──[shared: projects, history.jsonl, todos, ...]──┐
 ~/.codex   ──► <profile>/codex/   ──[shared: sessions, ...]────────────────────────┤
 ~/.gemini  ──► <profile>/gemini/  ──[shared: <paths Phase 0 confirms>]─────────────┤
                                                                                      ▼
                                                          ~/.agman/.state/
                                                          ├── claude/  (unchanged)
                                                          ├── codex/   (new)
                                                          └── gemini/  (new)

 Every profile's claude/codex/gemini dirs symlink their session sub-paths into the SAME
 shared pool per tool. Persona (instructions, settings, MCP config, skills, credentials)
 stays per-profile and un-pooled, exactly as today — only session/history state pools.

                              ┌───────────────────────────┐
                              │      agman sessions        │
                              │  reads ~/.agman/.state/*   │
                              │  directly — no per-tool    │
                              │  live scanning across      │
                              │  every profile is needed,  │
                              │  because the data already  │
                              │  lives in one place         │
                              └───────────────────────────┘
```

The mechanism doesn't change — `merge_tree` / `adopt_shared_state` / `link_shared_state`
(`bin/agman:700-812`) already are generic, path-based operations. What changes is **who calls
them**: today only `cmd_use` against the Claude dir; proposed, `cmd_use` against every in-scope
adapter, driven by a per-adapter shared-entries registry instead of one Claude-shaped constant.
This is also why `agman sessions` gets simpler once this lands: it reads one pooled location per
tool instead of walking every profile's private tree.

---

## Why this shape, not a wrapper/orchestrator

Earlier in scoping, a more ambitious "agman drives the model APIs directly and owns the whole
conversation loop" option was considered — real-time model switching, zero dependency on any
CLI's own storage, agman as the actual agent runtime. It was explicitly rejected: it breaks the
pure-bash/no-dependencies/no-network constraints this project is built on (CLAUDE.md hard
constraints #1–2) and turns agman into a different product.

What's proposed here stays inside the existing identity: agman still doesn't run agents or
generate session content — it just now **owns storage of** the content each CLI already
generates, for all three tools uniformly instead of one. The symlink-and-pool pattern that
already works for Claude is the load-bearing idea; this generalizes it rather than replacing it.

---

## Model/vendor agnosticism

This design treats Claude Code, Codex CLI, and Gemini CLI identically — one adapter-driven
mechanism (`ADAPTER_NAMES` plus a per-adapter shared-entries registry, §"Proposed state") applied
uniformly to all three, not a Claude-shaped mechanism with two bolt-ons. Nothing in the pooling
logic branches on which foundation model backs a given CLI; the only per-tool differences are the
literal on-disk paths/formats each CLI happens to write to, which is a fact about that CLI's
storage layer, not a design choice that favors any vendor. This mirrors agman's existing identity
as a whole: it manages config for AI coding agents without caring which model runs behind them,
and this feature keeps that property rather than special-casing Claude because it shipped first.

If a fourth tool is ever added, it plugs into the same registry the same way — no architectural
change, just a new adapter entry with its own shared-entries list once its storage format is
known.

---

## Design decisions already made in scoping

- **Storage model**: agman archives full copies of session data into its own tree (not a
  live-reading index), reusing the existing Claude pooling mechanism.
- **Pooling scope**: Codex and Gemini sessions pool across profiles exactly like Claude's do
  today — one consistent model for all three tools, not archive-but-isolate.
- **Sequencing**: verify Codex/Gemini's real on-disk paths before building the pooling/merge
  logic, given the risk of misfiling real session data on a wrong path guess — see Phase 0 below.

---

## Phase 0 — Verify Codex and Gemini session storage (blocking, do first)

Reuse the exact method already validated in this repo (`docs/roadmap.md`, Phase 3 verification):
spin up Docker containers with the real `@openai/codex` and `@google/gemini-cli` npm packages,
**actually run a multi-turn conversation** (the existing trace apparently didn't exercise real
chat logging — it only confirmed `settings.json`/`projects.json`/`history/` were touched for
Gemini, not that `tmp/*/chats/*.json` holds transcripts), and strace file writes under `~/.codex`
and `~/.gemini`.

Confirm and record (append to `docs/roadmap.md` in the same style as the existing entries):

- **Codex**: exact session file path pattern (expected `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
  per web research), and the first-line `SessionMeta` JSON shape (field names for `id`, `cwd`,
  `model_provider`) so extraction code targets real keys, not guessed ones.
- **Gemini**: where conversation transcripts actually live — `tmp/<hash>/chats/*.json`,
  `history/`, or something else — and its schema, plus whether `projects.json` really is a
  hash→project-path map (needed to make any Gemini grouping human-readable).

If either tool's real behavior diverges materially from the web research, adjust the Phase 1
design below accordingly before writing code against it.

---

## Phase 1 — Generalize shared-state pooling from Claude-only to all three tools

Currently (`bin/agman`):

- `SHARED_STATE_ENTRIES` (~line 52-53) is one flat array of `name:type` pairs.
- `adopt_shared_state`/`link_shared_state` (~line 760-812) are called from `cmd_use` (~line
  1179-1252) **only** against `profile_claude_dir(...)` (lines 1223, 1230) — Codex and Gemini's
  whole config dirs are symlinked wholesale per `ADAPTER_LINKS` (~line 80-84) with no shared
  sub-path pooling at all.
- `merge_tree` (~line 700-723) is already generic (path-based, not Claude-specific) — it's the
  invocation, not the mechanism, that's Claude-only today. This is good: the merge/conflict core
  (including the `.agman-conflict`/`.agman-orphaned` safety net and `list_conflict_leftovers`,
  ~line 751-755) should mostly work unchanged once called more broadly; audit it for any
  Claude-specific path assumptions during implementation rather than assuming zero changes.

Changes:

1. Replace the single `SHARED_STATE_ENTRIES` with a per-adapter registry — a new parallel array
   indexed like `ADAPTER_NAMES` (bash 3.2, no associative arrays, same convention as
   `ADAPTER_LINKS`/`ADAPTER_ENVVARS`), e.g. `ADAPTER_SHARED_ENTRIES`, holding each tool's
   shareable sub-paths:
   - `claude`: unchanged — `projects:d history.jsonl:f todos:d shell-snapshots:d file-history:d session-env:d sessions:d`
   - `codex`: `sessions:d` (plus whatever Phase 0 confirms, e.g. a sqlite index — decide during
     verification whether that's worth pooling too or is safely per-profile/regenerable)
   - `gemini`: whatever Phase 0 confirms as the real transcript location(s)
2. Generalize `adopt_shared_state`/`link_shared_state` to take an adapter index (or an explicit
   shared-entries list + target dir) instead of being implicitly Claude-shaped.
3. In `cmd_use`, loop the adopt/link-shared-state calls over every in-scope adapter (reusing
   `adapter_in_scope`, ~line 152-167) instead of hardcoding the Claude dir — this is the one
   change with the most blast radius, since it's on the critical path of every `agman use`.
4. `cmd_off` and `cmd_doctor`'s shared-state reporting (~line 1526-1546) generalize the same way
   — un-pool and report status for all three tools, not just Claude.
5. `AGMAN_SHARE_STATE=0` opt-out applies uniformly across all three once generalized (currently
   Claude-only by construction).
6. `SEED_EXCLUDES` (~line 92-96) already lists `sessions`/`projects`/`tmp`/`history` as
   machine-local — this stays correct as-is: a freshly created profile still shouldn't inherit
   one specific profile's session archive via `--copy-current`/`--from`; it gets the shared pool
   through `agman use` instead, exactly like Claude does today.
7. **`LAYOUT_VERSION` bump required** (CLAUDE.md hard constraint #5) — this is a real on-disk
   layout change. Write a migration function analogous to the v0.6.0 Claude-pooling migration:
   on `agman use`, absorb whatever real (non-pooled) Codex/Gemini session data each existing
   profile is holding into the new shared paths, file-by-file, never overwriting — i.e. an
   `adopt_shared_state` pass against every profile's Codex/Gemini dirs the first time this
   ships, mirroring exactly how the original Claude migration merged `global` and per-profile
   history into `.state` (see `docs/plan-sessions-run-project.md` §1 for the precedent and its
   stated rationale for shared-by-default).

---

## Phase 2 — `agman sessions` report command

With pooling generalized, all three tools can be reported consistently (no more Claude-vs-
Codex/Gemini asymmetric grouping — that asymmetry only existed because pooling was Claude-only).

- New `cmd_sessions`, structurally modeled on `cmd_doctor` (~line 1466-1595): same
  `printf '%-Ns %s\n'` aligned report style, same "skip a tool's section if none present" gating
  via `adapter_enabled`.
- Report groups by project/cwd where resolvable (Claude: encoded-cwd dirname, no parsing needed;
  Codex: optional `cwd` enrichment from the verified `SessionMeta` shape; Gemini: per Phase 0
  findings — default to filesystem-metadata-only, i.e. filename + last-modified, if the real
  schema turns out too fragile to parse without adding a dependency).
- Flags: `--tool <claude|codex|gemini>` (validate via `adapter_index`, ~line 112-119), `--profile
  <name>` (only meaningful pre-pooling context or for filtering display, since sessions are
  pooled — keep for filtering the report, not for implying isolation). Defer `--json` to a fast
  follow unless the jq/python3 fast path alone is judged sufficient (skip the hand-rolled
  no-tool JSON-escaping fallback in v1 to avoid shipping a correctness-risky code path — see
  `json_tool()`, ~line 398-402, for the existing jq→python3→none pattern to follow when it is
  built).
- No new JSON parsing dependency: reuse the `json_tool()` jq→python3→none fallback chain
  end-to-end; when `none`, degrade to filename/mtime-only extraction (never error out).
- Wire into `main()` dispatch (~line 2571-2597) next to `doctor)`, and add a `Commands:` line +
  short explanatory paragraph to `cmd_help` (~line 2479-2547).

---

## Files to touch

- `bin/agman` — adapter registry (~72-96), shared-state functions (~689-812), `cmd_use`
  (~1179-1252), `cmd_off`, `cmd_doctor`, new `cmd_sessions` near `cmd_doctor`, `main()` dispatch,
  `cmd_help`, `LAYOUT_VERSION` + migration function (near `migrate_profile`, ~line 249-269).
- `tests/run.sh` — extend the existing shared-state/conflict fixtures (~line 752-783) to cover
  Codex/Gemini pooling and migration; new tests for `cmd_sessions` output and flags; reuse the
  multi-tool `mrun()` sandbox (~line 309-361) and the no-jq/no-python3 minimal-PATH fixture
  (~line 496) for the fallback-extraction path.
- `tests/docker-session-*.sh` — extend or add a Codex/Gemini equivalent of
  `docker-session-resume.sh`/`docker-session-upgrade.sh`, proving pooling+resume end-to-end
  against real CLIs, not just fixtures.
- `docs/roadmap.md` — record Phase 0 verification findings in the existing style.
- `README.md` — update the "Sessions" section (currently Claude-only framing) to describe
  pooling for all three tools, and document the new `agman sessions` command.

---

## Verification / testing

- Phase 0: Docker+strace probes against real `codex`/`gemini` CLIs, conversation actually
  exercised (not just tool startup) — this is the gating step before Phase 1 code is written.
- `bash tests/run.sh` and `shellcheck -S warning -e SC2088 bin/agman install.sh tests/run.sh`
  before any PR, per CLAUDE.md.
- Docker session tests (`tests/docker-session-*.sh`) must still pass unmodified for Claude, and
  new equivalents should confirm a Codex/Gemini session created under one profile is visible and
  resumable from another after `agman use <other-profile>` — the actual behavioral contract this
  whole feature is meant to deliver.
- Manual smoke test: `agman sessions` output against a sandbox with synthetic multi-tool,
  multi-profile fixtures, and (if available) a real local Codex/Gemini install.

---

## Effort estimate (scoping-level)

| Phase | Estimate | Why |
|---|---|---|
| 0 — Verification | S–M, one-time | Blocking; reuses an established method in this repo, but requires real conversations, not just tool startup, to be traced. |
| 1 — Generalize pooling to Codex/Gemini | M–L | Touches `cmd_use`'s critical path, needs a `LAYOUT_VERSION` bump + migration, must not regress the existing Claude docker-session test suite. |
| 2 — `agman sessions` command | S–M | Modeled closely on `cmd_doctor`; most of the parsing risk was already retired by Phase 0. |
| Tests | M | Multi-tool sandbox and no-jq/python3 fixtures already exist and are reusable; new Docker session tests for Codex/Gemini are the bulk of the new test-authoring effort. |
| **Total** | **L** (multi-session effort) | This is now a layout/architecture change plus a new command, not a small additive feature — size the review and rollout accordingly (e.g. land Phase 1 and Phase 2 as separate PRs, per CLAUDE.md's branch-per-change convention). |
