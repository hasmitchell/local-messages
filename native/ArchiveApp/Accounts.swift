import Foundation

struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let path: String
    var setupComplete: Bool
    var directory: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

// Names are user-chosen labels. Google credentials remain in the per-directory
// Keychain entry; an existing archive is registered in place, never moved.
final class AccountStore {
    private struct Catalog: Codable { var version = 1; var profiles: [AccountProfile] }
    let root: URL
    private(set) var profiles: [AccountProfile]
    private var file: URL { root.appendingPathComponent("accounts.json") }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.GoogleMessagingAppMac.viewer", isDirectory: true)
    }
    init(root: URL = defaultRoot) throws {
        self.root = root.standardizedFileURL
        profiles = []
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 128 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            guard catalog.version == 1, catalog.profiles.count <= 100,
                  Set(catalog.profiles.map(\.id)).count == catalog.profiles.count,
                  Set(catalog.profiles.map { Self.key($0.directory) }).count == catalog.profiles.count,
                  catalog.profiles.allSatisfy({ Self.validName($0.name) && $0.path.hasPrefix("/") }) else { throw CocoaError(.fileReadCorruptFile) }
            profiles = catalog.profiles
        }
    }
    static func key(_ directory: URL) -> String { directory.standardizedFileURL.resolvingSymlinksInPath().path }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    func profile(at directory: URL) -> AccountProfile? { profiles.first { Self.key($0.directory) == Self.key(directory) } }
    private func commit(_ updated: [AccountProfile]) throws {
        guard updated.count <= 100 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try JSONEncoder().encode(Catalog(profiles: updated)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        profiles = updated
    }
    @discardableResult func register(directory: URL, name: String? = nil) throws -> AccountProfile {
        if let existing = profile(at: directory) { return existing }
        let profile = AccountProfile(id: UUID(), name: name ?? (profiles.isEmpty ? "Personal" : "Account \(profiles.count + 1)"), path: directory.standardizedFileURL.path, setupComplete: true)
        guard Self.validName(profile.name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try commit(profiles + [profile])
        return profile
    }
    func createPending(name: String) throws -> AccountProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let id = UUID()
        let directory = root.appendingPathComponent("Archives", isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = AccountProfile(id: id, name: name, path: directory.path, setupComplete: false)
        try commit(profiles + [profile])
        return profile
    }
    func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name), let index = profiles.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileWriteInvalidFileName) }
        var changed = profiles; changed[index].name = name
        try commit(changed)
    }
    func complete(_ id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var changed = profiles; changed[index].setupComplete = true
        try commit(changed)
    }
}

// Explicit archive arguments win; normal launches restore the last selection.
enum AccountLaunch {
    static func directory(arguments: [String], savedPath: String?, profiles: [AccountProfile]) -> URL? {
        func argument(_ flag: String) -> URL? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let explicit = argument("--archive") { return explicit }
        if let savedPath { return URL(fileURLWithPath: savedPath, isDirectory: true) }
        if let profile = profiles.first(where: { $0.setupComplete }) { return profile.directory }
        if let fallback = argument("--default-archive"), FileManager.default.fileExists(atPath: fallback.appendingPathComponent("archive.db").path) { return fallback }
        return nil
    }
}
