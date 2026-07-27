#!/usr/bin/env bash
# Adversarial names for the shared-state merge. Encoded project directories
# always start with '-', so any command that receives one as a bare argument can
# read it as an option. These names are legal on disk and must survive a merge
# without loss.
set -u

AGMAN=/work/bin/agman
export HOME=/root AGMAN_HOME=/root/.agman AGMAN_TOOLS=claude
A="$AGMAN_HOME"

# Deliberately do NOT pre-create ~/.claude or ~/.claude.json: agman must find a
# profile symlink here, and a real path would (correctly) make it refuse.
IDENT='{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"a"}}'

# Layout a 0.5.0 user could plausibly have: history split across the backup and
# an active profile, with hostile directory and file names.
mkdir -p "$A/global/claude" "$A/one/claude"
printf '2\n' | tee "$A/global/.agman-layout" > "$A/one/.agman-layout"
printf '%s\n' "$IDENT" > "$A/global/claude.json"
printf '%s\n' "$IDENT" > "$A/one/claude.json"

NAMES=('-Users-me-work' '--help' '-rf-danger' '-n' 'with space' '-Users-me-work-nested')
i=0
for n in "${NAMES[@]}"; do
  i=$((i + 1))
  # Alternate which side each project directory starts on so the merge has to
  # combine both, including the same directory existing on both sides.
  if [ $((i % 2)) -eq 0 ]; then base="$A/global/claude/projects"; else base="$A/one/claude/projects"; fi
  mkdir -p "$base/$n"
  printf '{"id":"%s"}\n' "$n" > "$base/$n/sess-$i.jsonl"
done
# The same project directory present on BOTH sides, different session files.
mkdir -p "$A/global/claude/projects/-Users-me-work" "$A/one/claude/projects/-Users-me-work"
printf '{"id":"g"}\n' > "$A/global/claude/projects/-Users-me-work/from-global.jsonl"
printf '{"id":"o"}\n' > "$A/one/claude/projects/-Users-me-work/from-one.jsonl"
# A deliberate true conflict: identical relative path on both sides.
printf '{"id":"conflict-global"}\n' > "$A/global/claude/projects/--help/same.jsonl"
mkdir -p "$A/one/claude/projects/--help"
printf '{"id":"conflict-one"}\n' > "$A/one/claude/projects/--help/same.jsonl"

before=$(find "$A/global/claude/projects" "$A/one/claude/projects" -name '*.jsonl' | wc -l | tr -d ' ')
ln -s "$A/one/claude" "$HOME/.claude"
ln -s "$A/one/claude.json" "$HOME/.claude.json"
printf 'one\n' > "$A/.default"

echo "session files before merge: $before"
echo
echo "=== agman use one ==="
"$AGMAN" use one 2>&1 | sed 's|/root|~|g;s|^|  |'

echo
echo "=== after: nothing may be lost ==="
after_shared=$(find "$A/.state/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
after_conflict=$(find "$A"/one/claude/projects.agman-conflict -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
after_left=$(find "$A/one/claude/projects" "$A/global/claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
echo "  in shared state:        $after_shared"
echo "  kept aside as conflict: $after_conflict"
echo "  left in profile:        $after_left"
echo "  TOTAL:                  $((after_shared + after_conflict + after_left))  (expected $before)"
if [ "$((after_shared + after_conflict + after_left))" -eq "$before" ]; then
  echo "  RESULT: no session file lost"
else
  echo "  RESULT: *** FILES LOST ***"
fi

echo
echo "=== each adversarial name landed in shared state ==="
for n in "${NAMES[@]}"; do
  c=$(find "$A/.state/projects/$n" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  printf '  %-24s %s file(s)\n' "$n" "$c"
done

echo
echo "=== profile links rather than shadowing ==="
if [ -L "$A/one/claude/projects" ]; then echo "  projects is a symlink (good)"; else echo "  *** projects is a real dir: shadows shared state ***"; fi

echo
echo "=== off restores everything as real paths ==="
"$AGMAN" off >/dev/null 2>&1
restored=$(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
echo "  restored under ~/.claude/projects: $restored"
if [ -L "$HOME/.claude/projects" ]; then echo "  *** still a symlink ***"; else echo "  real directory (good)"; fi
