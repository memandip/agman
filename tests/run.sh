#!/usr/bin/env bash
#
# agman test suite. No dependencies beyond bash + coreutils (+ curl and jq or
# python3 where present; those paths are skipped or exercised as fallbacks).
# Runs fully sandboxed: fake $HOME, stub tool binaries, temp AGMAN_HOME.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AGM="$ROOT/bin/agman"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- sandbox ---------------------------------------------------------------

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/skills" "$HOME/.claude/plugins"
printf 'GLOBAL RULES\n' > "$HOME/.claude/CLAUDE.md"
printf '{}\n' > "$HOME/.claude/settings.json"
printf 'ephemeral\n' > "$HOME/.claude/sessions/s1.jsonl"
printf 'a skill\n' > "$HOME/.claude/skills/foo.md"
printf 'plugin data\n' > "$HOME/.claude/plugins/p.json"

# Realistic identity state: the keys Claude Code checks for onboarding/auth,
# plus noise that a clean seed must leave behind.
cat > "$HOME/.claude.json" <<'EOF'
{
  "mcpServers": {},
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.205",
  "userID": "user-abc123",
  "machineID": "machine-xyz789",
  "oauthAccount": {
    "accountUuid": "acct-1111",
    "emailAddress": "dev@example.com",
    "organizationName": "Example Org"
  },
  "numStartups": 42,
  "tipsHistory": {"tip-a": 1},
  "projects": {"/some/personal/path": {"hasTrustDialogAccepted": true}}
}
EOF
# Simulates the Linux/Windows layout, where Claude Code keeps credentials
# inside the config dir. Absent on macOS (Keychain), and agman's handling is
# driven by file existence rather than OS detection, so this exercises it.
printf '{"claudeAiOauth":{"accessToken":"FAKE-TOKEN-DO-NOT-USE"}}\n' > "$HOME/.claude/.credentials.json"
chmod 600 "$HOME/.claude/.credentials.json"

export AGMAN_HOME="$HOME/.agman"
# Pin the tool set so results don't depend on which CLIs the host happens to
# have installed. Multi-tool behavior gets its own sandbox below.
export AGMAN_TOOLS="claude"
unset CLAUDE_CONFIG_DIR AGMAN_SHELL_INTEGRATION AGMAN_CLAUDE_HOME AGMAN_RAW_URL \
      AGMAN_TARGET_HOME CODEX_HOME 2>/dev/null || true

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'STUB_CLAUDE CONFIG_DIR=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*"
EOF
chmod +x "$TMP/bin/claude"
ln -s "$AGM" "$TMP/bin/agman"
export PATH="$TMP/bin:$PATH"

# --- assertion helpers -------------------------------------------------------

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

assert_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc (command failed)"; fi
}

assert_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc (expected failure, got success)"; else ok "$desc"; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$desc" ;;
    *) bad "$desc (missing '$needle' in: $haystack)" ;;
  esac
}

assert_lacks() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) bad "$desc (unexpectedly found '$needle')" ;;
    *) ok "$desc" ;;
  esac
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected '$expected', got '$actual')"; fi
}

assert_exists()  { local desc="$1" p="$2"; if [ -e "$p" ]; then ok "$desc"; else bad "$desc ($p missing)"; fi }
assert_missing() { local desc="$1" p="$2"; if [ ! -e "$p" ]; then ok "$desc"; else bad "$desc ($p exists)"; fi }

assert_symlink_to() {
  local desc="$1" link="$2" target="$3"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    ok "$desc"
  else
    bad "$desc ($link -> '$(readlink "$link" 2>/dev/null || echo not-a-symlink)', wanted '$target')"
  fi
}

assert_real_dir() {
  local desc="$1" p="$2"
  if [ -d "$p" ] && [ ! -L "$p" ]; then ok "$desc"; else bad "$desc ($p is not a real directory)"; fi
}

# --- create: layout 2 -------------------------------------------------------

assert_ok   "create is empty by default" "$AGM" create personal
assert_exists  "starter CLAUDE.md lands in claude/" "$AGMAN_HOME/personal/claude/CLAUDE.md"
assert_contains "starter CLAUDE.md names the profile" "$(cat "$AGMAN_HOME/personal/claude/CLAUDE.md")" "personal profile"
assert_missing "empty profile does not copy settings" "$AGMAN_HOME/personal/claude/settings.json"
assert_eq   "new profile records the layout version" "2" "$(cat "$AGMAN_HOME/personal/.agman-layout")"

assert_ok   "create --copy-current seeds from current config" "$AGM" create work --copy-current
assert_eq   "seeded CLAUDE.md content" "GLOBAL RULES" "$(cat "$AGMAN_HOME/work/claude/CLAUDE.md")"
assert_exists  "seeded settings.json" "$AGMAN_HOME/work/claude/settings.json"
assert_exists  "seeded skills" "$AGMAN_HOME/work/claude/skills/foo.md"
assert_exists  "seeded identity file as claude.json" "$AGMAN_HOME/work/claude.json"
assert_missing "sessions excluded from seed" "$AGMAN_HOME/work/claude/sessions"
assert_missing "credentials never copied into a profile (would go stale)" "$AGMAN_HOME/work/claude/.credentials.json"
assert_fail "duplicate create rejected" "$AGM" create work

assert_ok   "create --from clones a profile" "$AGM" create staging --from work
assert_eq   "clone carries CLAUDE.md" "GLOBAL RULES" "$(cat "$AGMAN_HOME/staging/claude/CLAUDE.md")"

assert_ok   "create --copy-current --link-plugins symlinks plugins" "$AGM" create linked --copy-current --link-plugins
if [ -L "$AGMAN_HOME/linked/claude/plugins" ]; then ok "plugins is a symlink"; else bad "plugins is a symlink"; fi

assert_fail "name with slash rejected" "$AGM" create foo/bar
assert_fail "name starting with dot rejected" "$AGM" create .hidden
assert_fail "name with space rejected" "$AGM" create "foo bar"
assert_fail "reserved name 'default' rejected" "$AGM" create default
assert_fail "reserved name 'global' rejected" "$AGM" create global
assert_fail "empty name rejected" "$AGM" create

out="$("$AGM" list)"
assert_contains "list shows work" "$out" "work"
assert_contains "list shows personal" "$out" "personal"

# --- foreign symlink protection ------------------------------------------------

