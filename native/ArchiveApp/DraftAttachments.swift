import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DraftAttachment: Codable, Sendable, Hashable, Identifiable {
    let id, name, mime, sha256: String
    let size: Int64
    static let byteLimit: Int64 = 25 * 1024 * 1024
}

actor AttachmentStager {
    func stage(urls: [URL], directory: URL, existing: [DraftAttachment]) throws -> [DraftAttachment] {
        guard existing.count + urls.count <= 10 else { throw AttachmentFailure.limit }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("drafts/attachments", isDirectory: true)
        // Compare canonical paths, not URL identity (picker URLs may carry a
        // base URL or cached resource metadata).
        guard folder.resolvingSymlinksInPath().path == folder.path else { throw AttachmentFailure.storage }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.deletingLastPathComponent().path)
        } catch { throw AttachmentFailure.storage }
        var staged: [DraftAttachment] = []
        var total = existing.reduce(Int64(0)) { $0 + $1.size }
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file: FileHandle
                do { file = try FileHandle(forReadingFrom: url) }
                catch { throw AttachmentFailure.reading }
                defer { try? file.close() }
                // The picker can cache an old size for a downloaded or replaced
                // image. Inspect the opened file, and read until EOF: a single
                // read(upToCount:) is allowed to return only part of a file.
                var attributes = stat()
                guard fstat(file.fileDescriptor, &attributes) == 0 else { throw AttachmentFailure.reading }
                guard attributes.st_mode & S_IFMT == S_IFREG else { throw AttachmentFailure.notAFile }
                guard attributes.st_size > 0 else { throw AttachmentFailure.empty }
                guard Int64(attributes.st_size) <= DraftAttachment.byteLimit - total else { throw AttachmentFailure.limit }
                var data = Data()
                do {
                    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                        guard Int64(data.count + chunk.count) <= DraftAttachment.byteLimit - total else { throw AttachmentFailure.limit }
                        data.append(chunk)
                    }
                } catch let error as AttachmentFailure { throw error }
                catch { throw AttachmentFailure.reading }
                guard data.count == attributes.st_size else { throw AttachmentFailure.changed }
                total += Int64(data.count)
                let name = url.lastPathComponent
                guard name.utf8.count <= 255, !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AttachmentFailure.name }
                let info = DraftAttachment(id: UUID().uuidString.lowercased(), name: name,
                    mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: Int64(data.count))
                let target = folder.appendingPathComponent(info.id)
                do {
                    try data.write(to: target, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    throw AttachmentFailure.storage
                }
                staged.append(info)
            }
            return staged
        } catch {
            for file in staged { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.id)) }
            throw error
        }
    }
}

enum AttachmentFailure: LocalizedError {
    case limit, reading, storage, notAFile, empty, changed, name
    var errorDescription: String? {
        switch self {
        case .limit: "Choose up to 10 files, with a combined size of 25 MB or less. Your phone or carrier may have a lower limit."
        case .reading: "This file could not be read. Check that it is downloaded and you can open it in Finder, then choose it again."
        case .storage: "The attachment could not be saved in this archive. Check the archive folder’s permissions and available disk space."
        case .notAFile: "Choose a photo or file, rather than a folder."
        case .empty: "This file is empty. Wait for it to finish saving, then choose it again."
        case .changed: "This file changed while it was being attached. Wait for it to finish saving, then choose it again."
        case .name: "This filename is too long or contains unsupported characters. Rename the file and choose it again."
        }
    }
}
