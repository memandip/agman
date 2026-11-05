# Sessions and history

**Short version:** `claude --resume` works no matter which profile is active. Sessions and
prompt history are shared; only the persona (instructions, settings, skills, MCP servers)
changes per profile.

## Why sharing is needed

Claude Code stores each resumable session inside its config folder:

```
<config dir>/projects/<encoded-cwd>/<session-id>.jsonl
```

If every profile had its own copy of that folder, switching would hide all your earlier
sessions. So agman keeps this state in one shared place that every profile links to.

## What is shared

| Tool | Shared location | Contents |
|---|---|---|
| Claude Code | `~/.agman/.state/` | `projects/` (transcripts, auto memory), `history.jsonl`, `todos`, `file-history`, `shell-snapshots`, `session-env`, `sessions` |
| Codex CLI | `~/.agman/.state/codex/` | sessions (rollouts), `history.jsonl`, `log`, `tmp`, `.tmp` (plugin cache) |
| Gemini CLI | `~/.agman/.state/gemini/` | `antigravity`, `antigravity-browser-profile`, `tmp`, `history` |

A side benefit: Antigravity's multi-GB browser profile inside `~/.gemini` is stored once, not
once per profile, and `agman remove` can never delete it.

## Keeping history separate instead

```bash
export AGMAN_SHARE_STATE=0
```

Each profile then keeps its own history, for example to keep client work strictly apart.
You lose resuming a session across profiles.

## Upgrading from an older agman

The next `agman use` merges each profile's history into the shared location, file by file,
and never overwrites. Transcripts have unique names, so clashes are practically impossible.
If one happens, your copy is kept as `projects.agman-conflict`, and both `agman doctor` and
`agman off` point it out.

## Turning agman off

`agman off` converts the shared links back into real folders under `~/.claude`, `~/.codex`
and `~/.gemini`, so everything keeps working without agman.
