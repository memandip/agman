# Accounts and login

**Short version:** switching profiles never logs you out. Every profile uses your current
Claude account unless you give it its own with `agman login`.

## Default: one shared account

New profiles inherit the account you're logged in with. Claude Code keeps login in two
places, and agman handles both:

| Part | Where it lives | What agman does |
|---|---|---|
| Account identity | `~/.claude.json` (`oauthAccount`, `hasCompletedOnboarding`, `userID`, `machineID`) | Copies these keys into new profiles; `agman use` fills them in for older profiles |
| Credentials | macOS Keychain | Nothing needed: the path stays `~/.claude`, so the entry is shared |
| Credentials | `<config dir>/.credentials.json` on Linux and Windows | Moves it to `~/.agman/.credentials.json` and links every profile to it, so a token refresh in one profile reaches all of them |

Only the account is copied; project state, history and caches are not. The copy uses `jq` or
`python3` when available. Without either, agman copies the whole file and tells you.

`agman off` turns the shared credential link back into a real file.

Run `agman doctor` to see each profile's login state. It only reports whether credentials
exist and never prints them.

## A separate account per profile

For example, a work login separate from your personal one:

```bash
agman login work      # runs 'claude setup-token', then asks for the token (hidden)
agman logout work     # back to the shared account
```

How it works: the token is saved inside the profile (file mode `600`), and the profile's
`settings.json` points Claude Code's `apiKeyHelper` setting at a small script that prints
it. That setting is read by the CLI, the VS Code extension and the Agent SDK, so the account
follows you into your IDE too.

### Limits of `setup-token` tokens

- Needs a Pro, Max, Team or Enterprise plan.
- Model requests only: no Remote Control and no claude.ai connectors. Local MCP servers work.
- Company-managed setups that set `forceLoginOrgUUID` reject it.
- Lasts about a year and does not refresh. Run `agman login` again to replace it.

### Copies never carry the account

`agman create --from` strips the token, the helper script and the `apiKeyHelper` setting,
so a copy starts on the shared login.

## Why agman doesn't snapshot Keychain entries

Refresh tokens change every time they're used. A saved copy is already out of date when you
switch back, and restoring it would log you out.
