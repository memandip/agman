#!/usr/bin/env bash
#
# loadout test suite. No dependencies beyond bash + coreutils.
# Runs fully sandboxed: fake $HOME, fake claude binary, temp LOADOUT_HOME.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CCP="$ROOT/bin/loadout"

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

export LOADOUT_HOME="$HOME/.loadouts"
unset CLAUDE_CONFIG_DIR LOADOUT_SHELL_INTEGRATION LOADOUT_CLAUDE_HOME 2>/dev/null || true

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'STUB_CLAUDE CONFIG_DIR=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*"
EOF
chmod +x "$TMP/bin/claude"
ln -s "$CCP" "$TMP/bin/loadout"
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

# --- create ------------------------------------------------------------------

assert_ok   "create seeds from current config by default" "$CCP" create work
assert_eq   "seeded CLAUDE.md content" "GLOBAL RULES" "$(cat "$LOADOUT_HOME/work/CLAUDE.md")"
assert_exists  "seeded settings.json" "$LOADOUT_HOME/work/settings.json"
assert_exists  "seeded skills dir" "$LOADOUT_HOME/work/skills/foo.md"
assert_exists  "seeded user .claude.json (MCP/global state)" "$LOADOUT_HOME/work/.claude.json"
assert_missing "sessions excluded from seed" "$LOADOUT_HOME/work/sessions"
assert_fail "duplicate create rejected" "$CCP" create work

assert_ok   "create --empty" "$CCP" create personal --empty
assert_missing "empty profile has no CLAUDE.md" "$LOADOUT_HOME/personal/CLAUDE.md"

assert_ok   "create --from clones a profile" "$CCP" create staging --from work
assert_eq   "clone carries CLAUDE.md" "GLOBAL RULES" "$(cat "$LOADOUT_HOME/staging/CLAUDE.md")"

assert_ok   "create --link-plugins symlinks plugins" "$CCP" create linked --link-plugins
if [ -L "$LOADOUT_HOME/linked/plugins" ]; then ok "plugins is a symlink"; else bad "plugins is a symlink"; fi

assert_fail "name with slash rejected" "$CCP" create foo/bar
assert_fail "name starting with dot rejected" "$CCP" create .hidden
assert_fail "name with space rejected" "$CCP" create "foo bar"
assert_fail "reserved name rejected" "$CCP" create default
assert_fail "empty name rejected" "$CCP" create

# --- list / use / current / dir ---------------------------------------------

out="$("$CCP" list)"
assert_contains "list shows work" "$out" "work"
assert_contains "list shows personal" "$out" "personal"

assert_ok "use work" "$CCP" use work
assert_contains "current reports default" "$("$CCP" current)" "work  (default)"
assert_eq "dir --active resolves default" "$LOADOUT_HOME/work" "$("$CCP" dir --active)"
assert_eq "dir <name> prints path" "$LOADOUT_HOME/personal" "$("$CCP" dir personal)"
assert_fail "dir for unknown profile fails" "$CCP" dir nosuch
assert_contains "list marks default with *" "$("$CCP" list)" "* work"
assert_fail "use unknown profile fails" "$CCP" use nosuch

# --- env / precedence ---------------------------------------------------------

out="$("$CCP" env work)"
assert_contains "env prints export line" "$out" "export CLAUDE_CONFIG_DIR="
assert_eq "env line is eval-able" "$LOADOUT_HOME/work" \
  "$(eval "$out"; printf '%s' "$CLAUDE_CONFIG_DIR")"

out="$(CLAUDE_CONFIG_DIR=/somewhere/else "$CCP" current)"
assert_contains "explicit env var wins over default" "$out" "/somewhere/else"

out="$(CLAUDE_CONFIG_DIR="$LOADOUT_HOME/personal" "$CCP" current)"
assert_contains "env var pointing at a profile is recognized" "$out" "personal"

# --- run / exec ----------------------------------------------------------------

out="$("$CCP" run work -- --help)"
assert_contains "run sets CLAUDE_CONFIG_DIR for claude" "$out" "CONFIG_DIR=$LOADOUT_HOME/work"
assert_contains "run forwards args" "$out" "ARGS=--help"

out="$("$CCP" exec personal -- claude hello)"
assert_contains "exec sets CLAUDE_CONFIG_DIR" "$out" "CONFIG_DIR=$LOADOUT_HOME/personal"
assert_fail "exec without command fails" "$CCP" exec work --

# --- rename / remove / off -----------------------------------------------------

assert_ok "rename default profile" "$CCP" rename work office
assert_eq "default follows rename" "$LOADOUT_HOME/office" "$("$CCP" dir --active)"
assert_fail "rename to existing name fails" "$CCP" rename office personal

assert_ok "remove with --yes" "$CCP" remove staging --yes
assert_missing "removed profile dir gone" "$LOADOUT_HOME/staging"
assert_fail "remove unknown profile fails" "$CCP" remove staging --yes

assert_ok "remove active default clears it" "$CCP" remove office --yes
assert_fail "dir --active fails with no default" "$CCP" dir --active
assert_contains "current reports none" "$("$CCP" current)" "none"

"$CCP" use personal >/dev/null
assert_ok "off clears default" "$CCP" off
assert_fail "dir --active fails after off" "$CCP" dir --active

# --- shell integration ----------------------------------------------------------

"$CCP" init zsh > "$TMP/snippet.sh"
assert_ok "init zsh output is valid bash syntax" bash -n "$TMP/snippet.sh"
assert_ok "init bash works" "$CCP" init bash
assert_fail "init fish rejected (roadmap)" "$CCP" init fish

out="$(bash -c 'eval "$(loadout init bash)"; loadout use personal >/dev/null; claude hi')"
assert_contains "hook: use exports into current shell" "$out" "CONFIG_DIR=$LOADOUT_HOME/personal"

out="$(bash -c 'eval "$(loadout init bash)"; claude hi')"
assert_contains "hook: claude wrapper honors persistent default" "$out" "CONFIG_DIR=$LOADOUT_HOME/personal"

out="$(bash -c 'eval "$(loadout init bash)"; loadout off >/dev/null; claude hi')"
assert_contains "hook: off returns claude to stock" "$out" "CONFIG_DIR=unset"

out="$(bash -c 'eval "$(loadout init bash)"; CLAUDE_CONFIG_DIR=/explicit claude hi')"
assert_contains "hook: explicit env var is never overridden" "$out" "CONFIG_DIR=/explicit"

# --- misc -----------------------------------------------------------------------

assert_ok "doctor runs" "$CCP" doctor
assert_ok "help runs" "$CCP" help
assert_contains "version prints" "$("$CCP" version)" "loadout"
assert_fail "unknown command fails" "$CCP" frobnicate

# --- summary --------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
