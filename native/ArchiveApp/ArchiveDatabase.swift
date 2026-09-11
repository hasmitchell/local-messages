import Foundation
import SQLite3

private func authorizeArchiveRead(_ context: UnsafeMutableRawPointer?, _ action: Int32, _ first: UnsafePointer<CChar>?, _ second: UnsafePointer<CChar>?, _ database: UnsafePointer<CChar>?, _ source: UnsafePointer<CChar>?) -> Int32 {
    switch action {
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE: return SQLITE_OK
    // FTS5 checks this read-only pragma when preparing a search.
    case SQLITE_PRAGMA:
        return first.map { String(cString: $0) == "data_version" } == true && second == nil ? SQLITE_OK : SQLITE_DENY
    default: return SQLITE_DENY
    }
}

// The connection belongs to ArchiveDatabase's actor. FULLMUTEX also protects
// SQLite during deinitialisation; no handle or statement is exposed to the UI.
private final class ReadConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(directory: URL) throws {
        let file = directory.appendingPathComponent("archive.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ArchiveFailure.missing }
        var opened: OpaquePointer?
        // Apple's SQLite needs a writable handle to initialise missing WAL/SHM
        // sidecars after the importer closes. Do not use CREATE. Both query_only
        // and the authorizer below prevent message, schema and pragma writes.
        var result = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        if result != SQLITE_OK {
            if let opened { sqlite3_close(opened) }
            opened = nil
            result = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ArchiveFailure.reading
        }
        handle = opened
        sqlite3_busy_timeout(handle, 1500)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { throw ArchiveFailure.reading }
        sqlite3_set_authorizer(handle, authorizeArchiveRead, nil)
    }
    deinit { sqlite3_close(handle) }
}

private enum BoundValue { case text(String), integer(Int64) }
private final class ReadStatement {
    let handle: OpaquePointer
    init(_ database: ReadConnection, _ sql: String, _ values: [BoundValue] = []) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw ArchiveFailure.incompatible }
        handle = prepared
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(handle, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(handle, index, number)
            }
            guard result == SQLITE_OK else { throw ArchiveFailure.reading }
        }
    }
    deinit { sqlite3_finalize(handle) }
    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ArchiveFailure.reading
        }
    }
    func text(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: value)
    }
    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func data(_ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(handle, column)))
    }
}

