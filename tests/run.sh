#!/usr/bin/env bash
#
# agman test suite. No dependencies beyond bash + coreutils + curl.
# Runs fully sandboxed: fake $HOME, fake claude binary, temp AGMAN_HOME.

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
printf '{"mcpServers":{}}\n' > "$HOME/.claude.json"

export AGMAN_HOME="$HOME/.agman"
unset CLAUDE_CONFIG_DIR AGMAN_SHELL_INTEGRATION AGMAN_CLAUDE_HOME AGMAN_RAW_URL 2>/dev/null || true

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

# --- create ------------------------------------------------------------------

assert_ok   "create is empty by default" "$AGM" create personal
assert_exists  "empty profile gets starter CLAUDE.md" "$AGMAN_HOME/personal/CLAUDE.md"
assert_contains "starter CLAUDE.md mentions profile name" "$(cat "$AGMAN_HOME/personal/CLAUDE.md")" "personal profile"
assert_missing "empty profile does not copy settings" "$AGMAN_HOME/personal/settings.json"

assert_ok   "create --copy-current seeds from current config" "$AGM" create work --copy-current
assert_eq   "seeded CLAUDE.md content" "GLOBAL RULES" "$(cat "$AGMAN_HOME/work/CLAUDE.md")"
assert_exists  "seeded settings.json" "$AGMAN_HOME/work/settings.json"
assert_exists  "seeded skills" "$AGMAN_HOME/work/skills/foo.md"
assert_exists  "seeded user .claude.json" "$AGMAN_HOME/work/.claude.json"
assert_missing "sessions excluded from seed" "$AGMAN_HOME/work/sessions"
assert_fail "duplicate create rejected" "$AGM" create work

assert_ok   "create --from clones a profile" "$AGM" create staging --from work
assert_eq   "clone carries CLAUDE.md" "GLOBAL RULES" "$(cat "$AGMAN_HOME/staging/CLAUDE.md")"

assert_ok   "create --copy-current --link-plugins symlinks plugins" "$AGM" create linked --copy-current --link-plugins
if [ -L "$AGMAN_HOME/linked/plugins" ]; then ok "plugins is a symlink"; else bad "plugins is a symlink"; fi

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
assert_fail "use refuses foreign ~/.claude symlink" "$AGM" use work
rm "$HOME/.claude"
mv "$HOME/.claude.keep" "$HOME/.claude"

# --- use: first switch backs up and symlinks ------------------------------------

out="$("$AGM" use work)"
assert_contains "use announces global backup" "$out" "global"
assert_symlink_to "~/.claude symlinked to profile" "$HOME/.claude" "$AGMAN_HOME/work"
assert_exists  "original config preserved as 'global' profile" "$AGMAN_HOME/global"
assert_eq   "global backup carries original CLAUDE.md" "GLOBAL RULES" "$(cat "$AGMAN_HOME/global/CLAUDE.md")"
assert_exists  "global backup captured ~/.claude.json" "$AGMAN_HOME/global/.claude.json"
assert_symlink_to "~/.claude.json symlinked to profile state" "$HOME/.claude.json" "$AGMAN_HOME/work/.claude.json"
assert_eq   "dir --active resolves default" "$AGMAN_HOME/work" "$("$AGM" dir --active)"
assert_contains "current reports active profile" "$("$AGM" current)" "work  (active"
assert_contains "list marks active profile" "$("$AGM" list)" "work  (active)"

# --- use: switching between profiles ---------------------------------------------

assert_ok "switch to second profile" "$AGM" use personal
assert_symlink_to "~/.claude repointed" "$HOME/.claude" "$AGMAN_HOME/personal"
assert_eq   "global backup untouched on second switch" "GLOBAL RULES" "$(cat "$AGMAN_HOME/global/CLAUDE.md")"
assert_exists  "empty profile got a .claude.json on activation" "$AGMAN_HOME/personal/.claude.json"
assert_symlink_to "~/.claude.json follows the switch" "$HOME/.claude.json" "$AGMAN_HOME/personal/.claude.json"

assert_fail "remove refuses the active profile" "$AGM" remove personal --yes
assert_ok  "use global returns to original config" "$AGM" use global
assert_symlink_to "~/.claude points at global" "$HOME/.claude" "$AGMAN_HOME/global"
assert_contains "current reports global" "$("$AGM" current)" "global  (active"
assert_ok  "switch back to personal" "$AGM" use personal

# --- rename while active -----------------------------------------------------------

assert_ok "rename active profile" "$AGM" rename personal personal2
assert_symlink_to "rename repoints ~/.claude" "$HOME/.claude" "$AGMAN_HOME/personal2"
assert_symlink_to "rename repoints ~/.claude.json" "$HOME/.claude.json" "$AGMAN_HOME/personal2/.claude.json"
assert_ok "rename back" "$AGM" rename personal2 personal
assert_symlink_to "~/.claude follows second rename" "$HOME/.claude" "$AGMAN_HOME/personal"
assert_fail "rename to existing name fails" "$AGM" rename staging work
assert_fail "rename to reserved name fails" "$AGM" rename staging global

