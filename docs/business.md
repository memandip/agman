# agman — business overview

Drafted 2026-08-12, rewritten 2026-08-19 to cover the whole business, not just one feature
question. What agman is, who it's for, who else is in this space, what makes it defensible, and
where the open feature decisions stand. Companion to `docs/architecture.md` and
`docs/session-pooling.md`, which cover technical design for specific pieces of this.

---

## What agman is

A free, open-source (MIT) command-line tool that lets someone switch between complete
work/personal/client setups for Claude Code, Codex CLI, and Gemini CLI — instructions, settings,
skills, MCP servers, and (optionally) separate accounts — the way `AWS_PROFILE` switches AWS
accounts. One command, `agman use <name>`, and every new terminal, IDE session, and background
process on the machine picks up the new persona, no shell configuration required.

**The problem it solves**: these CLIs give a single global config directory each. Anyone doing
work and personal AI-assisted coding — or freelancers juggling several clients — either
hand-edits config files to switch context, or keeps separate machines/containers to avoid
cross-contamination. Nothing native solves this, and the closest built-in primitive
(`CLAUDE_CONFIG_DIR`) is undocumented, ignored by the VS Code extension, and doesn't exist at all
for Gemini CLI.

**Distribution**: Homebrew tap (`brew install agman`), curl-pipe installer, self-updating.
Zero runtime dependencies — pure bash, works on macOS, Linux, WSL, and Git Bash.

## Revenue model

**The CLI itself: free, and should stay free.** It's the adoption/trust funnel, not a place to
monetize — charging for it would kill the zero-friction install that's the whole pitch against
paid rivals (see cc-switch below).

**The one plausible paid layer: organization governance on `agman cloud`.** The hosted sync
service is currently free, with a real seed of a team feature already in place —
`agman cloud init <org-slug>` creates a profile from a team default. The pattern would be the
standard "free open-source core + paid hosted service" model (Tailscale, Warp, ngrok,
1Password/Doppler for teams): individuals sync their own profiles for free, and a company paying
to standardize AI-agent config across its engineering org — shared MCP servers, approved skills,
policy, SSO — is a plausible buyer in a way an individual switching their own profiles is not.

**Not close today.** Minimal adoption signal (4 GitHub stars, 0 forks, 0 watchers as of
2026-08-19 — far below the Homebrew-core notability threshold), the one price comparison in this
space (cc-switch, $19–199/mo) sells a much broader bundle than agman's minimal scope, and org
governance would need real engineering (SSO, audit, billing, support) this project doesn't have
yet. Revisit only with organic adoption or actual inbound demand for org governance — evidence
first, not a plan to build now.

---

## Goal

**Become the default way developers manage multiple identities for AI coding agents** — the
`AWS_PROFILE` of this space: free, zero-dependency, and trusted enough that installing it is a
non-decision. Concretely, that means:

- **Correctness first.** Cover all three major CLIs properly, verified against real installs
  rather than assumed from vendor docs — not a "best effort" integration. This is largely done:
  Claude Code, Codex CLI, and Gemini CLI are all verified end-to-end (session resume, account
  handling, multi-tool activation), each with a Docker-traced reproduction on record
  (`docs/roadmap.md`).
- **Stay the free, no-account option as the space commercializes.** A paid competitor
  (cc-switch, $19–199/mo) already exists for a fuller version of this job. agman's bet is that a
  meaningful share of this market — individual developers, not teams needing a managed GUI — will
  keep choosing free and dependency-free over a subscription, the way `direnv`/`chezmoi`/`aws-vault`
  won that same bet in adjacent spaces.
- **Grow distribution.** Homebrew tap is live; the next concrete milestone is the notability
  threshold for `homebrew-core` (30 forks/watchers or 75 stars — currently at 4 stars, 0 forks, 0
  watchers as of 2026-08-19, so not close yet), which would remove the tap-trust step entirely
  for new users.
- **Extend coverage, not scope.** More adapters (Qwen Code, Kimi CLI) once their config layouts
  are verified against real installs, and profile sharing over git (`push`/`pull` to a repo the
  user already owns) as the next sync milestone beyond the current hosted `agman cloud` — growing
  *which tools and which sync paths* agman covers, not turning it into a different kind of
  product (an IDE, a GUI, an agent runtime). The vendor-routing decision above is evaluated
  against this same test: does it extend agman's existing job, or does it require becoming
  something else.

