#!/usr/bin/env bash
# Verifies that `agman run` gives Claude Code the profile's identity, not a blank
# config. Claude Code resolves .claude.json relative to the config dir when
# CLAUDE_CONFIG_DIR is set, so user-scope MCP servers are the observable proof:
# `claude mcp list` reads them without needing credentials.
set -u

AGMAN=/work/bin/agman
export HOME=/root AGMAN_HOME=/root/.agman AGMAN_TOOLS=claude
mkdir -p /root/work "$HOME/.claude"

# A global config with its own MCP server, so a leak in either direction shows.
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"g"},"mcpServers":{"global-server":{"command":"true"}}}\n' > "$HOME/.claude.json"
printf 'GLOBAL RULES\n' > "$HOME/.claude/CLAUDE.md"

"$AGMAN" create work >/dev/null 2>&1
# Give the profile a distinct user-scope MCP server.
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"w"},"mcpServers":{"work-profile-server":{"command":"true"}}}\n' > /root/.agman/work/claude.json
printf 'WORK RULES\n' > /root/.agman/work/claude/CLAUDE.md
cd /root/work || exit 1

servers() { claude mcp list 2>&1 | grep -oE 'work-profile-server|global-server|No MCP servers' | sort -u | tr '\n' ' '; }

echo "=== agman NOT active: plain claude sees the global server ==="
echo "  $(servers)"

echo
echo "=== agman run work: must see the profile's server ==="
out=$(CLAUDE_CONFIG_DIR="$("$AGMAN" dir work)" claude mcp list 2>&1 | grep -oE 'work-profile-server|global-server|No MCP servers' | sort -u | tr '\n' ' ')
echo "  $out"
case "$out" in
  *work-profile-server*) echo "  PASS: run uses the profile's identity" ;;
  *) echo "  FAIL: run does not see the profile's identity" ;;
esac

echo
echo "=== the profile's CLAUDE.md is the one in the config dir ==="
echo "  $(cat "$("$AGMAN" dir work)/CLAUDE.md")"

echo
echo "=== no stray identity file: one real file, reached through a link ==="
link=/root/.agman/work/claude/.claude.json
if [ -L "$link" ]; then
  echo "  .claude.json is a link -> $(readlink "$link" | sed 's|/root|~|')"
else
  echo "  FAIL: .claude.json inside the config dir is a real file (drift)"
fi

echo
echo "=== a write under run lands in the profile's single identity file ==="
CLAUDE_CONFIG_DIR="$("$AGMAN" dir work)" claude mcp add probe --scope user -- true >/dev/null 2>&1
grep -oE 'probe|work-profile-server' /root/.agman/work/claude.json | sort -u | tr '\n' ' ' | sed 's/^/  /'
echo
echo "  global config untouched: $(grep -oE 'probe' "$HOME/.claude.json" >/dev/null 2>&1 && echo 'NO — leaked' || echo yes)"

echo
echo "=== project-local selection: .agman file picks the profile ==="
printf 'profile: work\n' > /root/work/.agman
printf '%s\n' /root/work/.agman > "$AGMAN_HOME/.trusted"
echo "  agman dir --for-cwd => $("$AGMAN" dir --for-cwd | sed 's|/root|~|')"
out=$(CLAUDE_CONFIG_DIR="$("$AGMAN" dir --for-cwd)" claude mcp list 2>&1 | grep -oE 'work-profile-server|global-server|No MCP servers' | sort -u | tr '\n' ' ')
echo "  claude there sees: $out"
