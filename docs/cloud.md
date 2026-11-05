# Cloud sync

`agman cloud` syncs profiles between machines and teams through an
[agman cloud](https://github.com/memandip/agman-cloud) server. The public server is
`https://agman.vercel.app`.

## Commands

```bash
agman cloud login [--url <url>] [--key-stdin]   # connect (URL defaults to the public server)
agman cloud push [name] [--dry-run] [--force]   # upload a profile
agman cloud pull <name> [--as <local>] [--force] # download a profile
agman cloud init <org-slug> [name]              # new profile from a team default
agman cloud list | status | logout
```

`--verbose` (or `AGMAN_VERBOSE=1`) logs each request line, payload size and response code.

## What is synced

A synced profile is a **persona, not a login**.

| Synced | Never synced by default |
|---|---|
| `CLAUDE.md`, settings, rules, skills, agents, MCP config, plugin references | Logins: the identity file, `.credentials.json`, per-profile tokens, Codex/Gemini auth, `.env` |
| | Session state: sessions, history, caches, `tmp`, logs, Antigravity's browser profile |
| | Rebuildable files: plugin caches, marketplace clones, `node_modules`, `.venv`/`venv`, `__pycache__`, `.git` |
| | agman leftovers: `*.agman-conflict`, `*.agman-orphaned` |

- A push is refused if a file looks like it contains a secret.
- `--include-secrets` (push) and `--with-secrets` (pull, init) carry logins too, for moving to
  your own new machine.
- After a pull, plugins are reinstalled from the profile's references (`enabledPlugins` and
  `plugins/known_marketplaces.json`) with the `claude` CLI. Set `AGMAN_CLOUD_NO_INSTALL=1` to skip.
- Rebuildable files are skipped for cloud only; local copies made with `agman create --from`
  keep them.

## Safety on pull

A downloaded profile is treated as untrusted:

- `hooks` and `apiKeyHelper` are removed from its `settings.json`.
- Shared-state links are never touched.
- An existing profile with the same name is backed up first.
- The active profile is refused unless you pass `--force`.

## Size limits

- `push --dry-run` lists every file and its size without contacting the server.
- A push over the server's limit is refused before upload, listing the largest files.
- Servers advertise two limits: `maxPushBytes` for direct uploads (Vercel caps these at about
  4.5 MB) and `blobPushBytes` for direct-to-storage uploads (up to 25 MB). agman picks the
  right one automatically.
- `AGMAN_CLOUD_MAX_PUSH_BYTES` overrides the limit and forces direct upload.
- Uploads show a progress bar in a terminal. `AGMAN_PROGRESS=1` or `0` forces it on or off.

## Security

- HTTPS is required. `AGMAN_CLOUD_INSECURE=1` allows `http://`.
- The API key is passed to `curl` through a file with mode `600`, never on the command line.
- Pushes are versioned and encrypted at rest on the server.
