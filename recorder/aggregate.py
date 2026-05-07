#!/usr/bin/env python3
"""Aggregate raw JSONL events from mac2-recorder into Mode A bash + Mode B markdown.

The recorder writes one JSON object per UI event (mousedown, mouseup, keydown,
…). This script collapses that stream into a small set of high-level actions
(click, drag, keys, type, activate) and emits two complementary artifacts:

  • <name>.sh — bash replay using mac2.sh. Fast and brittle: no eyes, no waits,
    no recovery. Best when the path is already known stable.
  • <name>.md — markdown journey for an AI executor with vision. Slower but
    self-checking: a Claude instance walks through the steps, screenshots
    between each, and notices when state drifted.

Both files are starting points. The recorder picks the best locator at capture
time but can't always know intent — review and edit before relying on them.

Usage: aggregate.py <input.jsonl> <name> [--out-dir <dir>] [--mac2 <expr>]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from typing import Any

# macOS virtual keycodes for non-printable keys we want to preserve as
# semantic key names rather than Unicode chars or "keycodeNN".
KEYCODE_TO_KEY: dict[int, str] = {
    36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
    76: "Enter", 117: "ForwardDelete",
    115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    123: "Left", 124: "Right", 125: "Down", 126: "Up",
    122: "F1", 120: "F2", 99: "F3", 118: "F4",
    96: "F5",  97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12",
}

# When a modifier is held (cmd/ctrl/alt), the OS often returns an empty
# `char` from CGEventKeyboardGetUnicodeString — the event is treated as a
# command, not text. We fall back to this US-QWERTY mapping so `cmd+S`
# emits as `cmd+s` rather than `cmd+keycode1`. Non-US layouts will look
# slightly off; users on those layouts can edit the generated script.
KEYCODE_TO_CHAR: dict[int, str] = {
    0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
    34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
    12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
    16: "y", 6: "z",
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
    23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    49: "space",
    27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
    43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
}

# When two consecutive printable keys are this far apart in seconds, they're
# treated as separate `type` actions (the user paused — likely a different
# field or a separate intent). 1.5s is generous enough to ride out a thinking
# pause without bundling a second sentence.
TYPE_GAP_S = 1.5

# Pixel distance between mousedown and mouseup that flips a click→drag.
# 5pt is the common UI threshold for "intent to drag" — anything tighter
# treats hand jitter as a drag.
DRAG_THRESHOLD_PT = 5


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("jsonl", help="raw event log from mac2-recorder")
    p.add_argument("name", help="basename for the output files")
    p.add_argument("--out-dir", default=".",
                   help="directory for <name>.sh and <name>.md (default: cwd)")
    p.add_argument("--mac2", default='"$M"',
                   help='shell expression for mac2.sh in the bash output (default: "$M")')
    p.add_argument("--snapshots-dir", default=None,
                   help="directory of AX-tree JSON snapshots produced by the recorder; "
                        "when supplied, snapshots are copied to <out-dir>/<name>.snapshots/ "
                        "and a rich journey is emitted that references them per step.")
    return p.parse_args()


def load_events(path: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                # Don't abort on a single bad line — the recorder writes
                # under signal handling and could in theory leave a half
                # written final record.
                pass
    return out


# ---------------------------------------------------------------------------
# Locator → mac2.sh strategy
# ---------------------------------------------------------------------------

def loc_to_strategy(loc: dict[str, Any] | None) -> tuple[str, str] | None:
    """Pick the most stable locator. Returns (strategy, value) or None.

    Priority is identifier > title > label+role > label. We deliberately
    refuse to fall back to plain role (`AXButton`) — it's almost never unique.
    """
    # `resolved == False` only means the recorder's hit-test missed at the
    # click point — the dict can still hold useful element data from the
    # focused-element path (`focusedLocator`), which doesn't set `resolved`.
    if not loc:
        return None
    if loc.get("resolved") is False:
        return None
    if loc.get("identifier"):
        return ("accessibility id", loc["identifier"])
    title = loc.get("title")
    label = loc.get("label")
    role = loc.get("role")
    if title:
        return ("-ios predicate string", f'title == "{_pred_esc(title)}"')
    if label and role:
        return ("-ios predicate string",
                f'label == "{_pred_esc(label)}" AND elementType == "{role}"')
    if label:
        return ("-ios predicate string", f'label == "{_pred_esc(label)}"')
    return None


def _pred_esc(s: str) -> str:
    """Escape a string for use inside a double-quoted predicate literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def describe_brief(loc: dict[str, Any] | None) -> str:
    """One-line element label for shell comments and markdown."""
    if not loc:
        return "(no element)"
    parts: list[str] = []
    if loc.get("identifier"):
        parts.append(f'id="{loc["identifier"]}"')
    if loc.get("title"):
        parts.append(f'title="{loc["title"]}"')
    elif loc.get("label"):
        parts.append(f'label="{loc["label"]}"')
    if loc.get("role"):
        parts.append(loc["role"])
    if not parts and loc.get("x") is not None:
        parts.append(f'@({loc["x"]},{loc["y"]})')
    return " ".join(parts) or "(unresolved)"


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def collect_snapshots(events: list[dict[str, Any]]) -> list[tuple[float, str]]:
    """Pull out the periodic-snapshot markers from the event stream.

    The recorder emits `{"type": "snapshot", "ax": "<filename>", "tt": <t>}`
    once per timer tick. We index them by timestamp so per-action snapshot
    lookup (find nearest before/after) is O(log N).
    """
    snaps: list[tuple[float, str]] = []
    for ev in events:
        if ev.get("type") == "snapshot" and ev.get("ax"):
            snaps.append((ev.get("tt", ev.get("t", 0.0)), ev["ax"]))
    snaps.sort()
    return snaps


