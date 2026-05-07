// Pure declarations only — no top-level statements. Swift treats the file
// in the swiftc invocation that has top-level statements as the "main"
// script and refuses to form @convention(c) function pointers from local
// scope. Keeping the callback and globals here makes them genuine module
// globals that the main file can reference.

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// MARK: - shared state ----------------------------------------------------

enum Recorder {
    static var outPath = "/tmp/mac2-record.jsonl"
    static var bundleFilter: String? = nil
    static var outFH: FileHandle? = nil
    static var currentTap: CFMachPort? = nil
    static var dragState: DragState? = nil
    static let outQueue = DispatchQueue(label: "mac2-recorder.out")

    // AX-tree snapshots: capture frontmost-window state before/after each
    // click and meaningful key event, so a downstream AI can see "what UI
    // existed at this moment" and rewrite recordings into idempotent,
    // state-aware scripts. Off via `--no-ax`.
    static var snapshotDir: String? = nil
    static var snapshotSeq: Int = 0
    static let snapshotQueue = DispatchQueue(label: "mac2-recorder.snap")
    static var snapshotTimer: DispatchSourceTimer? = nil
}

struct DragState {
    let startX: Int
    let startY: Int
    let startedAt: TimeInterval
    let downLocator: [String: Any]
    var maxDistance: Double
}

// MARK: - emit ------------------------------------------------------------

func emit(_ event: [String: Any]) {
    var e = event
    e["t"] = Date().timeIntervalSince1970
    Recorder.outQueue.sync {
        guard let fh = Recorder.outFH,
              let data = try? JSONSerialization.data(withJSONObject: e, options: []) else { return }
        fh.write(data)
        fh.write(Data([0x0a]))
    }
}

// MARK: - AX helpers ------------------------------------------------------

func axStr(_ el: AXUIElement, _ attr: String) -> String? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axElem(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    guard let raw = v else { return nil }
    if CFGetTypeID(raw) == AXUIElementGetTypeID() {
        return (raw as! AXUIElement)
    }
    return nil
}

func axAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
}

// MARK: - AX tree snapshots ----------------------------------------------

/// Total elements visited per snapshot. AX trees on rich apps (Word's
/// document body, web views) can be tens of thousands of nodes; reading
/// every attribute on each one takes seconds even at sub-ms per query.
/// We bail out once this budget is exhausted — the AI consumer of the
/// snapshot doesn't need the whole document text, just the chrome.
private var dumpBudget = 0
private let dumpBudgetMax = 1500

