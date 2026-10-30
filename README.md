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

Short version: the plugin reads a few session events, turns each into one of seven words (`working`, `question`, `waiting`, `tool`, `fail`, `done`, `end`), and sends that word plus a session id to a script on your own computer, which sets your Hue light over your local network. Nothing is sent to the author or any other service, and the plugin never answers, changes or blocks anything Claude does.

### Claude Code: shell hooks

`hooks/hooks.json` runs one script, `scripts/hue-status.sh`, by its literal path under `${CLAUDE_PLUGIN_ROOT}`:

| Hook | Command | Why |
|---|---|---|
| UserPromptSubmit | `hue-status.sh working` | you sent a message |
| PreToolUse (AskUserQuestion) | `hue-status.sh question` | Claude asks you a question |
| Notification (permission_prompt / elicitation_dialog) | `hue-status.sh waiting` / `question` | a prompt waits for you |
| PostToolUse, PostToolUseFailure (Bash) | `hue-status.sh testcheck` | was this a failed test run? |
| PostToolUse, PostToolUseFailure (all tools) | `hue-status.sh tool` | a prompt you answered is over |
| Stop | `hue-status.sh done` | the turn finished |
| SessionEnd | `hue-status.sh end` | the session closed |

The script reads the hook's JSON from stdin: `session_id`, and for `testcheck` the Bash command and its output, which it only matches against test-runner and failure patterns. It runs no other script and installs nothing. It always exits 0, and each bridge request times out after 3 seconds, so it never blocks Claude.

### Cowork: hooks module (`hooks/register.ts`)

Cowork runs in the cloud or a VM, which cannot reach a bridge on your home network, so the module asks your linked Mac to run the script instead.

- **The one tool it calls itself:** `osascript` from the **Control your Mac** extension (MCP server `remote-devices`, tool `Control_your_Mac__osascript`). Each call runs exactly `do shell script` of `~/.claude/hue/hue-status.sh <word>` with `{"session_id":"cowork-<id>"}` on stdin, nothing else. It is called when you send a message, when Claude asks a question, when a permission prompt is shown, after a tool call that followed one of those prompts, when a Bash test run fails, when a turn ends, and when the session ends. The model never sees or triggers these calls. If no Mac is linked the call fails quietly and the module pauses for 60 seconds.
- **What it reads:** that a prompt was submitted (not its text); the name of each tool called; for Bash tools (`Bash`, `mcp__remote-devices__device_bash`) the command and the result text, matched inside the module against test-runner and failure patterns; whether a turn ended in the main conversation; the session id.
- **What it sends, and where:** only the event word and `cowork-<session id>`, to the script on your own Mac. No conversation text, commands, tool output or file contents leave the module. From the Mac, the script sends only light commands (on, brightness, colour, blink) to your Hue Bridge over plain HTTP on your local network.
- **Permission hook:** the module watches `PermissionRequest` (and the `Notification` event) only to turn the light orange while a permission prompt is shown. It decides nothing: it never allows, denies or asks, and always passes the request on unchanged to you.
- **Tool calls:** it watches every tool call only to read the result after the tool has run, and returns that result unchanged. It never denies or rewrites a call.

### Setup (`/hue-setup`)

The skill runs `scripts/hue-setup.sh` on your computer (in Cowork: on the linked Mac through the same osascript tool). It copies `hue-status.sh` and `hue-setup.sh` into `~/.claude/hue/`, finds the bridge (Bonjour and `https://discovery.meethue.com`, Signify's public bridge finder), pairs with it after you press the link button, lists your lights and runs a short colour test.

### Files

Everything lives in `~/.claude/hue/`: `config` (bridge IP, bridge username, chosen light; mode 600), `sessions/` (one small state file per session), `flash` (the current flash), and the copied scripts. The bridge username is never printed and goes only to your bridge.

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
