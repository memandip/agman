# Stealth: block a forced telemetry exporter

Some Claude Code team accounts set an OpenTelemetry exporter (`OTEL_EXPORTER_OTLP_ENDPOINT`)
that you can't turn off in settings. `agman stealth` blocks it at the network level, so that
telemetry never leaves your machine.

> If the exporter was set by your employer, check that blocking it is allowed.
> If you set it yourself, just turn it off instead: `"CLAUDE_CODE_ENABLE_TELEMETRY": "0"` in
> the profile's `settings.json` `env` block.

## Quick start

```bash
agman stealth detect          # which telemetry hosts were found, and where
agman stealth enable work     # always protect the 'work' profile
agman run work                # starts claude with telemetry blocked
```

Nothing found? Save the host yourself: `agman stealth hosts add otel.example.com --profile work`.

## Usage

```bash
agman stealth claude --otel https://otel.example.com/v1/traces
```

This starts your normal `claude` through a local [mitmproxy](https://mitmproxy.org). Requests
to that host get a `403`; everything else, including `api.anthropic.com`, works as usual.

| Option | Meaning |
|---|---|
| `--otel <hosts>` | Hosts to block (see below). Optional when hosts are saved or detected |
| `--save` | Also save the `--otel` hosts for the profile |
| `--profile <name>` | Run with that profile's config (default: the active profile's saved hosts) |
| anything else | Passed to `claude`, e.g. `--resume` |

```bash
agman stealth claude --otel otel.example.com --profile work --resume
agman stealth status   # is the proxy running, and what does it block?
agman stealth stop     # stop the proxy
```

### Listing hosts

Full URLs and bare names both work; agman keeps only the host name.

```bash
--otel https://otel.example.com:4317/v1/traces   # blocks otel.example.com
--otel a.example.com,b.example.com
--otel a.example.com, b.example.com             # spaces are fine, quoted or not
--otel a.example.com --otel=b.example.com       # repeat the flag
```

A blocked host covers its subdomains too: blocking `example.com` also blocks
`otel.example.com`. Sibling hosts are not covered: blocking `otel.example.com` does not
block `metrics.example.com`.

### Auto-detect

You usually don't need `--otel` at all. Before launching, agman looks for every
`OTEL_EXPORTER_OTLP_ENDPOINT` (and its `_TRACES_`, `_METRICS_`, `_LOGS_` variants) that Claude
would see, and blocks those hosts too:

- the current environment
- the profile's `settings.json` and `settings.local.json` (`env` block)
- `./.claude/settings.json` and `./.claude/settings.local.json` in the current directory
- the managed settings file (`/Library/Application Support/ClaudeCode/managed-settings.json`
  on macOS, `/etc/claude-code/managed-settings.json` on Linux)

Endpoints on `localhost` or `127.x` are skipped: they never leave the machine.

```bash
agman stealth detect                 # what would be blocked, and where it was found
agman stealth detect --profile work
```

### Saved hosts

Save hosts per profile so you never retype them:

```bash
agman stealth hosts add otel.example.com --profile work
agman stealth hosts --profile work           # list
agman stealth hosts rm otel.example.com --profile work
agman stealth claude --otel otel.example.com --save   # launch and save in one go
```

Without `--profile`, these act on the active profile.

Every launch blocks the union of `--otel`, the saved hosts, and the detected hosts. If all
three are empty, agman refuses to start.

### Enable stealth for a profile

```bash
agman stealth enable work     # no name: the active profile
agman stealth disable work
```

While enabled, `agman run work` always launches through the proxy. With the shell
integration loaded (`eval "$(agman init)"`), plain `claude` does too whenever `work` is the
profile in use. `agman stealth status` lists each profile's state and saved hosts.

### What is not covered

Plain `claude` goes through the proxy **only** if its profile is enabled and the shell
integration is loaded. IDE extensions are never covered. The proxy keeps running in the
background until `agman stealth stop`.

## Setup (macOS)

```bash
brew install mitmproxy     # lsof and curl come with macOS
```

The first run creates `~/.mitmproxy/mitmproxy-ca-cert.pem` if needed. Claude trusts it via
`NODE_EXTRA_CA_CERTS`; nothing else on your system does. To trust it system-wide (optional):

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/.mitmproxy/mitmproxy-ca-cert.pem
```

## Details

- State, including the generated addon `block_otel.py` and each profile's saved hosts and
  enabled flag (`profiles/<name>.hosts`, `profiles/<name>.enabled`), lives in
  `~/.agman/.stealth`. It is never synced or copied with a profile. `rename` and `remove`
  keep it in step.
- One proxy serves every stealth session. Starting another session with new hosts adds them;
  it never drops hosts an already-running session needs. `agman stealth stop` clears the list.
- Dependencies are checked only when you run `stealth`; the rest of agman needs none.
- Before launching, agman checks that the block actually works. If a request gets through, it
  stops instead of running unprotected.

| Variable | Default |
|---|---|
| `AGMAN_STEALTH_PORT` | `8080` |
| `AGMAN_STEALTH_CA` | `~/.mitmproxy/mitmproxy-ca-cert.pem` |
| `AGMAN_STEALTH_MANAGED` | Managed-settings files to scan, colon-separated |
