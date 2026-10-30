#!/bin/bash
# Tests for the plugin's shell scripts, against a fake Hue Bridge: a `curl`
# stub that logs each request instead of sending it.
# Usage: bash tests/run.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/hue-status-light/scripts"
TESTS="$ROOT/tests"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HUE_DIR/curl.log"
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FLASH_SECS=0

FAILED=0
PASSED=0
check() {   # check <description> <command...>
  local d="$1"; shift
  if "$@"; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); echo "FAIL $d"; fi
}

fresh() {   # a new, configured ~/.claude/hue
  export HUE_DIR="$WORK/hue.$RANDOM$RANDOM"
  mkdir -p "$HUE_DIR"
  printf 'BRIDGE_IP=10.0.0.2\nHUE_USER=abc-123\nTARGET=light\nTARGET_ID=1\n' > "$HUE_DIR/config"
}

hook() {    # hook <command> [session]: run hue-status.sh as a hook would
  printf '{"session_id":"%s"}' "${2:-s1}" | "$SCRIPTS/hue-status.sh" "$1"
}

state() { cut -d' ' -f1 "$HUE_DIR/sessions/${1:-s1}" 2>/dev/null; }

last_put() { tail -n 1 "$HUE_DIR/curl.log" 2>/dev/null; }

# --- test-run detection, end to end through `hue-status.sh testcheck` -------
while IFS="$(printf '\t')" read -r want cmd; do
  case "$want" in yes|no) ;; *) continue ;; esac
  fresh
  jq -nc --arg c "$cmd" '{session_id:"s1",hook_event_name:"PostToolUseFailure",tool_input:{command:$c},error:"Exit code 1"}' \
    | "$SCRIPTS/hue-status.sh" testcheck
  if [ "$want" = yes ]; then
    check "failing '$cmd' counts as a failed test" [ "$(state)" = failed ]
  else
    check "failing '$cmd' is not a test run" [ -z "$(state)" ]
  fi
done < "$TESTS/commands.txt"

fresh
jq -nc '{session_id:"s1",hook_event_name:"PostToolUse",tool_input:{command:"pytest | tail"},tool_response:{stdout:"== 2 failed, 5 passed ==",stderr:""}}' \
  | "$SCRIPTS/hue-status.sh" testcheck
check "failure text in the output of an exit-0 test run counts" [ "$(state)" = failed ]

fresh
jq -nc '{session_id:"s1",hook_event_name:"PostToolUseFailure",tool_input:{command:"pytest"},is_interrupt:true}' \
  | "$SCRIPTS/hue-status.sh" testcheck
check "an interrupted test run does not count" [ -z "$(state)" ]

# --- state machine ------------------------------------------------------------
fresh
hook working
check "working is dim blue" grep -q '"bri":60' "$HUE_DIR/curl.log"
hook waiting
check "permission prompt -> permission" [ "$(state)" = permission ]
check "permission prompt flashes orange" grep -q '"xy":\[0.55,0.41\],"alert":"lselect"' "$HUE_DIR/curl.log"
hook tool
check "a tool finishing unblocks the session" [ "$(state)" = working ]
hook done
check "done -> done" [ "$(state)" = done ]

fresh
hook working; hook fail; hook done
check "done after a failed test keeps the red reminder" [ "$(state)" = failed ]
hook working
check "your next message clears the red reminder" [ "$(state)" = working ]

fresh
hook question; hook waiting
check "a permission notice right after a question stays purple" [ "$(state)" = question ]

fresh
hook working; hook question; hook idle
check "idle after Esc on a question settles the session" [ "$(state)" = done ]
fresh
hook working; hook waiting; hook idle
check "idle after Esc on a permission prompt settles the session" [ "$(state)" = done ]
fresh
hook working; hook fail; hook idle
check "idle after a failed test keeps the red reminder" [ "$(state)" = failed ]
fresh
hook working; hook done; sleep 1; : > "$HUE_DIR/curl.log"; hook idle
check "idle after a normal finish changes nothing" [ "$(state)" = done ]
check "idle after a normal finish sends nothing" [ ! -s "$HUE_DIR/curl.log" ]

fresh
hook working s1; hook question s2; hook done s1
sleep 1
check "the most urgent session wins the steady colour" grep -q '0.27,0.12\],"alert":"none"' <(last_put)
hook end s2
check "session end forgets the session" [ ! -e "$HUE_DIR/sessions/s2" ]

# Parallel hooks after a Bash call that needed approval: `tool` and `fail`
# race; whatever the order, the session must end up failed.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  fresh
  hook working; hook waiting
  hook tool & hook fail & wait
  check "racing tool/fail ends up failed" [ "$(state)" = failed ]
done

# --- input hardening ----------------------------------------------------------
fresh
printf '{"session_id":"..."}' | "$SCRIPTS/hue-status.sh" working
check "a session id with no safe characters falls back to default" [ "$(state default)" = working ]
left=("$HUE_DIR"/sessions/.[!.]*)
check "no hidden temp files are left behind" [ ! -e "${left[0]}" ]

fresh
printf 'BRIDGE_IP=10.0.0.2\nHUE_USER=x;touch %s/PWNED\nTARGET=light\nTARGET_ID=1\n' "$HUE_DIR" > "$HUE_DIR/config"
hook working
"$SCRIPTS/hue-setup.sh" check >/dev/null 2>&1
"$SCRIPTS/hue-setup.sh" lights >/dev/null 2>&1
check "config values are never run as code" [ ! -e "$HUE_DIR/PWNED" ]
check "a damaged config is ignored" [ ! -e "$HUE_DIR/curl.log" ]

fresh
echo WAITING > "$HUE_DIR/.pair-status"
"$SCRIPTS/hue-setup.sh" pair-status 1 >/dev/null
check "pair-status exits 0 while still waiting" [ $? -eq 0 ]

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
