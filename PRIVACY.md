# Privacy policy — Hue Status Light

_Last updated: 30 October 2026_

Hue Status Light is an open-source plugin for Claude Code and Cowork. It is built so that **none of your data leaves your own computer and home network.**

## What the plugin collects

Nothing. The author runs no servers and receives no data. There is no analytics, telemetry, crash reporting or tracking of any kind.

## What it processes, and where

- **Session events** (a message was sent, Claude asked a question, a permission prompt is shown, a tool finished, a turn or session ended). These are turned into one of eight status words and a session id. They are processed only on your computer, or for Cowork, only if you turn on the plugin option `cowork_mac_light`, inside your own session and then on your linked Mac.
- **Bash commands and their output**, only to check whether a test run failed. This check happens in place; the command and output are not stored or sent anywhere.
- **Your Hue Bridge address, bridge username and chosen light**, stored in `~/.claude/hue/config` on your computer (file mode 600). The bridge username is sent only to your own bridge.

## Network connections

- Plain HTTP requests from your computer to **your own Hue Bridge on your local network**, to change the light.
- During setup only: a request to `https://discovery.meethue.com`, the public Hue Bridge finder run by Signify, to find bridges on your network. That service sees your public IP address as for any web request; see Signify's own privacy notice.

No other connections are made.

## Data stored on your computer

Everything lives in `~/.claude/hue/`: the config file, one small state file per session (a status word and a timestamp, ignored after 3 hours and removed when the session ends), and copies of the plugin's scripts. Delete that folder to remove all of it.

## Contact

Questions: open an issue at https://github.com/swapanchhabra/hue-status-light/issues
