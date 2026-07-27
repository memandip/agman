# CLAUDE.md — agman

Project-local instructions for AI coding agents working in this repo. These OVERRIDE
default behavior. Read before making changes.

## What this project is

**agman** (**ag**ent **man**ager) switches complete config profiles for AI coding agents —
Claude Code, Codex CLI, Gemini CLI — the way `AWS_PROFILE` switches AWS accounts. A profile
is one config tree per tool under `~/.agman/<name>`; `agman use <name>` activates it by
**symlinking** each tool's real config path (`~/.claude`, `~/.claude.json`, `~/.codex`,
`~/.gemini`) at the profile.

**The problem it solves:** people keep separate work/personal/client setups (instructions,
settings, rules, skills, agents, MCP servers, accounts) but the agent CLIs offer no first-class
way to switch between them. Env-var overrides don't generalize — Gemini CLI has no config-dir
override at all — so agman switches by symlink, which needs no shell integration and applies to
every new session machine-wide, IDE extensions included. Sessions and prompt history are kept in
shared state (`~/.agman/.state`) so `claude --resume` keeps working across profile switches;
only the persona is per-profile.

## Architecture — what you're editing

- **`bin/agman`** — the entire program. One pure-bash script, **no dependencies**.
- **`install.sh`** — curl-pipe installer.
- **`tests/run.sh`** — the test suite. `tests/docker-session-*.sh` — containerized upgrade/resume tests.
- **`docs/`** — `design.md`, `roadmap.md`, `index.html` (landing page).
- **`.github/workflows/`** — `ci.yml` (tests + shellcheck), `homebrew.yml` (release → tap PR).

### Hard constraints (do not break these)

1. **Bash 3.2 compatible.** Stock macOS ships bash 3.2. No associative arrays, no `mapfile`,
   no `${var,,}`. Parallel indexed arrays are used deliberately — keep that style.
2. **No runtime dependencies.** Pure bash + coreutils only. Don't add jq, python, node, etc.
3. **POSIX-portable.** Must work on macOS, Linux, WSL, and Git Bash.
4. **Never touch symlinks agman didn't create.** The safety model (refusing foreign symlinks,
   refusing to remove the active profile, backing up originals to the `global` profile) is
   load-bearing. Preserve it.
5. **Two version counters, different jobs.** `AGMAN_VERSION` is the release version (semver).
   `LAYOUT_VERSION` is the on-disk profile layout — bump it only when the `~/.agman` layout
   changes in a way that needs migration, and add the migration path.

## Branch & PR workflow (required)

**Never push features or fixes directly to `main`.** Every feature and every fix goes through a
pull request.

1. Branch from `main`: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `ci/<slug>`, `chore/<slug>`.
2. Commit with a clear message; keep changes scoped to the stated task.
3. Push the branch and open a PR against `main` with `gh pr create`.
4. CI (tests on ubuntu + macos, shellcheck) must pass before merge.
5. **Do not commit, push, or open a PR without the user's explicit approval.**

Direct commits to `main` are reserved for the user, not for agents.

## Versioning — [semver.org](https://semver.org/)

Given `MAJOR.MINOR.PATCH`:

- **MAJOR** — incompatible changes: CLI/flag removals or renames, a layout change that can't
  auto-migrate, dropped platform support.
- **MINOR** — backward-compatible functionality: new commands/flags, new managed tool.
- **PATCH** — backward-compatible bug fixes and doc-only corrections.

Pre-1.0.0 (current): the API is not yet stable, but keep the same discipline — breaking
changes bump MINOR, fixes bump PATCH.

### Cutting a release

1. Update `AGMAN_VERSION` in [bin/agman](bin/agman) to match the new tag (without the `v`).
2. Land it via PR.
3. Tag `vX.Y.Z` and publish a GitHub Release. Publishing triggers `homebrew.yml`, which opens a
   PR against `memandip/homebrew-agman`; merging that PR publishes the brew formula.
4. Keep the git tag, `AGMAN_VERSION`, and the release in agreement.

## Local checks before opening a PR

```console
$ bash tests/run.sh                                   # full suite (also runs in CI)
$ shellcheck -S warning -e SC2088 bin/agman install.sh tests/run.sh
```

Add or update tests in `tests/run.sh` for any behavior change. If you touch upgrade/migration or
session-resume behavior, also run the relevant `tests/docker-session-*.sh`.

## Conventions

- Match the surrounding shell style: lowercase function names, `printf` over `echo` for anything
  with variables, `die`/helper functions already defined in the script.
- Keep comments sparse and precise — explain *why*, not *what*. Don't add line-by-line comments.
- User-facing strings sometimes contain `~/.claude` literally; that's why shellcheck excludes
  SC2088. Don't "fix" those into path expansions.
- Update `README.md` and `docs/` when behavior or the CLI surface changes.
- Make only the changes the task needs — no speculative "nice to have" additions unless asked.
