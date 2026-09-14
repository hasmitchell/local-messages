import AppKit
import ImageIO
import SwiftUI

// Shared colours, avatar, date labels and text helpers for the whole interface.

let archiveBubble = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.11, green: 0.50, blue: 0.44, alpha: 1)
        : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.38, alpha: 1)
})
let archiveAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.34, green: 0.81, blue: 0.71, alpha: 1)
        : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.38, alpha: 1)
})
// Fill for prominent buttons: dark enough for white text in both appearances.
let archiveProminent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.07, green: 0.44, blue: 0.38, alpha: 1)
        : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.38, alpha: 1)
})

extension View {
    /// The app's prominent button: teal fill with readable white text.
    func prominentButton() -> some View { buttonStyle(.borderedProminent).tint(archiveProminent) }
}

// Content scrolls beneath the glass toolbar. macOS 26's soft edge fade leaves
// the title sitting on message text; the hard style puts a translucent band
// under the toolbar so the title stays legible while the glass look remains.
struct LegibleToolbarEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.scrollEdgeEffectStyle(.hard, for: .top) } else { content }
    }
}

// One vocabulary of motion for the whole app.
enum Motion {
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.82)
    static let bouncy = Animation.spring(response: 0.32, dampingFraction: 0.55)
}

// Icon buttons that squash on press and spring back.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.bouncy, value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == BouncyButtonStyle {
    static var bouncy: BouncyButtonStyle { BouncyButtonStyle() }
}

// Floating circular control that jumps a scroll view to an edge. The material
// disc is part of the label, so the whole circle is the hit area and the
// whole disc squashes on press.
struct FloatingJumpButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(archiveAccent)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.bouncy)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .help(title).accessibilityLabel(title)
    }
}

let incomingBubble = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.13)
        : NSColor(white: 0, alpha: 0.065)
})
let composerField = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.07)
        : NSColor(white: 0, alpha: 0.035)
})

struct Avatar: View {
    let name: String
    let size: CGFloat
    var group = false
    var imageURL: URL? = nil
    @State private var photo: CGImage?

    private var letters: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.13, green: 0.55, blue: 0.49), Color(red: 0.36, green: 0.42, blue: 0.86), Color(red: 0.86, green: 0.47, blue: 0.20),
            Color(red: 0.80, green: 0.33, blue: 0.48), Color(red: 0.24, green: 0.53, blue: 0.82), Color(red: 0.55, green: 0.38, blue: 0.80),
            Color(red: 0.60, green: 0.45, blue: 0.30), Color(red: 0.30, green: 0.60, blue: 0.35)
        ]
        let value = name.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
        return palette[Int(value % UInt64(palette.count))]
    }
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.78), color], startPoint: .top, endPoint: .bottom))
            if let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
            } else if group { Image(systemName: "person.2.fill").font(.system(size: size * 0.40, weight: .medium)).foregroundStyle(.white) }
            else if letters.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white) }
            else { Text(letters).font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
        .task(id: imageURL) {
            guard let imageURL else { photo = nil; return }
            let loaded = await ThumbnailStore.shared.image(at: imageURL)?.image
            guard !Task.isCancelled else { return }
            photo = loaded
        }
    }
}

enum RelativeDate {
    private static func dayLabel(_ date: Date, now: Date, calendar: Calendar, long: Bool) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let recent = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= recent {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return long ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)) : date.formatted(.dateTime.day().month(.abbreviated))
        }
        return long ? date.formatted(.dateTime.day().month(.wide).year()) : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
    /// Compact label for list rows: time today, weekday this week, otherwise a date.
    static func list(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return dayLabel(date, now: now, calendar: calendar, long: false)
    }
    /// Timeline separator such as "Today 5:58 pm" or "Wed, 10 September 3:15 pm".
    static func separator(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        dayLabel(date, now: now, calendar: calendar, long: true) + "  " + date.formatted(date: .omitted, time: .shortened)
    }
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

// Message text is untrusted content: only detected http(s) links become tappable.
enum MessageText {
    private final class Box: @unchecked Sendable { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 2000; return cache }()
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkified(_ text: String) -> AttributedString {
        if let cached = cache.object(forKey: text as NSString) { return cached.value }
        var result = AttributedString(text)
        if let detector {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
                result[attributed].link = url
                result[attributed].underlineStyle = .single
            }
        }
        cache.setObject(Box(result), forKey: text as NSString)
        return result
    }

    /// Bolds each whitespace-separated query term inside a search result preview.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace).map(String.init) where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let attributed = Range(found, in: result) { result[attributed].inlinePresentationIntent = .stronglyEmphasized }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return result
    }
}

// Image pixel sizes let the timeline reserve the final frame before the
// thumbnail decodes, so scrolling to a message never drifts afterwards.
final class ImageSizeCache: @unchecked Sendable {
    static let shared = ImageSizeCache()
    private let cache = NSCache<NSURL, NSValue>()
    func size(for url: URL) -> CGSize? {
        if let known = cache.object(forKey: url as NSURL) { return known.sizeValue }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        cache.setObject(NSValue(size: size), forKey: url as NSURL)
        return size
    }
    static func fit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        return CGSize(width: max(80, (size.width * scale).rounded()), height: max(80, (size.height * scale).rounded()))
    }
}

// Observes whether the hosting window is key, so notification suppression and
// unread tracking react to the real window rather than to any key window.
struct WindowKeyObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> NSView { let view = ObservingView(); view.changed = changed; return view }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ObservingView)?.changed = changed }

    final class ObservingView: NSView {
        var changed: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            // Selector observers are unregistered automatically when the view deallocates.
            center.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: window)
            changed?(window.isKeyWindow)
        }
        @objc private func becameKey(_ note: Notification) { changed?(true) }
        @objc private func resignedKey(_ note: Notification) { changed?(false) }
    }
}
