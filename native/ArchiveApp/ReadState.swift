import CryptoKit
import Foundation

// Records which conversations were viewed on this Mac. Reading here never
// changes the phone's read state, so the unread marker combines the phone's
// flag with a local "seen up to this message" watermark.
@MainActor
final class SeenStore {
    private let key: String
    private var seen: [String: Int64]

    init(directory: URL) {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        key = "seen:" + digest.prefix(24)
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        seen = stored.mapValues(Int64.init)
    }

    func isUnread(_ conversation: ConversationRecord) -> Bool {
        conversation.unread && (seen[conversation.id] ?? 0) < conversation.timestamp
    }

    @discardableResult
    func markSeen(_ id: String, timestamp: Int64) -> Bool {
        guard (seen[id] ?? 0) < timestamp else { return false }
        seen[id] = timestamp
        if seen.count > 2000 {
            // Keep the store bounded; the oldest watermarks are the least useful.
            for (dropped, _) in seen.sorted(by: { $0.value < $1.value }).prefix(500) { seen.removeValue(forKey: dropped) }
        }
        UserDefaults.standard.set(seen.mapValues(Int.init), forKey: key)
        return true
    }
}
