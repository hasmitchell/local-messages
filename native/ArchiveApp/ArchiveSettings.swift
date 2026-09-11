import Foundation

struct ArchiveSettings: Codable, Sendable, Hashable {
    var historySince: String
    var retentionDays: Int
    enum CodingKeys: String, CodingKey { case historySince = "history_since", retentionDays = "retention_days" }
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }
    static var initial: ArchiveSettings {
        ArchiveSettings(historySince: dateString(Calendar.current.date(byAdding: .year, value: -1, to: Date())!), retentionDays: 0)
    }
    var date: Date { Self.parseDate(historySince) ?? Date() }
    var valid: Bool { Self.parseDate(historySince).map { $0 >= Self.parseDate("2000-01-01")! && $0 <= Date() } == true && (0...36500).contains(retentionDays) }
    var cleanupDate: Date? {
        guard retentionDays > 0 else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(byAdding: .day, value: -retentionDays, to: utc.startOfDay(for: Date()))
    }
}

actor SettingsRepository {
    private func location(_ directory: URL) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent("settings.json")
        guard file.resolvingSymlinksInPath() == file else { throw CocoaError(.fileWriteInvalidFileName) }
        return file
    }
    func load(directory: URL) throws -> ArchiveSettings {
        let file = try location(directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return .initial }
        let data = try Data(contentsOf: file)
        guard data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: data)
        guard settings.valid else { throw CocoaError(.fileReadCorruptFile) }
        return settings
    }
    func save(_ settings: ArchiveSettings, directory: URL) throws {
        guard settings.valid else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = try location(directory)
        try JSONEncoder().encode(settings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