/// Walk the AX subtree rooted at `el` and serialize it to a nested dict.
/// Caps at `maxDepth=6` (deep enough for sheet > content > controls but
/// not deep enough to descend into the document text body) and at
/// `dumpBudgetMax` total elements. Reset the budget at the call site.
func dumpAXTree(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 6) -> [String: Any] {
    if depth == 0 { dumpBudget = dumpBudgetMax }
    var d: [String: Any] = [:]
    if dumpBudget <= 0 { return d }
    dumpBudget -= 1
    if let r = axStr(el, kAXRoleAttribute as String), !r.isEmpty { d["role"] = r }
    if let s = axStr(el, kAXSubroleAttribute as String), !s.isEmpty { d["subrole"] = s }
    if let i = axStr(el, kAXIdentifierAttribute as String), !i.isEmpty { d["identifier"] = i }
    if let t = axStr(el, kAXTitleAttribute as String), !t.isEmpty { d["title"] = t }
    if let l = axStr(el, "AXLabel"), !l.isEmpty { d["label"] = l }
    if let v = axStr(el, kAXValueAttribute as String), !v.isEmpty {
        // Truncate giant values (a text view's whole document) so the JSON
        // doesn't blow up. AI consumers care about presence, not contents.
        d["value"] = v.count > 200 ? String(v.prefix(200)) + "…" : v
    }

    // Frame: position + size are returned as AXValue boxed CGPoint/CGSize.
    // Unbox into ints for compact JSON.
    if let posRaw = axAttr(el, kAXPositionAttribute as String),
       CFGetTypeID(posRaw) == AXValueGetTypeID() {
        var pt = CGPoint.zero
        AXValueGetValue(posRaw as! AXValue, .cgPoint, &pt)
        d["x"] = Int(pt.x); d["y"] = Int(pt.y)
    }
    if let sizeRaw = axAttr(el, kAXSizeAttribute as String),
       CFGetTypeID(sizeRaw) == AXValueGetTypeID() {
        var sz = CGSize.zero
        AXValueGetValue(sizeRaw as! AXValue, .cgSize, &sz)
        d["w"] = Int(sz.width); d["h"] = Int(sz.height)
    }

    if let enabled = axAttr(el, kAXEnabledAttribute as String) as? Bool { d["enabled"] = enabled }
    if let focused = axAttr(el, kAXFocusedAttribute as String) as? Bool, focused { d["focused"] = true }
    if let selected = axAttr(el, kAXSelectedAttribute as String) as? Bool, selected { d["selected"] = true }

    if depth < maxDepth && dumpBudget > 0 {
        if let raw = axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement], !raw.isEmpty {
            var kids: [[String: Any]] = []
            kids.reserveCapacity(raw.count)
            for c in raw {
                if dumpBudget <= 0 {
                    kids.append(["truncated": true])
                    break
                }
                kids.append(dumpAXTree(c, depth: depth + 1, maxDepth: maxDepth))
            }
            d["children"] = kids
        }
    }
    return d
}

/// Pick the right root for a "what's on screen right now" snapshot.
/// Uses NSWorkspace to find the frontmost-app PID, then AX to get its
/// focused window. (Pure AX via `kAXFocusedApplicationAttribute` on the
/// system-wide element returned nil on non-main threads in practice;
/// NSWorkspace.frontmostApplication is the reliable cross-thread answer.)
func frontmostWindowElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElem = AXUIElementCreateApplication(app.processIdentifier)
    if let win = axElem(appElem, kAXFocusedWindowAttribute as String) {
        return win
    }
    if let main = axElem(appElem, kAXMainWindowAttribute as String) {
        return main
    }
    return appElem
}

