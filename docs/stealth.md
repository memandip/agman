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

This starts your normal `claude` through a local [mitmproxy](https://mitmproxy.org). The
exporter's own requests (`/v1/traces`, `/v1/metrics`, `/v1/logs`, and the gRPC service
paths) get a `403`; everything else — including `api.anthropic.com` and any
non-telemetry traffic to the blocked host itself — works as usual.

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

Full URLs and bare names both work. A bare name blocks the exporter's paths on the
whole host; a URL with a path scopes the block to the exporter's paths under that
path.

```bash
--otel https://otel.example.com:4317/v1/traces   # same as blocking otel.example.com
--otel https://otel.example.com/collect          # blocks /collect/v1/traces, /collect/v1/metrics, /collect/v1/logs
--otel otel.example.com                          # blocks the exporter's paths on the whole host
--otel a.example.com,b.example.com
--otel a.example.com, b.example.com             # spaces are fine, quoted or not
--otel a.example.com --otel=b.example.com       # repeat the flag
```

A blocked host covers its subdomains too: blocking `example.com` also blocks
`otel.example.com`. Sibling hosts are not covered: blocking `otel.example.com` does not
block `metrics.example.com`.

### Hosts that serve more than telemetry

Some companies run one hostname for everything Claude Code needs: the login gateway,
the remotely managed settings, a usage-limits widget — and the OTEL collector. Blocking
such a host outright breaks Claude Code (with `forceRemoteSettingsRefresh` the CLI exits
when it cannot freshly fetch the managed settings). That is why the block is scoped to
the exporter's own request paths: the collector answers `403`, and the gateway endpoints
on the same host pass through untouched.

The passthrough is not free: on a blocked host, agman's local proxy terminates TLS (claude
trusts it via `NODE_EXTRA_CA_CERTS`) and forwards the request unmodified to the real
server. Nothing is stored, but the proxy is on the path for that host's traffic.

Three guards keep the scoped block honest when the org changes things:

- The signal-specific endpoint variables (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and
  friends) carry the full URL the exporter posts to, so a path that is not itself an
  OTLP path is blocked exactly, not treated as a base to extend.
- Requests carrying an OTLP/protobuf or gRPC body are blocked on a blocked host even
  when the path is unknown — no Claude Code API traffic uses those content types.
- Everything that passes through on a blocked host is logged in the daemon log
  (`[agman stealth] passed …`), so telemetry taking an unexpected route is visible
  instead of escaping silently.

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

## Launching from your home directory

`--profile` points Claude Code at the profile's config (`CLAUDE_CONFIG_DIR`), and its
`CLAUDE.md` and `rules/` load as your user memory. But when you launch from your home
directory, Claude Code also reads `$HOME/.claude/CLAUDE.md` and `$HOME/.claude/rules/**`
as **project** memory — and `~/.claude` is the machine-active profile's tree. Without a
guard, the active profile's instructions would load on top of the profile you asked for.

agman handles this automatically: when `agman run` or `agman stealth claude` launches a
profile other than the machine-active one (by `--profile`, or because the shell's
`CLAUDE_CONFIG_DIR` points at it), it passes Claude Code a `claudeMdExcludes` setting
naming the active profile's `CLAUDE.md` and `rules/` (both as the `~/.claude/…` path
Claude computes and the directory it points at), so only the asked-for profile's memory
loads. Launching the machine-active profile needs no exclusion. If you pass `--settings`
yourself, agman stands down — merge your own exclusion in that case. A plain `claude`
after `agman env`, or under `agman exec`, gets no flag; launch with `agman run` or
`agman stealth claude` instead.

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
- Before launching, agman checks that the block actually works: an exporter path must be
  answered by the addon's own `403`, and a non-telemetry path on the same host must not
  be. If either check fails, it stops instead of running with a leaking or over-broad
  block.

| Variable | Default |
|---|---|
| `AGMAN_STEALTH_PORT` | `8080` |
| `AGMAN_STEALTH_CA` | `~/.mitmproxy/mitmproxy-ca-cert.pem` |
| `AGMAN_STEALTH_MANAGED` | Managed-settings files to scan, colon-separated |
