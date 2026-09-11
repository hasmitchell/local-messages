import Foundation

struct ArchiveStorageUsage: Sendable, Equatable {
    var database: Int64 = 0
    var media: Int64 = 0
    var drafts: Int64 = 0
    var workingFiles: Int64 = 0
    var other: Int64 = 0
    var availableOnDrive: Int64?
    var incomplete = false
    var total: Int64 { database + media + drafts + workingFiles + other }
}

actor ArchiveStorageReader {
    func measure(directory: URL) throws -> ArchiveStorageUsage {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var result = ArchiveStorageUsage()
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
            result.incomplete = true
            return true
        }) else { throw CocoaError(.fileReadUnknown) }
        // Read filesystem metadata only; never open message or image contents.
        for case let file as URL in entries {
            try Task.checkCancellation()
            do {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { entries.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0))
                // Foundation may enumerate /var through its /private/var alias.
                // Normalize both sides before assigning a storage category.
                let path = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard path.starts(with: root.pathComponents) else { result.incomplete = true; continue }
                let components = Array(path.dropFirst(root.pathComponents.count))
                switch components.first {
                case "media": result.media += bytes
                case "drafts": result.drafts += bytes
                case "archive.db": result.database += bytes
                case "archive.db-wal", "archive.db-shm", "archive.db-journal": result.workingFiles += bytes
                default: result.other += bytes
                }
            } catch {
                // Sync can replace/remove a file during this approximate scan.
                if FileManager.default.fileExists(atPath: file.path) { result.incomplete = true }
            }
        }
        if let space = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            result.availableOnDrive = Int64(space)
        }
        return result
    }
}