/// Schedule an AX-tree snapshot of the frontmost window. ALL work runs on
/// the background queue — including resolving the frontmost window and
/// walking the tree. The calling thread (the event-tap callback in
/// practice) only allocates a sequence number, formats the filename,
/// captures the timestamp, and posts a closure: ~10µs of work, well
/// within the tap's tolerance.
///
/// Why fully async: an earlier version resolved the AX root on the
/// calling thread "for safety" — under load (many fast clicks against
/// Word's huge tree) those queries piled up and starved the event tap,
/// dropping events. The 1500-element budget + 0.2s messaging timeout in
/// dumpAXTree keep the bg work bounded so the queue never builds up
/// faster than it drains.
///
/// `delay` lets callers post-date for transitions (sheet animation, async
/// UI updates after a click). The post-click dump uses ~120ms.
func captureSnapshot(_ phase: String, delay: TimeInterval = 0) -> String? {
    guard let dir = Recorder.snapshotDir else { return nil }
    let seq = Recorder.snapshotSeq
    Recorder.snapshotSeq += 1
    let name = String(format: "%05d-%@.json", seq, phase as CVarArg)
    let full = (dir as NSString).appendingPathComponent(name)
    let captureT = Date().timeIntervalSince1970

    let work: () -> Void = {
        guard let root = frontmostWindowElement() else { return }
        AXUIElementSetMessagingTimeout(root, 0.2)
        let tree = dumpAXTree(root)
        let payload: [String: Any] = [
            "phase": phase,
            "t": captureT,
            "tree": tree,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        try? data.write(to: URL(fileURLWithPath: full))
    }
    if delay > 0 {
        Recorder.snapshotQueue.asyncAfter(deadline: .now() + delay, execute: work)
    } else {
        Recorder.snapshotQueue.async(execute: work)
    }
    return name
}

func collectLocator(_ e: AXUIElement) -> [String: Any] {
    var d: [String: Any] = [:]
    if let id = axStr(e, kAXIdentifierAttribute as String), !id.isEmpty { d["identifier"] = id }
    if let role = axStr(e, kAXRoleAttribute as String), !role.isEmpty { d["role"] = role }
    if let sub = axStr(e, kAXSubroleAttribute as String), !sub.isEmpty { d["subrole"] = sub }
    if let t = axStr(e, kAXTitleAttribute as String), !t.isEmpty { d["title"] = t }
    if let l = axStr(e, "AXLabel"), !l.isEmpty { d["label"] = l }
    if let v = axStr(e, kAXValueAttribute as String), !v.isEmpty, v.count < 200 { d["value"] = v }

    // Walk up the parent chain for context — capped at 6 to keep cost
    // bounded on deep webview trees. The post-processor uses this to
    // disambiguate identical-looking elements.
    var path: [String] = []
    var cur: AXUIElement? = e
    var depth = 0
    while let c = cur, depth < 6 {
        let role = axStr(c, kAXRoleAttribute as String) ?? "?"
        let title = axStr(c, kAXTitleAttribute as String) ?? ""
        let crumb = title.isEmpty ? role : "\(role)[\(title.prefix(40))]"
        path.append(crumb)
        cur = axElem(c, kAXParentAttribute as String)
        depth += 1
    }
    if !path.isEmpty { d["path"] = path.reversed().joined(separator: " > ") }
    return d
}

func locatorAt(_ p: CGPoint) -> [String: Any] {
    var d: [String: Any] = ["x": Int(p.x), "y": Int(p.y)]
    let sys = AXUIElementCreateSystemWide()
    var raw: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &raw)
    if err == .success, let e = raw {
        d["resolved"] = true
        for (k, v) in collectLocator(e) { d[k] = v }
    } else {
        d["resolved"] = false
        d["axError"] = "\(err.rawValue)"
    }
    return d
}

func focusedLocator() -> [String: Any]? {
    let sys = AXUIElementCreateSystemWide()
    guard let e = axElem(sys, kAXFocusedUIElementAttribute as String) else { return nil }
    let d = collectLocator(e)
    return d.isEmpty ? nil : d
}

func isSecureFocus() -> Bool {
    let sys = AXUIElementCreateSystemWide()
    guard let e = axElem(sys, kAXFocusedUIElementAttribute as String) else { return false }
    if let role = axStr(e, kAXRoleAttribute as String), role == "AXSecureTextField" { return true }
    if let sub  = axStr(e, kAXSubroleAttribute as String), sub  == "AXSecureTextField" { return true }
    return false
}

// MARK: - app + modifiers -------------------------------------------------

func frontApp() -> [String: Any] {
    var d: [String: Any] = [:]
    if let app = NSWorkspace.shared.frontmostApplication {
        d["bundle"] = app.bundleIdentifier ?? ""
        d["name"]   = app.localizedName ?? ""
        d["pid"]    = Int(app.processIdentifier)
    }
    return d
}

func mods(from flags: CGEventFlags) -> [String] {
    var out: [String] = []
    if flags.contains(.maskCommand)     { out.append("cmd") }
    if flags.contains(.maskShift)       { out.append("shift") }
    if flags.contains(.maskAlternate)   { out.append("alt") }
    if flags.contains(.maskControl)     { out.append("ctrl") }
    if flags.contains(.maskSecondaryFn) { out.append("fn") }
    return out
}

func bundleMatchesFilter() -> Bool {
    guard let want = Recorder.bundleFilter else { return true }
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == want
}

// MARK: - event tap callback ---------------------------------------------

