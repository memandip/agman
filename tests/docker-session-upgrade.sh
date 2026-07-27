#!/usr/bin/env bash
# Simulates the state a v0.5.0 user is already in — sessions stranded in the
# 'global' backup, plus a few created while another profile was active — and
# checks that upgrading and switching once recovers all of them.
set -u

AGMAN=/work/bin/agman
export HOME=/root AGMAN_HOME=/root/.agman AGMAN_TOOLS=claude
WORK=/root/work; ENC="-root-work"
OLD="aaaaaaaa-1111-1111-1111-111111111111"   # created before agman existed
MID="bbbbbbbb-2222-2222-2222-222222222222"   # created while 'personal' was active
mkdir -p "$WORK"

mk() { # $1=projects dir  $2=session id  $3=label
  mkdir -p "$1/$ENC"
  cat > "$1/$ENC/$2.jsonl" <<JSONL
{"type":"summary","summary":"$3","leafUuid":"cccccccc-0000-0000-0000-000000000003"}
{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"$3"},"uuid":"$2","timestamp":"2026-07-25T10:00:00.000Z","userType":"external","entrypoint":"cli","cwd":"$WORK","sessionId":"$2","version":"2.1.220","gitBranch":""}
JSONL
}

probe() {
  cd "$WORK" || return
  if claude --resume "$1" -p x 2>&1 </dev/null | grep -qi "No conversation found"; then
    printf 'MISSING'; else printf 'FOUND'; fi
}

# --- hand-build the layout agman 0.5.0 leaves behind -------------------------
mkdir -p "$AGMAN_HOME/global/claude" "$AGMAN_HOME/personal/claude"
printf '2\n' > "$AGMAN_HOME/global/.agman-layout"
printf '2\n' > "$AGMAN_HOME/personal/.agman-layout"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"a"}}\n' > "$AGMAN_HOME/global/claude.json"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"a"}}\n' > "$AGMAN_HOME/personal/claude.json"
printf 'ORIGINAL RULES\n' > "$AGMAN_HOME/global/claude/CLAUDE.md"
printf 'PERSONAL RULES\n' > "$AGMAN_HOME/personal/claude/CLAUDE.md"
mk "$AGMAN_HOME/global/claude/projects"   "$OLD" "pre-agman session"
mk "$AGMAN_HOME/personal/claude/projects" "$MID" "session made under personal"
printf 'old prompt\n' > "$AGMAN_HOME/global/claude/history.jsonl"
ln -s "$AGMAN_HOME/personal/claude" "$HOME/.claude"
ln -s "$AGMAN_HOME/personal/claude.json" "$HOME/.claude.json"
printf 'personal\n' > "$AGMAN_HOME/.default"

echo "### state left by agman 0.5.0 (before upgrade) ###"
echo "  ~/.claude -> $(readlink "$HOME/.claude" | sed 's|/root|~|')"
echo "  pre-agman session ($OLD):  $(probe "$OLD")   <- stranded in 'global'"
echo "  session under personal:     $(probe "$MID")"

echo
echo "### upgrade: run the new agman once ###"
"$AGMAN" use personal 2>&1 | sed 's|/root|~|g;s|^|  |'

echo
echo "### after the upgrade switch ###"
echo "  pre-agman session:  $(probe "$OLD")"
echo "  personal session:   $(probe "$MID")"
echo "  both merged into shared state:"
find "$AGMAN_HOME/.state/projects" -name '*.jsonl' 2>/dev/null | sed 's|/root|~|;s|^|    |'
echo "  history.jsonl adopted: $(cat "$AGMAN_HOME/.state/history.jsonl" 2>/dev/null || echo MISSING)"

echo
echo "### and they stay visible from the other profile ###"
"$AGMAN" create work >/dev/null 2>&1
"$AGMAN" use work >/dev/null 2>&1
echo "  after 'agman use work':"
echo "    pre-agman session: $(probe "$OLD")"
echo "    personal session:  $(probe "$MID")"

echo
echo "### off hands everything back ###"
"$AGMAN" off >/dev/null 2>&1
echo "  ~/.claude real dir: $([ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ] && echo yes || echo NO)"
echo "  pre-agman session: $(probe "$OLD")"
echo "  personal session:  $(probe "$MID")"
echo "  transcripts now at: $(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ') file(s) under ~/.claude/projects"