---

## Competitive landscape

### Direct competitors — same job, AI-CLI profile/account switching

| Tool | What it does | vs. agman |
|---|---|---|
| **[aisw](https://github.com/burakdede/aisw)** | Free, open-source CLI. Switches named credential profiles across Claude Code, Codex CLI, Gemini CLI, and Antigravity with one command — the closest thing to a direct clone of agman's own pitch. | Closest real competitor. Covers the same three tools plus Antigravity. Whether it covers the config-dir problem the same way (symlink vs. env-var only) or handles Gemini CLI's lack of a config-dir override is worth a closer look before assuming parity — but it's the one project actually chasing the identical niche. |
| **[cc-switch](https://cc-switch.org)** | Commercial desktop app (Starter $19/mo, Team $69/mo, Scale $199/mo). Broader scope than agman: providers, MCP servers, prompts, skills, sessions, sync, and backups across Claude Code, Codex, Gemini CLI, OpenCode, and OpenClaw, with a GUI and system-tray switching. | Paid, GUI-first, and scoped as a full "AI CLI management" product rather than a lightweight config switcher. agman's free, dependency-free, terminal-native model is the opposite bet — no account, no app to keep running, one script. |
| **Smaller single-purpose switchers** (Raycast's Claude Code Config Switcher, `cccs`, `claude-code-switch`, `claude-profile-switch`, `claude-switch`, and similar) | Mostly Claude-Code-only, several focused narrowly on switching API keys/models rather than a full persona (instructions, skills, MCP, account). | A crowded long tail, but narrow: single-tool, and often solving the API-key-swap problem rather than agman's "complete persona across three tools" scope. Not a threat individually, but signals real, validated demand for *some* version of this. |

### Adjacent tooling — same pattern, different domain

| Tool | What it does | Relevance |
|---|---|---|
| **[chezmoi](https://www.chezmoi.io)** | Dotfiles manager: templated configs, secrets kept out of the repo, single source of truth synced across machines. | Not AI-tool-specific, but the closest prior-art for "one config, many machines, secrets handled carefully" — a design agman's own cloud-sync feature deliberately borrows from (secrets excluded by default, encryption for what is synced). |
| **[Atuin](https://atuin.sh)** | Shell history sync with client-side encryption; the server never sees plaintext data. | The privacy model agman cloud aims for: an encryption key the user holds, not an account-based, server-readable sync (the VS Code Settings Sync counter-model). |
| **`aws-vault` / `AWS_PROFILE`** | The UX pattern agman explicitly borrows its identity from — named profiles, one command to switch, per-shell overrides available. | Not a competitor, a design reference: the pitch "AWS_PROFILE for AI coding agents" is deliberate positioning against a pattern developers already trust. |

### The AI-vendor-routing landscape (relevant only to the advisory feature under consideration)

A separate question from "does a competitor switch profiles like agman" is "does anything
automatically pick the *best AI vendor* for a task" — this was researched because it's a feature
being considered (see "Open feature decision" below), not because it's what agman does today.

| Tool | What it does | vs. agman |
|---|---|---|
| **[OpenRouter](https://openrouter.ai)**, **LiteLLM Router** | Route API calls across many providers/deployments by cost or availability, behind one API key/billing account. | API-endpoint-level, not authenticated CLI products — doesn't touch account-access constraints at all. |
| **RouteLLM, Not Diamond, Martian/ROUTERBENCH** | Learned classifiers that pick the "best" model per query, benchmarked across many models. | Same API-endpoint layer; every one of them is candid that this is still unsolved/fuzzy even under one account. |
| **GitHub Copilot "Auto model selection", Cursor's router** | Auto-pick a model inside their own product. | Never crosses vendor accounts — every candidate model sits under the same subscription. |
| **[Claude Code Router](https://github.com/musistudio/claude-code-router)** | Local gateway giving several CLIs one endpoint, with user-defined routing rules. | Closest analogue to automatic cross-vendor routing found anywhere — but it's user-configured rules, not automatic task-based inference, and a network proxy, not a config-profile switcher. |
| **[CodeAgentSwarm](https://www.codeagentswarm.com)** | Closed-source desktop app running several CLIs side by side in parallel terminals. | Solves "run several agents at once," not "which one should I use, and do I even have access." |
| **[Clink](https://github.com/BeehiveInnovations/pal-mcp-server)** | Lets one CLI spawn a subagent from another CLI mid-session via MCP. | In-session subagent delegation with broad auto-approval flags — a different problem, and a riskier permission posture than agman would take. |

---

## What makes agman defensible

1. **It's the only mechanism that actually covers Gemini CLI.** Gemini has no config-directory
   environment variable at all — env-var-based competitors structurally cannot switch it. agman's
   symlink-based activation is the one approach that generalizes to all three tools, which is why
   it was chosen over the simpler env-var design early on.
2. **Zero dependencies, free, no account.** Against a commercial GUI competitor (cc-switch) and a
   growing long tail of small utilities, "one bash script, no signup, no daemon" is a real
   difference in adoption friction, not just a philosophical stance.
3. **It already knows what a person actually has.** Per profile, agman knows which tools and
   credentials exist. No competitor — router or switcher — starts from that fact, which is the
   basis for the advisory feature below.
4. **Session continuity was solved, not assumed.** `claude --resume` keeps working across profile
   switches because agman pools session history centrally — a real, previously-broken behavior
   (see `docs/roadmap.md` v0.6.0) that a naive symlink-swap design would not have gotten right.

---

## Open feature decision: should agman route across AI vendors?

Separate from agman's existing job (switching *your own* profiles), a further question was
raised: should agman also **recommend which vendor — and how hard it should think — fits a given
task** (Opus at high effort for code, Nano Banana for images), constrained by which accounts a
person actually holds and only ever pointing at a profile that can actually do the task?

**What we found**: nobody in the routing landscape above solves this — every router either works
on interchangeable API endpoints or stays inside one vendor's own product, and every credible
attempt at real quality-based routing (even the *easier*, single-vendor case) is candid that it's
still unreliable. That's both the opportunity (a real, unaddressed gap) and the reason to be
careful about how far to chase it.

**Recommendation, in order:**

1. **Ship a shared skills layer** — reusable playbooks (health-check, code-review) that work
   across Claude, Codex, and Gemini automatically, because the three tools already standardized on
   the same open format. Low effort, ships value immediately.
2. **Ship an honest advisory feature** — agman tells you, from what your own profiles actually
   have, which one fits a task and at what effort level, checking not just whether a tool is
   installed but whether the profile has whatever plugin the capability actually needs (e.g.
   image generation is a Gemini CLI *extension*, not a built-in). It recommends; you still decide
   and run it yourself. No model-quality guessing required for a useful first version — just an
   editable table, expected to need occasional updating as benchmarks and models move.
3. **Don't build automatic, silent switching mid-task — and be upfront this can't be a live
   handoff even if we wanted it to be.** Every well-funded specialist attempting real automatic
   routing admits it's unreliable even in the easier single-vendor case. But there's a harder,
   structural reason too: Claude Code, Codex, and Gemini CLI keep separate, incompatible session
   formats, so agman cannot carry an in-progress conversation from one tool into another even in
   principle — the advisory can only ever inform which profile you launch *next*, not swap
   mid-task. Building toward silent automatic switching would also turn agman into a
   fundamentally different kind of product — one running its own AI conversation loop — and would
   still lose on quality to teams funding exactly that research. Revisit only if real usage of the
   advisory feature shows a pattern stable enough to justify going further.

Technical shape for the two recommended pieces: `docs/architecture.md`. This decision doesn't
block or depend on session pooling (`docs/session-pooling.md`) — that's independent, in-flight
work extending the same "pool Claude's session handling to all three tools" pattern that already
shipped for Claude alone.

---

## Bottom line

agman's core bet — a free, dependency-free, symlink-based switcher that's the only thing covering
all three major AI CLIs including Gemini — is validated by real, if scattered, competition: a
crowded field of narrow single-tool utilities and one close direct competitor (aisw) confirms the
problem is real, while a commercial alternative (cc-switch) confirms people will pay for a fuller
version of it, leaving room for agman's free/lightweight positioning. The vendor-routing question
is a smaller, separate bet: the honest-recommender version is a genuine, unaddressed niche worth
building; the fully-automatic version is a research problem better-funded teams haven't solved,
and isn't where agman should compete.
