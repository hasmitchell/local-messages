import Foundation

struct ConversationRecord: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let folder: String
    let timestamp: Int64
    let preview: String
    let messageCount: Int
    var unread = false
    var participants: [ConversationParticipant] = []
    var otherParticipants: [ConversationParticipant] { participants.filter { !$0.isMe } }
    var numbers: String { otherParticipants.map(\.number).filter { !$0.isEmpty }.joined(separator: ", ") }
    var ownParticipantIDs: Set<String> { Set(participants.filter(\.isMe).map(\.id)) }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000_000) }
    var title: String {
        if !name.isEmpty { return name }
        let people = otherParticipants.map { $0.name.isEmpty ? $0.number : $0.name }.filter { !$0.isEmpty }
        return people.isEmpty ? "Unknown number" : people.joined(separator: ", ")
    }
    var isGroup: Bool { otherParticipants.count > 1 }
    var isEmpty: Bool { messageCount == 0 }
    /// Contact photo for one-to-one conversations; paths are data, so they are confined to media/avatars.
    func avatarURL(in directory: URL) -> URL? {
        guard !isGroup, let path = otherParticipants.first?.avatarPath, path.hasPrefix("media/avatars/"),
              !path.split(separator: "/").contains("..") else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/media/avatars/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var isArchived: Bool { folder == "ARCHIVE" }
}

struct ConversationParticipant: Codable, Sendable, Hashable, Identifiable {
    let id, name, number: String
    let isMe: Bool
    /// Relative path of the phone's contact photo, filled from the archive's avatar table.
    var avatarPath: String? = nil
    enum CodingKeys: String, CodingKey { case id, name, number; case isMe = "is_me" }
}

struct ContactEntry: Identifiable, Sendable, Hashable {
    let id, name, number: String
    var avatarPath: String? = nil
    var title: String { name.isEmpty ? number : name }
}

struct SharedFile: Identifiable, Sendable {
    let message: MessageRecord
    let attachment: AttachmentRecord
    var id: String { message.id + ":" + attachment.id }
}
struct SharedLink: Identifiable, Sendable {
    let message: MessageRecord
    let url: URL
    var id: String { message.id + ":" + url.absoluteString }
}
struct ConversationLibrary: Sendable {
    var files: [SharedFile] = []
    var links: [SharedLink] = []
    var scanned = 0
    var hasMore = false
}

enum TimelinePolicy {
    static func followsLatest(atBottom: Bool, hasLater: Bool, highlighting: Bool) -> Bool { atBottom && !hasLater && !highlighting }
}

struct AttachmentRecord: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let mime: String
    let size: Int64
    let path: String?
    let state: String
    var mediaType: String { mime.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "" }
    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isContact: Bool {
        ["text/vcard", "text/x-vcard", "application/vcard", "application/x-vcard"].contains(mediaType) || name.lowercased().hasSuffix(".vcf")
    }
    var isDownloaded: Bool { state == "downloaded_original" }
    var displayName: String { name.isEmpty ? (isImage ? "Photo" : isContact ? "Shared contact" : "Attachment") : name }

    // Treat paths in an archive as data, not permission to open arbitrary files.
    func localURL(in directory: URL) -> URL? {
        guard isDownloaded, let path, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/media/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

struct ReactionRecord: Decodable, Sendable, Hashable {
    let emoji: String
    let participants: [String]?
    var count: Int { max(1, participants?.count ?? 0) }
}

struct MessageRecord: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let conversationID: String
    let body: String
    let sender: String
    let outgoing: Bool
    let transport: String
    let status: String
    let replyTo: String?
    private let savedAttachments: [AttachmentRecord]?
    private let savedReactions: [ReactionRecord]?
    var timestamp: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, body, sender, outgoing, transport, status
        case conversationID = "conversation_id", replyTo = "reply_to"
        case savedAttachments = "attachments", savedReactions = "reactions"
    }
    var attachments: [AttachmentRecord] { savedAttachments ?? [] }
    var reactions: [ReactionRecord] { savedReactions ?? [] }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000_000) }
    var preview: String {
        if !body.isEmpty { return body.replacingOccurrences(of: "\n", with: " ") }
        if !attachments.isEmpty { return attachments.count == 1 ? attachments[0].displayName : "\(attachments.count) attachments" }
        return status.contains("DELETED") ? "Deleted message" : "Message"
    }
    var deliveryLabel: String? {
        guard outgoing else { return nil }
        if status.contains("FAILED") { return "Failed to send" }
        if status.contains("READ") || status.contains("DISPLAYED") { return "Read" }
        if status.contains("DELIVERED") { return "Delivered" }
        if status == "OUTGOING_COMPLETE" { return "Sent" }
        if status.contains("SENDING") || status.contains("YET_TO_SEND") || status.contains("AWAITING_RETRY") { return "Sending" }
        if status.contains("SENT") || status.contains("SEND_COMPLETE") { return "Sent" }
        return nil
    }
}

struct ArchiveOverview: Sendable, Equatable {
    let conversations: [ConversationRecord]
    let messageCount: Int
    let imageCount: Int
    let newest: Date?
    var avatarURLs: [String: URL] = [:]
}

struct MessageWindow: Sendable {
    let messages: [MessageRecord]
    let hasEarlier: Bool
    let hasLater: Bool
    var submissions: [String: String] = [:]
}

struct SearchPage: Sendable {
    let messages: [MessageRecord]
    let total: Int
}

enum ArchiveFailure: LocalizedError {
    case missing, incompatible, reading
    var errorDescription: String? {
        switch self {
        case .missing: "Choose a folder containing an imported message archive."
        case .incompatible: "This folder does not contain a supported message archive."
        case .reading: "The archive could not be read. Try reloading it after the import finishes."
        }
    }
}

struct MessageArrival: Sendable {
    let sequence: Int64
    let message: MessageRecord
}
enum NotificationPolicy {
    static func shouldNotify(_ message: MessageRecord, started: Date, now: Date, activeConversation: String?) -> Bool {
        !message.outgoing && message.status.hasPrefix("INCOMING_") && !message.status.contains("DELETED") && !message.status.contains("FAILED") && !message.status.contains("DOWNLOAD") && message.conversationID != activeConversation && message.date >= started && message.date >= now.addingTimeInterval(-300) && message.date <= now.addingTimeInterval(60)
    }
}
