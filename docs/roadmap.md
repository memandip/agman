# agman roadmap — research findings and phased plan

Research date: 2026-07-25. Verified against primary sources (vendor docs) plus direct
inspection of this machine. Confidence tags: **[Certain]** hard evidence, **[Likely]**
strong inference, **[Guessing]** gap-filling.

---

## 1. The login-prompt bug (root cause found)

### How Claude Code actually stores auth

**[Certain]** Per the [authentication docs](https://code.claude.com/docs/en/authentication):

| Platform | Credential storage |
|---|---|
| macOS | encrypted macOS Keychain (**not** in the config dir) |
| Linux | `~/.claude/.credentials.json`, mode `0600` — **inside the config dir** |
| Windows | `%USERPROFILE%\.claude\.credentials.json` |

> "If you've set the `CLAUDE_CONFIG_DIR` environment variable on Linux or Windows, the
> `.credentials.json` file lives under that directory instead."

**[Certain]** On macOS the Keychain item name is derived from the config dir path. Direct
evidence from this machine — four distinct credential entries:

```
"Claude Code-credentials"            (default ~/.claude, created 2026-05-16)
"Claude Code-credentials-15d224e4"   (created 2026-05-28)
"Claude Code-credentials-48a8ed3a"   (created 2026-05-03)
"Claude Code-credentials-dbbd77c0"   (created 2026-05-03)
```

The suffixed entries predate agman and came from earlier manual `CLAUDE_CONFIG_DIR`
experiments. The exact hash input was not reversed (not sha256/md5/sha1 of the obvious
path strings), but the pattern is unambiguous: **default path → unsuffixed item; custom
path → suffixed item.**

**[Certain]** Identity/onboarding state lives in `~/.claude.json`, not the config dir.
Relevant keys observed locally: `oauthAccount`, `userID`, `hasCompletedOnboarding`,
`machineID`, `firstStartTime`, `numStartups`.

### Why the prompt appears

Two independent causes, which together explain "sometimes":

1. **[Likely] Blank identity metadata.** agman v0.2 writes `{}` as a new profile's
   `.claude.json` and symlinks `~/.claude.json` at it. With `oauthAccount` and
   `hasCompletedOnboarding` missing, Claude Code treats the session as a fresh install and
   runs onboarding/login — *even though the Keychain token is still valid.* Corroborated by
   [aisw's write-up](https://burakdede.com/blog/ai-switcher-multiple-accounts-claude-code-codex-cli-gemini-cli/):
   the credential payload and `~/.claude.json` metadata must stay in sync, "rather than
   updating one and silently breaking the other."
2. **[Likely] Config-dir path changes.** Any path other than `~/.claude` maps to a
   different macOS Keychain item (and a different `.credentials.json` on Linux/Windows), so
   auth appears absent. This affects `agman run`/`exec`/`env` and the optional shell hook —
   all of which set `CLAUDE_CONFIG_DIR` — but **not** the symlink switch.

### Why symlink activation is the right architecture

**[Certain]** Because the symlink keeps the literal path `~/.claude`, the macOS Keychain
item name is unchanged, so **auth is shared across profiles by default on macOS** — exactly
the "by default it should use current account" requirement.

**[Certain]** On Linux/Windows the opposite is true: `.credentials.json` lives inside the
config dir, so symlinking gives each profile its own credentials, and an empty profile has
none. Sharing the current account there requires explicitly copying or symlinking
`.credentials.json` into the profile.

### Fix design

**Default — inherit the current account (all platforms):**
- On `create`, seed the profile's `.claude.json` with the auth/onboarding subset of the
  live one: `oauthAccount`, `userID`, `hasCompletedOnboarding`, `machineID`,
  `firstStartTime`. Deliberately exclude per-project state (`projects`), caches, and tips
  history so profiles stay clean.
- On Linux/Windows, also link or copy `.credentials.json` into the profile (mode `0600`).
- Add `agman doctor` checks: report per-profile auth presence and whether identity metadata
  is seeded.

**Opt-in — a different account per profile:**

**[Certain]** Do **not** snapshot/restore Keychain items. Refresh tokens rotate on every
use, so a saved snapshot is stale by the time you switch back, and restoring it overwrites
a valid entry and logs you out ([documented failure mode](https://gist.github.com/fortunto2/b326e4727e32f9af1742f0710dcc5f75)).

Use long-lived tokens instead. **[Certain]** `claude setup-token` mints a **one-year**
OAuth token (`sk-ant-oat01-…`) that does not rotate; it is printed once and saved nowhere.

Wire it per profile via the profile's own `settings.json`:

```json
{ "apiKeyHelper": "~/.agman/<profile>/agman-token.sh" }
```

**[Certain]** `apiKeyHelper` "appl[ies] to the CLI and the surfaces that wrap it, including
the VS Code extension, the Agent SDK, and GitHub Actions" — so this works in IDEs, unlike
an env var agman can't inject. It is honored from user-scope settings, which is precisely
what the symlink swaps. Called after 5 minutes or on HTTP 401; TTL via
`CLAUDE_CODE_API_KEY_HELPER_TTL_MS`; warn if the script takes >10 s.

**[Certain]** Authentication precedence (highest first): cloud provider →
`ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` → `apiKeyHelper` → `CLAUDE_CODE_OAUTH_TOKEN`
→ subscription OAuth from `/login`.

Caveats to document: `setup-token` requires Pro/Max/Team/Enterprise; its tokens can only
make model requests (no Remote Control, no claude.ai connectors — local MCP still works);
`forceLoginOrgUUID` **blocks** sessions authenticated via `apiKeyHelper`/env credentials,
so enterprise-managed machines may not be able to use this path; `--bare` ignores
`CLAUDE_CODE_OAUTH_TOKEN`.

---

### Phase 1 verification record (v0.3.0)

Evidence gathered while implementing, beyond the docs above:

**[Certain]** Extracted from the shipped `claude` 2.1.205 binary (it embeds its JS bundle):
onboarding is gated by `if (!config.hasCompletedOnboarding)`, and Claude's own telemetry
defines cached auth as `oauthAccount !== undefined || hasCompletedOnboarding === true`.

**[Certain]** Claude Code's own sandbox provisioning does exactly what agman now does: it
writes a fresh config with `{hasCompletedOnboarding: true, …}` and copies the host's
`~/.claude.json` into the target config dir. The seeding approach matches upstream behavior
rather than working around it.

**[Certain]** `oauthAccount` holds only identity and plan metadata (account/org UUIDs,
email, display name, tiers) — no tokens or secrets — so seeding it carries no credential
material. It is PII, which is why cloud sync (Phase 5) must exclude it by default.

**[Certain]** `.claude.json` resolves under the home directory, so the symlink agman
maintains at `~/.claude.json` is the file sessions actually read.

Reproduction and fix, verified in an isolated Linux container against the conditions above:
a profile with `{}` (v0.2 behavior) yields "onboarding: WOULD RUN / auth: MISSING"; the same
switch under v0.3.0 yields "onboarding: SKIPPED / auth: CACHED", with the profile's own
`CLAUDE.md` active and no personal `projects` state leaked.

**Bug found by cross-platform testing:** bash 3.2 rejects self-referencing single-statement
declarations (`local dir="$1" f="$dir/x"`) under `set -u`. Two functions had it. One failed
loudly; the other silently resolved `dir` from the *caller's* scope via dynamic scoping and
only worked by coincidence. Both split into separate statements; the pattern is now absent
from the file.

Test matrix: 122 assertions passing on macOS (bash 3.2.57, jq + python3 + curl) and Debian
stable (bash 5.2.37, jq only, no curl, no python3 — exercising the fallback and
missing-curl paths). shellcheck `-S warning -e SC2088` clean.

## 2. Releases and Homebrew

**[Certain]** homebrew-core requires notability of **at least 30 forks, 30 watchers, or 75
stars**, and per [Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae): "Upstream
must identify the packaged version as stable and provide an immutable tag or release,"
archives "verified with SHA-256," and no fetching "from a moving default branch."

agman currently has 0 stars → **[Certain]** homebrew-core is not an option yet. Ship a
self-hosted tap.

**Plan:**
1. Tag `v0.3.0`, create a GitHub Release with an auto-generated tarball; record its SHA-256.
2. Create `memandip/homebrew-agman` (naming convention makes
   `brew install memandip/agman/agman` work). Formula for a single script:

```ruby
class Agman < Formula
  desc "Agent manager: config profiles for AI coding agents"
  homepage "https://github.com/memandip/agman"
  url "https://github.com/memandip/agman/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "..."
  license "MIT"

  def install
    bin.install "bin/agman"
  end

  test do
    assert_match "agman", shell_output("#{bin}/agman version")
  end
end
```

3. Automate bumps on release with
   [`mislav/bump-homebrew-formula-action`](https://github.com/mislav/bump-homebrew-formula-action)
   (minimal; no Homebrew install or tap clone needed) or
   [`dawidd6/action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula).
   **[Certain]** Both require a PAT rather than `GITHUB_TOKEN`, because the bump forks the
   tap and opens a PR.
4. Revisit homebrew-core once the notability threshold is met.

Keep `install.sh` (curl-pipe) as the primary path for Linux/WSL users.

---

## 3. Multi-tool adapters

| Tool | Config dir | Env override | Auth location |
|---|---|---|---|
| Claude Code | `~/.claude` + `~/.claude.json` | `CLAUDE_CONFIG_DIR` **[Certain]**, undocumented | Keychain (macOS) / `.credentials.json` in config dir (Linux/Win) **[Certain]** |
| Codex CLI | `~/.codex` | `CODEX_HOME` **[Certain]**, documented; also `CODEX_SQLITE_HOME` | inside `CODEX_HOME` **[Certain]** |
| Gemini CLI | `~/.gemini` | **no config-dir override** — `GEMINI_HOME` sets the *parent* home dir; `GEMINI_CONFIG_DIR` is an [open feature request (#2815)](https://github.com/google-gemini/gemini-cli/issues/2815) **[Likely]** | `~/.gemini/oauth_creds.json` **[Likely]** |
| Qwen Code | `~/.qwen` | unverified (Gemini CLI fork, so likely similar) **[Guessing]** | `~/.qwen/oauth_creds.json`, multi-account in `oauth_accounts.json` **[Likely]** |
| Kimi Code CLI | `~/.kimi-code` (data + `credentials/` at `0700`) and `~/.kimi/config.toml` | `KIMI_CODE_HOME` **[Certain]** | `~/.kimi-code/credentials/` **[Likely]** |

**Key architectural validation:** Gemini CLI has no config-dir env var, so **symlink
swapping is the only universal mechanism** — agman's v0.2 pivot generalizes correctly,
while env-var-based competitors cannot cover Gemini at all.

**[Likely]** A cross-tool convention is emerging: Kimi reads `~/.agents/skills/` and
`~/.agents/AGENTS.md` for resources shared between agents. Worth supporting as a shared
layer rather than duplicating per tool.

**Design:** a declarative adapter registry — `{name, paths[], env_var?, auth_paths[],
detect}` — with profile layout `~/.agman/<profile>/<tool>/`. `use` symlinks every path for
each *detected* tool (skipping tools not installed), which keeps single-tool users on
today's behavior. Prior art worth borrowing: aisw snapshots state transactionally and rolls
back on failure, preserves file modes, and refuses to touch symlinks.

**Migration concern:** today's layout is `~/.agman/<profile>/` = a Claude config dir
directly. Moving to `<profile>/claude/` needs a one-time migration with a layout version
marker in the profile.

---

## 4. Cloud-hosted configs

### What the established tools do

**[Certain]** [chezmoi](https://www.chezmoi.io/user-guide/frequently-asked-questions/design/):
secrets are **never** stored in the repo — password-manager integration for real secrets,
`age`/`gpg`/`rage` encryption for sensitive files that must be versioned, templates for
machine-specific variation, single source of truth.

**[Certain]** Atuin: registration generates an **encryption key stored locally** that must
be copied to other machines; all data is encrypted client-side before upload, so the server
operator — official or self-hosted — cannot read it. Self-hosting is first-class.

**[Likely]** VS Code Settings Sync is the counter-model: account-based (Microsoft/GitHub),
server-side, no user-held key — lower friction, weaker privacy.

### Recommended shape for agman

**Phase A — git-backed remotes (zero infrastructure).** `agman push` / `agman pull` against
a git repo the user already owns (GitHub/GitLab, private). Auth is the user's existing git
credentials; company accounts work automatically via their existing org repos and SSO. This
delivers ~90% of the requested value at ~5% of the cost and is the standard practice for
dotfiles.

**The `.agman` file** — mirroring `.nvmrc`/`.tool-versions`: a project-root file naming the
profile, optionally with a remote:

```
profile: acme-work
remote: git@github.com:acme/agman-profiles.git
```

`agman use` with no argument reads `.agman`, and if the named profile isn't local, clones or
fetches it from the remote. **[Likely]** Add a trust prompt on first use of a remote from a
checked-out file — a `.agman` in a shared repo is untrusted input, the same threat model as
Claude Code's own external-import approval dialog.

**Secrets policy (non-negotiable):** profiles contain credentials and MCP tokens. Exclude
all auth material from sync by default (`.credentials.json`, `agman-token.sh`, anything
matching credential patterns), make inclusion explicit and encrypted (`age`), and document
that a synced profile is not a synced login.

**Phase B — hosted service.** Only if adoption justifies it. Requirements: E2E encryption
with a client-held key (Atuin model, so the server never sees configs), OAuth 2.0
Authorization Code + **PKCE** for browser-capable machines with **Device Authorization
Grant** fallback for SSH/headless (the flow `gh auth login` and `aws sso login` use),
tokens in the OS credential store (`security` / `secret-tool` / PasswordVault) with a
`0600` file fallback, and OIDC/SAML for company accounts. **[Likely]** PKCE is effectively
mandatory: OAuth 2.1 will require it for all clients. This phase carries ongoing cost,
security liability, and support burden — it is a product, not a feature.

---

## 5. agman.sh domain

**[Certain]** `.sh` is a premium ccTLD (Saint Helena). Porkbun: **$31.20 first year,
$46.65/year renewal**. Roughly 3–4× a `.dev` or `.com`.

**[Certain]** The `curl | bash` install-domain pattern (`sh.rustup.rs`,
`get.docker.com`) is just a static HTTPS-served script; GitHub Pages or Cloudflare Pages
with a CNAME does it for free.

**Recommendation: defer.** `raw.githubusercontent.com` already serves `install.sh` and
`agman update` correctly today. $47/year buys polish, not capability. Revisit when the
project has users. If registering, Cloudflare Registrar is at-cost but doesn't accept all
TLDs for new registrations; Porkbun is the practical option for `.sh`.

---

## Phased plan, ranked by value ÷ risk

| Phase | Scope | Effort | Risk | Why this order |
|---|---|---|---|---|
| **1** ✅ | **Fix the login prompt** — shipped in v0.3.0. Seeds `.claude.json` identity keys on create and backfills on `use`; promotes Linux/Windows `.credentials.json` to a shared file every profile links to; `doctor` reports per-profile auth | S | Low | The only user-visible defect; blocks daily use |
| **2** ✅ | **Release engineering** — v0.3.0 tagged and released; [memandip/homebrew-agman](https://github.com/memandip/homebrew-agman) tap live (`brew audit --strict --online` clean, `brew install` + `brew test` verified); bump workflow added, pending the `HOMEBREW_TAP_TOKEN` secret | S | Low | Distribution unblocks adoption; also the notability path to homebrew-core |
| **3** | **Multi-tool adapters.** Registry + profile layout migration; Codex and Gemini first (documented mechanisms), Qwen/Kimi after verification | M | Med | Makes the "agent manager" name honest; layout migration is the risky part |
| **4** | **Per-profile accounts.** `agman login <profile>` wrapping `setup-token`, token at `0600`, wired through profile `settings.json` `apiKeyHelper` | M | Med | Depends on Phase 1's auth model; document the Remote-Control/connector and `forceLoginOrgUUID` limits |
| **5** | **Git-backed sync + `.agman`.** `push`/`pull`, `.agman` resolution with remote fetch, trust prompt, secret exclusion | M | Med | Delivers the cloud requirement with zero infrastructure |
| **6** | **Hosted cloud + SSO.** E2E encryption, PKCE/device flow, org accounts | L | High | Only with real demand; ongoing cost and security liability |
| **—** | **Domain `agman.sh`** | S | Low | Defer: $47/yr for cosmetics |

### Cross-cutting

- Every phase keeps the guarantee that an inactive agman is indistinguishable from not
  having it installed.
- Test suite grows with each phase (86 assertions today); auth paths need fake-Keychain and
  fake-token fixtures so CI never touches real credentials.
- Never log or echo token values; `doctor` reports presence and expiry only.
