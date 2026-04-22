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
#   click-at <x> <y>           — macos: click at absolute screen coordinates
#   keys <key> [key ...]       — macos: keys; each key may be "Return", "a", "cmd+n", ...
#   applescript <command>      — macos: appleScript escape hatch; prints stdout
#   launch <bundleId>          — macos: launchApp (reuses existing session)
#   activate <bundleId>        — macos: activateApp
#   status                     — GET /status
#   stop                       — DELETE current session
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
    RESP=$(curl -s -X POST "$APPIUM/session" \
      -H 'Content-Type: application/json' \
      -d "{\"capabilities\": {\"alwaysMatch\": {
            \"platformName\": \"mac\",
            \"appium:automationName\": \"mac2\",
            \"appium:bundleId\": \"$BUNDLE\"
          }}}")
    S=$(echo "$RESP" | jq_py 'import sys,json; print(json.load(sys.stdin)["value"]["sessionId"])' <<<"$RESP")
    echo "$S" > "$SID_FILE"
    echo "session=$S bundle=$BUNDLE"
    ;;

  stop)
    S=$(sid)
    curl -s -X DELETE "$APPIUM/session/$S" > /dev/null
    rm -f "$SID_FILE"
    echo "session $S stopped"
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
      -d "$(python3 -c "import json,sys; print(json.dumps({'using':sys.argv[1],'value':sys.argv[2]}))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; print(v.get("ELEMENT") or v["element-6066-11e4-a52e-4f735466cecf"])')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s -X POST "$APPIUM/session/$S/element/$EID/click" > /dev/null
    echo "clicked $STRAT=$VAL eid=$EID"
    ;;

  type)
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"; TEXT="${3:?text}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps({'using':sys.argv[1],'value':sys.argv[2]}))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; print(v.get("ELEMENT") or v["element-6066-11e4-a52e-4f735466cecf"])')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s -X POST "$APPIUM/session/$S/element/$EID/value" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps({'text':sys.argv[1]}))" "$TEXT")" > /dev/null
    echo "typed into $STRAT=$VAL"
    ;;

  click-at)
    S=$(sid); X="${1:?x}"; Y="${2:?y}"
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "{\"script\": \"macos: click\", \"args\": [{\"x\": $X, \"y\": $Y}]}" > /dev/null
    echo "clicked at ($X,$Y)"
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
