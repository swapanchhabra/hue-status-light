#!/bin/bash
# Claude Code / Cowork -> Philips Hue status light, shared by many sessions.
#
# Usage: hue-status.sh <command>   (hook JSON on stdin supplies session_id)
#   working   you sent a message: session is busy; clears its red reminder
#   question  Claude asks you a question         -> purple flash, then steady purple
#   waiting   Claude needs a permission approval  -> orange flash, then steady orange
#   tool      a tool finished: unblocks a session that was question/waiting
#   testcheck Claude Code Bash hook: like fail, but only for a failed test run
#   fail      a test run failed this turn (red wins at turn end)
#   done      turn finished: bright GREEN flash, or RED flash + red
#             reminder if a test failed this turn
#   end       session closed: forget it
#   reset     forget all sessions, light off
#   status    print what every session is doing (debugging)
#
# Steady colour = the most urgent state over all live sessions:
#   question (purple) > waiting (orange) > failed (red reminder)
#   > working (dim blue) > done (green) > nothing (off)
# Every flash is FLASH_SECS (5 s) at full brightness; a newer flash replaces
# an older one, and the steady colour always comes back afterwards.
# State lives in $HUE_DIR (default ~/.claude/hue): config, sessions/, flash.
# Only talks to the Hue Bridge named in the config, over the local network.
# Always exits 0 so it never blocks Claude.

HUE_DIR="${HUE_DIR:-$HOME/.claude/hue}"
CONFIG="$HUE_DIR/config"
SDIR="$HUE_DIR/sessions"
FLASH="$HUE_DIR/flash"
LOG="$HUE_DIR/hue.log"
CURL="$(command -v curl || echo /usr/bin/curl)"

STALE_SECS=${STALE_SECS:-10800}   # ignore sessions silent for 3 h
FLASH_SECS=${FLASH_SECS:-5}

C_GREEN="0.17,0.70"
C_ORANGE="0.55,0.41"
C_RED="0.675,0.322"
C_PURPLE="0.27,0.12"
C_BLUE="0.16,0.07"

[ -r "$CONFIG" ] || exit 0
# shellcheck disable=SC1090
. "$CONFIG"
[ -n "$BRIDGE_IP" ] && [ -n "$HUE_USER" ] && [ -n "$TARGET_ID" ] || exit 0
mkdir -p "$SDIR"

case "$TARGET" in
  group) URL="http://$BRIDGE_IP/api/$HUE_USER/groups/$TARGET_ID/action" ;;
  *)     URL="http://$BRIDGE_IP/api/$HUE_USER/lights/$TARGET_ID/state" ;;
esac

CMD="$1"
NOW=$(date +%s)

# --- session id from hook stdin -------------------------------------------
SESSION="default"
case "$CMD" in status|reset|"") NOSTDIN=1 ;; esac
if [ -z "$NOSTDIN" ] && [ ! -t 0 ]; then
  INPUT="$(cat 2>/dev/null)"
  if [ -n "$INPUT" ]; then
    SID="$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ -n "$SID" ] && SESSION="$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-')"
  fi
fi
SF="$SDIR/$SESSION"

# --- testcheck: Claude Code PostToolUse / PostToolUseFailure hook for Bash --
# Counts as "fail" only when the command looks like a test run AND it failed:
# a non-zero exit (not a user interrupt), or failure text in the output.
# Needs jq (built into macOS 15+); without it failed tests are not detected.
if [ "$CMD" = testcheck ]; then
  JQ="$(command -v jq || true)"
  [ -n "$JQ" ] && [ -n "$INPUT" ] || exit 0
  TCMD="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null)"
  [ -n "$TCMD" ] || exit 0
  TEST_RE='(^|[;&|[:space:](])(pytest|py\.test|jest|vitest|mocha|ava|playwright test|cypress run|go test|cargo (test|nextest)|ctest|rspec|phpunit|dotnet test|swift test|tox|nox|(npm|pnpm|yarn|bun)( run)? test([:[:space:]]|$)|npx (jest|vitest|mocha|playwright)|python[0-9.]* -m (pytest|unittest)|(\./)?gradlew?[^;&|]* (test|check)|mvn[^;&|]* (test|verify)|xcodebuild[^;&|]* test|make[^;&|]* (test|check))'
  printf '%s' "$TCMD" | grep -Eq "$TEST_RE" || exit 0
  EVENT="$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null)"
  if [ "$EVENT" = "PostToolUseFailure" ]; then
    [ "$(printf '%s' "$INPUT" | "$JQ" -r '.is_interrupt // false' 2>/dev/null)" = "true" ] && exit 0
  else
    OUT="$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_response.stdout?, .tool_response.stderr?, (.tool_response|strings)?] | map(select(.)) | join("\n")' 2>/dev/null)"
    FAIL_RE='(\b[1-9][0-9]* (failed|failing|failures?)\b|^FAIL[[:space:]:]|--- FAIL|test result: FAILED|^FAILED |BUILD FAILURE|Tests run:.*Failures: [1-9])'
    printf '%s' "$OUT" | grep -Eq "$FAIL_RE" || exit 0
  fi
  CMD=fail
