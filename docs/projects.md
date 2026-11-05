# Per-project and per-shell profiles

## A profile per repository

Put a `.agman` file in the repository root:

```
profile: acme-work
```

From that folder or any subfolder, `agman use` and `agman run` with no name use it:

```bash
cd ~/work/acme && agman use      # switches to acme-work
```

The file comes with a clone, so agman asks once before trusting it and remembers your
answer. Outside an interactive terminal it refuses instead of switching silently.

### Do you need one?

Claude Code already supports per-project config: `./CLAUDE.md`, `./.claude/settings.json`,
`./.claude/rules/`, `./.claude/skills/`, `./.claude/agents/` and `./.mcp.json`. Use a
`.agman` file only for things that have no project scope: the account, user-level MCP
servers, installed plugins, or the whole persona.

## A profile per terminal

`agman use` changes every new session on the machine. To run two profiles side by side,
such as a work terminal and a personal terminal:

**One shell, by hand:**

```bash
eval "$(agman env personal)"
```

**Automatically**, by adding this to `~/.zshrc` or `~/.bashrc`:

```bash
eval "$(agman init zsh)"   # or: agman init bash
```

With that hook:

- `agman use` and `agman off` also update the current shell.
- Entering a folder with a `.agman` file switches that terminal; leaving switches back.
- It works by setting `CLAUDE_CONFIG_DIR`, so it affects terminals only. IDE extensions
  don't see shell variables and keep following `agman use`.
- A `CLAUDE_CONFIG_DIR` you set yourself always wins; the hook only changes values it set.

**One command:**

```bash
agman run work               # start claude once with 'work'
agman exec work -- <command> # run anything with 'work'
```

Started from your home directory, `agman run` also keeps the machine-active profile's
`CLAUDE.md` and `rules/` out of the session, where `~/.claude` would otherwise load as
project memory (see [launching from your home directory](stealth.md#launching-from-your-home-directory)).

## Which profile wins

1. `CLAUDE_CONFIG_DIR` set in the shell (from `env`, `run`, `exec` or the hook).
2. The profile chosen with `agman use`.
3. Neither: your normal `~/.claude`.

Gemini CLI has no override variable, so only option 2 applies to it.
