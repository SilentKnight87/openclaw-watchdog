# OpenClaw Gateway Watchdog

This repository contains a standalone macOS watchdog for the OpenClaw gateway. It runs independently from OpenClaw itself, checks the gateway every five minutes, attempts escalating repairs, and sends direct Telegram alerts when it heals the service or gives up.

## Files

- `openclaw-watchdog.sh`: Main watchdog script.
- `install.sh`: Copies the watchdog into `~/clawd/tools/watchdog`, renders the LaunchAgent plist, and loads it.
- `uninstall.sh`: Unloads the LaunchAgent and removes the installed watchdog files.
- `ai.openclaw.watchdog.plist`: LaunchAgent template rendered by `install.sh`.
- `tests/watchdog-tests.sh`: Plain Bash test suite for the watchdog behavior.

## Behavior

- Health check via `curl http://127.0.0.1:18789/health`, then `lsof -i :18789` fallback.
- Healing ladder:
  1. `openclaw gateway restart`
  2. `yes | openclaw doctor --fix`
  3. `launchctl bootout/bootstrap` for `ai.openclaw.gateway`
- Telegram bot token is read from `~/.openclaw/openclaw.json` with `jq`, or `sed` fallback if `jq` is unavailable.
- Logs are written to `~/clawd/logs/watchdog.log` and truncated to the last 1000 lines.
- State is stored in `~/clawd/logs/watchdog.state`.
- Concurrent runs are prevented by a lock directory.

## Install

```bash
./install.sh
```

If an installation already exists, rerun with `FORCE=1` to replace it:

```bash
FORCE=1 ./install.sh
```

## Uninstall

```bash
./uninstall.sh
```

## Test

```bash
./tests/watchdog-tests.sh
```
