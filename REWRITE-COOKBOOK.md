# Rewriting a recording into an idempotent script

When the user asks "turn this recording into a robust script that I can run on
any input," they hand you four things in `journeys/<name>.*`:

| File | What it is |
|---|---|
| `<name>.sh` | Naïve replay — every action in order, no state checks. **Brittle starting point**, not the goal. |
| `<name>.md` | Human-readable step list. Same actions, prose form. |
| `<name>.rich.md` | Per-step links to AX-tree snapshots before/after each action. **The primary input.** |
| `<name>.snapshots/` | The raw JSON snapshots referenced by `rich.md`. |

Your job is to **read the snapshots, infer intent, and write a script that survives the things the recording can't see**: state drift, conditional flow, parameterization. Save it next to the original as `<name>-idempotent.sh` (or whatever name fits the task).

The recorder is faithful but stupid. You are the one with judgement.

---

## The default contract every output script should satisfy

Pin these in the script's top comment so the next reader knows what's promised:

1. **Every UI action has a 1-second timeout.** No `sleep` to wait for state — only `wait`, `wait-not`, `exists`. Failures surface immediately with the step name.
2. **The script is idempotent.** Running it twice on the same input yields the same output (or a clean no-op if already done).
3. **Each step is preceded by a state probe** when the action is conditional. "Click X only if Y." The probe is in the script, not in the user's head.
4. **All blind constants come from arguments or environment.** Don't hard-code paths, filenames, or timeouts the recording happened to have.
5. **stderr is human-readable.** Print the step name before each action so a slow run is debuggable.

---

## Step-by-step process

### 1. Read the rich journey first, not the bash

The bash file is the recording's brittle interpretation. The rich markdown is the raw evidence. Read it top to bottom. For each step, open the linked `pre` and `post` JSON snapshots and answer:

- What changed in the AX tree between `pre` and `post`? That's what this click *did*.
- What was the click *for* — what state transition did the user intend?
- Which AX attributes are the right witnesses for "is this state already true?"

Examples of state transitions to look for:

| Action recorded | Real intent | Probe |
|---|---|---|
| Click disclosure triangle | Expand panel if compact | `exists "ColumnView"` — only present when expanded |
| Click "Cancel" on Templates picker | Dismiss cold-start dialog | `exists "CancelButton"` — only present in the picker |
| Click in file browser cell A, then B, then C | Navigate to a folder | Set the destination directly via `attr` / setting field value |
| Type a string into the focused field | Fill a known field | Use `clear` + `type "<id>" "<value>"` against the field's locator |

### 2. Drop accidental clicks

A real recording almost always contains noise: the user reorienting between steps, a stray click on the dock to switch apps, a `cmd+c` that copied a path the user never used. If a step's pre and post snapshots are nearly identical and the click landed on something with no useful identifier (a generic AXGroup, an AXLayoutArea, an offscreen item), it is probably noise. Drop it.

The signal: useful actions move the AX tree in a measurable way (a sheet appears, a popup opens, a value changes, a button enables).

### 3. Replace sequence-of-clicks with state-aware shortcuts

Recordings capture *how a human navigated*, not *the cleanest way to get there*. Examples:

- A series of file-browser clicks → set the save panel's filename to the absolute path; macOS expands it on save.
- Click "Print" toolbar → `cmd+P` → `wait` for the print sheet's identifier. Which is more reliable depends on the app; pick the one whose pre/post snapshots show a single, clean transition.
- Drag from (x1,y1) to (x2,y2) → if the recording was a window resize / split-view drag, the same outcome can usually be set via `AXSize` / `AXValue` directly with `mac2.sh` … `attr`/AppleScript. Coordinates break on different displays.

### 4. Probe before every conditional click

For every click whose outcome depends on current UI state (toggles, "skip if already done"), write a guard:

```bash
# Expand the save panel only if it's currently compact.
# AXBrowser id=ColumnView is the marker — it only exists in expanded mode.
if ! "$M" exists "accessibility id" "ColumnView"; then
  "$M" click "accessibility id" "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE"
  "$M" wait "accessibility id" "ColumnView" 1
fi
```