fi

# --- helpers -----------------------------------------------------------------
put() {
  "$CURL" -s -m 3 -X PUT -d "$1" "$URL" >/dev/null 2>&1 \
    || echo "$(date '+%F %T') PUT failed: $1" >> "$LOG"
}

get_state() {   # -> sets ST and TS for this session
  ST=none; TS=0
  [ -f "$SF" ] && read -r ST TS < "$SF"
}

set_state() {
  printf '%s %s\n' "$1" "$NOW" > "$SF.tmp.$$" && mv -f "$SF.tmp.$$" "$SF"
}

steady_state() {   # most urgent state over all live sessions
  best=none; rank=0
  for f in "$SDIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.turnfail|*.tmp.*) continue ;; esac
    read -r st ts < "$f"
    if [ $((NOW - ${ts:-0})) -gt "$STALE_SECS" ]; then
      rm -f "$f" "$f.turnfail"; continue
    fi
    case "$st" in
      question) r=5 ;; permission) r=4 ;; failed) r=3 ;;
      working) r=2 ;; done) r=1 ;; *) r=0 ;;
    esac
    [ "$r" -gt "$rank" ] && { rank=$r; best=$st; }
  done
  echo "$best"
}

body_for() {
  case "$1" in
    question)   echo "{\"on\":true,\"bri\":200,\"xy\":[$C_PURPLE],\"alert\":\"none\"}" ;;
    permission) echo "{\"on\":true,\"bri\":200,\"xy\":[$C_ORANGE],\"alert\":\"none\"}" ;;
    failed)     echo "{\"on\":true,\"bri\":200,\"xy\":[$C_RED],\"alert\":\"none\"}" ;;
    working)    echo "{\"on\":true,\"bri\":60,\"xy\":[$C_BLUE],\"alert\":\"none\"}" ;;
    done)       echo "{\"on\":true,\"bri\":200,\"xy\":[$C_GREEN],\"alert\":\"none\"}" ;;
    *)          echo '{"on":false,"alert":"none"}' ;;
  esac
}

flash_active() {
  [ -f "$FLASH" ] || return 1
  read -r _tok fts < "$FLASH"
  [ $((NOW - ${fts:-0})) -le $((FLASH_SECS + 5)) ]
}

apply_steady() {   # $1 = force (ignore a running flash)
  if [ "$1" != force ] && flash_active; then return; fi
  rm -f "$FLASH"
  put "$(body_for "$(steady_state)")"
}

flash() {   # $1 = xy
  tok="$NOW-$$-$RANDOM"
  printf '%s %s\n' "$tok" "$NOW" > "$FLASH"
  put "{\"on\":true,\"bri\":254,\"xy\":[$1],\"alert\":\"lselect\"}"
  # one-off timer in the background: after FLASH_SECS, unless a newer flash
  # took over, show the steady colour again
  (
    sleep "$FLASH_SECS"
    NOW=$(date +%s)
    [ -f "$FLASH" ] || exit 0
    read -r cur _ts < "$FLASH"
    [ "$cur" = "$tok" ] || exit 0
    apply_steady force
  ) </dev/null >/dev/null 2>&1 &
}

# --- commands ----------------------------------------------------------------
case "$CMD" in
  working)
    rm -f "$SF.turnfail"
    set_state working
    apply_steady
    ;;
  question)
    set_state question
    flash "$C_PURPLE"
    ;;
  waiting)
    get_state
    # a question also raises a permission-style notice: keep it purple
    if [ "$ST" = question ] && [ $((NOW - TS)) -lt 10 ]; then exit 0; fi
    set_state permission
    flash "$C_ORANGE"
    ;;
  tool)
    get_state
    case "$ST" in
      question|permission)
        if [ -f "$SF.turnfail" ]; then set_state failed; else set_state working; fi
        apply_steady ;;
    esac
    ;;
  fail)
    touch "$SF.turnfail"
    set_state failed
    apply_steady
    ;;
  done)
    if [ -f "$SF.turnfail" ]; then
      rm -f "$SF.turnfail"
      set_state failed          # reminder stays until your next message
      flash "$C_RED"
    else
      set_state done
      flash "$C_GREEN"
    fi
    ;;
  end)
    rm -f "$SF" "$SF.turnfail"
    apply_steady
    ;;
  reset)
    rm -f "$SDIR"/* "$FLASH" 2>/dev/null
    put '{"on":false,"alert":"none"}'
    ;;
  status)
    echo "steady: $(steady_state)"
    for f in "$SDIR"/*; do
      [ -f "$f" ] || continue
      case "$f" in *.turnfail|*.tmp.*) continue ;; esac
      read -r st ts < "$f"
      echo "  $(basename "$f")  $st  $((NOW - ts))s ago$([ -f "$f.turnfail" ] && echo '  (test failed this turn)')"
    done
    flash_active && echo "  flash running"
    ;;
  *)
    echo "usage: $(basename "$0") working|question|waiting|tool|testcheck|fail|done|end|reset|status" >&2
    ;;
esac
exit 0
