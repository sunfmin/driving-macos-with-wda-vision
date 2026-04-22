#!/bin/bash
# Mac2 (WebDriverAgentMac) helper for Claude Code vision-based testing
# Goes through Appium on :4723. Session id is cached in /tmp/mac2.sid so
# Claude Code can run one command per step without juggling state.
#
# Usage: ./mac2.sh <command> [args...]
#   start <bundleId>           — boot Mac2 session for a macOS app
#   screenshot [path]          — write PNG (default /tmp/mac_screen.png) and print path
#   source [format]            — dump element tree (format: xml|description, default xml)
#   click <strategy> <value>   — find element by strategy/value and click
#   type  <strategy> <value> <text>
#   drag  <fromX> <fromY> <toX> <toY> [duration=0.3]
#                              — clickAndDrag at absolute screen coordinates
#   wait  <strategy> <value> [timeout=10]
#                              — poll until element exists; exits 0 when found, 1 on timeout
#   click-at <x> <y>           — macos: click at absolute screen coordinates
#   keys <key> [key ...]       — macos: keys; each key may be "Return", "a", "cmd+n", ...
#   applescript <command>      — macos: appleScript escape hatch; prints stdout
#   launch <bundleId>          — macos: launchApp (reuses existing session)
#   activate <bundleId>        — macos: activateApp
#   session-alive              — exits 0 if cached session still valid, 1 otherwise
#   status                     — GET /status
#   stop                       — DELETE current session (+ kills WDA Runner)
#
# Locator strategies (ranked fastest → slowest):
#   accessibility id  |  class name  |  -ios predicate string  |  -ios class chain  |  xpath

set -euo pipefail

APPIUM="${APPIUM_URL:-http://localhost:4723}"
SID_FILE="${MAC2_SID_FILE:-/tmp/mac2.sid}"

sid() {
  [ -f "$SID_FILE" ] || { echo "no session — run: ./mac2.sh start <bundleId>" >&2; exit 2; }
  cat "$SID_FILE"
}

jq_py() { python3 -c "$1"; }

cmd="${1:-}"; shift || true

case "$cmd" in
  start)
    BUNDLE="${1:?usage: start <bundleId>}"
    # newCommandTimeout = 3600 so idle sessions stay alive for ~1h. Default
    # (60s) makes sessions die between diagnostic steps — every "why did my
    # session disappear?" moment comes from this.
    RESP=$(curl -s -X POST "$APPIUM/session" \
      -H 'Content-Type: application/json' \
      -d "{\"capabilities\": {\"alwaysMatch\": {
            \"platformName\": \"mac\",
            \"appium:automationName\": \"mac2\",
            \"appium:bundleId\": \"$BUNDLE\",
            \"appium:newCommandTimeout\": 3600,
            \"appium:skipAppKill\": true
          }}}")
    S=$(echo "$RESP" | jq_py 'import sys,json; print(json.load(sys.stdin)["value"]["sessionId"])' <<<"$RESP")
    echo "$S" > "$SID_FILE"
    echo "session=$S bundle=$BUNDLE"
    ;;

  stop)
    S=$(sid)
    curl -s -X DELETE "$APPIUM/session/$S" > /dev/null
    rm -f "$SID_FILE"
    # DELETE /session alone leaves WebDriverAgentRunner-Runner.app on screen
    # as a blank window (+ its xcodebuild parent) — kill them so the user's
    # workspace is clean.
    pkill -f "WebDriverAgentRunner-Runner" 2>/dev/null || true
    pkill -f "xcodebuild.*WebDriverAgentMac" 2>/dev/null || true
    echo "session $S stopped (runner + xcodebuild killed)"
    ;;

  status)
    curl -s "$APPIUM/status" | jq_py 'import sys,json; d=json.load(sys.stdin); print(d)'
    ;;

  screenshot)
    S=$(sid); OUT="${1:-/tmp/mac_screen.png}"
    curl -s "$APPIUM/session/$S/screenshot" | \
      python3 -c "import sys,json,base64; open('$OUT','wb').write(base64.b64decode(json.load(sys.stdin)['value']))"
    echo "$OUT"
    ;;

  source)
    S=$(sid); FMT="${1:-xml}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: source\", \"args\": [{\"format\": \"$FMT\"}]}" | \
      jq_py 'import sys,json; print(json.load(sys.stdin)["value"])'
    ;;

  click)
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; print(v.get("ELEMENT") or v["element-6066-11e4-a52e-4f735466cecf"])')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s -X POST "$APPIUM/session/$S/element/$EID/click" > /dev/null
    echo "clicked $STRAT=$VAL eid=$EID"
    ;;

  type)
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"; TEXT="${3:?text}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; print(v.get("ELEMENT") or v["element-6066-11e4-a52e-4f735466cecf"])')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s -X POST "$APPIUM/session/$S/element/$EID/value" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(text=sys.argv[1])))" "$TEXT")" > /dev/null
    echo "typed into $STRAT=$VAL"
    ;;

  click-at)
    S=$(sid); X="${1:?x}"; Y="${2:?y}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: click\", \"args\": [{\"x\": $X, \"y\": $Y}]}" > /dev/null
    echo "clicked at ($X,$Y)"
    ;;

  drag)
    S=$(sid); FX="${1:?fromX}"; FY="${2:?fromY}"; TX="${3:?toX}"; TY="${4:?toY}"; DUR="${5:-0.3}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: clickAndDrag\", \"args\": [{\"duration\": $DUR, \"startX\": $FX, \"startY\": $FY, \"endX\": $TX, \"endY\": $TY}]}" > /dev/null
    echo "dragged ($FX,$FY) → ($TX,$TY) in ${DUR}s"
    ;;

  wait)
    # Poll for an element every 200ms up to `timeout` seconds. Replaces
    # `sleep N` guesses — exits the moment the element exists, so scripts
    # don't pay a fixed wait cost for fast paths.
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"; TIMEOUT="${3:-10}"
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      RESP=$(curl -s -X POST "$APPIUM/session/$S/element" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")")
      FOUND=$(echo "$RESP" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin)["value"]
    eid=v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf")
    print(eid if eid else "")
