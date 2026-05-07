// Top-level script that drives the recorder. Free declarations for the
// callback + globals live in mac2-recorder-core.swift — see the comment
// there for why the split exists.
//
// Build:  swiftc -O mac2-recorder-main.swift mac2-recorder-core.swift -o mac2-recorder
// Run:    ./mac2-recorder -o /tmp/mac2-record.jsonl [--bundle <id>]
// Stop:   kill -TERM <pid>   (the wrapper does this automatically)

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// MARK: - argv ------------------------------------------------------------

var snapshotsEnabled = true
var snapshotDirOverride: String? = nil
do {
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-o", "--out":
            guard i+1 < argv.count else { fputs("missing value for \(a)\n", stderr); exit(2) }
            Recorder.outPath = argv[i+1]; i += 2
        case "--bundle":
            guard i+1 < argv.count else { fputs("missing value for \(a)\n", stderr); exit(2) }
            Recorder.bundleFilter = argv[i+1]; i += 2
        case "--no-ax":
            // Skip per-event AX-tree snapshots. Use this for short
            // recordings where you only need the action stream and don't
            // plan to feed the result to an AI for state-aware rewriting.
            snapshotsEnabled = false; i += 1
        case "--snapshot-dir":
            guard i+1 < argv.count else { fputs("missing value for \(a)\n", stderr); exit(2) }
            snapshotDirOverride = argv[i+1]; i += 2
        case "-h", "--help":
            print("usage: mac2-recorder [-o <jsonl>] [--bundle <bundleId>] [--no-ax] [--snapshot-dir <path>]")
            print("  -o               output JSONL path (default /tmp/mac2-record.jsonl)")
            print("  --bundle         only record events whose frontmost app matches this bundle id")
            print("  --no-ax          skip AX-tree snapshots (default: take pre/post per click + key)")
            print("  --snapshot-dir   directory for snapshot JSON files (default: <out>.snapshots/)")
            exit(0)
        default:
            fputs("unknown arg: \(a)\n", stderr); exit(2)
        }
    }
}

// MARK: - permission gate -------------------------------------------------

let trustOpts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
if !AXIsProcessTrustedWithOptions(trustOpts) {
    fputs("[recorder] not trusted yet. macOS just popped the Accessibility prompt — grant access to *this binary* (mac2-recorder), then re-run.\n", stderr)
    exit(3)
}

// MARK: - output ----------------------------------------------------------

FileManager.default.createFile(atPath: Recorder.outPath, contents: nil)
guard let fh = FileHandle(forWritingAtPath: Recorder.outPath) else {
    fputs("cannot open \(Recorder.outPath) for writing\n", stderr); exit(4)
}
Recorder.outFH = fh

// Snapshot directory: default is <jsonl>.snapshots/, sibling of the events
// log. Recreate it fresh each run so old snapshots don't leak into a new
// recording's namespace.
if snapshotsEnabled {
    let snapDir = snapshotDirOverride ?? (Recorder.outPath + ".snapshots")
    let url = URL(fileURLWithPath: snapDir)
    try? FileManager.default.removeItem(at: url)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Recorder.snapshotDir = snapDir
        fputs("[recorder] AX snapshots → \(snapDir)\n", stderr)
    } catch {
        fputs("[recorder] could not create snapshot dir \(snapDir): \(error). Continuing without snapshots.\n", stderr)
        Recorder.snapshotDir = nil
    }
}

// MARK: - event tap setup -------------------------------------------------

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue)

guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: eventCallback,
        userInfo: nil)
else {
    fputs("[recorder] failed to create event tap. Verify Accessibility permission for this binary.\n", stderr)
    exit(5)
}
Recorder.currentTap = tap

let runSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), runSrc, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// MARK: - periodic snapshot timer -----------------------------------------

// Why a timer instead of per-event snapshots: walking Word's AX tree (a
// huge document accessibility hierarchy) can take 100s of ms per query.
// Doing that synchronously inside the CGEventTap callback drops events;
// even doing it async still has the AX root resolution on the main
// thread. A 1Hz timer keeps the cost off the event path entirely. The
// post-processor matches each event to the nearest-by-timestamp snapshot.
if let dir = Recorder.snapshotDir {
    let timer = DispatchSource.makeTimerSource(queue: Recorder.snapshotQueue)
    timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(150))
    timer.setEventHandler {
        guard let root = frontmostWindowElement() else { return }
        AXUIElementSetMessagingTimeout(root, 0.2)
        let tree = dumpAXTree(root)
        let now = Date().timeIntervalSince1970
        let seq = Recorder.snapshotSeq
        Recorder.snapshotSeq += 1
        let name = String(format: "%05d-tick.json", seq)
        let full = (dir as NSString).appendingPathComponent(name)
        let payload: [String: Any] = [
            "phase": "tick",
            "t": now,
            "tree": tree,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            try? data.write(to: URL(fileURLWithPath: full))
        }
        // Drop a marker into the JSONL so the post-processor can locate
        // this snapshot by sequence as well as timestamp.
        emit(["type": "snapshot", "ax": name, "tt": now])
    }
    timer.resume()
    Recorder.snapshotTimer = timer
}

// MARK: - run -------------------------------------------------------------

emit([
    "type": "session_start",
    "app": frontApp(),
    "out": Recorder.outPath,
    "bundleFilter": Recorder.bundleFilter as Any,
    "pid": Int(getpid()),
])

signal(SIGTERM) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
signal(SIGINT)  { _ in CFRunLoopStop(CFRunLoopGetMain()) }

fputs("[recorder] writing to \(Recorder.outPath) — kill -TERM \(getpid()) (or Ctrl+C) to stop\n", stderr)
CFRunLoopRun()

emit(["type": "session_end"])
try? Recorder.outFH?.close()
fputs("[recorder] stopped\n", stderr)
