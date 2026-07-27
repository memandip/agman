#!/usr/bin/env bash
# Reproduces (and later verifies the fix for) the report that Claude Code
# sessions become unresumable after switching agman profiles.
#
# `claude --resume <id>` validates the session locally before contacting the
# API, so "No conversation found with session ID" vs. a later auth failure is a
# reliable signal without any credentials.
set -u

AGMAN=/work/bin/agman
export HOME=/root AGMAN_HOME=/root/.agman AGMAN_TOOLS=claude
SID="11111111-2222-3333-4444-555555555555"
WORK=/root/work
ENC="-root-work"

mkdir -p "$WORK" "$HOME/.claude"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"a"},"userID":"u"}\n' > "$HOME/.claude.json"
printf 'PERSONAL RULES\n' > "$HOME/.claude/CLAUDE.md"

# A transcript matching the shape Claude Code actually writes.
write_session() {
  local dir="$1/projects/$ENC"
  mkdir -p "$dir"
  cat > "$dir/$SID.jsonl" <<JSONL
{"type":"summary","summary":"work done before the profile switch","leafUuid":"cccccccc-0000-0000-0000-000000000003"}
{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"remember the number 4271"},"uuid":"aaaaaaaa-0000-0000-0000-000000000001","timestamp":"2026-07-25T10:00:00.000Z","userType":"external","entrypoint":"cli","cwd":"$WORK","sessionId":"$SID","version":"2.1.220","gitBranch":""}
{"parentUuid":"aaaaaaaa-0000-0000-0000-000000000001","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Noted: 4271."}]},"uuid":"bbbbbbbb-0000-0000-0000-000000000002","timestamp":"2026-07-25T10:00:05.000Z","userType":"external","cwd":"$WORK","sessionId":"$SID","version":"2.1.220","gitBranch":""}
JSONL
}

probe() { # prints FOUND or MISSING based on the local session lookup
  cd "$WORK" || return
  local out
  out=$(claude --resume "$SID" -p "continue" 2>&1 </dev/null)
  if printf '%s' "$out" | grep -qi "No conversation found"; then
    printf 'MISSING'
  else
    printf 'FOUND'
  fi
}

state() { # how ~/.claude resolves right now
  if [ -L "$HOME/.claude" ]; then printf '~/.claude -> %s' "$(readlink "$HOME/.claude" | sed 's|/root|~|')"
  else printf '~/.claude is a real directory'; fi
}

echo "############ 1. unmanaged baseline ############"
write_session "$HOME/.claude"
echo "  $(state)"
echo "  transcript on disk: $(ls "$HOME/.claude/projects/$ENC/" 2>/dev/null | tr '\n' ' ')"
echo "  claude --resume  => $(probe)"

echo
echo "############ 2. create profiles and switch ############"
"$AGMAN" create personal >/dev/null 2>&1
"$AGMAN" create work >/dev/null 2>&1
"$AGMAN" use personal >/dev/null 2>&1
echo "  after 'agman use personal':"
echo "    $(state)"
echo "    transcript visible at ~/.claude/projects/$ENC/: $(ls "$HOME/.claude/projects/$ENC/" 2>/dev/null | tr '\n' ' ' || echo '(nothing)')"
echo "    claude --resume  => $(probe)"

echo
echo "############ 3. switch to the other profile ############"
"$AGMAN" use work >/dev/null 2>&1
echo "  after 'agman use work':"
echo "    $(state)"
echo "    claude --resume  => $(probe)"

echo
echo "############ 4. is the transcript actually gone, or stranded? ############"
find /root/.agman -name "$SID.jsonl" 2>/dev/null | sed 's|/root|~|;s|^|    found at: |' || true
echo

echo "############ 5. switch back ############"
"$AGMAN" use personal >/dev/null 2>&1
echo "    claude --resume  => $(probe)"

echo
echo "############ 6. off (restore) ############"
"$AGMAN" off >/dev/null 2>&1
echo "    $(state)"
echo "    claude --resume  => $(probe)"
