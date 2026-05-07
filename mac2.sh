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
#   wait-not <strategy> <value> [timeout=10]
#                              — poll until element disappears; for "dialog dismissed"
#   exists <strategy> <value>  — single-shot probe; exits 0 if found, 1 if not (no polling)
#   attr  <strategy> <value> <attribute>
#                              — print one attribute (AXValue, AXEnabled, AXTitle, …)
#                                so scripts can branch on UI state
#   clear <strategy> <value>   — clear a text field (sendKeys appends; this replaces)
#   set-value <strategy> <value> <text>
#                              — atomic AX value set (CJK-safe; faster than
#                                clear+type for long / non-Latin strings)
#   click-at <x> <y>           — macos: click at absolute screen coordinates
#   keys <key> [key ...]       — macos: keys; each key may be "Return", "a", "cmd+n", ...
#   applescript <command>      — macos: appleScript escape hatch; prints stdout
#   launch <bundleId>          — macos: launchApp (reuses existing session)
#   activate <bundleId>        — macos: activateApp
#   session-alive              — exits 0 if cached session still valid, 1 otherwise
#   status                     — GET /status
#   stop [--hard]              — DELETE current session. By default leaves
#                                the WDA Runner alive so the next start is
#                                fast (~2s). --hard kills it (clean state
#                                but 20–60s rebuild on next start).
#   record start [name]        — capture human input via mac2-recorder; writes
#                                JSONL to /tmp/mac2-record.jsonl. Optional
#                                [--bundle <id>] filters to one app.
#   record stop                — SIGTERM the recorder, run aggregator, emit
#                                journeys/<name>.sh + journeys/<name>.md
#   record status              — print recorder PID + output path, or "idle"
#
# Locator strategies (ranked fastest → slowest):
#   accessibility id  |  class name  |  -ios predicate string  |  -ios class chain  |  xpath

set -euo pipefail

