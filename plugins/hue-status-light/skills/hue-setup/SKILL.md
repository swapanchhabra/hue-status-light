---
name: hue-setup
description: Set up the hue-status-light plugin - find the Philips Hue Bridge, pair with it, pick a colour light and test it. Use when the person runs /hue-setup, asks to set up, re-pair, change or test their Hue status light, or when the plugin says it is not set up yet.
---

# Set up the Hue status light

Goal: a paired Hue Bridge, one colour light (or room) chosen as the status light, and the scripts installed in `~/.claude/hue/` on the computer that is on the same network as the bridge. Work step by step and check in with the person where noted. Keep messages short.

The helper script is `scripts/hue-setup.sh` in this plugin: two folders up from this skill's base directory (`<base>/../../scripts/`). Its subcommands: `check`, `install`, `discover`, `bridge-info <ip>`, `pair <ip>`, `pair-status [secs]`, `lights`, `groups`, `target light|group <id>`, `test`.

Rules:
- Never print, echo or `cat` `~/.claude/hue/config`: it holds the bridge username, which works like a password on the local network. Use `hue-setup.sh check` to see what is configured.
- Only colour-capable lights work (COLOUR = yes in `lights`).
- Do not edit the person's `settings.json` without asking.

## 0. Where to run the commands

- **Claude Code on the computer itself** (macOS or Linux, same network as the bridge): run commands with the Bash tool, e.g. `bash "<base>/../../scripts/hue-setup.sh" check`. After step 1, use `~/.claude/hue/hue-setup.sh`.
- **Cowork** (the session runs in the cloud or a VM and cannot reach the bridge): the commands must run on the person's **Mac** through the `Control your Mac` osascript tool (`mcp__remote-devices__Control_your_Mac__osascript`, loaded with ToolSearch if deferred), as `do shell script "~/.claude/hue/hue-setup.sh <subcommand>"`. If no such tool exists, tell the person that Cowork needs a task linked to their Mac with the "Control your Mac" extension enabled, and stop. The Cowork part works on macOS only.

## 1. Install the scripts

- Claude Code: `bash "<base>/../../scripts/hue-setup.sh" install`.
- Cowork: copy the two files `hue-status.sh` and `hue-setup.sh` from `<base>/../../scripts/` to the Mac. For each file, base64-encode it in your own shell (`base64 -w0 <file>`) and run on the Mac:
  `do shell script "mkdir -p ~/.claude/hue && chmod 700 ~/.claude/hue && echo '<BASE64>' | base64 -D > ~/.claude/hue/<name> && chmod 755 ~/.claude/hue/<name>"`
- Then run `check`. If jq is missing, say failed-test detection and setup need it (`brew install jq`; macOS 15+ has it built in).
- If `check` shows the bridge is already paired and a target is set, ask whether to keep it (go to step 5) or set up again.

## 2. Find the bridge — check in

Run `discover`. Show what it found (IP, name, model) and ask the person to confirm the bridge (AskUserQuestion). If nothing is found, ask for the IP (Hue app → Settings → My Hue System → Bridge → i).

## 3. Pair — check in

1. Run `pair <ip>`. It polls the bridge in the background for 2 minutes.
2. Ask the person to press the round link button on top of the bridge, then tell you (AskUserQuestion: "Pressed it" / "Not near it").
3. Run `pair-status 20` until it prints `PAIRED` (or `TIMEOUT`: offer to start `pair` again).

## 4. Choose the light — check in

Run `lights` (and `groups` if they might prefer a room). Show the colour-capable lights with ID, name and whether they are reachable, and ask which one to use. Unreachable lights are usually switched off at the wall. A group is fine too; white-only lights in it simply will not change colour. Then run `target light <id>` or `target group <id>`.

## 5. Test — check in

Run `test`: the light shows green, orange, purple, red and blue for 1.5 s each, then goes back to how it was. Ask whether they saw it.

## 6. Finish

Tell the person, in a few lines:
- The colours: purple = Claude is asking you a question, orange = a permission prompt, red = a test failed (until you reply), dim blue = working, green = all done. Each event flashes at full brightness for 5 s first. With several sessions the light shows whichever needs them most.
- Claude Code: new sessions on this computer use it automatically (the plugin's hooks). Cowork: tasks linked to this Mac use it while the Mac is awake with the Claude app running.
- `~/.claude/hue/hue-status.sh status` shows what each session is doing; `~/.claude/hue/hue-status.sh reset` turns the light off and forgets all sessions.

If `~/.claude/settings.json` already has hooks that run `~/.claude/hue/hue-status.sh` (from a manual setup), every event would fire twice: offer to remove those entries (back the file up first) and only do it if the person says yes.
