# hue-status-light

Turn one Philips Hue colour light into a status light for all your Claude Code and Cowork sessions. Glance at the lamp to see whether Claude is waiting for you, finished, or ran into a failing test, even with several sessions running at once.

| Light | Meaning |
|---|---|
| 🟣 purple | Claude is asking you a question |
| 🟠 orange | Claude needs a permission approval |
| 🔴 red | a test run failed (stays until you reply in that session) |
| 🔵 dim blue | sessions are working |
| 🟢 green | everything is done |

Every event first **flashes at full brightness for 5 seconds**: purple on a question, orange on a permission prompt, green when a turn finishes, or red when a test failed during that turn. Then the light settles on the steady colour.

**Many sessions, one light.** Each session keeps its own state; the steady colour always shows whichever session needs you most (question > permission > failed test > working > done). If session B finishes while session A is waiting for an answer, the light flashes green and goes back to purple. Sessions silent for 3 hours are ignored.

## Requirements

- A Philips Hue Bridge (v2, the square one) and at least one **colour** Hue light.
- **Claude Code** on macOS or Linux, on the same network as the bridge, with `curl` and `jq` (jq is built into macOS 15+, otherwise `brew install jq` / your package manager).
- **Cowork** (optional): macOS, the Claude desktop app, tasks linked to your Mac, and the **Control your Mac** extension enabled. The Mac must be awake with the Claude app running.

Regular chats on claude.ai cannot drive the light: they do not run plugin hooks.

## Install

In Claude Code:

```
/plugin marketplace add swapanchhabra/hue-status-light
/plugin install hue-status-light@hue-status-light
```

From a shell: `claude plugin marketplace add swapanchhabra/hue-status-light` then `claude plugin install hue-status-light@hue-status-light`.

In the Claude desktop app: click **+** next to the prompt box → **Plugins** → **Add marketplace** → `swapanchhabra/hue-status-light` → add **hue-status-light**.

## Set up

Run **`/hue-setup`** (or ask Claude to "set up my Hue status light"). Claude will:

1. find your Hue Bridge and ask you to confirm it,
2. ask you to press the bridge's link button to pair,
3. list your colour lights and let you pick one (or a room),
4. show a short colour test.

## What it runs and what it sends

- **Claude Code:** the plugin's hooks run `scripts/hue-status.sh` (and `scripts/hue-test-check.sh` after Bash commands, to spot failed test runs) on your computer.
- **Cowork:** a hooks module runs `~/.claude/hue/hue-status.sh` on your linked Mac through the Control your Mac extension (`osascript` → `do shell script`). It runs only that script, with a session id and an event name.
- **Network:** plain HTTP requests to your Hue Bridge on your local network, nothing else. During setup, `discover` also asks `https://discovery.meethue.com` (Signify's public bridge finder) for bridges on your network. No data is sent to the author or any other service.
- **Files:** everything lives in `~/.claude/hue/` — `config` (bridge IP, bridge username, chosen light; mode 600), `sessions/` (one small state file per session), and copies of the scripts. The bridge username is never printed or sent anywhere except to your bridge.
- Hooks never block Claude: every script exits 0 and bridge requests time out after 3 seconds.

## Useful commands

```
~/.claude/hue/hue-status.sh status   # what every session is doing
~/.claude/hue/hue-status.sh reset    # forget all sessions, light off
~/.claude/hue/hue-setup.sh test      # colour test
```

Re-run `/hue-setup` to pick another light or pair a new bridge.

## Uninstall

Uninstall the plugin (`/plugin uninstall hue-status-light`), then delete `~/.claude/hue/`. To revoke the bridge pairing, remove "claude#statuslight" in the Hue app (Settings → Apps / Connected apps).

## How it works

`hue-status.sh` stores each session's latest state (`working`, `question`, `permission`, `failed`, `done`) with a timestamp, recomputes the most urgent one across all sessions on every event, and sets the light through the Hue API v1. Flashes use the bridge's own `lselect` alert; a short one-off background timer restores the steady colour after 5 seconds. Failed tests are detected from the command (pytest, jest, vitest, go test, cargo test, npm/pnpm/yarn test, mvn, gradle, …) plus a non-zero exit code or failure text in the output.

## License

MIT
