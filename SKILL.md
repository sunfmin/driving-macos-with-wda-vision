---
name: driving-macos-with-wda-vision
description: Use when Claude Code is asked to drive, test, or automate a native macOS application end-to-end — reproducing a bug on a Mac app, running an AI-driven UI test, verifying visual state, or building a desktop agent flow. Triggers include appium-mac2-driver, WebDriverAgentMac, macOS UI automation, Mac app screenshot-based testing, "click / type / open / verify in <some Mac app>" against a running app. Do not use when the target is an iOS simulator/device (use the iOS WDA skill), when the work is pure XCUITest inside an Xcode project, or when no actual macOS app is under test.
---

# Driving macOS with WDA + Claude Code Vision

## Overview

`appium-mac2-driver` bundles `WebDriverAgentMac` — an XCTest HTTP server (code-borrowed from Facebook's iOS WebDriverAgent) reachable through Appium on `localhost:4723`. It finds elements and executes actions reliably via the macOS accessibility tree. It cannot **judge** whether the screen looks right.

**You (Claude Code) are the vision.** You take screenshots via the helper, `Read` them (images are loaded directly into the conversation), decide what to do, then issue the next action. No external LLM call, no API key.

**Core principle: WDA locates and acts. You judge and decide. Never guess pixel coordinates — always ask WDA for an element by strategy + value.**

## When to Use

**Symptoms that trigger this skill:**
- User asks to drive, test, or demo a specific Mac app
- Test oracle is visual ("is the error banner shown", "does the chart match the mockup")
- Bug reproduction requires screenshot evidence per step
- Layout is dynamic and a single predicate can't cover every state

**Do NOT use when:**
- Target is iOS — use the iOS WDA skill (port 8100, `mobile:` extensions)
- You have Xcode project access to the app — write XCUITest directly
- User wants cross-app orchestration on one Mac — Mac2 is single-session per machine

## The Loop

```
    start Mac2 session for <bundleId>   (once)
             │
             ▼
    ./mac2.sh screenshot /tmp/s.png
             │
             ▼
    Read /tmp/s.png   ← you inspect the image yourself
             │
             ▼
    decide: done?  stuck?  next action?
             │
   ┌─────────┼──────────────────────┐
   ▼         ▼                      ▼
  done    stuck (ask user)    next action
                                    │
                       ./mac2.sh click  <strategy> <value>
                       ./mac2.sh type   <strategy> <value> "text"
                       ./mac2.sh keys   cmd+n
                                    │
                                    └──▶ back to screenshot
```

**One action per iteration.** Never batch ("click A then type B then press C") — you need a fresh screenshot to confirm each step landed.

## Setup (one-time per machine)

```bash
npm i -g appium
appium driver install mac2
appium driver doctor mac2          # reports AX permission, xcode-select, testmanagerd
appium                             # start the server on :4723 (leave running)
```

Doctor flags the manual steps:
1. Grant Accessibility to `Xcode Helper.app` (System Settings → Privacy & Security → Accessibility)
2. `automationmodetool enable-automationmode-without-authentication` (macOS 12+)
3. `appium driver run mac2 open-wda` once to re-sign the WDA target

If Appium isn't already on `:4723`, start it yourself with `appium` in a background Bash call — don't ask first. It's a long-lived process; just leave it running for the rest of the session.

## Quick Reference — `mac2.sh` commands

Place `mac2.sh` next to this SKILL.md. All commands are exposed via this one wrapper so you issue a single `Bash` call per step. It caches the session id in `/tmp/mac2.sid`.

| Command | What it does |
|---------|--------------|
| `./mac2.sh start <bundleId>` | Boot session (e.g. `com.apple.TextEdit`). Sets `newCommandTimeout: 3600` so idle sessions live ~1h. |
| `./mac2.sh screenshot [path]` | Save PNG (default `/tmp/mac_screen.png`), print path |
| `./mac2.sh click <strategy> <value>` | Find element and click |
| `./mac2.sh type <strategy> <value> "text"` | Find element and type |
| `./mac2.sh drag <fromX> <fromY> <toX> <toY> [duration=0.3]` | clickAndDrag between absolute points (divider drags, slider drags) |
| `./mac2.sh wait <strategy> <value> [timeout=10]` | **Poll** until an element exists — use this instead of `sleep N` |
| `./mac2.sh keys <key> [key ...]` | e.g. `Return`, `Tab`, `cmd+n`, `cmd+shift+s` |
| `./mac2.sh click-at <x> <y>` | Absolute screen coordinates — **only when no locator exists** |
| `./mac2.sh applescript "<cmd>"` | Escape hatch for Finder / menu bar / Mission Control |
| `./mac2.sh source [xml\|description]` | Dump accessibility tree — use when picking a locator is ambiguous |
| `./mac2.sh activate <bundleId>` | Bring app forward without restarting |
| `./mac2.sh session-alive` | Exit 0 if cached session still valid, 1 otherwise — use in scripts to skip re-`start` |
| `./mac2.sh stop` | Terminate session + kill WDA Runner window |

**Locator strategies** (fastest → slowest):
1. `"accessibility id"` — AX identifier
2. `"class name"` — `XCUIElementTypeButton`, `XCUIElementTypeTextField`, …
3. `"-ios predicate string"` — NSPredicate, e.g. `label == "Save" AND enabled == 1`
4. `"-ios class chain"` — XPath-shaped, predicate-backed
5. `"xpath"` — slowest, last resort

## How You (Claude Code) Run a Step

Example — "open TextEdit and type 'hello'":

```
Bash(./mac2.sh start com.apple.TextEdit)
Bash(./mac2.sh screenshot /tmp/s1.png)
Read(/tmp/s1.png)            # you see: "New Document" button visible
Bash(./mac2.sh click "accessibility id" "newDocument")   # or label-based predicate
Bash(./mac2.sh screenshot /tmp/s2.png)
Read(/tmp/s2.png)            # you see: blank editor with caret
Bash(./mac2.sh type "class name" "XCUIElementTypeTextView" "hello")
Bash(./mac2.sh screenshot /tmp/s3.png)
Read(/tmp/s3.png)            # you verify "hello" rendered
```

If a locator isn't obvious from the screenshot, run `./mac2.sh source xml` once, pick a predicate, then continue the loop.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Calling `./mac2.sh click-at X Y` by eyeballing coordinates from the screenshot | Your pixel estimation is off by 100-200pt on Retina. Use a locator. `click-at` is reserved for cases where `source` shows no findable element |
| Batching multiple actions without re-screenshotting between them | One action → screenshot → verify → next action. Always |
| Asking for a full accessibility tree before every step | Only dump `source` when a locator is unclear. The screenshot is the default judgment surface |
| Using `xpath` because it's familiar | 5-10× slower than `-ios predicate string` over the same elements |
| Starting a new session per action | Session is cached in `/tmp/mac2.sid`. Call `start` once, reuse until done |
| Running Mac2 while user has another Mac2 session open | HID is exclusive — you'll race. Check `./mac2.sh status` first if in doubt |
| Using `macos: appleScript` for things XCTest supports | It's the escape hatch for Finder / menu bar / Mission Control — not the default |
| Forgetting `stop` at end | Leaves `/tmp/mac2.sid` pointing at a dead session. Always clean up |
| `sleep N` between actions to wait for UI to settle | Replace with `./mac2.sh wait <strategy> <value>` — returns the moment the element appears, doesn't pay fixed cost on fast paths |
| Running `pkill -f WebDriverAgent*` between tests | Forces xcodebuild to re-compile WDA (20–60s) on the next `start`. Leave Runner alive between sessions; only kill on true cleanup |
| Testing a local debug build that has the same bundle ID as an installed `/Applications/<App>.app` | LaunchServices binds the bundle ID to the installed copy; Mac2's `appium:app` attaches the session to the wrong process (often Finder). Give the debug build a distinct bundle ID (`PlistBuddy -c "Set CFBundleIdentifier com.foo.app.debug" Debug/App.app/Contents/Info.plist` + re-sign + `lsregister -f`) |

## Speed tips

The difference between a snappy loop and "why is this so slow" comes down to four things:

1. **`wait`, not `sleep`.** `sleep 4` after a click wastes 3.8s on fast paths and may still be too short when the machine is loaded. `./mac2.sh wait "accessibility id" "someID" 10` exits as soon as the element shows up and gives you a real timeout error when it doesn't. Use it for: "wait for app to finish launching" (wait for a known window/element), "wait for navigation" (wait for the next screen's identifier), "wait for async content to load" (wait for a specific label).