mv "$HOME/.claude" "$HOME/.claude.keep"
ln -s "$TMP/not-agman" "$HOME/.claude"
out="$("$AGM" use work 2>&1 || true)"
assert_contains "use refuses a foreign ~/.claude symlink" "$out" "not managed by agman"
assert_symlink_to "foreign symlink left untouched" "$HOME/.claude" "$TMP/not-agman"
# A refused tool must not be half-activated: the sibling path (~/.claude.json)
# must stay put rather than being stranded in the backup profile.
assert_exists "refused tool leaves ~/.claude.json in place" "$HOME/.claude.json"
assert_missing "refused tool creates no partial backup" "$AGMAN_HOME/global"
rm "$HOME/.claude"
mv "$HOME/.claude.keep" "$HOME/.claude"

# --- use: first switch backs up and symlinks ------------------------------------

out="$("$AGM" use work)"
assert_contains "use announces the global backup" "$out" "global"
assert_symlink_to "~/.claude points at the profile's claude tree" "$HOME/.claude" "$AGMAN_HOME/work/claude"
assert_symlink_to "~/.claude.json points at the profile's claude.json" "$HOME/.claude.json" "$AGMAN_HOME/work/claude.json"
assert_exists  "originals preserved as the 'global' profile" "$AGMAN_HOME/global/claude"
assert_eq   "global backup carries the original CLAUDE.md" "GLOBAL RULES" "$(cat "$AGMAN_HOME/global/claude/CLAUDE.md")"
assert_exists  "global backup captured the identity file" "$AGMAN_HOME/global/claude.json"
assert_eq   "dir --active resolves the claude tree" "$AGMAN_HOME/work/claude" "$("$AGM" dir --active)"
assert_contains "current reports the active profile and tools" "$("$AGM" current)" "work  (active for: claude)"
assert_contains "list marks the active profile" "$("$AGM" list)" "work  (active: claude)"

# --- use: switching between profiles ---------------------------------------------

assert_ok "switch to a second profile" "$AGM" use personal
assert_symlink_to "~/.claude repointed" "$HOME/.claude" "$AGMAN_HOME/personal/claude"
assert_eq   "global backup untouched on the second switch" "GLOBAL RULES" "$(cat "$AGMAN_HOME/global/claude/CLAUDE.md")"
assert_symlink_to "~/.claude.json follows the switch" "$HOME/.claude.json" "$AGMAN_HOME/personal/claude.json"

assert_fail "remove refuses the active profile" "$AGM" remove personal --yes
assert_ok  "use global returns to the original config" "$AGM" use global
assert_symlink_to "~/.claude points at global" "$HOME/.claude" "$AGMAN_HOME/global/claude"
assert_contains "current reports global" "$("$AGM" current)" "global  (active"
assert_ok  "switch back to personal" "$AGM" use personal

# --- rename while active -----------------------------------------------------------

assert_ok "rename the active profile" "$AGM" rename personal personal2
assert_symlink_to "rename repoints ~/.claude" "$HOME/.claude" "$AGMAN_HOME/personal2/claude"
assert_symlink_to "rename repoints ~/.claude.json" "$HOME/.claude.json" "$AGMAN_HOME/personal2/claude.json"
assert_ok "rename back" "$AGM" rename personal2 personal
assert_fail "rename to an existing name fails" "$AGM" rename staging work
assert_fail "rename to a reserved name fails" "$AGM" rename staging global

# --- off: restore originals ----------------------------------------------------------

assert_ok "off restores the original config" "$AGM" off
assert_real_dir "~/.claude is a real directory again" "$HOME/.claude"
assert_eq   "restored CLAUDE.md content" "GLOBAL RULES" "$(cat "$HOME/.claude/CLAUDE.md")"
if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then ok "~/.claude.json restored as a real file"; else bad "~/.claude.json restored as a real file"; fi
assert_contains "restored identity content" "$(cat "$HOME/.claude.json")" "mcpServers"
assert_missing "emptied global backup cleaned up" "$AGMAN_HOME/global"
assert_fail "dir --active fails after off" "$AGM" dir --active
assert_contains "current reports none after off" "$("$AGM" current)" "none"
assert_ok "off is idempotent when unmanaged" "$AGM" off

# --- env / precedence -----------------------------------------------------------------

out="$("$AGM" env work)"
assert_contains "env prints a CLAUDE_CONFIG_DIR export" "$out" "export CLAUDE_CONFIG_DIR="
assert_eq "env line is eval-able" "$AGMAN_HOME/work/claude" \
  "$(eval "$out"; printf '%s' "$CLAUDE_CONFIG_DIR")"
unset CLAUDE_CONFIG_DIR

out="$(CLAUDE_CONFIG_DIR=/somewhere/else "$AGM" current)"
assert_contains "explicit env var wins in current" "$out" "/somewhere/else"

out="$(CLAUDE_CONFIG_DIR="$AGMAN_HOME/personal/claude" "$AGM" current)"
assert_contains "env var pointing into a profile is recognized" "$out" "personal"

# --- run / exec --------------------------------------------------------------------------

out="$("$AGM" run work -- --help)"
assert_contains "run sets CLAUDE_CONFIG_DIR for claude" "$out" "CONFIG_DIR=$AGMAN_HOME/work/claude"
assert_contains "run forwards args" "$out" "ARGS=--help"

out="$("$AGM" exec personal -- claude hello)"
assert_contains "exec sets CLAUDE_CONFIG_DIR" "$out" "CONFIG_DIR=$AGMAN_HOME/personal/claude"
out="$("$AGM" exec personal -- sh -c 'printf "CODEX_HOME=%s" "$CODEX_HOME"')"
assert_contains "exec also sets CODEX_HOME" "$out" "CODEX_HOME=$AGMAN_HOME/personal/codex"
assert_fail "exec without a command fails" "$AGM" exec work --

# --- optional shell integration --------------------------------------------------------------

"$AGM" init zsh > "$TMP/snippet.sh"
assert_ok "init zsh output is valid bash syntax" bash -n "$TMP/snippet.sh"
assert_ok "init bash works" "$AGM" init bash
assert_fail "init fish rejected (roadmap)" "$AGM" init fish

out="$(bash -c 'eval "$(agman init bash)"; agman use personal >/dev/null; claude hi')"
assert_contains "hook: use exports into the current shell" "$out" "CONFIG_DIR=$AGMAN_HOME/personal/claude"

out="$(bash -c 'eval "$(agman init bash)"; claude hi')"
assert_contains "hook: claude wrapper honors the persistent default" "$out" "CONFIG_DIR=$AGMAN_HOME/personal/claude"

out="$(bash -c 'eval "$(agman init bash)"; agman off >/dev/null; claude hi')"
assert_contains "hook: off returns claude to stock" "$out" "CONFIG_DIR=unset"

out="$(bash -c 'eval "$(agman init bash)"; CLAUDE_CONFIG_DIR=/explicit claude hi')"
assert_contains "hook: explicit env var is never overridden" "$out" "CONFIG_DIR=/explicit"