except Exception:
    print("")')
      if [ -n "$FOUND" ]; then
        echo "found $STRAT=$VAL (eid=$FOUND)"
        exit 0
      fi
      sleep 0.2
    done
    echo "timeout after ${TIMEOUT}s waiting for $STRAT=$VAL" >&2
    exit 1
    ;;

  session-alive)
    [ -f "$SID_FILE" ] || { echo "no cached session"; exit 1; }
    S=$(cat "$SID_FILE")
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$APPIUM/session/$S/title" 2>/dev/null || echo 000)
    case "$HTTP" in
      200) echo "alive ($S)"; exit 0 ;;
      404) echo "dead ($S) — session terminated by Appium"; exit 1 ;;
      *)   echo "unknown (HTTP $HTTP)"; exit 1 ;;
    esac
    ;;

  keys)
    S=$(sid); [ $# -ge 1 ] || { echo "usage: keys <key> [key ...]" >&2; exit 2; }
    BODY=$(python3 -c "import json,sys; print(json.dumps({'script':'macos: keys','args':[{'keys':sys.argv[1:]}]}))" "$@")
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "$BODY" > /dev/null
    echo "keys: $*"
    ;;

  applescript)
    S=$(sid); CMD="${1:?command}"
    BODY=$(python3 -c "import json,sys; print(json.dumps({'script':'macos: appleScript','args':[{'command':sys.argv[1]}]}))" "$CMD")
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "$BODY" | jq_py 'import sys,json; print(json.load(sys.stdin).get("value",""))'
    ;;

  launch)
    S=$(sid); BUNDLE="${1:?bundleId}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: launchApp\", \"args\": [{\"bundleId\": \"$BUNDLE\"}]}" > /dev/null
    echo "launched $BUNDLE"
    ;;

  activate)
    S=$(sid); BUNDLE="${1:?bundleId}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: activateApp\", \"args\": [{\"bundleId\": \"$BUNDLE\"}]}" > /dev/null
    echo "activated $BUNDLE"
    ;;

  ""|help|-h|--help)
    sed -n '2,22p' "$0"
    ;;

  *)
    echo "unknown command: $cmd" >&2
    sed -n '2,22p' "$0" >&2
    exit 2
    ;;
esac