actor ArchiveDatabase {
    private let connection: ReadConnection
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        connection = try ReadConnection(directory: directory)
    }

    #if ARCHIVE_TESTING
    func rejectsWritesForTesting() -> Bool {
        sqlite3_exec(connection.handle, "PRAGMA query_only=OFF", nil, nil, nil) != SQLITE_OK &&
        sqlite3_exec(connection.handle, "DELETE FROM messages", nil, nil, nil) != SQLITE_OK &&
        sqlite3_exec(connection.handle, "CREATE TABLE unexpected(value TEXT)", nil, nil, nil) != SQLITE_OK
    }
    #endif

    private func hasTable(_ name: String) throws -> Bool {
        try scalar("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)", [.text(name)]) == 1
    }
    func outbox(conversation: String) throws -> [OutboxRecord] {
        guard try hasTable("outbox") else { return [] }
        let command = try hasTable("outbox_commands") ? "(SELECT payload FROM outbox_commands c WHERE c.id=outbox.id)" : "NULL"
        let rows = try ReadStatement(connection, "SELECT id,conversation_id,body,state,reason,remote_id,created,\(command) FROM outbox WHERE conversation_id=? AND state!='applied' AND (state!='confirmed' OR NOT EXISTS(SELECT 1 FROM messages WHERE id=outbox.remote_id)) ORDER BY created", [.text(conversation)])
        var result: [OutboxRecord] = []
        while try rows.next() { result.append(OutboxRecord(id: rows.text(0), conversationID: rows.text(1), body: rows.text(2), state: rows.text(3), reason: rows.text(4), remoteID: rows.text(5), created: rows.integer(6), command: try? JSONDecoder().decode(SendCommand.self, from: rows.data(7)))) }
        return result
    }
    struct SubmissionStatus: Sendable { let state, reason, remoteID: String }
    func submission(_ id: String) throws -> SubmissionStatus? {
        guard try hasTable("outbox") else { return nil }
        let row = try ReadStatement(connection, "SELECT state,reason,remote_id FROM outbox WHERE id=?", [.text(id)])
        guard try row.next() else { return nil }
        return SubmissionStatus(state: row.text(0), reason: row.text(1), remoteID: row.text(2))
    }
    func submissionExists(_ id: String) throws -> Bool {
        guard try hasTable("outbox") else { return false }
        return try scalar("SELECT EXISTS(SELECT 1 FROM outbox WHERE id=?)", [.text(id)]) == 1
    }
    func arrivalCursor() throws -> Int64 {
        guard try hasTable("arrivals") else { return 0 }
        return try scalar("SELECT coalesce(max(sequence),0) FROM arrivals", [])
    }
    func arrivals(after sequence: Int64) throws -> [MessageArrival] {
        guard try hasTable("arrivals") else { return [] }
        let rows = try ReadStatement(connection, "SELECT a.sequence,m.timestamp,m.payload FROM arrivals a JOIN messages m ON m.id=a.message_id WHERE a.sequence>? ORDER BY a.sequence LIMIT 200", [.integer(sequence)])
        var result: [MessageArrival] = []
        while try rows.next() {
            var message = try JSONDecoder().decode(MessageRecord.self, from: rows.data(2))
            message.timestamp = rows.integer(1)
            result.append(MessageArrival(sequence: rows.integer(0), message: message))
        }
        return result
    }

    func isLive() throws -> Bool {
        let row = try ReadStatement(connection, "SELECT value FROM metadata WHERE key='kind'")
        return try row.next() && row.text(0) == "live"
    }

    func dataVersion() throws -> Int64 { try scalar("PRAGMA data_version", []) }

    // Re-read exactly the visible range. New messages stay behind a button so
    // background sync cannot jump away from a search result or older history.
    func refresh(_ visible: [MessageRecord], conversation: String, followingLatest: Bool = false) throws -> MessageWindow {
        if followingLatest { return try latest(conversation: conversation) }
        guard let first = visible.first, let last = visible.last else { return try latest(conversation: conversation) }
        let messages = try readMessages("WHERE conversation_id=? AND (timestamp>? OR (timestamp=? AND id>=?)) AND (timestamp<? OR (timestamp=? AND id<=?)) ORDER BY timestamp,id",
            [.text(conversation), .integer(first.timestamp), .integer(first.timestamp), .text(first.id), .integer(last.timestamp), .integer(last.timestamp), .text(last.id)])
        return try window(messages, conversation: conversation)
    }

    private func avatarPaths() throws -> [String: String] {
        guard try hasTable("participant_avatars") else { return [:] }
        let rows = try ReadStatement(connection, "SELECT participant_id,path FROM participant_avatars WHERE path!=''")
        var paths: [String: String] = [:]
        while try rows.next() { paths[rows.text(0)] = rows.text(1) }
        return paths
    }

    func overview() throws -> ArchiveOverview {
        let avatars = try avatarPaths()
        let details = try hasTable("conversation_details") ? "(SELECT payload FROM conversation_details d WHERE d.id=c.id)" : "NULL"
        let rows = try ReadStatement(connection, """
            SELECT c.id,c.name,c.folder,c.last_message,
              (SELECT count(*) FROM messages m WHERE m.conversation_id=c.id),
              (SELECT m.payload FROM messages m WHERE m.conversation_id=c.id ORDER BY timestamp DESC,id DESC LIMIT 1), \(details), c.unread
            FROM conversations c ORDER BY c.last_message DESC,c.id
            """)
        var conversations: [ConversationRecord] = []
        let decoder = JSONDecoder()
        while try rows.next() {
            let payload = rows.data(5)
            let preview: String
            if payload.isEmpty { preview = "No messages in the saved date range" }
            else { preview = try decoder.decode(MessageRecord.self, from: payload).preview }
            var participants = (try? decoder.decode([ConversationParticipant].self, from: rows.data(6))) ?? []
            if !avatars.isEmpty {
                for index in participants.indices { participants[index].avatarPath = avatars[participants[index].id] }
            }
            conversations.append(ConversationRecord(id: rows.text(0), name: rows.text(1), folder: rows.text(2), timestamp: rows.integer(3), preview: preview, messageCount: Int(rows.integer(4)), unread: rows.integer(7) != 0, participants: participants))
        }
        let stats = try ReadStatement(connection, "SELECT count(*),coalesce(max(timestamp),0) FROM messages")
        guard try stats.next() else { throw ArchiveFailure.reading }
        let count = Int(stats.integer(0)), newest = stats.integer(1)
        let media = try ReadStatement(connection, """
            SELECT count(*) FROM messages m,json_each(m.payload,'$.attachments') a
            WHERE json_extract(a.value,'$.state')='downloaded_original' AND json_extract(a.value,'$.mime') LIKE 'image/%'
            """)
        guard try media.next() else { throw ArchiveFailure.reading }
        return ArchiveOverview(conversations: conversations, messageCount: count, imageCount: Int(media.integer(0)), newest: newest > 0 ? Date(timeIntervalSince1970: Double(newest) / 1_000_000) : nil)
    }

    func latest(conversation: String) throws -> MessageWindow {
        let messages = try readMessages("WHERE conversation_id=? ORDER BY timestamp DESC,id DESC LIMIT 100", [.text(conversation)]).reversed()
        return try window(Array(messages), conversation: conversation)
    }

    func around(messageID: String, conversation: String) throws -> MessageWindow {
        let target = try readMessages("WHERE id=? AND conversation_id=?", [.text(messageID), .text(conversation)])
        guard let message = target.first else { return try latest(conversation: conversation) }
        let before = try readMessages("WHERE conversation_id=? AND (timestamp<? OR (timestamp=? AND id<?)) ORDER BY timestamp DESC,id DESC LIMIT 50", [.text(conversation), .integer(message.timestamp), .integer(message.timestamp), .text(message.id)])
        let after = try readMessages("WHERE conversation_id=? AND (timestamp>? OR (timestamp=? AND id>?)) ORDER BY timestamp,id LIMIT 50", [.text(conversation), .integer(message.timestamp), .integer(message.timestamp), .text(message.id)])
        return try window(Array(before.reversed()) + target + after, conversation: conversation)
    }

    func earlier(than message: MessageRecord) throws -> [MessageRecord] {
        Array(try readMessages("WHERE conversation_id=? AND (timestamp<? OR (timestamp=? AND id<?)) ORDER BY timestamp DESC,id DESC LIMIT 100", [.text(message.conversationID), .integer(message.timestamp), .integer(message.timestamp), .text(message.id)]).reversed())
    }

    func later(than message: MessageRecord) throws -> [MessageRecord] {
        try readMessages("WHERE conversation_id=? AND (timestamp>? OR (timestamp=? AND id>?)) ORDER BY timestamp,id LIMIT 100", [.text(message.conversationID), .integer(message.timestamp), .integer(message.timestamp), .text(message.id)])
    }

    func window(_ messages: [MessageRecord], conversation: String) throws -> MessageWindow {
        guard let first = messages.first, let last = messages.last else { return MessageWindow(messages: [], hasEarlier: false, hasLater: false) }
        let earlier = try scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND (timestamp<? OR (timestamp=? AND id<?)))", [.text(conversation), .integer(first.timestamp), .integer(first.timestamp), .text(first.id)])
        let later = try scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND (timestamp>? OR (timestamp=? AND id>?)))", [.text(conversation), .integer(last.timestamp), .integer(last.timestamp), .text(last.id)])
        return MessageWindow(messages: messages, hasEarlier: earlier == 1, hasLater: later == 1)
    }

    static func literalQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
    }

    func library(conversation: String, limit: Int) throws -> ConversationLibrary {
        let messages = try readMessages("WHERE conversation_id=? ORDER BY timestamp DESC,id DESC LIMIT ?", [.text(conversation), .integer(Int64(min(max(limit, 100), 100_000) + 1))])
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var result = ConversationLibrary()
        result.hasMore = messages.count > limit
        for message in messages.prefix(limit) {
            result.scanned += 1
            for file in message.attachments { result.files.append(SharedFile(message: message, attachment: file)) }
            var seen = Set<String>()
            let range = NSRange(message.body.startIndex..., in: message.body)
            for match in detector.matches(in: message.body, range: range) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url.absoluteString).inserted else { continue }
                result.links.append(SharedLink(message: message, url: url))
            }
        }
        return result
    }

    func cleanupPreview(before date: Date) throws -> Int {
        Int(try scalar("SELECT count(*) FROM messages WHERE timestamp<?", [.integer(Int64(date.timeIntervalSince1970 * 1_000_000))]))
    }

    func search(_ query: String, conversation: String?, limit: Int = 100) throws -> SearchPage {
        let literal = Self.literalQuery(query)
        guard !literal.isEmpty else { return SearchPage(messages: [], total: 0) }
        let scope = conversation ?? ""
        let bindings: [BoundValue] = [.text(literal), .text(scope), .text(scope)]
        let from = "FROM message_search JOIN messages m ON m.rowid=message_search.rowid WHERE message_search MATCH ? AND (?='' OR m.conversation_id=?)"
        let total = try scalar("SELECT count(*) " + from, bindings)
        let statement = try ReadStatement(connection, "SELECT m.timestamp,m.payload " + from + " ORDER BY m.timestamp DESC,m.id DESC LIMIT ?", bindings + [.integer(Int64(min(max(limit, 1), 10_000)))])
        return SearchPage(messages: try decodeMessages(statement), total: Int(total))
    }

    private func scalar(_ sql: String, _ values: [BoundValue]) throws -> Int64 {
        let statement = try ReadStatement(connection, sql, values)
        guard try statement.next() else { throw ArchiveFailure.reading }
        return statement.integer(0)
    }
    private func readMessages(_ suffix: String, _ values: [BoundValue]) throws -> [MessageRecord] {
        try decodeMessages(ReadStatement(connection, "SELECT timestamp,payload FROM messages " + suffix, values))
    }
    private func decodeMessages(_ statement: ReadStatement) throws -> [MessageRecord] {
        var messages: [MessageRecord] = []
        let decoder = JSONDecoder()
        while try statement.next() {
            var message = try decoder.decode(MessageRecord.self, from: statement.data(1))
            message.timestamp = statement.integer(0)
            messages.append(message)
        }
        return messages
    }
}