# --- multi-tool sandbox: claude + codex + gemini -----------------------------------------

M="$TMP/multi"
mkdir -p "$M/.claude" "$M/.codex/skills" "$M/.gemini"
printf 'M CLAUDE\n' > "$M/.claude/CLAUDE.md"
cp "$HOME/.claude.json" "$M/.claude.json"
printf 'M CODEX\n' > "$M/.codex/AGENTS.md"
printf '{"model":"x"}\n' > "$M/.codex/config.toml"
printf 'codex skill\n' > "$M/.codex/skills/s.md"
printf 'M GEMINI\n' > "$M/.gemini/GEMINI.md"
printf '{"theme":"dark"}\n' > "$M/.gemini/settings.json"
mrun() { env HOME="$M" AGMAN_HOME="$M/.agman" AGMAN_TOOLS="claude codex gemini" "$AGM" "$@"; }
MA="$M/.agman"

assert_ok "multi-tool: create profile" mrun create teamwork
assert_exists "multi-tool: codex tree created for a detected tool" "$MA/teamwork/codex"
assert_exists "multi-tool: gemini tree created for a detected tool" "$MA/teamwork/gemini"

out="$(mrun use teamwork)"
assert_contains "multi-tool: use reports all three tools" "$out" "tools: claude codex gemini"
assert_symlink_to "multi-tool: ~/.claude linked" "$M/.claude" "$MA/teamwork/claude"
assert_symlink_to "multi-tool: ~/.codex linked" "$M/.codex" "$MA/teamwork/codex"
assert_symlink_to "multi-tool: ~/.gemini linked" "$M/.gemini" "$MA/teamwork/gemini"
assert_eq "multi-tool: original codex config backed up" "M CODEX" "$(cat "$MA/global/codex/AGENTS.md")"
assert_eq "multi-tool: original gemini config backed up" "M GEMINI" "$(cat "$MA/global/gemini/GEMINI.md")"
assert_contains "multi-tool: current lists every active tool" "$(mrun current)" "active for: claude codex gemini"

# Each tool's config is genuinely separate per profile.
printf 'TEAM CODEX RULES\n' > "$MA/teamwork/codex/AGENTS.md"
assert_ok "multi-tool: create a second profile" mrun create solo
assert_ok "multi-tool: switch profiles" mrun use solo
assert_symlink_to "multi-tool: codex follows the switch" "$M/.codex" "$MA/solo/codex"
assert_missing "multi-tool: solo has its own empty codex tree" "$MA/solo/codex/AGENTS.md"
assert_ok "multi-tool: switch back" mrun use teamwork
assert_eq "multi-tool: teamwork codex config intact" "TEAM CODEX RULES" "$(cat "$M/.codex/AGENTS.md")"

out="$(mrun env teamwork)"
assert_contains "multi-tool: env emits CODEX_HOME" "$out" "export CODEX_HOME="
assert_contains "multi-tool: env notes gemini has no env override" "$out" "no config-dir environment variable"

# A foreign symlink for one tool must not block the others.
mrun off >/dev/null
rm -rf "$M/.gemini"
ln -s "$TMP/not-agman-gemini" "$M/.gemini"
out="$(mrun use teamwork 2>&1)"
assert_contains "multi-tool: foreign gemini link is refused" "$out" "gemini:"
assert_contains "multi-tool: other tools still activate" "$out" "tools: claude codex"
assert_symlink_to "multi-tool: foreign gemini link untouched" "$M/.gemini" "$TMP/not-agman-gemini"
rm -f "$M/.gemini"

mrun off >/dev/null
assert_real_dir "multi-tool: off restores ~/.codex" "$M/.codex"
assert_eq "multi-tool: restored codex content" "M CODEX" "$(cat "$M/.codex/AGENTS.md")"

# --- migration from the legacy (layout 1) profile shape ------------------------------------

