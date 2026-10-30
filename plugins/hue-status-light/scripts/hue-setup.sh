#!/bin/bash
# hue-status-light setup helper. Run on the computer that is on the same
# network as the Hue Bridge (for Cowork: the Mac linked to your tasks).
#
#   hue-setup.sh check                 what is installed / configured
#   hue-setup.sh install               copy the scripts into ~/.claude/hue
#   hue-setup.sh discover              find Hue Bridges on the network
#   hue-setup.sh bridge-info <ip>      name and model of a bridge
#   hue-setup.sh pair <ip>             start pairing (press the bridge's link
#                                      button within 2 minutes)
#   hue-setup.sh pair-status [secs]    wait up to secs (default 15) for pairing
#   hue-setup.sh lights                list lights; only colour lights work
#   hue-setup.sh groups                list rooms / zones
#   hue-setup.sh target light|group <id>
#   hue-setup.sh test                  show each colour briefly, then restore
#
# The bridge username is written only to ~/.claude/hue/config (mode 600) and
# is never printed. Network traffic: the bridge on your LAN, plus
# https://discovery.meethue.com for `discover`.

HUE_DIR="${HUE_DIR:-$HOME/.claude/hue}"
CONFIG="$HUE_DIR/config"
PAIR_STATUS="$HUE_DIR/.pair-status"
HERE="$(cd "$(dirname "$0")" && pwd)"
CURL="$(command -v curl || echo /usr/bin/curl)"
JQ="$(command -v jq || true)"

umask 077
mkdir -p "$HUE_DIR"
chmod 700 "$HUE_DIR" 2>/dev/null

die() { echo "ERROR: $*" >&2; exit 1; }