# --- off: restore original ----------------------------------------------------------

assert_ok "off restores original config" "$AGM" off
if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then ok "~/.claude is a real directory again"; else bad "~/.claude is a real directory again"; fi
assert_eq   "restored CLAUDE.md content" "GLOBAL RULES" "$(cat "$HOME/.claude/CLAUDE.md")"
if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then ok "~/.claude.json restored as real file"; else bad "~/.claude.json restored as real file"; fi
assert_contains "restored .claude.json content" "$(cat "$HOME/.claude.json")" "mcpServers"
assert_missing "global profile consumed by restore" "$AGMAN_HOME/global"
assert_fail "dir --active fails after off" "$AGM" dir --active
assert_contains "current reports none after off" "$("$AGM" current)" "none"
assert_ok "off is idempotent when unmanaged" "$AGM" off

# --- env / precedence -----------------------------------------------------------------

out="$("$AGM" env work)"
assert_contains "env prints export line" "$out" "export CLAUDE_CONFIG_DIR="
assert_eq "env line is eval-able" "$AGMAN_HOME/work" \
  "$(eval "$out"; printf '%s' "$CLAUDE_CONFIG_DIR")"

out="$(CLAUDE_CONFIG_DIR=/somewhere/else "$AGM" current)"
assert_contains "explicit env var wins in current" "$out" "/somewhere/else"

out="$(CLAUDE_CONFIG_DIR="$AGMAN_HOME/personal" "$AGM" current)"
assert_contains "env var pointing at a profile is recognized" "$out" "personal"

# --- run / exec --------------------------------------------------------------------------

out="$("$AGM" run work -- --help)"
assert_contains "run sets CLAUDE_CONFIG_DIR for claude" "$out" "CONFIG_DIR=$AGMAN_HOME/work"
assert_contains "run forwards args" "$out" "ARGS=--help"

out="$("$AGM" exec personal -- claude hello)"
assert_contains "exec sets CLAUDE_CONFIG_DIR" "$out" "CONFIG_DIR=$AGMAN_HOME/personal"
assert_fail "exec without command fails" "$AGM" exec work --

# --- optional shell integration --------------------------------------------------------------

"$AGM" init zsh > "$TMP/snippet.sh"
assert_ok "init zsh output is valid bash syntax" bash -n "$TMP/snippet.sh"
assert_ok "init bash works" "$AGM" init bash
assert_fail "init fish rejected (roadmap)" "$AGM" init fish

out="$(bash -c 'eval "$(agman init bash)"; agman use personal >/dev/null; claude hi')"
assert_contains "hook: use exports into current shell" "$out" "CONFIG_DIR=$AGMAN_HOME/personal"

out="$(bash -c 'eval "$(agman init bash)"; claude hi')"
assert_contains "hook: claude wrapper honors persistent default" "$out" "CONFIG_DIR=$AGMAN_HOME/personal"

out="$(bash -c 'eval "$(agman init bash)"; agman off >/dev/null; claude hi')"
assert_contains "hook: off returns claude to stock" "$out" "CONFIG_DIR=unset"

out="$(bash -c 'eval "$(agman init bash)"; CLAUDE_CONFIG_DIR=/explicit claude hi')"
assert_contains "hook: explicit env var is never overridden" "$out" "CONFIG_DIR=/explicit"

# --- update -------------------------------------------------------------------------------------

mkdir -p "$TMP/self" "$TMP/remote/bin"
cp "$AGM" "$TMP/self/agman"
chmod +x "$TMP/self/agman"
sed 's/^AGMAN_VERSION=.*/AGMAN_VERSION="9.9.9"/' "$AGM" > "$TMP/remote/bin/agman"

out="$(AGMAN_RAW_URL="file://$TMP/remote" "$TMP/self/agman" update)"
assert_contains "update reports new version" "$out" "9.9.9"
assert_contains "update replaced the script" "$(grep -m1 '^AGMAN_VERSION=' "$TMP/self/agman")" "9.9.9"
assert_fail "update fails cleanly on bad source" env AGMAN_RAW_URL="file://$TMP/nonexistent" "$TMP/self/agman" update

# --- misc ------------------------------------------------------------------------------------------

assert_ok "doctor runs" "$AGM" doctor
assert_ok "help runs" "$AGM" help
assert_contains "version prints" "$("$AGM" version)" "agman"
assert_fail "unknown command fails" "$AGM" frobnicate
assert_ok "remove inactive profile with --yes" "$AGM" remove staging --yes
assert_missing "removed profile dir gone" "$AGMAN_HOME/staging"
assert_fail "remove unknown profile fails" "$AGM" remove staging --yes
assert_fail "use unknown profile fails" "$AGM" use nosuch
assert_fail "dir for unknown profile fails" "$AGM" dir nosuch

# --- summary --------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