G="$TMP/legacy"
mkdir -p "$G/.claude" "$G/.agman/oldwork/skills"
printf 'LIVE\n' > "$G/.claude/CLAUDE.md"
cp "$HOME/.claude.json" "$G/.claude.json"
# A layout-1 profile: Claude files sat directly at the profile root.
printf 'OLD WORK RULES\n' > "$G/.agman/oldwork/CLAUDE.md"
printf '{"a":1}\n' > "$G/.agman/oldwork/settings.json"
printf 'old skill\n' > "$G/.agman/oldwork/skills/old.md"
cp "$HOME/.claude.json" "$G/.agman/oldwork/.claude.json"
grun() { env HOME="$G" AGMAN_HOME="$G/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
GA="$G/.agman"

assert_contains "legacy profile is flagged in list" "$(grun list)" "legacy layout"

out="$(grun use oldwork)"
assert_contains "migration is announced" "$out" "Migrated profile 'oldwork'"
assert_contains "migration explains the new layout" "$out" "one config tree per tool"
assert_exists "migrated CLAUDE.md moved into claude/" "$GA/oldwork/claude/CLAUDE.md"
assert_eq "migrated content preserved" "OLD WORK RULES" "$(cat "$GA/oldwork/claude/CLAUDE.md")"
assert_exists "migrated skills moved into claude/" "$GA/oldwork/claude/skills/old.md"
assert_exists "identity file renamed to claude.json" "$GA/oldwork/claude.json"
assert_missing "old root CLAUDE.md gone" "$GA/oldwork/CLAUDE.md"
assert_eq "layout marker written" "2" "$(cat "$GA/oldwork/.agman-layout")"
assert_symlink_to "migrated profile is linked correctly" "$G/.claude" "$GA/oldwork/claude"

backup="$(find "$GA/.backups" -maxdepth 1 -name 'oldwork-layout1-*' | head -1)"
if [ -n "$backup" ]; then
  ok "pre-migration backup kept"
  assert_eq "backup holds the original layout" "OLD WORK RULES" "$(cat "$backup/CLAUDE.md")"
else
  bad "pre-migration backup kept"
  bad "backup holds the original layout"
fi
assert_lacks "list no longer flags a migrated profile" "$(grun list)" "legacy layout"
assert_ok "migrate is idempotent" grun migrate
assert_eq "content still intact after re-migrate" "OLD WORK RULES" "$(cat "$GA/oldwork/claude/CLAUDE.md")"
grun off >/dev/null

# --- identity seeding (the login-prompt fix) -----------------------------------------

ID_HOME="$TMP/idhome"
mkdir -p "$ID_HOME/.claude"
cp "$HOME/.claude.json" "$ID_HOME/.claude.json"
printf 'GLOBAL RULES\n' > "$ID_HOME/.claude/CLAUDE.md"
printf '{"claudeAiOauth":{"accessToken":"FAKE-TOKEN-DO-NOT-USE"}}\n' > "$ID_HOME/.claude/.credentials.json"
idrun() { env HOME="$ID_HOME" AGMAN_HOME="$ID_HOME/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
IDA="$ID_HOME/.agman"

assert_ok "empty profile creation succeeds" idrun create solo
json="$(cat "$IDA/solo/claude.json")"
assert_contains "seeds hasCompletedOnboarding (the onboarding gate)" "$json" '"hasCompletedOnboarding"'
assert_contains "onboarding gate seeded as true" "$json" 'true'
assert_contains "seeds oauthAccount (account identity)" "$json" '"oauthAccount"'
assert_contains "oauthAccount carries the account uuid" "$json" 'acct-1111'
assert_contains "seeds userID" "$json" '"userID"'
assert_contains "seeds machineID" "$json" '"machineID"'
assert_lacks "clean seed excludes projects state" "$json" '/some/personal/path'
assert_lacks "clean seed excludes tips history" "$json" 'tipsHistory'

out="$(idrun create seeded2 2>&1)"
assert_contains "create reports account inheritance" "$out" "inherits your current Claude account"

assert_ok "copy-current profile creation succeeds" idrun create fullcopy --copy-current
assert_contains "copy-current profile has identity" "$(cat "$IDA/fullcopy/claude.json")" '"oauthAccount"'

# --- repair path: profiles created before identity seeding existed ---------------------

mkdir -p "$IDA/legacy2"
printf '2\n' > "$IDA/legacy2/.agman-layout"
mkdir -p "$IDA/legacy2/claude"
printf '{}\n' > "$IDA/legacy2/claude.json"
out="$(idrun use legacy2 2>&1)"
assert_contains "use repairs a profile with no identity" "$out" "Seeded this profile"
assert_contains "repaired profile gained identity" "$(cat "$IDA/legacy2/claude.json")" '"hasCompletedOnboarding"'

# --- shared credentials (Linux/Windows layout) ----------------------------------------

assert_exists "first switch promotes credentials to the shared file" "$IDA/.credentials.json"
assert_contains "shared credential content preserved" "$(cat "$IDA/.credentials.json")" "FAKE-TOKEN-DO-NOT-USE"
assert_symlink_to "backup profile links to shared credentials" "$IDA/global/claude/.credentials.json" "$IDA/.credentials.json"
assert_symlink_to "active profile links to shared credentials" "$IDA/legacy2/claude/.credentials.json" "$IDA/.credentials.json"
perm="$(ls -l "$IDA/.credentials.json" | cut -c1-10)"
assert_eq "shared credentials stay owner-only" "-rw-------" "$perm"

assert_ok "switching to another profile works" idrun use solo
assert_symlink_to "second profile also links to shared credentials" "$IDA/solo/claude/.credentials.json" "$IDA/.credentials.json"

# A profile holding its own real credential file is left alone (Phase 4 path).
printf '{"own":"creds"}\n' > "$IDA/seeded2/claude/.credentials.json" 2>/dev/null || {
  mkdir -p "$IDA/seeded2/claude"; printf '{"own":"creds"}\n' > "$IDA/seeded2/claude/.credentials.json"; }
idrun use seeded2 >/dev/null
if [ -L "$IDA/seeded2/claude/.credentials.json" ]; then
  bad "profile with its own credentials keeps them"
else
  assert_contains "profile with its own credentials keeps them" "$(cat "$IDA/seeded2/claude/.credentials.json")" '"own"'
fi

# --- off leaves a self-contained config ------------------------------------------------

assert_ok "off restores the original config" idrun off
if [ -L "$ID_HOME/.claude/.credentials.json" ]; then
  bad "restored credentials are a real file, not a link"
else
  ok "restored credentials are a real file, not a link"
fi
assert_contains "restored credentials keep their content" "$(cat "$ID_HOME/.claude/.credentials.json")" "FAKE-TOKEN-DO-NOT-USE"
assert_missing "shared credential file cleaned up after off" "$IDA/.credentials.json"

# Links left dangling by 'off' must not be presented to Claude Code as creds.
idrun use solo >/dev/null
if [ -L "$IDA/solo/claude/.credentials.json" ] && [ ! -e "$IDA/solo/claude/.credentials.json" ]; then
  bad "dangling credential link is cleaned up on switch"
else
  ok "dangling credential link is cleaned up on switch"
fi
idrun off >/dev/null

# --- doctor ----------------------------------------------------------------------------

out="$(idrun doctor)"
assert_contains "doctor reports per-profile auth" "$out" "per-profile auth:"
assert_contains "doctor reports identity state" "$out" "identity-seeded"
assert_contains "doctor reports the json merge backend" "$out" "json merge:"
assert_contains "doctor lists the tool table" "$out" "Claude Code"
assert_lacks "doctor never prints token material" "$out" "FAKE-TOKEN"

out="$(env HOME="$M" AGMAN_HOME="$M/.agman" AGMAN_TOOLS="claude codex gemini" "$AGM" doctor)"
assert_contains "doctor lists codex" "$out" "Codex CLI"
assert_contains "doctor lists gemini" "$out" "Gemini CLI"
assert_contains "doctor notes gemini has no env override" "$out" "symlink switching only"

# A minimal PATH with neither jq nor python3, reused by the fallback tests.
mkdir -p "$TMP/barebin"
for c in ls cp mv rm mkdir ln cat find chmod readlink grep sed printf date mktemp \
         sort head cut wc dirname basename tr awk uname id env rmdir; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$TMP/barebin/$c" 2>/dev/null
done
BASH_BIN="$(command -v bash)"

# --- shared session state: `claude --resume` must survive a switch -----------------------
#
# Claude Code stores a resumable session at
#   <config dir>/projects/<encoded-cwd>/<session-id>.jsonl
# so a per-profile config dir would strand every earlier session. These check
# the paths a real `claude --resume` reads; the end-to-end check against the
# actual CLI lives in the Docker scripts referenced in docs/roadmap.md.

ST="$TMP/state"
mkdir -p "$ST/.claude/projects/-root-work" "$ST/.claude/todos"
cp "$HOME/.claude.json" "$ST/.claude.json"
printf 'STATE RULES\n' > "$ST/.claude/CLAUDE.md"
printf '{"sessionId":"sess-old"}\n' > "$ST/.claude/projects/-root-work/sess-old.jsonl"
printf 'a prompt\n' > "$ST/.claude/history.jsonl"
printf '{"t":1}\n' > "$ST/.claude/todos/t1.json"
strun() { env HOME="$ST" AGMAN_HOME="$ST/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
SA="$ST/.agman"
SESS="projects/-root-work/sess-old.jsonl"

strun create alpha >/dev/null 2>&1
strun create beta >/dev/null 2>&1
strun use alpha >/dev/null 2>&1

assert_exists "session history promoted to shared state" "$SA/.state/$SESS"
assert_exists "prompt history promoted to shared state" "$SA/.state/history.jsonl"
assert_symlink_to "active profile links projects at shared state" "$SA/alpha/claude/projects" "$SA/.state/projects"
assert_exists "transcript is reachable through ~/.claude (what --resume reads)" "$ST/.claude/$SESS"
assert_eq "transcript content intact" '{"sessionId":"sess-old"}' "$(cat "$ST/.claude/$SESS")"

strun use beta >/dev/null 2>&1
assert_exists "transcript still reachable after switching profiles" "$ST/.claude/$SESS"
assert_exists "prompt history still reachable after switching" "$ST/.claude/history.jsonl"

# A session written while beta is active must be visible from alpha too.
printf '{"sessionId":"sess-new"}\n' > "$ST/.claude/projects/-root-work/sess-new.jsonl"
strun use alpha >/dev/null 2>&1
assert_exists "session created under one profile is visible from the other" "$ST/.claude/projects/-root-work/sess-new.jsonl"

out="$(strun doctor)"
assert_contains "doctor reports shared session state" "$out" "session state: shared at"

# off must hand the history back as real paths, not leave dangling links.
strun off >/dev/null 2>&1
assert_real_dir "off restores ~/.claude" "$ST/.claude"
if [ -L "$ST/.claude/projects" ]; then
  bad "off restores projects as a real directory"
else
  assert_exists "off restores projects as a real directory" "$ST/.claude/$SESS"
fi
assert_exists "off keeps the session written under a profile" "$ST/.claude/projects/-root-work/sess-new.jsonl"
assert_exists "off restores prompt history" "$ST/.claude/history.jsonl"
assert_missing "shared state directory cleaned up by off" "$SA/.state"

# Re-activating after off must not leave a dangling link where history should be.
strun use alpha >/dev/null 2>&1
assert_exists "history survives an off/use round trip" "$ST/.claude/$SESS"
strun off >/dev/null 2>&1

# --- recursive merge: two profiles holding history for the same project ------------------
#
# Regression guard. Merging only top-level entries left each profile with a real
# projects/ directory that shadowed the shared one, so each saw half the history.

MG="$TMP/merge"
mkdir -p "$MG/.agman/global/claude/projects/-root-work" \
         "$MG/.agman/one/claude/projects/-root-work"
printf '2\n' > "$MG/.agman/global/.agman-layout"
printf '2\n' > "$MG/.agman/one/.agman-layout"
cp "$HOME/.claude.json" "$MG/.agman/global/claude.json"
cp "$HOME/.claude.json" "$MG/.agman/one/claude.json"
printf '{"id":"from-global"}\n' > "$MG/.agman/global/claude/projects/-root-work/g.jsonl"
printf '{"id":"from-one"}\n'    > "$MG/.agman/one/claude/projects/-root-work/o.jsonl"
ln -s "$MG/.agman/one/claude" "$MG/.claude"
ln -s "$MG/.agman/one/claude.json" "$MG/.claude.json"
mgrun() { env HOME="$MG" AGMAN_HOME="$MG/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }

mgrun use one >/dev/null 2>&1
assert_exists "merge keeps the session from the backup profile" "$MG/.agman/.state/projects/-root-work/g.jsonl"
assert_exists "merge keeps the session from the active profile" "$MG/.agman/.state/projects/-root-work/o.jsonl"
if [ -L "$MG/.agman/one/claude/projects" ]; then
  ok "merged profile links projects rather than shadowing shared state"
else
  bad "merged profile links projects rather than shadowing shared state"
fi
assert_exists "both sessions reachable from the active profile" "$MG/.claude/projects/-root-work/g.jsonl"
assert_exists "second session reachable too" "$MG/.claude/projects/-root-work/o.jsonl"

# Encoded project directories start with '-', which trips tools that read them
# as options. Guard the path that used to call dirname on them.
mgrun create two >/dev/null 2>&1
printf '{"id":"deep"}\n' > "$MG/.agman/.state/projects/-root-work/deep.jsonl"
out="$(mgrun use two 2>&1)"
assert_lacks "no tool parses an encoded project dir as an option" "$out" "invalid option"
assert_exists "history intact after switching to a new profile" "$MG/.claude/projects/-root-work/deep.jsonl"
mgrun off >/dev/null 2>&1

# --- identity is reachable both ways ------------------------------------------------------
#
# Claude Code resolves .claude.json relative to the config dir when
# CLAUDE_CONFIG_DIR is set, and relative to $HOME otherwise. agman keeps one real
# identity file and makes it reachable from both, so `agman run` sees the
# profile's account and user-scope MCP servers rather than a blank config that
# Claude Code would create itself.

ID2="$TMP/ident"
mkdir -p "$ID2/.claude"
cp "$HOME/.claude.json" "$ID2/.claude.json"
printf 'IDENT RULES\n' > "$ID2/.claude/CLAUDE.md"
irun() { env HOME="$ID2" AGMAN_HOME="$ID2/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
IA="$ID2/.agman"

irun create p1 >/dev/null 2>&1
assert_symlink_to "create links identity into the config dir" \
  "$IA/p1/claude/.claude.json" "$IA/p1/claude.json"
assert_contains "the link resolves to the profile's real identity" \
  "$(cat "$IA/p1/claude/.claude.json")" '"oauthAccount"'

# The path `agman run` exports must contain a readable identity file.
rundir="$(irun dir p1)"
assert_eq "run/exec point at the profile's claude tree" "$IA/p1/claude" "$rundir"
assert_exists "identity is present where CLAUDE_CONFIG_DIR points" "$rundir/.claude.json"

# Writes through the link must land in the single real file, not shadow it.
printf '{"hasCompletedOnboarding":true,"mcpServers":{"viaLink":{}}}\n' > "$IA/p1/claude/.claude.json"
assert_contains "a write through the link updates the real file" "$(cat "$IA/p1/claude.json")" 'viaLink'
if [ -L "$IA/p1/claude/.claude.json" ]; then ok "the link survives a write"; else bad "the link survives a write"; fi

# Drift: a real file inside the config dir, as an older `agman run` produced.
rm -f "$IA/p1/claude/.claude.json"
printf '{"machineID":"stray"}\n' > "$IA/p1/claude/.claude.json"
out="$(irun doctor)"
assert_contains "doctor reports identity drift" "$out" "IDENTITY DRIFT"
out="$(irun use p1 2>&1)"
assert_contains "use rescues a stray identity file" "$out" "agman-orphaned"
assert_exists "the stray file is kept, not deleted" "$IA/p1/claude/.claude.json.agman-orphaned"
assert_symlink_to "identity is linked again after the rescue" \
  "$IA/p1/claude/.claude.json" "$IA/p1/claude.json"
assert_contains "doctor reports a healthy link" "$(irun doctor)" "identity linked"

# off must not leave the in-config-dir link dangling in a restored config.
irun off >/dev/null 2>&1
if [ -L "$ID2/.claude/.claude.json" ]; then
  bad "off removes the in-config-dir identity link"
else
  ok "off removes the in-config-dir identity link"
fi
assert_exists "off restores the real identity file" "$ID2/.claude.json"

# --- project-local .agman file ------------------------------------------------------------

PJ="$TMP/project"
mkdir -p "$PJ/.claude" "$PJ/repo/nested/deep"
cp "$HOME/.claude.json" "$PJ/.claude.json"
prun() { env HOME="$PJ" AGMAN_HOME="$PJ/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
PA="$PJ/.agman"
prun create acme >/dev/null 2>&1
printf '# what this repo wants\nprofile: acme\n' > "$PJ/repo/.agman"
# agman records canonical paths, so trust entries must use the same form.
PJC="$(cd "$PJ" && pwd -P)"

# Untrusted and non-interactive: must refuse rather than switch silently.
out="$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" use </dev/null 2>&1 || true)"
assert_contains "an untrusted .agman file is refused non-interactively" "$out" "not trusted yet"
assert_missing "refusing to trust changes nothing" "$PJ/.agman/.default"

# Trust it the way an interactive confirmation would, then it resolves.
printf '%s\n' "$PJC/repo/.agman" > "$PA/.trusted"
out="$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" use 2>&1)"
assert_contains "a trusted .agman file selects its profile" "$out" "Using profile 'acme'"
assert_contains "and the switch actually happens" "$out" "Switched to profile 'acme'"

# Found from a subdirectory, like .nvmrc.
got="$(cd "$PJ/repo/nested/deep" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" dir --for-cwd 2>/dev/null)"
assert_eq "the file is found from a subdirectory" "$PA/acme/claude" "$got"

# Outside the project there is nothing to resolve, and --for-cwd stays silent.
got="$(cd "$PJ" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" dir --for-cwd 2>/dev/null || true)"
assert_eq "outside the project it resolves to nothing" "" "$got"

# A bare profile name on its own line is accepted too.
printf 'acme\n' > "$PJ/repo/.agman"
got="$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" dir --for-cwd 2>/dev/null)"
assert_eq "a bare profile name is accepted" "$PA/acme/claude" "$got"

# A file naming something that does not exist must say so, not fail obscurely.
printf 'profile: nosuchprofile\n' > "$PJ/repo/.agman"
printf '%s\n' "$PJC/repo/.agman" > "$PA/.trusted"
out="$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" use 2>&1 || true)"
assert_contains "an unknown profile name is reported clearly" "$out" "does not exist"

