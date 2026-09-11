import Foundation

struct DraftRecord: Codable, Sendable, Equatable {
    var body = ""
    var submissionID: String?
    var files: [DraftAttachment]?
    var attachments: [DraftAttachment] { files ?? [] }
}
actor DraftRepository {
    private var versions: [String: Int] = [:]
    private func draftFile(_ directory: URL) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("drafts", isDirectory: true)
        let file = folder.appendingPathComponent("drafts.json")
        guard folder.resolvingSymlinksInPath().path == folder.path, file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileWriteInvalidFileName) }
        return file
    }
    func load(directory: URL) throws -> [String: DraftRecord] {
        let file = try draftFile(directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: DraftRecord].self, from: Data(contentsOf: file))
    }
    func save(_ drafts: [String: DraftRecord], directory: URL, revision: Int) throws {
        guard revision > (versions[directory.path] ?? -1) else { return }
        let file = try draftFile(directory)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try JSONEncoder().encode(drafts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        versions[directory.path] = revision
    }
}

struct SendCommand: Codable, Sendable, Hashable {
    var kind = "send_text"
    var connection: String? = nil
    let id: String
    let conversationID: String
    let body: String
    var files: [DraftAttachment]? = nil
    var messageID: String? = nil
    var emoji: String? = nil
    enum CodingKeys: String, CodingKey { case kind, id, body, connection, files, emoji; case conversationID = "conversation_id", messageID = "message_id" }
    static func validBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.unicodeScalars.count <= 4000 && body.utf8.count <= 16000
    }
}

struct OutboxRecord: Identifiable, Sendable, Hashable {
    let id, conversationID, body, state, reason, remoteID: String
    let created: Int64
    var command: SendCommand? = nil
    var isReaction: Bool { command?.kind == "react" }
    var files: [DraftAttachment] { command?.files ?? [] }
    var label: String {
        switch state {
        case "preparing": "Preparing to send…"
        case "sending": files.isEmpty ? "Sending…" : "Uploading attachments and sending…"
        case "accepted": "Accepted by phone · Waiting for message"
        case "confirmed": "On your phone · Updating conversation"
        case "unknown": "Send unconfirmed · Check your phone before sending again"
        case "failed": reason == "offline" ? "Not sent · Phone connection unavailable" : reason == "preflight" ? "Not sent · Check conversation, SIM and attached files" : reason == "attachment_preparation" ? "Not sent · Attachment upload failed" : reason == "phone_rejected" ? "Phone rejected this message" : "Not sent · Interrupted before sending"
        default: "Checking send status…"
        }
    }
}
