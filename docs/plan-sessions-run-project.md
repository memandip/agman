# Plan: session history, `agman run`, and per-project profiles

Drafted 2026-07-28. Research and options only — no implementation. Every claim below was
checked against Claude Code 2.1.220 in a container; the probes are reproducible.

---

## 1. Sessions unresumable after switching — already shipped

**Status: fixed in v0.6.0.** Claude Code stores a resumable session inside the config
directory, at `<config dir>/projects/<encoded-cwd>/<session-id>.jsonl`, which is exactly what
`agman use` swaps. Nothing was ever deleted — transcripts stayed in whichever profile was
active when they were written.

v0.6.0 moves session and history state to `$AGMAN_HOME/.state` and symlinks it from every
profile: `projects`, `history.jsonl`, `todos`, `shell-snapshots`, `file-history`,
`session-env`, `sessions`. Verified end to end against the real CLI in
`tests/docker-session-resume.sh` and `tests/docker-session-upgrade.sh`.

**Action for you:** `brew upgrade agman` (or `agman update`), then `agman use <profile>` once.
That switch merges history stranded in `global` and in other profiles back into shared state.

### 1a. What the right approach actually is

You asked for research rather than a fix, so here are the options that were on the table.

| Approach | Resume works across profiles | Isolation | Verdict |
|---|---|---|---|
| **Per-profile history** (pre-0.6.0) | no | total | This *is* the reported bug |
| **Shared history** (v0.6.0) | yes | none for history | Chosen default |
| Share transcripts, keep auto-memory per profile | yes | partial | Possible refinement, see below |
| Union/overlay view of several profiles | yes | read-only | Needs FUSE/OverlayFS — not portable, rejected |
| Copy history in and out on switch | yes, lossily | partial | Racy, duplicates data, rejected |

**Why shared-by-default is right.** Session history is a record of *your work*, not part of the
agent's persona. A transcript is keyed by working directory, so a work profile only ever sees
sessions for repositories you actually opened in it — the cross-contamination risk is much
smaller than it first appears. And the failure mode of the alternative is severe: losing the
ability to resume is worse than a longer `--resume` list. `AGMAN_SHARE_STATE=0` exists for
people who need strict separation and accept that cost.

**The one open question.** `projects/` holds two different things: session transcripts *and*
Claude Code's auto-memory (`projects/<p>/memory/MEMORY.md`). Sharing the directory shares both.
Auto-memory is arguably knowledge about a codebase (share it) rather than about a persona (keep
it separate) — but if you want work-profile notes to stay out of a personal profile, that needs
splitting them. It is doable (symlink `projects/<p>/*.jsonl` individually) but fragile, because
new project directories appear constantly and each would need linking on the fly.

Recommendation: leave as is. Revisit only if auto-memory bleed turns out to matter in practice.

---

## 2. `agman run <profile>` does not fully use that profile — real bug, mechanism verified

Your report is right that something is wrong, but the boundary is narrower and stranger than
"it still reads the global `~/.claude`".

### What was measured

`agman run`/`exec`/`env` set `CLAUDE_CONFIG_DIR=<profile>/claude`. Against 2.1.220:

- **Honored from the profile:** `settings.json` (proved by planting invalid JSON in the profile
  and seeing `Invalid settings — /root/.agman/work/claude/settings.json: Invalid or malformed
  JSON`), and everything else inside the config dir — `CLAUDE.md`, `skills/`, `agents/`,
  `plugins/`, `rules/`.
- **NOT honored:** `.claude.json`. With `CLAUDE_CONFIG_DIR` set, Claude Code looks for it
  **inside** the config dir. agman deliberately keeps identity as a *sibling*
  (`<profile>/claude.json`), because symlink mode needs `~/.claude.json` to point at it. Result
  under `run`: `claude mcp list` reports "No MCP servers configured" — it sees neither the
  global file nor the profile's.

So `agman run` loses exactly what lives in `.claude.json`: **user-scope MCP servers, account
identity, onboarding state, and per-project state.** Missing identity is also why a `run` can
land you at a login prompt.

### The worse part

`.claude.json` is not merely unread — **Claude Code creates it** inside the config dir when
absent. A single `agman run work` writes a fresh `<profile>/claude/.claude.json` with a new
`machineID` and no `oauthAccount`. The profile then carries *two* divergent identity files: the
sibling that symlink mode uses, and this one that env mode uses. Left alone, they drift.

### Fix options

**A — link identity into the config dir (recommended).** Maintain
`<profile>/claude/.claude.json` as a symlink to `<profile>/claude.json`. One real file, reachable
by both access paths: symlink mode via `~/.claude.json`, env mode via the config dir.

*Verified:* with the link in place, `claude mcp list` under `CLAUDE_CONFIG_DIR` reports the
profile's `work-profile-server`, and `claude mcp add --scope user` writes through the link into
the single sibling file, which stays a real file.

Work: create the link in `use`/`create`; clean it in `off`; have `doctor` detect and offer to
remove a stray real `.claude.json` that a pre-fix `run` created. Effort S, risk low, no layout
change.