# An invalid name must be rejected rather than reaching the filesystem.
printf 'profile: ../escape\n' > "$PJ/repo/.agman"
out="$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" use 2>&1 || true)"
assert_lacks "a path-traversal name never resolves" "$out" "Switched to profile"

printf 'profile: acme\n' > "$PJ/repo/.agman"
assert_contains "doctor reports the project file" "$(cd "$PJ/repo" && env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" doctor)" "project file:"
env HOME="$PJ" AGMAN_HOME="$PA" AGMAN_TOOLS="claude" "$AGM" off >/dev/null 2>&1

# --- the shell hook switches per directory ------------------------------------------------

HK="$TMP/hook"
mkdir -p "$HK/.claude" "$HK/repo" "$HK/other"
cp "$HOME/.claude.json" "$HK/.claude.json"
env HOME="$HK" AGMAN_HOME="$HK/.agman" AGMAN_TOOLS="claude" "$AGM" create hooked >/dev/null 2>&1
printf 'profile: hooked\n' > "$HK/repo/.agman"
HKC="$(cd "$HK" && pwd -P)"
mkdir -p "$HK/.agman" && printf '%s\n' "$HKC/repo/.agman" > "$HK/.agman/.trusted"

out="$(env HOME="$HK" AGMAN_HOME="$HK/.agman" AGMAN_TOOLS="claude" bash -c '
eval "$(agman init bash)"
cd '"$HK"'/repo && _agman_autoswitch && printf "in-repo=%s\n" "${CLAUDE_CONFIG_DIR:-unset}"
cd '"$HK"'/other && _agman_autoswitch && printf "outside=%s\n" "${CLAUDE_CONFIG_DIR:-unset}"
')"
assert_contains "the hook exports the project profile on entry" "$out" "in-repo=$HK/.agman/hooked/claude"
assert_contains "and unsets it again on leaving" "$out" "outside=unset"

