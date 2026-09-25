#if UI_SNAPSHOTS
import AppKit
import SQLite3
import SwiftUI

// Review-only helper: renders the app's own windows to PNG files so UI changes
// can be checked on a synthetic fixture without screen-recording permission.
// Compiled only when the build passes -D UI_SNAPSHOTS; never part of the product.
@MainActor
enum SnapshotRunner {
    private static var extraWindows: [NSWindow] = []
    static func schedule(model: ArchiveModel) {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let output = value("--snapshot") else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let scenario = value("--scenario") ?? "main"
        let width = Double(value("--width") ?? "") ?? 1160
        let height = Double(value("--height") ?? "") ?? 780
        Task {
            let started = Date()
            while (model.loading || (model.overview != nil && model.loadingMessages)) && Date().timeIntervalSince(started) < 20 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(800))
            if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                window.setContentSize(NSSize(width: width, height: height))
                window.makeKeyAndOrderFront(nil)
            }
            try? await Task.sleep(for: .milliseconds(400))
            if scenario == "performance" || scenario == "composer-checks" || scenario == "send-animation" {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if scenario == "performance" { await ResponsivenessRunner.run(model: model, output: directory) }
                else if scenario == "send-animation" { await SendAnimationRunner.run(model: model, output: directory) }
                else { await ResponsivenessRunner.validate(model: model, output: directory) }
                exit(0)
            }
            if scenario == "idle" {
                let seconds = Int(value("--seconds") ?? "") ?? 5
                if let id = value("--conversation") { model.select(id); while model.loadingMessages { try? await Task.sleep(for: .milliseconds(20)) } }
                for _ in 0..<(Int(value("--earlier") ?? "") ?? 0) where model.hasEarlier {
                    model.loadMore(earlier: true)
                    while model.paging { try? await Task.sleep(for: .milliseconds(20)) }
                }
                try? await Task.sleep(for: .seconds(2))
                // The connected worker repeats its status every two seconds.
                if let count = Int(value("--arrival-cost") ?? ""), let conversation = model.selectedID,
                   ["review-fixture", "livecopy"].contains(model.directory?.lastPathComponent ?? "") {
                    // Writes to a disposable copy only, never a real archive.
                    var db: OpaquePointer?
                    sqlite3_open_v2(model.directory!.appendingPathComponent("archive.db").path, &db, SQLITE_OPEN_READWRITE, nil)
                    let arrivals = await ResponsivenessRunner.changeCost(count: count, settle: 1800) { index in
                        let id = "perf-arrival-\(index)-\(UUID().uuidString)"
                        let stamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
                        let payload = #"{"id":"\#(id)","conversation_id":"\#(conversation)","body":"Timing check \#(index)","sender":"Test","outgoing":false,"transport":"RCS","status":"INCOMING_COMPLETE"}"#
                        sqlite3_exec(db, "INSERT INTO messages VALUES('\(id)','\(conversation)',\(stamp),'Timing check','Test','\(payload)'); UPDATE conversations SET last_message=\(stamp) WHERE id='\(conversation)'", nil, nil, nil)
                    }
                    sqlite3_close(db)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metrics: [String: Any] = ["arrival_cpu_ms": arrivals.medianMS, "arrival_redraws": arrivals.renders, "messages": model.messages.count]
                    try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if arguments.contains("--slide-trace") {
                    // Per display frame, with as few reads as possible: sidebar width,
                    // the search field's window position, the split view's width.
                    NSApp.activate(ignoringOtherApps: true)
                    guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { exit(4) }
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    func split(_ view: NSView) -> NSSplitView? { (view as? NSSplitView) ?? view.subviews.lazy.compactMap(split).first }
                    func searchField(_ view: NSView) -> NSSearchField? { (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField).first }
                    guard let splitView = window.contentView.flatMap(split), let field = splitView.arrangedSubviews.first.flatMap(searchField) else { exit(5) }
                    let sidebarItem = (splitView.delegate as? NSSplitViewController)?.splitViewItems.first
                    var lines: [String] = []
                    for pass in ["close", "open"] {
                        lines.append("--- \(pass)")
                        let start = Date()
                        ResponsivenessRunner.toggleSidebar()
                        _ = await ResponsivenessRunner.frames {
                            while Date().timeIntervalSince(start) < 0.6 {
                                try? await Task.sleep(for: .milliseconds(8))
                                let width = ResponsivenessRunner.sidebarWidth()
                                let sx = Int(field.convert(field.bounds, to: nil).minX)
                                let state = sidebarItem.map { "\($0.isCollapsed ? "c" : "o")\($0.collapseBehavior.rawValue)" } ?? "?"
                                lines.append(String(format: "%4.0fms w%3d search-x%5d split-w%5d %@", Date().timeIntervalSince(start) * 1000, Int(width), sx, Int(splitView.frame.width), state))
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("slide-trace.txt"), atomically: true, encoding: .utf8)
                    exit(0)
                }
                if arguments.contains("--toolbar-trace") {
                    // On every display frame of a close then an open, records the
                    // sidebar width and each toolbar item's position, to show which
                    // items AppKit removes, re-adds or moves abruptly.
                    NSApp.activate(ignoringOtherApps: true)
                    guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { exit(4) }
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    var lines: [String] = []
                    func split(_ view: NSView) -> NSSplitView? { (view as? NSSplitView) ?? view.subviews.lazy.compactMap(split).first }
                    let splitView = window.contentView.flatMap(split)
                    @MainActor func describe() -> String {
                        let items = (window.toolbar?.items ?? []).map { item -> String in
                            let id = item.itemIdentifier.rawValue.replacingOccurrences(of: "com.apple.SwiftUI.", with: "").prefix(22)
                            guard let view = item.view, view.superview != nil else { return "\(id)[-]" }
                            let frame = view.convert(view.bounds, to: nil)
                            return "\(id)[\(Int(frame.minX))+\(Int(frame.width))\(view.isHiddenOrHasHiddenAncestor ? "h" : "")]"
                        }
                        func searchField(_ view: NSView) -> NSSearchField? { (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField).first }
                        var field = "no-sidebar-search"
                        if let sidebar = splitView?.arrangedSubviews.first, let found = searchField(sidebar) {
                            let frame = found.convert(found.bounds, to: nil)
                            field = "search[\(Int(frame.minX))+\(Int(frame.width))\(found.isHiddenOrHasHiddenAncestor ? "h" : "")]"
                        }
                        let width = ResponsivenessRunner.sidebarWidth()
                        let sidebarItem = (splitView?.delegate as? NSSplitViewController)?.splitViewItems.first
                        let state = sidebarItem.map { "\($0.isCollapsed ? "collapsed" : "open")/b\($0.collapseBehavior.rawValue)" } ?? "?"
                        return "sidebar \(Int(width)) \(state) \(field): " + items.joined(separator: " ")
                    }
                    for pass in ["close", "open"] {
                        lines.append("--- \(pass)")
                        let start = Date()
                        ResponsivenessRunner.toggleSidebar()
                        var last = ""
                        while Date().timeIntervalSince(start) < 0.8 {
                            let now = describe()
                            if now != last { lines.append(String(format: "%4.0fms ", Date().timeIntervalSince(start) * 1000) + now); last = now }
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("toolbar-trace.txt"), atomically: true, encoding: .utf8)
                    exit(0)
                }
                if arguments.contains("--toolbar-shots") {
                    try? await Task.sleep(for: .seconds(1))
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for name in ["open", "collapsed"] {
                        if name == "collapsed" { ResponsivenessRunner.toggleSidebar(); try? await Task.sleep(for: .seconds(1)) }
                        if let window = NSApp.windows.first(where: { $0.isVisible }), let rep = render(window), let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("toolbar-\(name).png"))
                        }
                    }
                    exit(0)
                }
                if let fraction = Double(value("--scroll-shot") ?? "") {
                    // Scrolls up as a user would, then renders what is on screen.
                    if arguments.contains("--force-hover"), let id = model.selectedID {
                        RenderCount.forceHover = true
                        model.select(id, force: true)
                        while model.loadingMessages { try? await Task.sleep(for: .milliseconds(20)) }
                    }
                    try? await Task.sleep(for: .seconds(1))
                    guard let scroll = ResponsivenessRunner.timelineScrollView(), let document = scroll.documentView else { exit(5) }
                    let target = document.frame.height * fraction
                    let startY = scroll.contentView.bounds.origin.y
                    for step in 1...40 {
                        let y = startY + (target - startY) * Double(step) / 40
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let window = NSApp.windows.first(where: { $0.isVisible }), let rep = render(window), let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: directory.appendingPathComponent("scrolled-0.png"))
                    }
                    try? JSONSerialization.data(withJSONObject: ["offset": scroll.contentView.bounds.origin.y], options: []).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if let steps = Int(value("--resize-cost") ?? "") {
                    // A sidebar slide, as window widths laid out one after another;
                    // forced layout keeps this independent of the display.
                    if let id = value("--conversation") { model.select(id); while model.loadingMessages { try? await Task.sleep(for: .milliseconds(20)) } }
                    if arguments.contains("--no-conversation") { model.selectedID = nil }
                    try? await Task.sleep(for: .seconds(1))
                    guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { exit(4) }
                    let start = window.frame
                    // Settle once so any off-screen spacing is in place.
                    window.contentView?.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(500))
                    var costs: [Double] = [], worst: [Double] = [], spikes: [String] = []
                    for round in 0..<4 {
                        let cpu = ResponsivenessRunner.threadCPU()
                        var roundWorst = 0.0
                        for step in 0...steps {
                            let progress = Double(step) / Double(steps)
                            let width = start.width + (round % 2 == 0 ? progress : 1 - progress) * 308
                            let stepStart = ResponsivenessRunner.threadCPU()
                            window.setFrame(NSRect(x: start.minX, y: start.minY, width: width, height: start.height), display: false)
                            window.contentView?.layoutSubtreeIfNeeded()
                            await Task.yield()
                            let stepCost = (ResponsivenessRunner.threadCPU() - stepStart) * 1000
                            roundWorst = max(roundWorst, stepCost)
                            if stepCost > 8 { spikes.append("r\(round) w\(Int(width)): \(Int(stepCost))ms") }
                        }
                        worst.append(roundWorst)
                        costs.append((ResponsivenessRunner.threadCPU() - cpu) * 1000 / Double(steps + 1))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metrics: [String: Any] = ["layout_ms_per_frame": costs, "worst_frame_ms": worst, "spikes": spikes, "messages": model.messages.count]
                    try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if let count = Int(value("--sidebar-toggle") ?? "") {
                    if let id = value("--conversation") { model.select(id); while model.loadingMessages { try? await Task.sleep(for: .milliseconds(20)) } }
                    if arguments.contains("--no-conversation") { model.selectedID = nil }
                    if arguments.contains("--activate") {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    var stalls: [Double] = [], costs: [Double] = [], mainCosts: [Double] = [], widths: [String] = [], dropped: [Int] = [], frameCounts: [Int] = [], slow: [String] = [], snaps: [String] = []
                    let renders = await RenderCount.during {
                        for _ in 0..<count {
                            try? await Task.sleep(for: .milliseconds(400))
                            let start = ResponsivenessRunner.cpuNow(), mainStart = ResponsivenessRunner.threadCPU()
                            let before = ResponsivenessRunner.sidebarWidth()
                            let frames = await ResponsivenessRunner.frames {
                                ResponsivenessRunner.toggleSidebar()
                                try? await Task.sleep(for: .milliseconds(700))
                            }
                            stalls.append(frames.worstMS); dropped.append(frames.over12ms); frameCounts.append(frames.count)
                            slow.append(ResponsivenessRunner.lastSlowFrames.joined(separator: ", "))
                            let snap = ResponsivenessRunner.lastSnap
                            snaps.append("\(Int(snap.points))pt (\(Int(snap.share * 100))%) at \(Int(snap.at))")
                            costs.append((ResponsivenessRunner.cpuNow() - start) * 1000)
                            mainCosts.append((ResponsivenessRunner.threadCPU() - mainStart) * 1000)
                            widths.append("\(Int(before))→\(Int(ResponsivenessRunner.sidebarWidth()))")
                        }
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metrics: [String: Any] = ["worst_frame_ms_median": stalls.sorted()[stalls.count / 2], "worst_frame_ms_max": stalls.max() ?? 0, "long_frames": dropped, "frames": frameCounts,
                                                  "toggle_cpu_ms_median": costs.sorted()[costs.count / 2], "toggle_main_cpu_ms_median": mainCosts.sorted()[mainCosts.count / 2], "redraws_per_toggle": renders.mapValues { $0 / count }, "messages": model.messages.count, "sidebar_widths": widths, "slow_frames": slow, "largest_step": snaps]
                    try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if let ids = value("--landing")?.split(separator: ",").map(String.init) {
                    var results: [[String: Any]] = []
                    for round in 0..<2 {
                        for id in ids {
                            try? await Task.sleep(for: .milliseconds(300))
                            let landing = await ResponsivenessRunner.landing(model: model, conversation: id)
                            results.append(["conversation": id, "round": round, "reversals": landing.reversals, "travel": Int(landing.travel), "from_bottom": Int(landing.fromBottom)])
                        }
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? JSONSerialization.data(withJSONObject: ["landings": results], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if let ids = value("--switch-between")?.split(separator: ",").map(String.init) {
                    var stalls: [Double] = [], ready: [Double] = []
                    for index in 0..<(Int(value("--switches") ?? "") ?? 10) {
                        try? await Task.sleep(for: .milliseconds(500))
                        let start = Date()
                        stalls.append(await ResponsivenessRunner.longestStall {
                            model.select(ids[index % ids.count])
                            while model.loadingMessages { try? await Task.sleep(for: .milliseconds(2)) }
                            ready.append(Date().timeIntervalSince(start) * 1000)
                            try? await Task.sleep(for: .milliseconds(300))
                        })
                    }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metrics: [String: Any] = ["switch_stall_ms_median": stalls.sorted()[stalls.count / 2], "switch_stall_ms_max": stalls.max() ?? 0, "switch_loaded_ms_median": ready.sorted()[ready.count / 2]]
                    try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if let count = Int(value("--publish-cost") ?? "") {
                    let status = await ResponsivenessRunner.changeCost(count: count) { model.syncStateChanged($0 % 2 == 0 ? .photosPending : .connected) }
                    let typing = await ResponsivenessRunner.changeCost(count: count) { model.typingChanged(digest: "elsewhere", active: $0 % 2 == 0) }
                    let highlight = await ResponsivenessRunner.changeCost(count: count) { model.highlightedID = $0 % 2 == 0 ? model.messages.first?.id : nil }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metrics: [String: Any] = ["status_cpu_ms": status.medianMS, "status_redraws": status.renders, "typing_elsewhere_cpu_ms": typing.medianMS, "typing_elsewhere_redraws": typing.renders,
                                                  "highlight_cpu_ms": highlight.medianMS, "highlight_redraws": highlight.renders, "messages": model.messages.count, "conversation": model.selectedID ?? ""]
                    try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                    exit(0)
                }
                if arguments.contains("--status-pulse") {
                    Task { while true { model.syncStateChanged(.connected); try? await Task.sleep(for: .seconds(2)) } }
                }
                let result = await ResponsivenessRunner.idle(model: model, seconds: seconds)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let metrics: [String: Any] = ["idle_cpu_percent": result.cpuPercent, "idle_redraws": result.renders, "seconds": seconds]
                try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle.json"))
                exit(0)
            }
            apply(scenario, to: model)
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if arguments.contains("--dump"), let content = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                var lines: [String] = []
                @MainActor func walk(_ view: NSView, _ depth: Int) {
                    lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden)")
                    if depth < 14 { for child in view.subviews { walk(child, depth + 1) } }
                }
                walk(content, 0)
                try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("\(scenario)-views.txt"), atomically: true, encoding: .utf8)
            }
            for (index, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                guard let rep = render(window), let data = rep.representation(using: .png, properties: [:]) else { continue }
                try? data.write(to: directory.appendingPathComponent("\(scenario)-\(index).png"))
            }
            exit(0)
        }
    }

    private static func apply(_ scenario: String, to model: ArchiveModel) {
        switch scenario {
        case "search": model.query = "booking"
        case "thread":
            model.showingThreadSearch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.threadQuery = "booking" }
        case "info": model.showingDetails = true
        case "settings", "settings-general", "settings-notifications", "settings-connection", "settings-history":
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        case "welcome": break
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "darkinfo": NSApp.appearance = NSAppearance(named: .darkAqua); model.showingDetails = true
        case "accounts": model.showingAccountSetup = false; model.showingAccounts = true
        case "empty": if let empty = model.conversations.first(where: { $0.messageCount == 0 }) { model.select(empty.id) }
        case "contact": if let dad = model.conversations.first(where: { $0.id == "dad" }) { model.select(dad.id) }
        case "draft": model.editDraft("A draft that has not been sent yet.\nSecond line of the draft.")
        case "old": model.select("alex", messageID: "alex-0000")
        case "newmessage": model.showingNewMessage = true
        case "inspector":
            // The inspector column renders off-process in glass mode, so host the
            // same view in a plain window to check its layout.
            if let conversation = model.selectedConversation {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Inspector"
                window.contentView = NSHostingView(rootView: ConversationInfo(conversation: conversation).environment(model))
                window.orderFront(nil)
                extraWindows.append(window)
            }
        default: break
        }
    }

    static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let content = window.contentView, let frame = content.superview, let layer = frame.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = frame.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        // Paint the window background first; backdrop (blur) layers do not render offscreen.
        context.setFillColor((window.backgroundColor ?? .windowBackgroundColor).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
#endif