def nearest_snapshots(snaps: list[tuple[float, str]],
                      t: float) -> tuple[str | None, str | None]:
    """Return (before, after) snapshot filenames straddling time t.

    Both can be None if t falls outside the recorded window. We don't
    fuzzy-match — the AI consumer should know whether it has a real
    "before" or just the closest available."""
    before: str | None = None
    after: str | None = None
    for st, name in snaps:
        if st <= t:
            before = name
        else:
            after = name
            break
    return before, after


def aggregate(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    pending_type: dict[str, Any] | None = None
    last_mousedown: dict[str, Any] | None = None
    bundle_state: str | None = None
    snaps = collect_snapshots(events)

    def flush_type() -> None:
        nonlocal pending_type
        if pending_type and pending_type["chars"]:
            actions.append({
                "kind": "type",
                "t": pending_type["start_t"],
                "focused": pending_type["focused"],
                "text": "".join(pending_type["chars"]),
            })
        pending_type = None

    for ev in events:
        kind = ev.get("type")
        ts = ev.get("t", 0.0)

        # Snapshot markers were already harvested by collect_snapshots; they
        # carry no action semantics so we drop them here.
        if kind == "snapshot":
            continue

        # App switch — emit `activate` whenever the frontmost bundle changes.
        # The recorder tags each event with the current frontmost app so we
        # don't need a separate AX observer.
        app = ev.get("app") or {}
        bundle = app.get("bundle")
        if bundle and bundle != bundle_state:
            flush_type()
            actions.append({
                "kind": "activate",
                "t": ts,
                "bundle": bundle,
                "name": app.get("name", ""),
            })
            bundle_state = bundle

        if kind == "mousedown":
            flush_type()
            last_mousedown = ev

        elif kind == "mouseup":
            if last_mousedown is None:
                continue
            dist = ev.get("maxDistance", 0)
            # Per-event snapshots (preferred): the recorder dispatches a
            # snapshot on each mousedown (`ax_pre`) and mouseup (`ax_post`,
            # 120ms delayed). These are tightly aligned with the action,
            # unlike the periodic timer snapshots which only get matched
            # by timestamp later.
            ax_pre = last_mousedown.get("ax_pre") or last_mousedown.get("ax")
            ax_post = ev.get("ax_post") or ev.get("ax")
            if dist > DRAG_THRESHOLD_PT:
                actions.append({
                    "kind": "drag",
                    "t": last_mousedown.get("t", ts),
                    "from": ev.get("from",
                                   {"x": last_mousedown["locator"].get("x", 0),
                                    "y": last_mousedown["locator"].get("y", 0)}),
                    "to": {"x": ev["locator"].get("x", 0),
                           "y": ev["locator"].get("y", 0)},
                    "duration": round(ev.get("duration", 0.3), 2),
                    "downLocator": ev.get("downLocator",
                                          last_mousedown.get("locator", {})),
                    "ax_pre": ax_pre,
                    "ax_post": ax_post,
                })
            else:
                actions.append({
                    "kind": "click",
                    "t": last_mousedown.get("t", ts),
                    "modifiers": last_mousedown.get("modifiers", []),
                    "locator": last_mousedown.get("locator", {}),
                    "ax_pre": ax_pre,
                    "ax_post": ax_post,
                })
            last_mousedown = None

        elif kind == "rightmousedown":
            flush_type()
            actions.append({
                "kind": "rightclick",
                "t": ts,
                "locator": ev.get("locator", {}),
            })
        elif kind == "rightmouseup":
            pass  # paired into the rightmousedown action above

        elif kind == "keydown":
            # Shift alone is just typing-with-shift; cmd/alt/ctrl signals a
            # combo. We use this distinction to decide between aggregating a
            # `type` action and emitting an immediate `keys` action.
            mods_meaningful = [m for m in ev.get("modifiers", []) if m != "shift"]
            char = ev.get("char", "") or ""
            kc = ev.get("keycode", -1)
            secure = ev.get("secureInput", False)

            if mods_meaningful:
                flush_type()
                key = (KEYCODE_TO_KEY.get(kc)
                       or (char if char else None)
                       or KEYCODE_TO_CHAR.get(kc)
                       or f"keycode{kc}")
                combo = "+".join(ev.get("modifiers", []) + [key])
                actions.append({
                    "kind": "keys",
                    "t": ts,
                    "combo": combo,
                    "ax_pre": ev.get("ax_pre") or ev.get("ax"),
                    "ax_post": ev.get("ax_post"),
                })
            elif kc in KEYCODE_TO_KEY:
                # Special key with no meaningful modifier — Enter, Tab, etc.
                flush_type()
                actions.append({
                    "kind": "keys",
                    "t": ts,
                    "combo": KEYCODE_TO_KEY[kc],
                    "ax_pre": ev.get("ax_pre") or ev.get("ax"),
                    "ax_post": ev.get("ax_post"),
                })
            elif secure:
                # Privacy: never record characters typed into a secure field.
                # Note that something happened so the journey isn't silently
                # missing user actions; the post-edit can decide what to do.
                flush_type()
                actions.append({
                    "kind": "secure",
                    "t": ts,
                    "focused": ev.get("focused", {}),
                })
            elif char:
                if pending_type and (
                    ts - pending_type["last_t"] > TYPE_GAP_S
                    or pending_type["focused"] != ev.get("focused", {})
                ):
                    flush_type()
                if pending_type is None:
                    pending_type = {
                        "start_t": ts,
                        "last_t": ts,
                        "focused": ev.get("focused", {}),
                        "chars": [],
                    }
                pending_type["chars"].append(char)
                pending_type["last_t"] = ts
            # else: keydown without a char and not in our keycode map — drop.

        # `flags`, `session_start`, `session_end` are informational only.

    flush_type()

    # Fill in snapshot refs from the timer stream, but ONLY where the
    # event-driven per-action snapshots are missing. Per-event snapshots
    # (set by the recorder directly on the click/key event) are tightly
    # aligned with the action and should always win when present. Timer
    # snapshots are coarser fallbacks for events that didn't trigger a
    # dedicated dump (e.g. plain typing, or if the recorder was started
    # with --no-ax-on-click in some future variant).
    if snaps:
        for a in actions:
            t_action = a.get("t", 0.0)
            before, after = nearest_snapshots(snaps, t_action)
            if not a.get("ax_pre") and before:
                a["ax_pre"] = before
            if not a.get("ax_post") and after:
                a["ax_post"] = after

    return actions


# ---------------------------------------------------------------------------
# Output: bash
# ---------------------------------------------------------------------------

def _bash_squote(s: str) -> str:
    """Bash-safe single-quoted string. Falls back to double-quoting if the
    value contains a single quote — rare but real (predicates can include
    apostrophes in titles like "Don't Save")."""
    if "'" not in s:
        return f"'{s}'"
    esc = (s.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace('$', '\\$')
            .replace('`', '\\`'))
    return f'"{esc}"'


def write_bash(actions: list[dict[str, Any]], args: argparse.Namespace) -> str:
    M = args.mac2
    out: list[str] = [
        "#!/bin/bash",
        f"# Generated by mac2.sh record from {os.path.basename(args.jsonl)}",
        f"# Generated at {datetime.datetime.now().isoformat(timespec='seconds')}",
        "#",
        "# This is a starting point — review and edit before depending on it.",
        "# - Locators were picked at capture time; if the UI shifts, prefer",
        "#   the matching .md journey (Mode B) which can adapt with vision.",
        "# - There are no `wait` calls between actions; if the app needs time",
        "#   to settle, add `\"$M\" wait <strategy> <value>` where appropriate.",
        "set -euo pipefail",
        "",
        # Resolve mac2.sh — works whether the script lives in journeys/ or
        # alongside the skill. Override with MAC2_SH=/path/to/mac2.sh.
        'M="${MAC2_SH:-}"',
        'if [ -z "$M" ]; then',
        '  for cand in '
        '"$(cd "$(dirname "$0")" && pwd)/mac2.sh" '
        '"$(cd "$(dirname "$0")/.." && pwd)/mac2.sh" '
        '"$HOME/.claude/skills/driving-macos-with-wda-vision/mac2.sh"; do',
        '    [ -x "$cand" ] && M="$cand" && break',
        '  done',
        'fi',
        '[ -x "$M" ] || { echo "mac2.sh not found — set MAC2_SH" >&2; exit 1; }',
        "",
    ]

    first_bundle = next((a["bundle"] for a in actions if a["kind"] == "activate"), None)
    if first_bundle:
        out.append(f'"$M" session-alive >/dev/null 2>&1 || "$M" start {_bash_squote(first_bundle)}')
        out.append("")

    for i, a in enumerate(actions, 1):
        kind = a["kind"]
        if kind == "activate":
            out.append(f'# step {i}: activate {a.get("name") or a["bundle"]}')
            out.append(f'"$M" activate {_bash_squote(a["bundle"])}')
        elif kind == "click":
            loc = a["locator"]
            strat = loc_to_strategy(loc)
            out.append(f"# step {i}: click {describe_brief(loc)}")
            if strat:
                out.append(f'"$M" click {_bash_squote(strat[0])} {_bash_squote(strat[1])}')
            else:
                out.append("# fallback: no stable locator — using raw screen coords (brittle)")
                out.append(f'"$M" click-at {loc.get("x", 0)} {loc.get("y", 0)}')
        elif kind == "drag":
            f = a["from"]; to = a["to"]
            out.append(f"# step {i}: drag ({f['x']},{f['y']}) -> ({to['x']},{to['y']}) "
                       f"from {describe_brief(a.get('downLocator'))}")
            out.append(f'"$M" drag {f["x"]} {f["y"]} {to["x"]} {to["y"]} {a.get("duration", 0.3)}')
        elif kind == "keys":
            out.append(f"# step {i}: keys")
            out.append(f'"$M" keys {a["combo"]}')
        elif kind == "type":
            text = a["text"]
            focused = a.get("focused") or {}
            strat = loc_to_strategy(focused) if focused else None
            short = text if len(text) <= 60 else text[:57] + "..."
            out.append(f"# step {i}: type {short!r}")
            if strat:
                out.append(f'"$M" type {_bash_squote(strat[0])} {_bash_squote(strat[1])} {_bash_squote(text)}')
            else:
                # No focused locator. AppleScript is the most reliable fallback
                # for typing into whatever has keyboard focus right now.
                ascript = f'tell application "System Events" to keystroke {json.dumps(text)}'
                out.append("# no focused-element locator — falling back to AppleScript keystroke")
                out.append(f'"$M" applescript {_bash_squote(ascript)}')
        elif kind == "rightclick":
            out.append(f"# step {i}: right-click {describe_brief(a['locator'])}")
            out.append("# right-click is not directly modeled by mac2.sh; using AppleScript fallback")
            x = a["locator"].get("x", 0); y = a["locator"].get("y", 0)
            ascript = (f'tell application "System Events" to '
                       f'click at {{{x}, {y}}} using {{control down}}')
            out.append(f'"$M" applescript {_bash_squote(ascript)}')
        elif kind == "secure":
            out.append(f"# step {i}: SECURE INPUT was active here — characters were not recorded")
            out.append("#   Edit this section: insert the right credential flow (e.g. via env var).")
        out.append("")

    path = os.path.join(args.out_dir, args.name + ".sh")
    with open(path, "w") as f:
        f.write("\n".join(out))
    os.chmod(path, 0o755)
    return path


# ---------------------------------------------------------------------------
# Output: markdown
# ---------------------------------------------------------------------------

def describe_md(loc: dict[str, Any] | None) -> str:
    """Human-readable element label for use inside markdown sentences.

    Output is meant to slot into "click ___" or "into ___", so keep it noun
    phrase-shaped — never start with "with id".
    """
    if not loc:
        return "(unknown element)"
    role = loc.get("role", "")
    role_word = role.removeprefix("AX").lower() if role.startswith("AX") else role
    if loc.get("title"):
        head = f'**"{loc["title"]}"** {role_word}'.strip()
    elif loc.get("label"):
        head = f'the `{loc["label"]}` {role_word}'.strip()
    elif loc.get("identifier"):
        head = f'the {role_word} `{loc["identifier"]}`'.strip() if role_word else f'`{loc["identifier"]}`'
    elif role_word:
        head = f'a {role_word}'
    elif loc.get("x") is not None:
        head = f'element at ({loc["x"]}, {loc["y"]})'
    else:
        head = "(unresolved element)"
    return head


def write_markdown(actions: list[dict[str, Any]], args: argparse.Namespace) -> str:
    first = next((a for a in actions if a["kind"] == "activate"), None)
    bundle = first["bundle"] if first else ""
    app_name = first.get("name", "") if first else ""

    lines: list[str] = []
    lines.append(f"# Journey: {args.name} (recorded)")
    lines.append("")
    lines.append(f"Recorded: {datetime.datetime.now().isoformat(timespec='seconds')}  ")
    if bundle:
        lines.append(f"App: **{app_name or bundle}** (`{bundle}`)")
    lines.append("")

    lines.extend([
        "## Goal",
        "",
        "> Edit this section: describe what success looks like in one sentence.",
        "",
        "## Preconditions",
        "",
        f"- Mac2 session attached to `{bundle or '<bundle>'}` "
        "(use `session-alive`, fall back to `start` if dead)",
        "- App in initial state (edit with specifics — eg. \"main window frontmost, no dialogs open\")",
        "",
        "## Steps",
        "",
        "Take a screenshot before each step and verify the expected state. Stop and ask the user if state has drifted from this script.",
        "",
    ])

    for i, a in enumerate(actions, 1):
        kind = a["kind"]
        if kind == "activate":
            lines.append(f'{i}. Activate **{a.get("name") or a["bundle"]}**.')
        elif kind == "click":
            lines.append(f'{i}. Click {describe_md(a["locator"])}.')
        elif kind == "drag":
            f = a["from"]; to = a["to"]
            from_label = describe_md(a.get("downLocator"))
            lines.append(
                f'{i}. Drag from {from_label} at ({f["x"]}, {f["y"]}) '
                f'to ({to["x"]}, {to["y"]}).'
            )
        elif kind == "keys":
            lines.append(f'{i}. Press `{a["combo"]}`.')
        elif kind == "type":
            text = a["text"]
            focused = a.get("focused") or {}
            short = text if len(text) <= 60 else text[:57] + "..."
            lines.append(f'{i}. Type `{short!r}` into {describe_md(focused)}.')
        elif kind == "rightclick":
            lines.append(f'{i}. Right-click {describe_md(a["locator"])}.')
        elif kind == "secure":
            lines.append(f'{i}. **[SECURE INPUT]** characters were not recorded — '
                         'fill in the credential flow manually.')
    lines.append("")

    lines.extend([
        "## Pass / Fail",
        "",
        "- Pass: edit me — what's the verifiable end state?",
        "- Fail: edit me — what would be a regression?",
        "",
        "## Hazards to watch for",
        "",
        "- Edit me: any dialogs (Setup, permissions, save prompts) that may pre-empt the flow?",
        "",
    ])

    path = os.path.join(args.out_dir, args.name + ".md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    return path


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def write_rich_markdown(actions: list[dict[str, Any]], args: argparse.Namespace,
                        snapshots_subdir: str | None) -> str:
    """Per-step journey that references AX-tree snapshots, designed for an
    AI to consume when rewriting a recording into a state-aware script.

    Each step lists the action, its locator, and paths to the pre/post
    snapshot JSON files. Reading the snapshot file shows the full AX tree
    of the frontmost window at that moment — including dialog state,
    sheet presence, popup values, all the things a stateless script can't
    derive from event-tape alone.
    """
    lines: list[str] = [
        f"# Journey (rich): {args.name}",
        "",
        "This file is the recording with AX-tree snapshots referenced per step.",
        "The bare bash and markdown next to it are starting points for *replay*;",
        "this file is the starting point for **rewriting** the recording into a",
        "smarter, state-aware script. Each step's snapshot JSON shows the full",
        "frontmost-window UI state at the moment the user acted.",
        "",
        "## How to use",
        "",
        "Hand this file (and the snapshots dir) to an AI with the instruction",
        "\"rewrite this into an idempotent script\". The AI can compare pre and",
        "post snapshots to spot toggles (does this click open the panel, or",
        "close it depending on current state?), notice popups whose value",
        "needs to be checked before clicking, and detect dialogs that should",
        "be dismissed conditionally.",
        "",
        "## Steps",
        "",
    ]

    snap_ref = (snapshots_subdir + "/") if snapshots_subdir else ""

    for i, a in enumerate(actions, 1):
        kind = a["kind"]
        if kind == "click":
            lines.append(f"### {i}. click {describe_brief(a['locator'])}")
        elif kind == "drag":
            f = a["from"]; to = a["to"]
            lines.append(f"### {i}. drag ({f['x']},{f['y']}) → ({to['x']},{to['y']})")
        elif kind == "keys":
            lines.append(f"### {i}. keys `{a['combo']}`")
        elif kind == "type":
            text = a["text"]
            short = text if len(text) <= 40 else text[:37] + "..."
            lines.append(f"### {i}. type `{short!r}` into {describe_brief(a.get('focused'))}")
        elif kind == "activate":
            lines.append(f"### {i}. activate {a.get('name') or a['bundle']}")
        elif kind == "rightclick":
            lines.append(f"### {i}. right-click {describe_brief(a['locator'])}")
        elif kind == "secure":
            lines.append(f"### {i}. SECURE INPUT — characters not recorded")
        lines.append("")
        ax_pre = a.get("ax_pre")
        ax_post = a.get("ax_post")
        if ax_pre or ax_post:
            if ax_pre:
                lines.append(f"- **pre**: [`{snap_ref}{ax_pre}`]({snap_ref}{ax_pre})")
            if ax_post:
                lines.append(f"- **post**: [`{snap_ref}{ax_post}`]({snap_ref}{ax_post})")
            lines.append("")

    path = os.path.join(args.out_dir, args.name + ".rich.md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    return path


def copy_snapshots(snapshots_dir: str, out_dir: str, name: str) -> str | None:
    """Copy snapshot JSONs to <out-dir>/<name>.snapshots/ so the journey
    is self-contained when moved. Returns the relative subdir name (for
    embedding into markdown links) or None on failure."""
    import shutil
    src = os.path.abspath(snapshots_dir)
    if not os.path.isdir(src):
        return None
    subdir = name + ".snapshots"
    dst = os.path.join(out_dir, subdir)
    # Wipe + repopulate so a re-run doesn't mix old + new snapshots.
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return subdir


def main() -> int:
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    events = load_events(args.jsonl)
    actions = aggregate(events)
    bash_path = write_bash(actions, args)
    md_path = write_markdown(actions, args)
    print(f"events={len(events)}  actions={len(actions)}", file=sys.stderr)
    print(f"  -> {bash_path}", file=sys.stderr)
    print(f"  -> {md_path}", file=sys.stderr)

    snapshots_subdir = None
    if args.snapshots_dir:
        snapshots_subdir = copy_snapshots(args.snapshots_dir, args.out_dir, args.name)
        if snapshots_subdir:
            rich_path = write_rich_markdown(actions, args, snapshots_subdir)
            count = len(os.listdir(os.path.join(args.out_dir, snapshots_subdir)))
            print(f"  -> {rich_path}  ({count} AX snapshots in {snapshots_subdir}/)", file=sys.stderr)
        else:
            print(f"  (snapshots dir {args.snapshots_dir} not found — skipping rich journey)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