func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // System taps occasionally get disabled (timeout, slow callback). Re-enable
    // and continue — losing the rest of the recording is worse than missing
    // one event.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = Recorder.currentTap { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if !bundleMatchesFilter() {
        return Unmanaged.passUnretained(event)
    }

    let p = event.location
    let f = event.flags
    let modList = mods(from: f)

    switch type {
    case .leftMouseDown, .rightMouseDown:
        let loc = locatorAt(p)
        // Pre-click snapshot: dispatched async, costs ~10µs in the
        // callback. The bg queue resolves the frontmost window and
        // walks the tree (bounded to ~150ms).
        let preSnap = captureSnapshot("pre-click")
        if type == .leftMouseDown {
            Recorder.dragState = DragState(
                startX: Int(p.x), startY: Int(p.y),
                startedAt: Date().timeIntervalSince1970,
                downLocator: loc, maxDistance: 0)
        }
        var down: [String: Any] = [
            "type": type == .leftMouseDown ? "mousedown" : "rightmousedown",
            "modifiers": modList, "locator": loc, "app": frontApp(),
        ]
        if let s = preSnap { down["ax_pre"] = s }
        emit(down)

    case .leftMouseDragged:
        guard var ds = Recorder.dragState else { break }
        let dx = p.x - CGFloat(ds.startX)
        let dy = p.y - CGFloat(ds.startY)
        let dist = sqrt(Double(dx*dx + dy*dy))
        if dist > ds.maxDistance { ds.maxDistance = dist }
        Recorder.dragState = ds
        // Don't emit per-dragged event — too noisy. Aggregator only needs
        // start (mousedown) + end (mouseup) + maxDistance.

    case .leftMouseUp, .rightMouseUp:
        let loc = locatorAt(p)
        // Post-click snapshot delayed 120ms so sheet animations / focus
        // changes can settle. Without the delay we capture a half-rendered
        // intermediate state that confuses downstream consumers.
        let postSnap = captureSnapshot("post-click", delay: 0.12)
        var payload: [String: Any] = [
            "type": type == .leftMouseUp ? "mouseup" : "rightmouseup",
            "modifiers": modList, "locator": loc, "app": frontApp(),
        ]
        if let s = postSnap { payload["ax_post"] = s }
        if type == .leftMouseUp, let ds = Recorder.dragState {
            payload["from"] = ["x": ds.startX, "y": ds.startY]
            payload["maxDistance"] = ds.maxDistance
            payload["downLocator"] = ds.downLocator
            payload["duration"] = Date().timeIntervalSince1970 - ds.startedAt
            Recorder.dragState = nil
        }
        emit(payload)

    case .keyDown:
        let secure = isSecureFocus()
        var actual = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8,
                                       actualStringLength: &actual,
                                       unicodeString: &buf)
        let str = (actual > 0 && !secure) ? String(utf16CodeUnits: buf, count: actual) : ""
        let kc = event.getIntegerValueField(.keyboardEventKeycode)

        // Snapshot only "interesting" keys — modifier combos (cmd+P) and
        // special keys (Return/Esc/Tab/arrows). Plain typing is captured
        // by the `focused` element on the event itself; per-keystroke
        // snapshots would 10× the snapshot count without adding signal.
        let modsMeaningful = modList.contains { $0 != "shift" }
        let isSpecial = (str.isEmpty || kc == 36 || kc == 48 || kc == 51 || kc == 53 ||
                         kc == 76 || kc == 117 || (kc >= 122 && kc <= 126))
        let preSnap = (modsMeaningful || isSpecial) ? captureSnapshot("pre-key") : nil
        let postSnap = (modsMeaningful || isSpecial) ? captureSnapshot("post-key", delay: 0.12) : nil

        var payload: [String: Any] = [
            "type": "keydown",
            "modifiers": modList,
            "keycode": kc,
            "char": str,
            "secureInput": secure,
            "focused": focusedLocator() ?? [:],
            "app": frontApp(),
        ]
        if let s = preSnap { payload["ax_pre"] = s }
        if let s = postSnap { payload["ax_post"] = s }
        emit(payload)

    case .flagsChanged:
        emit(["type": "flags", "modifiers": modList])

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