2. **Keep Appium + WDA Runner alive across iterations.** The first `start` of a session compiles WDA's xcodebuild scheme (20–60s). Subsequent `start`s reuse the compiled binary and take ~2s. If you `pkill -f WebDriver*` between iterations, you pay the compile cost every time. The `stop` subcommand deliberately kills the Runner because leaving the blank window onscreen annoys the user; for tight iteration loops, just don't call `stop` — call a fresh `start` and the new session re-uses the Runner.

3. **`newCommandTimeout: 3600`** (already the default in `start` here). Without it, sessions die after 60s of inactivity — every "session does not exist" you hit mid-diagnostic comes from this.

4. **Skip the bundle-ID + codesign + lsregister dance when Info.plist didn't change.** If you're iterating on source only (no `project.yml` / Info.plist edits), xcodebuild overwrites the binary but the plist stays. You only need to re-apply the debug bundle ID the first time — after that, `open <DebugApp>` is enough. Only re-run `PlistBuddy` + `codesign` + `lsregister` when the plist gets regenerated.

## Persisting tests — save scenarios to project, not to the skill

**The skill ships primitives. Tests live in the project being tested.** Don't add bug-specific scripts here; they rot and nobody can tell which project they belong to.

A scenario is just a bash file in `<project>/scripts/` that chains `mac2.sh` commands:

```bash
#!/bin/bash
# scripts/test-inspector-drag-crash.sh
# Reproduces the NavigationSplitView drag crash. Run with the debug build
# already installed (see CLAUDE.md for the bundle-ID rename step).
set -euo pipefail
MAC2="$HOME/.claude/skills/driving-macos-with-wda-vision/mac2.sh"
BUNDLE="com.mycompany.app.debug"

"$MAC2" session-alive >/dev/null 2>&1 || "$MAC2" start "$BUNDLE"
"$MAC2" wait "accessibility id" "libraryRecordingRow_2" 10
"$MAC2" click "accessibility id" "libraryRecordingRow_2"
"$MAC2" wait "accessibility id" "aiChatPanel" 5

# Find the inspector splitter and drag it
XML=$("$MAC2" source xml)
SX=$(echo "$XML" | grep -oE '<XCUIElementTypeSplitter[^>]+>' | sed -n '2p' \
    | grep -oE 'x="[0-9]+"' | head -1 | grep -oE '[0-9]+')
SY=$(echo "$XML" | grep -oE '<XCUIElementTypeSplitter[^>]+>' | sed -n '2p' \
    | grep -oE 'y="[0-9]+"' | head -1 | grep -oE '[0-9]+')
for i in $(seq 1 20); do
  "$MAC2" drag "$SX" "$SY" "$((SX - 150))" "$SY" 0.3
  "$MAC2" drag "$((SX - 150))" "$SY" "$((SX + 150))" "$SY" 0.3
  "$MAC2" drag "$((SX + 150))" "$SY" "$SX" "$SY" 0.3
done
echo "survived 20 iterations — no crash"
```

Now every run is one command: `./scripts/test-inspector-drag-crash.sh`. The `session-alive` guard at the top means you don't pay the WDA compile cost if the session is already up. The `wait` calls replace every `sleep`. Store it next to the code it verifies, commit it, and the next session (yours or another Claude instance) picks up a working repro in seconds instead of re-deriving it from logs.

## Red Flags — stop and rethink

- You're reading pixel coordinates off the screenshot to feed into a command
- You're issuing three WDA calls between screenshots
- You're sending the accessibility XML *and* the screenshot to reason at the same time
- You're running `xcodebuild` or reinstalling WDA mid-loop
- The user asked for a cross-app scenario (Finder → App A → App B) and you started a single Mac2 session for only one of them
- You "know" the button must be at (640, 380) from the previous run — **the user's display setup may differ; always locate fresh each run**

## Interrupt Conditions — ask the user

- 3 consecutive screenshots show the same state despite actions (you're stuck)
- A password/TouchID prompt appears (you can't drive auth)
- A destructive confirmation appears that the user didn't authorize (Delete, Empty Trash, Sign Out)
- You needed `applescript` for an operation that wasn't obviously desktop-system-level

## See Also

- Project wiki: `wiki/entities/appium-mac2-driver.md`, `wiki/analyses/macos-desktop-automation-landscape.md`
- iOS counterpart pattern in `raw/wda.sh` — same loop shape, port 8100, `mobile:` extensions, touch instead of mouse
- `appium/appium-mac2-driver` README — canonical `macos:` extension reference

## Caveat

Authored without the RED-phase baseline testing (creating-skills TDD). Running a pressure test requires real macOS + Xcode + Mac2 infrastructure that isn't available to a scripted subagent. Treat as v0 — iterate the skill if you catch yourself rationalizing a shortcut (guessing coordinates, batching actions, skipping screenshots) during a real session.