**B — move identity inside the config dir (layout v3).** Store it at
`<profile>/claude/.claude.json` and point `~/.claude.json` there. Conceptually cleaner — one
directory holds everything for a tool — but it is a layout migration with the same class of risk
as the v2 move. Effort M, risk medium. Worth folding in only if the layout is being revised for
another reason.

**C — copy identity in and out around `run`.** Rejected: two processes running different
profiles would race, and a crash mid-run leaves the copy behind.

**Also in scope for this fix, whichever option:**
- `agman env` should emit nothing that implies MCP/identity work when they will not.
- `doctor` should flag stray `<profile>/claude/.claude.json` real files as drift.
- A test that asserts `run` sees the profile's MCP servers, not the global ones.

---

## 3. Per-project `.agman` — brainstorm

Two different things are bundled in the request: a *file* that selects a profile, and a
*directory* that is a project-local profile.

### The constraint that shapes everything

Symlink switching is **machine-global**: `~/.claude` can point at exactly one profile. Per-project
selection therefore cannot use symlinks — two terminals in two repositories would fight over the
same link, and `cd` would silently change config for every running session.

Per-project selection has to be **per-process**, i.e. `CLAUDE_CONFIG_DIR`. That works for the CLI
but **not for IDE extensions**, which do not inherit a shell's environment. So per-project
profiles are inherently a terminal-scoped feature, and the docs must say so plainly rather than
implying parity with `agman use`.

### Do not rebuild what Claude Code already has

Project-scoped configuration already exists natively: `./CLAUDE.md`, `./.claude/settings.json`,
`./.claude/rules/`, `./.claude/skills/`, `./.claude/agents/`, `./.claude/commands/`, and
`./.mcp.json` for project MCP servers. For most "this repo needs different instructions" needs,
those are the correct answer and agman should point at them.

A project-local agman profile only adds value for things with **no project scope**: the account
used, user-scope MCP servers, installed plugins, and the whole-persona swap. That is a real but
much narrower gap, and worth stating before building.

### Option 3a — `.agman` file that names a profile (recommended first step)

A committable file in the repository root:

```
profile: acme-work
```

- `agman use` with no arguments reads it and activates that profile.
- `agman run` with no profile does the same for one process.
- Optional shell hook (`chpwd` / `PROMPT_COMMAND` / direnv) exports `CLAUDE_CONFIG_DIR` on `cd`,
  giving true per-directory behavior in the terminal.

**Security:** a `.agman` file arrives with a cloned repository, so it is untrusted input. It must
never cause a profile to be created, fetched, or switched without a first-use prompt — the same
threat model as Claude Code's approval dialog for external `@` imports. Trust decisions get
recorded per repository path.

Effort S–M, risk low. Delivers the `.nvmrc` ergonomics people expect.

### Option 3b — `.agman/` directory as a project-local profile

`agman init --local` creates `./.agman/claude/…` and `agman use` in that directory points
`CLAUDE_CONFIG_DIR` at it.

Open questions to settle before building:
1. **Committed or ignored?** A project-local config dir accumulates credentials, session state,
   and caches. It must be gitignored, which means it cannot be the mechanism for *sharing* setup
   with a team — that is what a committed `.agman` file plus a shared profile is for.
2. **Seeded from what?** An empty local profile inherits no account, so it needs the same
   identity seeding as `create`, or the first run prompts for login.
3. **Where does session history go?** Shared state is keyed on `$AGMAN_HOME`. A project-local
   profile either joins the same shared state (consistent, recommended) or fragments history
   again — which is the bug from item 1 in a new costume.
4. **Cleanup.** Deleting a repository leaves nothing behind, which is good, but the profile's
   history in shared state persists. Acceptable, worth documenting.

Effort M, risk medium. Sensible only after 3a exists and the CLI-only limitation is documented.

---

## Proposed sequencing

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 1 | Verify v0.6.0 fixes your case | — | — | Upgrade, then `agman use <profile>` once |
| 2 | **Fix `run`/`exec`/`env` identity (option A)** | S | Low | Verified mechanism and verified fix; biggest correctness win |
| 3 | `doctor` reports identity drift + stray `.claude.json` | S | Low | Ships with 2 |
| 4 | `.agman` file selection with a trust prompt (3a) | S–M | Low | Ergonomics people ask for |
| 5 | Optional `cd` hook for auto-switching | S | Low | Terminal only, must be documented as such |
| 6 | Project-local `.agman/` directory (3b) | M | Med | Only after 4, and only if 3b's four questions are answered |
| — | Split auto-memory from transcripts | M | Med | Defer unless bleed proves to matter |

Items 2 and 3 are one PR. Item 4 is its own. Item 6 deserves its own design pass.

## Open decisions for you

1. **Option A or B** for the identity fix — link into the config dir now, or fold it into a
   layout v3 migration later.
2. **Is auto-memory sharing acceptable?** Leaving it shared is the recommendation.
3. **Scope of `.agman`**: file-selects-a-profile first (3a), or go straight to a project-local
   directory (3b)?
4. **Auto-switching on `cd`**: worth shipping given it only works in the terminal?