valid_ip() { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?$'; }

set_kv() {   # set_kv KEY VALUE  (keeps the other lines of the config)
  touch "$CONFIG"
  grep -v "^$1=" "$CONFIG" > "$CONFIG.tmp" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >> "$CONFIG.tmp"
  mv -f "$CONFIG.tmp" "$CONFIG"
  chmod 600 "$CONFIG"
}

load_config() {
  [ -r "$CONFIG" ] || die "no config yet: run discover, pair and target first"
  # shellcheck disable=SC1090
  . "$CONFIG"
  [ -n "$BRIDGE_IP" ] && [ -n "$HUE_USER" ] || die "not paired yet: run pair <ip>"
  API="http://$BRIDGE_IP/api/$HUE_USER"
}

need_jq() { [ -n "$JQ" ] || die "jq is needed (built into macOS 15+; otherwise: brew install jq)"; }

case "$1" in
  check)
    echo "os: $(uname -s) $(uname -r)"
    echo "curl: ${CURL}"
    echo "jq: ${JQ:-MISSING (needed for setup and failed-test detection)}"
    echo "dir: $HUE_DIR"
    for f in hue-status.sh hue-setup.sh; do
      [ -x "$HUE_DIR/$f" ] && echo "installed: $f" || echo "not installed: $f"
    done
    if [ -r "$CONFIG" ]; then
      # shellcheck disable=SC1090
      . "$CONFIG"
      echo "bridge: ${BRIDGE_IP:-none}"
      echo "paired: $([ -n "$HUE_USER" ] && echo yes || echo no)"
      echo "target: ${TARGET:-none} ${TARGET_ID}"
    else
      echo "config: none"
    fi
    ;;

  install)
    for f in hue-status.sh hue-setup.sh; do
      [ -f "$HERE/$f" ] || die "missing $HERE/$f"
      if [ "$HERE" != "$HUE_DIR" ]; then cp -f "$HERE/$f" "$HUE_DIR/$f"; fi
      chmod 755 "$HUE_DIR/$f"
    done
    rm -f "$HUE_DIR/hue-test-check.sh"   # merged into hue-status.sh in 1.0.1
    echo "installed into $HUE_DIR"
    ;;

  discover)
    FOUND=""
    D="$("$CURL" -s -m 6 https://discovery.meethue.com/ 2>/dev/null)"
    IPS="$(printf '%s' "$D" | grep -o '"internalipaddress"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ "$(uname -s)" = Darwin ] && command -v dns-sd >/dev/null; then
      T="$(mktemp)"
      ( dns-sd -B _hue._tcp local. > "$T" 2>&1 & P=$!; sleep 4; kill $P 2>/dev/null ) 2>/dev/null
      N="$(grep ' Add ' "$T" | grep '_hue._tcp' | sed 's/.*_hue._tcp\.[[:space:]]*//' | head -n 3 | paste -sd ';' -)"
      [ -n "$N" ] && echo "bonjour: $N"
      rm -f "$T"
    fi
    for ip in $IPS; do
      INFO="$("$CURL" -s -m 4 "http://$ip/api/config" 2>/dev/null)"
      NAME="$(printf '%s' "$INFO" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
      MODEL="$(printf '%s' "$INFO" | grep -o '"modelid"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
      echo "bridge: $ip  ${NAME:-?}  ${MODEL:-unreachable from here}"
      FOUND=1
    done
    [ -n "$FOUND" ] || echo "no bridge found via discovery.meethue.com; find its IP in the Hue app (Settings > Bridges > i) or your router"
    ;;

  bridge-info)
    valid_ip "$2" || die "usage: bridge-info <ip>"
    "$CURL" -s -m 5 "http://$2/api/config" || die "bridge not reachable at $2"
    echo
    ;;

  pair)
    valid_ip "$2" || die "usage: pair <ip>"
    "$CURL" -s -m 5 "http://$2/api/config" | grep -q '"bridgeid"' || die "no Hue Bridge answers at $2"
    echo WAITING > "$PAIR_STATUS"
    (
      for _ in $(seq 1 60); do
        R="$("$CURL" -s -m 3 -X POST -d '{"devicetype":"claude#statuslight"}' "http://$2/api")"
        U="$(printf '%s' "$R" | grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
        if [ -n "$U" ]; then
          set_kv BRIDGE_IP "$2"; set_kv HUE_USER "$U"
          echo PAIRED > "$PAIR_STATUS"; exit 0
        fi
        sleep 2
      done
      echo TIMEOUT > "$PAIR_STATUS"
    ) </dev/null >/dev/null 2>&1 &
    echo "STARTED: press the round link button on the bridge within 2 minutes"
    ;;

  pair-status)
    W="${2:-15}"
    for _ in $(seq 1 "$W"); do
      S="$(cat "$PAIR_STATUS" 2>/dev/null)"
      [ "$S" = WAITING ] || break
      sleep 1
    done
    S="$(cat "$PAIR_STATUS" 2>/dev/null)"
    echo "${S:-NOT STARTED}"
    [ "$S" = PAIRED ] || [ "$S" = TIMEOUT ] && rm -f "$PAIR_STATUS"
    ;;

  lights)
    load_config; need_jq
    printf 'ID\tCOLOUR\tREACHABLE\tTYPE\tNAME\n'
    "$CURL" -s -m 5 "$API/lights" | "$JQ" -r '
      to_entries | sort_by(.key|tonumber)[] |
      [ .key,
        (if ((.value.state.xy != null) or (.value.capabilities.control.colorgamuttype != null)) then "yes" else "no" end),
        (if .value.state.reachable then "yes" else "no" end),
        .value.type, .value.name ] | @tsv' || die "could not read lights"
    ;;

  groups)
    load_config; need_jq
    LJSON="$("$CURL" -s -m 5 "$API/lights")"
    printf 'ID\tTYPE\tCOLOUR LIGHTS\tNAME\n'
    "$CURL" -s -m 5 "$API/groups" | "$JQ" -r --argjson L "$LJSON" '
      to_entries | sort_by(.key|tonumber)[] |
      [ .key, .value.type,
        ("\([.value.lights[] | select($L[.].state.xy != null)] | length)/\(.value.lights | length)"),
        .value.name ] | @tsv' || die "could not read groups"
    ;;

  target)
    load_config
    case "$2" in light|group) ;; *) die "usage: target light|group <id>" ;; esac
    printf '%s' "$3" | grep -Eq '^[0-9]+$' || die "usage: target light|group <id>"
    if [ "$2" = light ]; then
      "$CURL" -s -m 5 "$API/lights/$3" | grep -q '"xy"' || die "light $3 does not exist or has no colour"
    else
      "$CURL" -s -m 5 "$API/groups/$3" | grep -q '"lights"' || die "group $3 does not exist"
    fi
    set_kv TARGET "$2"; set_kv TARGET_ID "$3"
    echo "target set: $2 $3"
    ;;

  test)
    load_config; need_jq
    [ -n "$TARGET_ID" ] || die "no target yet: run target light|group <id>"
    if [ "$TARGET" = group ]; then
      URL="$API/groups/$TARGET_ID/action"; PREV="$("$CURL" -s -m 5 "$API/groups/$TARGET_ID" | "$JQ" -c '.action | {on,bri,xy}')"
    else
      URL="$API/lights/$TARGET_ID/state"; PREV="$("$CURL" -s -m 5 "$API/lights/$TARGET_ID" | "$JQ" -c '.state | {on,bri,xy}')"
    fi
    for c in "green 0.17,0.70" "orange 0.55,0.41" "purple 0.27,0.12" "red 0.675,0.322" "blue 0.16,0.07"; do
      set -- $c
      "$CURL" -s -m 3 -X PUT -d "{\"on\":true,\"bri\":200,\"xy\":[$2]}" "$URL" >/dev/null
      echo "showing $1"; sleep 1.5
    done
    [ -n "$PREV" ] && "$CURL" -s -m 3 -X PUT -d "$PREV" "$URL" >/dev/null
    echo "restored previous state"
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
