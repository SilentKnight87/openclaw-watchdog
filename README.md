# OpenClaw Gateway Watchdog

This repository contains a standalone macOS watchdog for the OpenClaw gateway. It runs independently from OpenClaw itself, checks the local gateway every five minutes, attempts escalating repairs, and sends Telegram alerts when it heals the service or gives up.

## Files

- `openclaw-watchdog.sh`: Main watchdog script.
- `install.sh`: Copies the watchdog into `~/clawd/tools/watchdog`, renders the LaunchAgent plist, and loads it.
- `uninstall.sh`: Unloads the LaunchAgent and removes the installed watchdog files.
- `ai.openclaw.watchdog.plist`: LaunchAgent template rendered by `install.sh`.
- `tests/watchdog-tests.sh`: Plain Bash test suite for the watchdog behavior.

## Prerequisites

- macOS with a logged-in user session. This installs a per-user LaunchAgent, not a system LaunchDaemon.
- `openclaw`
- `curl`
- `lsof`
- `perl`
- `jq` is optional. If it is missing, the watchdog falls back to `sed` for token and state parsing.
- A Telegram bot token in `~/.openclaw/openclaw.json`
- A valid Telegram chat ID configured for the watchdog. This repo does not ship with one.

## Behavior

- Primary health check: `curl -sf http://127.0.0.1:18789/health`
- Port `18789` is still checked with `lsof`, but only for diagnostics. An open port alone no longer counts as healthy.
- Healing ladder:
  1. `openclaw gateway restart`
  2. `yes | openclaw doctor --fix`
  3. `launchctl bootout/bootstrap` for `ai.openclaw.gateway`
- Each heal step has a timeout so one hung command does not wedge the watchdog forever.
- Telegram bot token is read from `~/.openclaw/openclaw.json` with `jq`, or `sed` fallback if `jq` is unavailable.
- Logs are written to `~/clawd/logs/watchdog.log` and truncated to the last 1000 lines.
- Launchd stdout/stderr are written to `~/clawd/logs/watchdog-launchd.log` and `~/clawd/logs/watchdog-launchd-err.log`.
- State is stored in `~/clawd/logs/watchdog.state`.
- Concurrent runs are prevented by a lock directory plus lock metadata, and stale locks are reclaimed automatically.

## Configuration

These can be overridden with environment variables in the LaunchAgent or before running the script manually.

- `WATCHDOG_CHAT_ID`: Required. Telegram chat ID for alerts. Example: `123456789` for a direct chat or `-1001234567890` for a group.
- `WATCHDOG_HEALTH_URL`: Health endpoint to probe. Default: `http://127.0.0.1:18789/health`
- `WATCHDOG_PORT`: Diagnostic port check. Default: `18789`
- `WATCHDOG_ALERT_WINDOW_SECONDS`: Alert rate-limit window. Default: `600`
- `WATCHDOG_CHECK_WAIT_SECONDS`: Wait after each heal step before re-checking health. Default: `15`
- `WATCHDOG_RESTART_TIMEOUT_SECONDS`: Timeout for `openclaw gateway restart`. Default: `30`
- `WATCHDOG_DOCTOR_TIMEOUT_SECONDS`: Timeout for `openclaw doctor --fix`. Default: `180`
- `WATCHDOG_NUCLEAR_TIMEOUT_SECONDS`: Timeout for the launchctl reset step. Default: `30`
- `WATCHDOG_LOCK_STALE_SECONDS`: Age after which a running lock may be reclaimed. Default: `900`
- `WATCHDOG_CONFIG_FILE`: OpenClaw config path. Default: `~/.openclaw/openclaw.json`
- `WATCHDOG_GATEWAY_PLIST`: Gateway LaunchAgent path. Default: `~/Library/LaunchAgents/ai.openclaw.gateway.plist`

## Install

```bash
WATCHDOG_CHAT_ID=123456789 ./install.sh
```

If an installation already exists, rerun with `FORCE=1` to replace it:

```bash
WATCHDOG_CHAT_ID=123456789 FORCE=1 ./install.sh
```

`install.sh` fails fast if `WATCHDOG_CHAT_ID` is missing or malformed. The installer writes that value into the LaunchAgent so the background watchdog keeps using the intended Telegram destination after installation.

## Post-Install Verification

```bash
launchctl print "gui/$(id -u)/ai.openclaw.watchdog"
plutil -p ~/Library/LaunchAgents/ai.openclaw.watchdog.plist | grep WATCHDOG_CHAT_ID -A1
tail -n 50 ~/clawd/logs/watchdog.log
tail -n 50 ~/clawd/logs/watchdog-launchd-err.log
```

## Operational Caveats

- The watchdog verifies local gateway health. It does not prove end-to-end remote reachability from Telegram, Tailscale, or your home network.
- `openclaw doctor --fix` is auto-confirmed with `yes`, so any prompt that command would normally ask is accepted automatically.
- If the Mac is rebooted and no user session is logged in, this LaunchAgent may not be running yet.

## Troubleshooting

- Main log: `~/clawd/logs/watchdog.log`
- State file: `~/clawd/logs/watchdog.state`
- Launchd stdout: `~/clawd/logs/watchdog-launchd.log`
- Launchd stderr: `~/clawd/logs/watchdog-launchd-err.log`
- If you suspect launchd is not loading the agent, inspect it with:

```bash
launchctl print "gui/$(id -u)/ai.openclaw.watchdog"
```

- If you need to run the watchdog manually:

```bash
~/clawd/tools/watchdog/openclaw-watchdog.sh
```

- If a stale lock ever survives unexpectedly, remove:

```bash
rm -f ~/clawd/logs/watchdog.lock.info
rmdir ~/clawd/logs/watchdog.lock
```

## Uninstall

```bash
./uninstall.sh
```

## Test

```bash
./tests/watchdog-tests.sh
```
