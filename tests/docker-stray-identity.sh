#!/usr/bin/env bash
# Reproduces the report that after Claude Code rewrites ~/.claude.json in
# place (write temp + rename, which destroys agman's symlink and leaves a
# real file), every later `agman use` printed
#   "…is a real path but the global backup already has claude.json;
#    leaving this tool alone"
# and claude never switched profiles again.
#
# Verifies the fix: the stray file is absorbed into the profile that was
# active (it holds the freshest account state), the switch relinks claude,
# the pristine global backup is never touched, and the recovery is
# repeatable. Runs inside a container:
#   docker run --rm -v "$PWD:/work" debian:stable-slim bash /work/tests/docker-stray-identity.sh
set -u

AGMAN=/work/bin/agman
export HOME=/root AGMAN_HOME=/root/.agman AGMAN_TOOLS=claude
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

# The exact mechanism Claude Code uses for config writes.
rewrite_identity_in_place() {
  printf '%s\n' "$1" > "$HOME/.claude.json.tmp"
  mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
}

mkdir -p "$HOME/.claude"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"original@home"},"mcpServers":{}}\n' > "$HOME/.claude.json"
printf 'GLOBAL RULES\n' > "$HOME/.claude/CLAUDE.md"

"$AGMAN" create work --copy-current >/dev/null 2>&1 || { bad "create work"; exit 1; }
"$AGMAN" create personal >/dev/null 2>&1 || { bad "create personal"; exit 1; }
"$AGMAN" use work >/dev/null 2>&1 || { bad "first use work"; exit 1; }
[ -L "$HOME/.claude.json" ] && ok "baseline: ~/.claude.json is a managed link" \
  || bad "baseline: ~/.claude.json is a managed link"

echo
echo "=== Claude Code rewrites ~/.claude.json in place (symlink destroyed) ==="
rewrite_identity_in_place '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"fresh@work"},"numStartups":42}'
[ ! -L "$HOME/.claude.json" ] && [ -f "$HOME/.claude.json" ] \
  && ok "wedge staged: real file where the symlink was, backup populated" \
  || bad "wedge staged"

echo
echo "=== agman use personal must recover, not leave claude alone ==="
out="$("$AGMAN" use personal 2>&1)"
echo "$out" | sed 's/^/    /'
case "$out" in
  *"leaving this tool alone"*) bad "use still wedges on the stray file" ;;
  *) ok "use no longer wedges" ;;
esac
case "$out" in
  *"tools: claude"*) ok "claude is in the switched tool list" ;;
  *) bad "claude is in the switched tool list" ;;
esac
[ "$(readlink "$HOME/.claude.json")" = "$AGMAN_HOME/personal/claude.json" ] \
  && ok "~/.claude.json relinked to the new profile" \
  || bad "~/.claude.json relinked to the new profile ($(readlink "$HOME/.claude.json" || echo real-file))"
grep -q 'fresh@work' "$AGMAN_HOME/work/claude.json" \
  && ok "freshest identity absorbed into the outgoing profile (work)" \
  || bad "freshest identity absorbed into the outgoing profile (work)"
grep -q 'original@home' "$AGMAN_HOME/global/claude.json" \
  && ok "pristine global backup untouched" \
  || bad "pristine global backup untouched"

echo
echo "=== recovery is repeatable: rewrite again, switch back ==="
rewrite_identity_in_place '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"fresher@personal"}}'
out="$("$AGMAN" use work 2>&1)"
case "$out" in
  *"tools: claude"*) ok "second recovery switches claude again" ;;
  *) bad "second recovery switches claude again ($out)" ;;
esac
grep -q 'fresher@personal' "$AGMAN_HOME/personal/claude.json" \
  && ok "second stray absorbed into its owner (personal)" \
  || bad "second stray absorbed into its owner (personal)"

echo
echo "=== ownerless stray (no surviving link): kept aside, switch proceeds ==="
rm -f "$HOME/.claude" "$HOME/.claude.json"
mkdir -p "$HOME/.claude"
printf 'stray tree\n' > "$HOME/.claude/STRAY.md"
printf '{"stray":true}\n' > "$HOME/.claude.json"
out="$("$AGMAN" use personal 2>&1)"
case "$out" in
  *"tools: claude"*) ok "ownerless stray does not block the switch" ;;
  *) bad "ownerless stray does not block the switch ($out)" ;;
esac
ls -d "$AGMAN_HOME"/.backups/claude-stray-* >/dev/null 2>&1 \
  && ok "stray config dir kept aside under .backups" \
  || bad "stray config dir kept aside under .backups"
grep -q 'stray tree' "$AGMAN_HOME"/.backups/claude-stray-*/STRAY.md \
  && ok "stray content preserved byte-for-byte" \
  || bad "stray content preserved byte-for-byte"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