APPIUM="${APPIUM_URL:-http://localhost:4723}"
SID_FILE="${MAC2_SID_FILE:-/tmp/mac2.sid}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Recorder state — single concurrent recording. Restarting overrides cleanly.
REC_PID_FILE="${MAC2_REC_PID:-/tmp/mac2-recorder.pid}"
REC_OUT_FILE="${MAC2_REC_OUT:-/tmp/mac2-record.jsonl}"
REC_META_FILE="${MAC2_REC_META:-/tmp/mac2-recorder.meta}"
REC_SNAP_DIR="${MAC2_REC_SNAP:-${REC_OUT_FILE}.snapshots}"
REC_BIN="$SKILL_DIR/mac2-recorder"
REC_AGGREGATE="$SKILL_DIR/recorder/aggregate.py"

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
    # By default: just close the session, leave WDA Runner alive so the
    # next `start` is ~2s instead of 20–60s. Pass `--hard` to also kill
    # the runner + xcodebuild (clean visual state, but next start has to
    # rebuild WDA).
    HARD=""
    [ "${1:-}" = "--hard" ] && HARD=1
    S=$(sid)
    curl -s -X DELETE "$APPIUM/session/$S" > /dev/null
    rm -f "$SID_FILE"
    if [ -n "$HARD" ]; then
      pkill -f "WebDriverAgentRunner-Runner" 2>/dev/null || true
      pkill -f "xcodebuild.*WebDriverAgentMac" 2>/dev/null || true
      echo "session $S stopped (runner + xcodebuild killed — next start will rebuild WDA)"
    else
      echo "session $S stopped (runner kept alive — next start will be fast)"
    fi
    ;;

  status)
    curl -s "$APPIUM/status" | jq_py 'import sys,json; d=json.load(sys.stdin); print(d)'
    ;;

  screenshot)
    # Shrink to long-edge ~1200px in place. Raw WDA screenshots are Retina
    # 4–5MB PNGs; Claude's vision works just as well on 300–500KB images
    # and reads them far faster. Set MAC2_RAW_SCREENSHOT=1 to skip the
    # resize when you need pixel-perfect output (rare).
    S=$(sid); OUT="${1:-/tmp/mac_screen.png}"
    curl -s "$APPIUM/session/$S/screenshot" | \
      python3 -c "import sys,json,base64; open('$OUT','wb').write(base64.b64decode(json.load(sys.stdin)['value']))"
    if [ -z "${MAC2_RAW_SCREENSHOT:-}" ]; then
      sips -Z 1200 "$OUT" --out "$OUT" >/dev/null 2>&1 || true
    fi
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

  exists)
    # Single-shot check: does this element exist right now? Exits 0 if
    # found, 1 if not. No polling — for "is the dialog still up?" gates
    # in idempotent scripts. Costs one /element request (~50ms typical).
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"
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
    [ -n "$FOUND" ] && exit 0 || exit 1
    ;;

  attr)
    # Read a single attribute on a located element. Use this to make
    # decisions: e.g. is the disclosure triangle's value "1" (expanded)
    # or "0" (collapsed)? Is the OK button enabled? Common attribute
    # names: AXValue, AXEnabled, AXSelected, AXFocused, AXTitle, AXLabel.
    # Prints the attribute value (empty if missing) on stdout.
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"; ATTR="${3:?attribute}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; eid=v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf") if isinstance(v,dict) else ""; print(eid or "")')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s "$APPIUM/session/$S/element/$EID/attribute/$ATTR" | \
      jq_py 'import sys,json; v=json.load(sys.stdin).get("value",""); print(v if v is not None else "")'
    ;;

  clear)
    # Clear a text field. Standard sendKeys on macOS *appends*, so to
    # replace existing text you have to clear first. WebDriver's per-
    # element /clear endpoint does the right thing without a focus dance.
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; eid=v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf") if isinstance(v,dict) else ""; print(eid or "")')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    curl -s -X POST "$APPIUM/session/$S/element/$EID/clear" > /dev/null
    echo "cleared $STRAT=$VAL"
    ;;

  set-value)
    # Atomically set the AXValue of an element. Unlike `type` (which
    # synthesizes per-character keyboard events and is painfully slow on
    # CJK or anything routed through a non-Latin input source), this
    # writes the AX value in one shot. Use this for filling save panels
    # with absolute paths, setting form fields with non-ASCII content,
    # or any case where typing fidelity matters more than simulating
    # real keyboard input.
    #
    # Backed by appium-mac2-driver's `macos: setValue` extension which
    # delegates to AXUIElementSetAttributeValue under the hood.
    S=$(sid); STRAT="${1:?strategy}"; VAL="${2:?value}"; TEXT="${3:?text}"
    EID=$(curl -s -X POST "$APPIUM/session/$S/element" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys; print(json.dumps(dict(using=sys.argv[1],value=sys.argv[2])))" "$STRAT" "$VAL")" | \
      jq_py 'import sys,json; v=json.load(sys.stdin)["value"]; eid=v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf") if isinstance(v,dict) else ""; print(eid or "")')
    [ -n "$EID" ] || { echo "element not found" >&2; exit 1; }
    BODY=$(python3 -c "import json,sys; print(json.dumps({'script':'macos: setValue','args':[{'elementId':sys.argv[1],'value':sys.argv[2]}]}))" "$EID" "$TEXT")
    curl -s -X POST "$APPIUM/session/$S/execute/sync" \
      -H 'Content-Type: application/json' \
      -d "$BODY" > /dev/null
    echo "set-value $STRAT=$VAL (atomic)"
    ;;

  wait-not)
    # Inverse of wait: poll until the element STOPS existing. Useful for
    # "wait for dialog to dismiss", "wait for spinner to vanish", etc.
    # Without this the alternative is sleep + hope.
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
      if [ -z "$FOUND" ]; then
        echo "gone $STRAT=$VAL"
        exit 0
      fi
      sleep 0.2
    done
    echo "timeout after ${TIMEOUT}s — $STRAT=$VAL still present" >&2
    exit 1
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

  record)
    SUB="${1:-}"; shift || true
    case "$SUB" in
      start)
        # Build the recorder lazily — first invocation pays ~3s; later ones
        # only rebuild if the .swift sources are newer than the binary.
        MAIN_SRC="$SKILL_DIR/recorder/main.swift"
        CORE_SRC="$SKILL_DIR/recorder/core.swift"
        if [ ! -x "$REC_BIN" ] || [ "$MAIN_SRC" -nt "$REC_BIN" ] || [ "$CORE_SRC" -nt "$REC_BIN" ]; then
          [ -f "$MAIN_SRC" ] && [ -f "$CORE_SRC" ] || { echo "recorder sources missing under $SKILL_DIR/recorder/" >&2; exit 1; }
          echo "compiling mac2-recorder…" >&2
          ( cd "$SKILL_DIR" && swiftc -O recorder/main.swift recorder/core.swift -o mac2-recorder ) || { echo "swiftc failed" >&2; exit 1; }
        fi

        # If a previous recording is still running, refuse — better that the
        # user sees the conflict than silently overwrites their last capture.
        if [ -f "$REC_PID_FILE" ]; then
          OLD=$(cat "$REC_PID_FILE")
          if kill -0 "$OLD" 2>/dev/null; then
            echo "recorder already running (pid $OLD). run: $0 record stop" >&2
            exit 1
          fi
          rm -f "$REC_PID_FILE"
        fi

        NAME="recording"; BUNDLE_FILTER=""; NO_AX=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --bundle) BUNDLE_FILTER="$2"; shift 2 ;;
            --no-ax)  NO_AX="--no-ax"; shift ;;
            -*) echo "unknown flag: $1" >&2; exit 2 ;;
            *)  NAME="$1"; shift ;;
          esac
        done

        # Launch detached so the recorder outlives this shell. nohup +
        # disown is the simplest way to do that and still have a PID we can
        # signal later. We pass flags one-at-a-time per branch to dodge
        # `set -u` on empty-array expansion (a bash 5.x corner case).
        if [ -n "$BUNDLE_FILTER" ] && [ -n "$NO_AX" ]; then
          nohup "$REC_BIN" -o "$REC_OUT_FILE" --bundle "$BUNDLE_FILTER" --no-ax >/tmp/mac2-recorder.log 2>&1 &
        elif [ -n "$BUNDLE_FILTER" ]; then
          nohup "$REC_BIN" -o "$REC_OUT_FILE" --bundle "$BUNDLE_FILTER" >/tmp/mac2-recorder.log 2>&1 &
        elif [ -n "$NO_AX" ]; then
          nohup "$REC_BIN" -o "$REC_OUT_FILE" --no-ax >/tmp/mac2-recorder.log 2>&1 &
        else
          nohup "$REC_BIN" -o "$REC_OUT_FILE" >/tmp/mac2-recorder.log 2>&1 &
        fi
        RPID=$!
        disown "$RPID" 2>/dev/null || true
        sleep 0.4
        if ! kill -0 "$RPID" 2>/dev/null; then
          echo "recorder exited immediately. last log:" >&2
          tail -5 /tmp/mac2-recorder.log >&2 || true
          echo "If it complained about Accessibility, grant the prompt and re-run." >&2
          exit 1
        fi
        echo "$RPID" > "$REC_PID_FILE"
        printf 'name=%s\nbundle=%s\nstartedAt=%s\nout=%s\n' \
          "$NAME" "$BUNDLE_FILTER" "$(date +%s)" "$REC_OUT_FILE" > "$REC_META_FILE"
        echo "recording → $REC_OUT_FILE  (pid=$RPID name=$NAME${BUNDLE_FILTER:+ bundle=$BUNDLE_FILTER})"
        echo "stop with: $0 record stop"
        ;;

      stop)
        [ -f "$REC_PID_FILE" ] || { echo "no recording in progress" >&2; exit 1; }
        RPID=$(cat "$REC_PID_FILE")
        if kill -0 "$RPID" 2>/dev/null; then
          kill -TERM "$RPID" 2>/dev/null || true
          # SIGTERM triggers CFRunLoopStop and a final emit. Give it half a
          # second to flush + close the JSONL.
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$RPID" 2>/dev/null || break
            sleep 0.1
          done
          kill -0 "$RPID" 2>/dev/null && kill -KILL "$RPID" 2>/dev/null || true
        fi
        rm -f "$REC_PID_FILE"

        NAME="recording"
        if [ -f "$REC_META_FILE" ]; then
          # shellcheck disable=SC1090
          . "$REC_META_FILE"
          [ -n "${name:-}" ] && NAME="$name"
        fi
        rm -f "$REC_META_FILE"

        # Optional name override on stop, useful when you didn't pick one
        # at start: ./mac2.sh record stop my-flow
        [ $# -gt 0 ] && NAME="$1"

        # Default to ./journeys/ in cwd — mirrors the convention SKILL.md
        # documents for hand-written journeys.
        OUT_DIR="${MAC2_JOURNEYS_DIR:-$(pwd)/journeys}"
        mkdir -p "$OUT_DIR"
        if [ ! -s "$REC_OUT_FILE" ]; then
          echo "warning: $REC_OUT_FILE is empty — nothing was captured" >&2
          exit 0
        fi
        AGG_ARGS=("$REC_OUT_FILE" "$NAME" --out-dir "$OUT_DIR")
        if [ -d "$REC_SNAP_DIR" ] && [ -n "$(ls -A "$REC_SNAP_DIR" 2>/dev/null)" ]; then
          AGG_ARGS+=(--snapshots-dir "$REC_SNAP_DIR")
        fi
        python3 "$REC_AGGREGATE" "${AGG_ARGS[@]}"
        echo "recording stopped. raw events: $REC_OUT_FILE"
        ;;

      status)
        if [ -f "$REC_PID_FILE" ] && kill -0 "$(cat "$REC_PID_FILE")" 2>/dev/null; then
          RPID=$(cat "$REC_PID_FILE")
          LINES=$(wc -l < "$REC_OUT_FILE" 2>/dev/null || echo 0)
          echo "recording (pid=$RPID, $LINES events captured so far, log=$REC_OUT_FILE)"
          [ -f "$REC_META_FILE" ] && cat "$REC_META_FILE"
        else
          echo "idle"
          [ -f "$REC_PID_FILE" ] && rm -f "$REC_PID_FILE"
        fi
        ;;

      ""|help|-h|--help)
        cat <<EOF
record subcommands:
  start [name] [--bundle <id>]   begin capture (default name: "recording")
  stop  [name]                   end capture, emit journeys/<name>.sh + .md
  status                         show running PID and event count
EOF
        ;;

      *)
        echo "unknown record subcommand: $SUB" >&2
        exit 2
        ;;
    esac
    ;;

  ""|help|-h|--help)
    sed -n '2,45p' "$0"
    ;;

  *)
    echo "unknown command: $cmd" >&2
    sed -n '2,45p' "$0" >&2
    exit 2
    ;;
esac