# A manual export must always win over the hook.
out="$(env HOME="$HK" AGMAN_HOME="$HK/.agman" AGMAN_TOOLS="claude" CLAUDE_CONFIG_DIR=/manual bash -c '
eval "$(agman init bash)"
cd '"$HK"'/repo && _agman_autoswitch && printf "manual=%s\n" "$CLAUDE_CONFIG_DIR"
')"
assert_contains "a manual CLAUDE_CONFIG_DIR is never overridden" "$out" "manual=/manual"

# --- diagnostics must describe the filesystem, not the flag -------------------------------
#
# Disabling sharing after the fact leaves existing links in place, so reporting
# the env var instead of the actual link state points people at the wrong thing.

DG="$TMP/diag"
mkdir -p "$DG/.claude/projects/-root-work"
cp "$HOME/.claude.json" "$DG/.claude.json"
printf '{"id":"d"}\n' > "$DG/.claude/projects/-root-work/d.jsonl"
dgrun() { env HOME="$DG" AGMAN_HOME="$DG/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
dgoff() { env HOME="$DG" AGMAN_HOME="$DG/.agman" AGMAN_TOOLS="claude" AGMAN_SHARE_STATE=0 "$AGM" "$@"; }

dgrun create d1 >/dev/null 2>&1
dgrun use d1 >/dev/null 2>&1
out="$(dgrun doctor)"
assert_contains "doctor counts profiles linked to shared state" "$out" "profile(s) linked"

# Same tree, sharing now disabled: the links still exist, so saying
# "per-profile" would be false.
out="$(dgoff doctor)"
assert_contains "doctor reports links that outlive the opt-out" "$out" "still point at"
assert_lacks "doctor does not claim per-profile while links exist" "$out" "session state: per-profile"
dgrun off >/dev/null 2>&1

# --- preserved conflict copies must be discoverable ----------------------------------------
#
# A merge never deletes: files it cannot place are kept aside. Silently is not
# good enough — doctor and off both have to mention them.

CF="$TMP/conflict"
mkdir -p "$CF/.agman/global/claude/projects/-root-work" \
         "$CF/.agman/one/claude/projects/-root-work"
printf '2\n' > "$CF/.agman/global/.agman-layout"
printf '2\n' > "$CF/.agman/one/.agman-layout"
cp "$HOME/.claude.json" "$CF/.agman/global/claude.json"
cp "$HOME/.claude.json" "$CF/.agman/one/claude.json"
# Identical relative path on both sides: a genuine conflict.
printf '{"side":"global"}\n' > "$CF/.agman/global/claude/projects/-root-work/same.jsonl"
printf '{"side":"one"}\n'    > "$CF/.agman/one/claude/projects/-root-work/same.jsonl"
ln -s "$CF/.agman/one/claude" "$CF/.claude"
ln -s "$CF/.agman/one/claude.json" "$CF/.claude.json"
cfrun() { env HOME="$CF" AGMAN_HOME="$CF/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }

out="$(cfrun use one 2>&1)"
assert_contains "merge warns when it keeps a copy aside" "$out" "agman-conflict"
assert_exists "the conflicting copy is preserved, not deleted" "$CF/.agman/one/claude/projects.agman-conflict/-root-work/same.jsonl"
assert_eq "shared state kept the other side" '{"side":"global"}' "$(cat "$CF/.agman/.state/projects/-root-work/same.jsonl")"
assert_eq "the preserved copy is the profile's own" '{"side":"one"}' "$(cat "$CF/.agman/one/claude/projects.agman-conflict/-root-work/same.jsonl")"
if [ -L "$CF/.agman/one/claude/projects" ]; then
  ok "a conflict still leaves a link, never a shadowing real directory"
else
  bad "a conflict still leaves a link, never a shadowing real directory"
fi
assert_contains "doctor surfaces preserved copies" "$(cfrun doctor)" "kept aside:"
out="$(cfrun off 2>&1)"
assert_contains "off reports copies it did not restore" "$out" "kept aside by an earlier merge"

# --- opt-out: AGMAN_SHARE_STATE=0 keeps history per-profile -------------------------------

PP="$TMP/perprofile"
mkdir -p "$PP/.claude/projects/-root-work"
cp "$HOME/.claude.json" "$PP/.claude.json"
printf '{"id":"iso"}\n' > "$PP/.claude/projects/-root-work/iso.jsonl"
pprun() { env HOME="$PP" AGMAN_HOME="$PP/.agman" AGMAN_TOOLS="claude" AGMAN_SHARE_STATE=0 "$AGM" "$@"; }
pprun create solo >/dev/null 2>&1
pprun use solo >/dev/null 2>&1
assert_missing "opt-out creates no shared state directory" "$PP/.agman/.state"
assert_contains "doctor reports the opt-out" "$(pprun doctor)" "per-profile (AGMAN_SHARE_STATE=0)"
pprun off >/dev/null 2>&1

# --- per-profile accounts (login / logout) ---------------------------------------------

A="$TMP/acct"
mkdir -p "$A/.claude"
cp "$HOME/.claude.json" "$A/.claude.json"
printf 'ACCT RULES\n' > "$A/.claude/CLAUDE.md"
arun() { env HOME="$A" AGMAN_HOME="$A/.agman" AGMAN_TOOLS="claude" "$AGM" "$@"; }
AA="$A/.agman"
FAKE_TOKEN="sk-ant-oat01-FAKE-PROFILE-TOKEN"

arun create client >/dev/null
# A pre-existing setting must survive the apiKeyHelper merge.
printf '{"theme":"dark"}\n' > "$AA/client/claude/settings.json"

assert_fail "login without a token fails" sh -c "printf '' | env HOME=$A AGMAN_HOME=$AA AGMAN_TOOLS=claude $AGM login client --token-stdin"

out="$(printf '%s\n' "$FAKE_TOKEN" | arun login client --token-stdin 2>&1)"
assert_contains "login reports the profile now has its own account" "$out" "own account"
assert_lacks "login never echoes the token" "$out" "$FAKE_TOKEN"
assert_contains "login documents the setup-token limits" "$out" "no Remote Control"

assert_exists "token file written" "$AA/client/claude/.agman-token"
perm="$(ls -l "$AA/client/claude/.agman-token" | cut -c1-10)"
assert_eq "token file is owner-only" "-rw-------" "$perm"
assert_exists "helper script written" "$AA/client/claude/agman-apikey.sh"
if [ -x "$AA/client/claude/agman-apikey.sh" ]; then ok "helper script is executable"; else bad "helper script is executable"; fi

# The helper is what Claude Code actually calls: it must print the token.
assert_eq "helper prints the profile token" "$FAKE_TOKEN" "$("$AA/client/claude/agman-apikey.sh")"

settings="$(cat "$AA/client/claude/settings.json")"
assert_contains "settings.json gains apiKeyHelper" "$settings" '"apiKeyHelper"'
assert_contains "apiKeyHelper points at the profile helper" "$settings" "$AA/client/claude/agman-apikey.sh"
assert_contains "existing settings preserved by the merge" "$settings" '"theme"'

json="$(cat "$AA/client/claude.json")"
assert_lacks "shared account metadata dropped so /status is not misleading" "$json" 'oauthAccount'
assert_contains "onboarding flag kept so no onboarding runs" "$json" 'hasCompletedOnboarding'

out="$(arun doctor)"
assert_contains "doctor reports the profile's own account" "$out" "own-account (token)"
assert_lacks "doctor never prints the token" "$out" "$FAKE_TOKEN"

# Activating must not clobber the profile's own account with shared identity.
out="$(arun use client 2>&1)"
assert_lacks "use does not warn about login for an own-account profile" "$out" "may prompt for login"
assert_lacks "use does not re-seed shared identity over an own account" "$(cat "$AA/client/claude.json")" 'oauthAccount'
assert_eq "helper still prints the token after activation" "$FAKE_TOKEN" "$("$AA/client/claude/agman-apikey.sh")"

# Renaming must leave apiKeyHelper pointing at a path that still exists.
arun rename client client2 >/dev/null
arun use client2 >/dev/null
settings="$(cat "$AA/client2/claude/settings.json")"
assert_contains "rename self-heals the apiKeyHelper path" "$settings" "$AA/client2/claude/agman-apikey.sh"
assert_lacks "stale apiKeyHelper path removed" "$settings" "$AA/client/claude/agman-apikey.sh"

# A clone must not inherit another profile's account.
arun create cloned --from client2 >/dev/null
assert_missing "clone does not carry the token" "$AA/cloned/claude/.agman-token"
assert_missing "clone does not carry the helper" "$AA/cloned/claude/agman-apikey.sh"
# Critically, the clone must not keep an apiKeyHelper pointing at the source
# profile's helper, which would authenticate it as that account.
assert_lacks "clone does not reference the source profile's helper" "$(cat "$AA/cloned/claude/settings.json" 2>/dev/null || echo '{}')" 'apiKeyHelper'
out="$(arun create cloned2 --from client2 2>&1)"
assert_contains "clone of an own-account profile says it uses the shared account" "$out" "shared Claude account"

out="$(arun logout client2 2>&1)"
assert_contains "logout reports the shared account is back" "$out" "shared Claude account"
assert_missing "logout removes the token" "$AA/client2/claude/.agman-token"
assert_missing "logout removes the helper" "$AA/client2/claude/agman-apikey.sh"
assert_lacks "logout removes apiKeyHelper from settings" "$(cat "$AA/client2/claude/settings.json")" 'apiKeyHelper'
assert_contains "logout keeps unrelated settings" "$(cat "$AA/client2/claude/settings.json")" '"theme"'
assert_contains "logout restores shared account identity" "$(cat "$AA/client2/claude.json")" 'oauthAccount'
out="$(arun logout client2 2>&1)"
assert_contains "logout is idempotent" "$out" "nothing to do"
arun off >/dev/null

# Without jq or python3: login still works when settings.json is absent (a fresh
# file can be written safely), and refuses rather than clobbering an existing one.
rm -rf "$TMP/barelogin"; mkdir -p "$TMP/barelogin"
cp "$HOME/.claude.json" "$TMP/barelogin/.claude.json"
barelogin() {
  env -i HOME="$TMP/barelogin" AGMAN_HOME="$TMP/barelogin/.agman" AGMAN_TOOLS="claude" \
    PATH="$TMP/barebin" "$BASH_BIN" "$AGM" "$@"
}
barelogin create fresh >/dev/null 2>&1
out="$(printf '%s\n' "$FAKE_TOKEN" | barelogin login fresh --token-stdin 2>&1)"
assert_contains "login works without jq/python3 when settings.json is absent" "$out" "own account"
assert_contains "fresh settings.json got apiKeyHelper" "$(cat "$TMP/barelogin/.agman/fresh/claude/settings.json")" 'apiKeyHelper'

barelogin create fresh2 >/dev/null 2>&1
printf '{"theme":"dark"}\n' > "$TMP/barelogin/.agman/fresh2/claude/settings.json"
out="$(printf '%s\n' "$FAKE_TOKEN" | barelogin login fresh2 --token-stdin 2>&1 || true)"
assert_contains "login refuses to clobber existing settings without a JSON tool" "$out" "without jq or python3"
assert_missing "refused login leaves no orphan token" "$TMP/barelogin/.agman/fresh2/claude/.agman-token"
assert_contains "existing settings untouched after refusal" "$(cat "$TMP/barelogin/.agman/fresh2/claude/settings.json")" '"theme"'

# --- JSON backend coverage: jq, python3, and the no-tool fallback ------------------------

if command -v jq >/dev/null 2>&1; then
  rm -rf "$TMP/jqhome"; mkdir -p "$TMP/jqhome"
  cp "$HOME/.claude.json" "$TMP/jqhome/.claude.json"
  env HOME="$TMP/jqhome" AGMAN_HOME="$TMP/jqhome/.agman" AGMAN_TOOLS="claude" \
    "$AGM" create viajq >/dev/null 2>&1
  json="$(cat "$TMP/jqhome/.agman/viajq/claude.json")"
  assert_contains "jq backend seeds identity" "$json" '"oauthAccount"'
  assert_lacks "jq backend produces a clean seed" "$json" '/some/personal/path'
else
  ok "jq backend skipped (jq not installed)"
  ok "jq clean-seed check skipped (jq not installed)"
fi

# Minimal PATH with neither jq nor python3: must still preserve login.
rm -rf "$TMP/barehome"; mkdir -p "$TMP/barehome"
cp "$HOME/.claude.json" "$TMP/barehome/.claude.json"
out="$(env -i HOME="$TMP/barehome" AGMAN_HOME="$TMP/barehome/.agman" AGMAN_TOOLS="claude" \
  PATH="$TMP/barebin" "$BASH_BIN" "$AGM" create barefallback 2>&1)"
assert_contains "fallback warns when no JSON tool exists" "$out" "neither jq nor python3"
assert_contains "fallback still preserves login state" "$(cat "$TMP/barehome/.agman/barefallback/claude.json")" '"hasCompletedOnboarding"'

# --- update -------------------------------------------------------------------------------------

mkdir -p "$TMP/self" "$TMP/remote/bin"
cp "$AGM" "$TMP/self/agman"
chmod +x "$TMP/self/agman"
sed 's/^AGMAN_VERSION=.*/AGMAN_VERSION="9.9.9"/' "$AGM" > "$TMP/remote/bin/agman"

if command -v curl >/dev/null 2>&1; then
  out="$(AGMAN_RAW_URL="file://$TMP/remote" "$TMP/self/agman" update)"
  assert_contains "update reports the new version" "$out" "9.9.9"
  assert_contains "update replaced the script" "$(grep -m1 '^AGMAN_VERSION=' "$TMP/self/agman")" "9.9.9"
  assert_fail "update fails cleanly on a bad source" env AGMAN_RAW_URL="file://$TMP/nonexistent" "$TMP/self/agman" update
else
  assert_fail "update requires curl and fails cleanly without it" \
    env AGMAN_RAW_URL="file://$TMP/remote" "$TMP/self/agman" update
  out="$(env AGMAN_RAW_URL="file://$TMP/remote" "$TMP/self/agman" update 2>&1 || true)"
  assert_contains "update explains the curl requirement" "$out" "curl is required"
  ok "update replacement check skipped (curl not installed)"
fi

# --- misc ------------------------------------------------------------------------------------------

assert_ok "help runs" "$AGM" help
assert_contains "help documents the supported tools" "$("$AGM" help)" "Gemini CLI"
assert_contains "version prints" "$("$AGM" version)" "agman"
assert_fail "unknown command fails" "$AGM" frobnicate
assert_ok "remove an inactive profile with --yes" "$AGM" remove staging --yes
assert_missing "removed profile dir gone" "$AGMAN_HOME/staging"
assert_fail "remove an unknown profile fails" "$AGM" remove staging --yes
assert_fail "use an unknown profile fails" "$AGM" use nosuch
assert_fail "dir for an unknown profile fails" "$AGM" dir nosuch

# --- summary --------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
