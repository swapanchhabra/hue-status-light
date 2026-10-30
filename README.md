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
- **Cowork** (optional, off by default): macOS, the Claude desktop app, tasks linked to your Mac, the **Control your Mac** extension enabled, and the plugin option **Cowork: drive the light through your Mac** (`cowork_mac_light`) turned on. To turn it on: `/plugin configure hue-status-light@hue-status-light` in Claude Code, or the plugin's settings in the desktop app. The Mac must be awake with the Claude app running.

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

Short version: the plugin reads a few session events, turns each into one of eight words (`working`, `question`, `waiting`, `tool`, `fail`, `done`, `idle`, `end`), and sends that word plus a session id to a script on your own computer, which sets your Hue light over your local network. Nothing is sent to the author or any other service, and the plugin never answers, changes or blocks anything Claude does.

### Claude Code: shell hooks

`hooks/hooks.json` runs one script, `scripts/hue-status.sh`, by its literal path under `${CLAUDE_PLUGIN_ROOT}`:

| Hook | Command | Why |
|---|---|---|
| UserPromptSubmit | `hue-status.sh working` | you sent a message |
| PreToolUse (AskUserQuestion) | `hue-status.sh question` | Claude asks you a question |
| Notification (permission_prompt / elicitation_dialog) | `hue-status.sh waiting` / `question` | a prompt waits for you |
| Notification (idle_prompt) | `hue-status.sh idle` | Claude has sat idle, e.g. after you pressed Esc |
| PostToolUse, PostToolUseFailure (Bash) | `hue-status.sh testcheck` | was this a failed test run? |
| PostToolUse, PostToolUseFailure (all tools) | `hue-status.sh tool` | a prompt you answered is over |
| Stop | `hue-status.sh done` | the turn finished |
| StopFailure | `hue-status.sh idle` | an API error ended the turn |
| SessionEnd | `hue-status.sh end` | the session closed |

The script reads the hook's JSON from stdin: `session_id`, and for `testcheck` the Bash command and its output, which it only matches against test-runner and failure patterns. It runs no other script and installs nothing. It always exits 0, and each bridge request times out after 3 seconds, so it never blocks Claude.

### Cowork: hooks module (`hooks/register.ts`)

Cowork runs in the cloud or a VM, which cannot reach a bridge on your home network, so the module asks your linked Mac to run the script instead.

**Off unless you turn it on.** The module registers no hooks and calls nothing until you turn on the plugin option `cowork_mac_light` (**Cowork: drive the light through your Mac**). Claude Code sessions on your computer never need it.

**Which tool the module calls itself, and when.** Exactly one: `osascript` from the **Control your Mac** extension (MCP server `remote-devices`, tool `Control_your_Mac__osascript`). The module calls it, not the model; the model never sees or triggers these calls. It calls it once for each of these events:

| Event | Word sent |
|---|---|
| you send a message | `working` |
| Claude asks you a question (AskUserQuestion, or an MCP elicitation) | `question` |
| a permission prompt is shown | `waiting` |
| a tool call finishes after one of those prompts | `tool` |
| a Bash test run fails | `fail` |
| a turn in the main conversation ends | `done`, or `idle` if you interrupted it or an error ended it |
| the session ends | `end` |

If no Mac is linked, the call fails quietly and the module waits 60 seconds before trying again.

**What that call does.** `osascript` is macOS's AppleScript runner, and `do shell script` runs one shell command on your Mac as you. The module's call always runs the same command, `~/.claude/hue/hue-status.sh <word>`, with `{"session_id":"cowork-<id>"}` on stdin. That is the plugin's own `scripts/hue-status.sh`, copied there by `/hue-setup`. It records the word for this session and sets the light; it reads no other files and runs nothing else.

**What the module reads.** From the conversation: that a prompt was submitted (never its text), the name of each tool called, and, for Bash tools (`Bash`, `mcp__remote-devices__device_bash`), the command and its result text, which it only matches against test-runner and failure patterns inside the module. It also reads whether a turn ended in the main conversation, and the session id. It reads no local files: the only local data involved is the script's own state in `~/.claude/hue/` on your Mac, which the script reads, not the module.

**What the module sends, and where.** Only the event word and `cowork-<session id>`, to that script on your own Mac. No message text, commands, tool output or file contents leave the module. From the Mac, the script sends only light commands (on, brightness, colour, blink) to your Hue Bridge over plain HTTP on your local network. Nothing goes to the author or any other service.

**What the permission hook decides, and when.** Nothing. The module watches `PermissionRequest` (and the `Notification` event) only to turn the light orange while a permission prompt is shown. It never allows, denies or asks, and always passes the request on unchanged, so the decision stays with you.

**Tool calls.** The module watches every tool call only to read the result after the tool has run, and returns that result unchanged. It never denies or rewrites a call.

### Setup (`/hue-setup`)

The skill runs `scripts/hue-setup.sh` on your computer (in Cowork: on the linked Mac through the same osascript tool). It copies `hue-status.sh` and `hue-setup.sh` into `~/.claude/hue/` (in Cowork the files are passed to the Mac base64-encoded, only because `do shell script` takes a single line; they are the plugin's own scripts, unchanged), finds the bridge (Bonjour and `https://discovery.meethue.com`, Signify's public bridge finder), pairs with it after you press the link button, lists your lights and runs a short colour test.

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

`hue-status.sh` stores each session's latest state (`working`, `question`, `permission`, `failed`, `done`) with a timestamp, recomputes the most urgent one across all sessions on every event, and sets the light through the Hue API v1. Flashes use the bridge's own `lselect` alert; a short one-off background timer restores the steady colour after 5 seconds. Failed tests are detected from the command (pytest, jest, vitest, go test, cargo test, npm/pnpm/yarn test, mvn, gradle, …, only when it is the command being run, so `which pytest` or `pip install pytest` do not count) plus a non-zero exit code or failure text in the output. A turn that an API error ends settles the light without a flash; so does a turn you stop with Esc, once Claude Code reports the session idle.

## License

MIT. See also the [privacy policy](PRIVACY.md) and [terms of use](TERMS.md).

Philips Hue is a trademark of Signify. This project is independent and not affiliated with Signify or Anthropic.