The probe uses `mac2.sh exists` (single shot, no polling). If the post-condition is what really matters, follow with `wait`.

### 5. Use `clear` before `type`

WDA's `type` (sendKeys) appends. If the field is auto-populated (filename in a save sheet, date in a form, the user's email cached from last time), append corrupts the value. **Always `clear` before `type` when the field's current contents matter.**

```bash
"$M" clear "accessibility id" "saveAsNameTextField"
"$M" type  "accessibility id" "saveAsNameTextField" "$DEST_PATH"
```

### 6. Replace timed waits with observable signals

Search the draft for any `sleep N` and replace it with the thing you're actually waiting for. Common signals:

| Why you're waiting | The right wait |
|---|---|
| Dialog about to appear | `wait` for an element inside it |
| Dialog about to dismiss | `wait-not` for an element that was inside it |
| File about to be written | poll `[ -s "$path" ]` with a hard timeout |
| App finishing background work | `attr` reading a status indicator (often AXValue of a label) |

If you genuinely cannot find a signal — e.g., a fixed animation duration — keep `sleep` but make it **tight** (≤500ms) and call out the assumption in a comment.

### 7. Surface failures, don't mask them

Wrap each action in a tiny helper that prints what it's about to do and exits non-zero with the step name on failure:

```bash
step() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
W()    { "$M" wait "$1" "$2" 1 >/dev/null 2>&1; }
WC()   { W "$1" "$2" || { echo "[fail] expected $1=$2 within 1s" >&2; exit 3; }; "$M" click "$1" "$2" >/dev/null; }
```

If WC times out, the message includes the locator — the next session has a precise place to look. No silent stalls.

### 8. Parameterize what's variable

If the recording was made on file `/Users/x/foo.docx` saving to `/Users/x/foo.pdf`, the script's audience wants `$1` for input and a derived output. Look at every absolute path, magic number, or string in the draft and ask: is this specific to the recording, or is it the contract? Hoist the former to args/env.

### 9. Hard preconditions go up top

Any external state the script depends on but doesn't manage gets a fail-fast preflight check:

```bash
"$M" session-alive >/dev/null 2>&1 || "$M" start <bundle>
[ -f "$DOC" ] || { echo "input not found: $DOC" >&2; exit 1; }
```

Putting these at the start means a misuse fails in 50ms instead of after the first 5 UI actions.

---

## Anti-patterns to refuse

- **Long timeouts to "be safe."** A 30s timeout means a real bug looks identical to a flaky network for half a minute. 1s, then fail.
- **`pkill -f` to clean up state mid-flow.** Killing processes the script doesn't own is a bug magnet. Drive what you started; ignore what you didn't.
- **`sleep N` between actions because "the UI needs time."** It needs an event, not time. Find the event.
- **Clicking by raw screen coordinates.** Different display, different result. Only acceptable when `mac2.sh source xml` shows no findable element AND the geometry is genuinely fixed.
- **Eyeballing the screenshot to read state.** That's the recorder's job at capture time. By the time you're rewriting, the snapshots have it.

---

## Output structure

Place the rewritten script next to the recording — same `journeys/` folder, suffixed `-idempotent.sh` (or any clearer name). Top of the file:

```bash
#!/bin/bash
# <name>-idempotent.sh — one-line description of what running this does.
#
# Synthesized from journeys/<name>.{md,rich.md} + AX snapshots. The two
# decisions worth knowing about:
#
#   1. <key non-obvious choice you made — e.g. "the disclosure triangle is
#      a toggle so we probe ColumnView before clicking">
#   2. <key non-obvious choice you made — e.g. "we set the save filename
#      to an absolute path instead of clicking through the file browser">
#
# Usage: ./<name>-idempotent.sh <required-arg> [optional-arg]
# Output: <what changes on disk / in the system>
```

Two paragraphs of decisions at the top is what makes the script maintainable. Without them, the next reader has to re-derive your reasoning from the snapshots.
