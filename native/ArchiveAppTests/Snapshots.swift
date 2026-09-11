#if UI_SNAPSHOTS
import AppKit
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
            apply(scenario, to: model)
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if arguments.contains("--dump"), let content = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                var lines: [String] = []
                func walk(_ view: NSView, _ depth: Int) {
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
        case "inspector":
            // The inspector column renders off-process in glass mode, so host the
            // same view in a plain window to check its layout.
            if let conversation = model.selectedConversation {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Inspector"
                window.contentView = NSHostingView(rootView: ConversationInfo(conversation: conversation).environmentObject(model))
                window.orderFront(nil)
                extraWindows.append(window)
            }
        default: break
        }
    }

    private static func render(_ window: NSWindow) -> NSBitmapImageRep? {
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
